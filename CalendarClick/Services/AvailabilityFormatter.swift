import Foundation

struct AvailabilityFormatter {
    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Formats availability slots into human-readable text for pasting.
    /// Pure function — no side effects.
    func format(
        slots: [Date: [TimeSlot]],
        showTimeZone: Bool = false
    ) -> String {
        guard !slots.isEmpty else { return "" }

        let sortedDays = slots.keys.sorted()
        var lines: [String] = []

        for day in sortedDays {
            guard let daySlots = slots[day], !daySlots.isEmpty else { continue }
            let sortedSlots = daySlots.sorted { $0.start < $1.start }
            let dayLabel = dateFormatter.string(from: day)
            let timeParts = sortedSlots.map { formatTimeRange($0) }
            lines.append("\(dayLabel): \(timeParts.joined(separator: ", "))")
        }

        if showTimeZone, let tz = TimeZone.current.abbreviation() {
            lines.append("(\(tz))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Time Range Formatting

    func formatTimeRange(_ slot: TimeSlot) -> String {
        let startHour = calendar.component(.hour, from: slot.start)
        let startMinute = calendar.component(.minute, from: slot.start)
        let endHour = calendar.component(.hour, from: slot.end)
        let endMinute = calendar.component(.minute, from: slot.end)

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

    /// Converts 24-hour to 12-hour display. 0 → 12, 13 → 1, etc.
    private func displayHour(from hour24: Int) -> Int {
        let h = hour24 % 12
        return h == 0 ? 12 : h
    }

    /// Returns "am" or "pm" for a 24-hour value. Hour 12-23 = pm, 0-11 = am.
    private func period(for hour24: Int) -> String {
        hour24 >= 12 ? "pm" : "am"
    }
}
