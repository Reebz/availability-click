import AppKit
import Foundation

enum FormatTemplate {
    case plainText
    case markdown
}

struct AvailabilityFormatter {
    // Computed so a system timezone change mid-run is picked up immediately
    // (Calendar.current is a frozen snapshot, unlike autoupdatingCurrent).
    private var calendar: Calendar { Calendar.current }

    /// Drives the hour cycle and day-label order (KTD5). Defaults to
    /// autoupdatingCurrent so a live locale change takes effect without
    /// relaunch -- mirroring the computed calendar above. Tests pin fixed
    /// locales for deterministic golden strings.
    var locale: Locale = .autoupdatingCurrent

    /// 24h locales get 24-hour output with no am/pm periods. Detected via
    /// the typed hourCycle API, not the dateFormat(fromTemplate: "j") sniff.
    private var uses24HourClock: Bool {
        switch locale.hourCycle {
        case .zeroToTwentyThree, .oneToTwentyFour:
            return true
        case .zeroToEleven, .oneToTwelve:
            return false
        @unknown default:
            return false
        }
    }

    /// Formats availability slots into human-readable text for pasting.
    /// Pure function — no side effects.
    func format(
        slots: [Date: [TimeSlot]],
        showTimeZone: Bool = false,
        template: FormatTemplate = .plainText,
        timezone: TimeZone? = nil,
        asOf: Date? = nil
    ) -> String {
        guard !slots.isEmpty else { return "" }

        let effectiveCalendar = calendar(for: timezone)
        var lines: [String] = []

        for line in dayLines(slots: slots, using: effectiveCalendar) {
            switch template {
            case .plainText:
                lines.append("\(line.label): \(line.times)")
            case .markdown:
                lines.append("- **\(line.label):** \(line.times)")
            }
        }

        if showTimeZone {
            lines.append("(\(Self.timezoneString(for: timezone)))")
        }
        if let asOf {
            lines.append(asOfLine(asOf, timezone: timezone))
        }

        return lines.joined(separator: "\n")
    }

    /// Rich-flavor rendering of the plain-text template: bold day labels,
    /// plain times (KTD4). The markdown template never goes through here --
    /// its syntax IS the artifact and stays pure plain text.
    func formatAttributed(
        slots: [Date: [TimeSlot]],
        showTimeZone: Bool = false,
        timezone: TimeZone? = nil,
        asOf: Date? = nil
    ) -> NSAttributedString {
        guard !slots.isEmpty else { return NSAttributedString() }

        let effectiveCalendar = calendar(for: timezone)
        let fontSize = NSFont.systemFontSize
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize)]
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]

        let result = NSMutableAttributedString()
        for line in dayLines(slots: slots, using: effectiveCalendar) {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: plain))
            }
            result.append(NSAttributedString(string: "\(line.label):", attributes: bold))
            result.append(NSAttributedString(string: " \(line.times)", attributes: plain))
        }

        if showTimeZone {
            result.append(NSAttributedString(
                string: "\n(\(Self.timezoneString(for: timezone)))",
                attributes: plain
            ))
        }
        if let asOf {
            result.append(NSAttributedString(
                string: "\n\(asOfLine(asOf, timezone: timezone))",
                attributes: plain
            ))
        }

        return result
    }

    // MARK: - As-Of Stamp

    /// The optional issuance stamp appended as the final line (R4): "(as of
    /// <date>, <time>)" in the formatter's locale and the effective (recipient
    /// or system) timezone, so it reads consistently with the slot times above
    /// it. Both renderers call this so they can't drift.
    ///
    /// Date and time are formatted separately and joined with an explicit ", "
    /// rather than a combined date+time style: the OS-chosen join drifts
    /// between " at " and "," across macOS versions (CI is macOS 15, dev is
    /// newer), which would make golden strings version-dependent. The
    /// narrow/no-break spaces some locales insert before AM/PM are normalized
    /// to a plain space for the same reason and for cleaner pasted text.
    private func asOfLine(_ date: Date, timezone: TimeZone?) -> String {
        let tz = timezone ?? TimeZone.current
        let dateF = DateFormatter()
        dateF.locale = locale
        dateF.timeZone = tz
        dateF.dateStyle = .medium
        dateF.timeStyle = .none
        let timeF = DateFormatter()
        timeF.locale = locale
        timeF.timeZone = tz
        timeF.dateStyle = .none
        timeF.timeStyle = .short
        let stamp = "\(dateF.string(from: date)), \(timeF.string(from: date))"
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return "(as of \(stamp))"
    }

    // MARK: - Proposal Sentence (U4)

    /// Renders the pre-selected proposal slots as one numbered sentence (R1/R2)
    /// rather than the day grid — a different shape, so it lives outside the
    /// FormatTemplate switch. Two or three slots read "reply with a number"; a
    /// single slot drops that phrasing (R2 honest framing). The trailing
    /// timezone and "as of" lines match the grid renderer (they reuse the same
    /// helpers), so the recipient timezone flows through consistently.
    func formatProposal(
        slots: [TimeSlot],
        showTimeZone: Bool = false,
        timezone: TimeZone? = nil,
        asOf: Date? = nil
    ) -> String {
        guard !slots.isEmpty else { return "" }

        let effectiveCalendar = calendar(for: timezone)
        let labelFormatter = dayLabelFormatter(timeZone: effectiveCalendar.timeZone)
        let sorted = slots.sorted { $0.start < $1.start }

        func describe(_ slot: TimeSlot) -> String {
            "\(labelFormatter.string(from: slot.start)), \(formatTimeRange(slot, using: effectiveCalendar))"
        }

        var lines: [String] = []
        if sorted.count == 1 {
            lines.append("Here's a time that could work: \(describe(sorted[0])).")
        } else {
            let items = sorted.enumerated().map { "\($0.offset + 1)) \(describe($0.element))" }
            lines.append("Here are a few times that could work — reply with a number: \(items.joined(separator: "; ")).")
        }

        if showTimeZone {
            lines.append("(\(Self.timezoneString(for: timezone)))")
        }
        if let asOf {
            lines.append(asOfLine(asOf, timezone: timezone))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Shared Line Building

    private func calendar(for timezone: TimeZone?) -> Calendar {
        guard let tz = timezone else { return calendar }
        var cal = Calendar.current
        cal.timeZone = tz
        return cal
    }

    /// One rendered day per element: label ("Wed Mar 25") and its time list
    /// ("9-10:30am, 2-3pm"). Shared by the plain and attributed renderers so
    /// their content can never drift apart.
    private func dayLines(
        slots: [Date: [TimeSlot]],
        using effectiveCalendar: Calendar
    ) -> [(label: String, times: String)] {
        // Day labels and grouping must follow the recipient timezone too, or a
        // converted time gets paired with the sender-local day name (Sydney
        // Tue 9am shown as "Tue ... 7pm" when it is Monday evening in New
        // York). A slot lists under the recipient-local day of its START time
        // -- slots spanning the recipient's midnight are not split.
        var groupedSlots: [Date: [TimeSlot]] = [:]
        for daySlots in slots.values {
            for slot in daySlots {
                let day = effectiveCalendar.startOfDay(for: slot.start)
                groupedSlots[day, default: []].append(slot)
            }
        }
        let labelFormatter = dayLabelFormatter(timeZone: effectiveCalendar.timeZone)

        return groupedSlots.keys.sorted().compactMap { day in
            guard let daySlots = groupedSlots[day], !daySlots.isEmpty else { return nil }
            let sortedSlots = daySlots.sorted { $0.start < $1.start }
            let label = labelFormatter.string(from: day)
            let times = sortedSlots
                .map { formatTimeRange($0, using: effectiveCalendar) }
                .joined(separator: ", ")
            return (label, times)
        }
    }

    /// Day labels are hand-assembled from locale-ordered components (OQ8):
    /// Date.FormatStyle inserts a comma in en_US ("Wed, Mar 25"), which would
    /// break every shipped golden string. The locale's own "MMMd" template
    /// decides day-first vs month-first; names come from the locale.
    private func dayLabelFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        let template = DateFormatter.dateFormat(
            fromTemplate: "MMMd", options: 0, locale: locale
        ) ?? "MMM d"
        f.dateFormat = Self.dayPrecedesMonth(inTemplate: template) ? "EEE d MMM" : "EEE MMM d"
        f.timeZone = timeZone
        return f
    }

    /// Internal for tests. Some locales answer the "MMMd" skeleton with the
    /// standalone month symbol "L" (e.g. Persian: "d LLL"), so probing only
    /// for "M" would misread a day-first locale as month-first.
    static func dayPrecedesMonth(inTemplate template: String) -> Bool {
        guard let dayIndex = template.firstIndex(of: "d"),
              let monthIndex = template.firstIndex(where: { $0 == "M" || $0 == "L" }) else {
            return false
        }
        return dayIndex < monthIndex
    }

    // MARK: - Time Range Formatting

    func formatTimeRange(_ slot: TimeSlot) -> String {
        formatTimeRange(slot, using: calendar)
    }

    func formatTimeRange(_ slot: TimeSlot, using cal: Calendar) -> String {
        let startHour = cal.component(.hour, from: slot.start)
        let startMinute = cal.component(.minute, from: slot.start)
        let endHour = cal.component(.hour, from: slot.end)
        let endMinute = cal.component(.minute, from: slot.end)

        // 24h is a real branch (KTD5): no am/pm periods, no same-period
        // suffix elision. "14-15" on the hour, "14:30-16:00" otherwise.
        if uses24HourClock {
            let bothOnTheHour = startMinute == 0 && endMinute == 0
            let startStr = format24Hour(hour: startHour, minute: startMinute, forceMinutes: !bothOnTheHour)
            let endStr = format24Hour(hour: endHour, minute: endMinute, forceMinutes: !bothOnTheHour)
            return "\(startStr)-\(endStr)"
        }

        let startPeriod = period(for: startHour)
        let endPeriod = period(for: endHour)
        let samePeriod = startPeriod == endPeriod

        let startStr = formatTime(hour: startHour, minute: startMinute, includeSuffix: !samePeriod)
        let endStr = formatTime(hour: endHour, minute: endMinute, includeSuffix: true)

        return "\(startStr)-\(endStr)"
    }

    // MARK: - Single Time Formatting

    private func formatTime(hour: Int, minute: Int, includeSuffix: Bool) -> String {
        let displayHour = displayHour(from: hour)
        let suffix = includeSuffix ? period(for: hour) : ""

        if minute == 0 {
            return "\(displayHour)\(suffix)"
        } else {
            return "\(displayHour):\(String(format: "%02d", minute))\(suffix)"
        }
    }

    private func format24Hour(hour: Int, minute: Int, forceMinutes: Bool) -> String {
        if forceMinutes {
            return "\(hour):\(String(format: "%02d", minute))"
        }
        return "\(hour)"
    }

    /// Converts 24-hour to 12-hour display. 0 → 12, 13 → 1, etc.
    private func displayHour(from hour24: Int) -> Int {
        let h = hour24 % 12
        return h == 0 ? 12 : h
    }

    /// Returns "am" or "pm" for a 24-hour value. Hour 12-23 = pm, 0-11 = am.
    private func period(for hour24: Int) -> String {
        hour24 >= 12 ? "pm" : "am"
    }

    /// Builds a timezone label like "Germany Time, GMT+2" (R3): a
    /// human-readable zone name plus exactly one GMT offset. The old code used
    /// `abbreviation()`, which returns the offset form ("GMT+2") for most
    /// zones and rendered a duplicated "(GMT+2, GMT+2)". The name now comes
    /// from `localizedZoneName` (KTD8); the offset is appended once.
    static func timezoneString(for timezone: TimeZone? = nil) -> String {
        let tz = timezone ?? TimeZone.current
        let seconds = tz.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        let gmtOffset: String
        if minutes == 0 {
            gmtOffset = String(format: "GMT%+d", hours)
        } else {
            gmtOffset = String(format: "GMT%+d:%02d", hours, minutes)
        }
        return "\(localizedZoneName(for: tz)), \(gmtOffset)"
    }

    /// The human-readable half of `timezoneString` (KTD8 fallback chain).
    /// `.shortGeneric` gives names like "Germany Time"/"India Time"; a NIL
    /// locale silently returns the GMT-offset form instead (verified), so the
    /// locale is always explicit. `.shortGeneric` can be nil for some
    /// zone/locale pairs (e.g. bare fixed-offset zones), so it falls through
    /// `.generic` and finally `abbreviation()`. Internal so tests exercise the
    /// chain directly.
    static func localizedZoneName(for tz: TimeZone) -> String {
        if let short = tz.localizedName(for: .shortGeneric, locale: .current), !short.isEmpty {
            return short
        }
        if let generic = tz.localizedName(for: .generic, locale: .current), !generic.isEmpty {
            return generic
        }
        return tz.abbreviation() ?? "UTC"
    }
}
