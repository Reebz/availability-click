@preconcurrency import EventKit
import Foundation

enum DateRangeType: Equatable {
    case thisWeek
    case businessDays(Int)
    case nextWeek
    case nextFortnight
    case next30Days
    /// Proposal window (U4): 30 calendar days starting today (not tomorrow),
    /// so a proposal can offer today's remaining slots. Internal to the
    /// proposal path — not exposed by the menu or the Shortcuts intent.
    case next30DaysIncludingToday
}

/// Seam over EKEvent so the busy/free decision matrix is unit-testable:
/// EKEvent's `status` and `attendees` are read-only, so tests cannot
/// construct the canceled/declined branches on the real type (R4).
protocol BlockableEvent {
    var isAllDay: Bool { get }
    var eventStart: Date { get }
    var eventEnd: Date { get }
    var isCanceled: Bool { get }
    var isFreeAvailability: Bool { get }
    var isDeclinedByCurrentUser: Bool { get }
}

extension EKEvent: BlockableEvent {
    var eventStart: Date { startDate }
    var eventEnd: Date { endDate }
    var isCanceled: Bool { status == .canceled }
    var isFreeAvailability: Bool { availability == .free }
    var isDeclinedByCurrentUser: Bool {
        guard let attendees, !attendees.isEmpty,
              let me = attendees.first(where: { $0.isCurrentUser }) else { return false }
        return me.participantStatus == .declined
    }
}

struct AvailabilityService {
    // Computed so a system timezone change mid-run is picked up immediately
    // (Calendar.current is a frozen snapshot, unlike autoupdatingCurrent).
    private var calendar: Calendar { Calendar.current }

    // MARK: - Public API

    func calculateAvailability(
        events: [EKEvent],
        rangeType: DateRangeType,
        now: Date = Date()
    ) -> [Date: [TimeSlot]] {
        let workingDays = Set(AppSettings.workingDays)
        let startMinutes = AppSettings.workingHoursStart
        let endMinutes = AppSettings.workingHoursEnd
        let bufferMinutes = AppSettings.todayBufferMinutes
        let eventBufferMinutes = AppSettings.eventBufferMinutes
        let minimumSlot = TimeInterval(AppSettings.minimumSlotMinutes * 60)

        guard endMinutes > startMinutes else { return [:] }

        let days = businessDaysForRange(rangeType, from: now, workingDays: workingDays)
        let filteredEvents = events.filter { shouldBlockTime($0) }

        // Clamp event slicing to the requested day range: fetched events only
        // need to OVERLAP the window, so a far-future endDate would otherwise
        // walk the slicing loop for years on the main actor.
        let rangeStart = days.first.map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: now)
        let rangeEnd = days.last.flatMap {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
        } ?? rangeStart
        let eventsByDay = groupEventsByDay(filteredEvents, clampedTo: rangeStart..<rangeEnd)

        var result: [Date: [TimeSlot]] = [:]
        let today = calendar.startOfDay(for: now)

        for day in days {
            let dayStart = calendar.startOfDay(for: day)
            var workStart = dateFromMinutes(startMinutes, on: dayStart)
            let workEnd = dateFromMinutes(endMinutes, on: dayStart)

            // Apply today buffer
            if calendar.isDate(dayStart, inSameDayAs: today) {
                let buffered = now.addingTimeInterval(TimeInterval(bufferMinutes * 60))
                workStart = max(workStart, buffered)
                if workStart >= workEnd { continue }
            }

            let dayEvents = paddedBlockingEvents(eventsByDay[dayStart] ?? [], byMinutes: eventBufferMinutes)
            let freeSlots = subtractEvents(
                from: TimeSlot(start: workStart, end: workEnd),
                events: dayEvents,
                workStart: dateFromMinutes(startMinutes, on: dayStart),
                workEnd: workEnd
            )

            // Round slot boundaries to configured granularity
            let granularity = AppSettings.roundingGranularity
            let roundedSlots: [TimeSlot]
            if granularity > 0 {
                roundedSlots = freeSlots.compactMap { slot in
                    let roundedStart = roundUp(slot.start, toMinutes: granularity)
                    let roundedEnd = roundDown(slot.end, toMinutes: granularity)
                    guard roundedStart < roundedEnd else { return nil }
                    return TimeSlot(start: roundedStart, end: roundedEnd)
                }
            } else {
                roundedSlots = freeSlots
            }

            let viable = roundedSlots.filter { $0.duration >= minimumSlot }
            if !viable.isEmpty {
                result[dayStart] = viable
            }
        }

        return result
    }

    // MARK: - Event Filtering

    func shouldBlockTime(_ event: some BlockableEvent) -> Bool {
        if event.isAllDay { return false }
        if isEffectivelyAllDay(event) { return false }
        if event.isCanceled { return false }
        if event.isFreeAvailability { return false }
        if event.isDeclinedByCurrentUser { return false }
        return true
    }

    // MARK: - Fetch Window

    /// Derives the fetch window from the same day list the availability math
    /// will report on. A fixed window can undershoot it (an evening click or
    /// sparse working days push the Nth business day past today+7) and a day
    /// with no fetched events reads as fully free. Shared by the click
    /// pipeline and the Shortcuts intent so the two can never diverge.
    func fetchWindow(for rangeType: DateRangeType, now: Date = Date()) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let days = businessDaysForRange(
            rangeType,
            from: now,
            workingDays: Set(AppSettings.workingDays)
        )

        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else {
            let fallbackEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
            return (today, fallbackEnd)
        }

        return (min(today, calendar.startOfDay(for: first)), end)
    }

    // MARK: - Date Range Calculation

    func businessDaysForRange(
        _ rangeType: DateRangeType,
        from now: Date,
        workingDays: Set<Int>
    ) -> [Date] {
        let today = calendar.startOfDay(for: now)

        switch rangeType {
        case .thisWeek:
            return thisWeekDays(from: today, workingDays: workingDays, now: now)

        case .businessDays(let count):
            return nextNBusinessDays(count, from: today, workingDays: workingDays, now: now)

        case .nextWeek:
            return nextWeekDays(from: today, workingDays: workingDays)

        case .nextFortnight:
            return fortnightDays(from: today, workingDays: workingDays)

        case .next30Days:
            return next30CalendarDays(from: today, workingDays: workingDays)

        case .next30DaysIncludingToday:
            return next30CalendarDaysIncludingToday(from: today, workingDays: workingDays, now: now)
        }
    }

    private func thisWeekDays(from today: Date, workingDays: Set<Int>, now: Date) -> [Date] {
        // Get Monday of current week
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday - 2 + 7) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else { return [] }

        var days: [Date] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
            let wd = calendar.component(.weekday, from: day)
            if workingDays.contains(wd) && day >= today {
                // Skip today once the buffered "now" leaves no viable window
                // (mirrors nextNBusinessDays) so the auto-roll below can fire
                // on a Friday-evening click as the README promises.
                if calendar.isDate(day, inSameDayAs: today) {
                    let buffered = now.addingTimeInterval(TimeInterval(AppSettings.todayBufferMinutes * 60))
                    let workEnd = dateFromMinutes(AppSettings.workingHoursEnd, on: day)
                    if buffered >= workEnd { continue }
                }
                days.append(day)
            }
        }

        // Auto-roll to next week if current week is exhausted
        if days.isEmpty {
            return nextWeekDays(from: today, workingDays: workingDays)
        }

        return days
    }

    private func nextNBusinessDays(_ n: Int, from today: Date, workingDays: Set<Int>, now: Date) -> [Date] {
        // An empty (or entirely invalid) working-days set would make the walk
        // below spin forever on the main actor -- the Settings toggles allow
        // unchecking all seven days.
        guard !workingDays.isEmpty else { return [] }

        var days: [Date] = []
        var cursor = today
        var iterations = 0
        let bufferMinutes = AppSettings.todayBufferMinutes
        let endMinutes = AppSettings.workingHoursEnd

        while days.count < n && iterations < 366 {
            iterations += 1
            let wd = calendar.component(.weekday, from: cursor)
            if workingDays.contains(wd) {
                // Check if today still has viable time
                if calendar.isDate(cursor, inSameDayAs: today) {
                    let buffered = now.addingTimeInterval(TimeInterval(bufferMinutes * 60))
                    let workEnd = dateFromMinutes(endMinutes, on: cursor)
                    if buffered < workEnd {
                        days.append(cursor)
                    }
                } else {
                    days.append(cursor)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return days
    }

    private func nextWeekDays(from today: Date, workingDays: Set<Int>) -> [Date] {
        // Find next Monday
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilNextMonday = (9 - weekday) % 7
        let offset = daysUntilNextMonday == 0 ? 7 : daysUntilNextMonday
        guard let nextMonday = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }

        var days: [Date] = []
        for i in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: i, to: nextMonday) else { continue }
            let wd = calendar.component(.weekday, from: day)
            if workingDays.contains(wd) {
                days.append(day)
            }
        }
        return days
    }

    private func fortnightDays(from today: Date, workingDays: Set<Int>) -> [Date] {
        // 14 calendar days starting from next Monday
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilNextMonday = (9 - weekday) % 7
        let offset = daysUntilNextMonday == 0 ? 7 : daysUntilNextMonday
        guard let nextMonday = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }

        var days: [Date] = []
        for i in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: i, to: nextMonday) else { continue }
            let wd = calendar.component(.weekday, from: day)
            if workingDays.contains(wd) {
                days.append(day)
            }
        }
        return days
    }

    private func next30CalendarDays(from today: Date, workingDays: Set<Int>) -> [Date] {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        var days: [Date] = []
        for i in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: i, to: tomorrow) else { continue }
            let wd = calendar.component(.weekday, from: day)
            if workingDays.contains(wd) {
                days.append(day)
            }
        }
        return days
    }

    /// Like `next30CalendarDays` but starting TODAY (U4 proposal window):
    /// working days only, and today is included only when the today-buffer
    /// leaves viable time — mirroring how business-day ranges treat today.
    private func next30CalendarDaysIncludingToday(
        from today: Date, workingDays: Set<Int>, now: Date
    ) -> [Date] {
        var days: [Date] = []
        for i in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: i, to: today) else { continue }
            let wd = calendar.component(.weekday, from: day)
            guard workingDays.contains(wd) else { continue }
            if calendar.isDate(day, inSameDayAs: today) {
                let buffered = now.addingTimeInterval(TimeInterval(AppSettings.todayBufferMinutes * 60))
                let workEnd = dateFromMinutes(AppSettings.workingHoursEnd, on: day)
                if buffered >= workEnd { continue }
            }
            days.append(day)
        }
        return days
    }

    // MARK: - Proposal Selection (U4)

    /// Picks up to `count` well-spread slots for the proposal sentence (KTD6):
    /// the earliest slot on each of the first `count` distinct days with
    /// availability; when distinct days run out, additional slots on
    /// already-used days (earliest first) fill the remainder. Pure and static —
    /// consumes the normal post-pipeline dictionary, so it inherits the event
    /// buffer, rounding and min-slot filtering and never re-derives
    /// availability.
    static func selectProposalSlots(from slots: [Date: [TimeSlot]], count: Int) -> [TimeSlot] {
        guard count > 0 else { return [] }
        let sortedDays = slots.keys.sorted()

        var chosen: [TimeSlot] = []
        for day in sortedDays {
            guard chosen.count < count else { break }
            if let earliest = slots[day]?.min(by: { $0.start < $1.start }) {
                chosen.append(earliest)
            }
        }

        // Fewer than `count` distinct days: fall back to the later slots on the
        // days already used, earliest first (dropFirst skips each day's already
        // chosen earliest).
        if chosen.count < count {
            var extras: [TimeSlot] = []
            for day in sortedDays {
                guard let daySlots = slots[day] else { continue }
                extras.append(contentsOf: daySlots.sorted { $0.start < $1.start }.dropFirst())
            }
            for slot in extras.sorted(by: { $0.start < $1.start }) {
                guard chosen.count < count else { break }
                chosen.append(slot)
            }
        }

        return chosen.sorted { $0.start < $1.start }
    }

    // MARK: - Event Buffer Padding

    /// Pads every blocking interval by `bufferMinutes` on each side before
    /// subtraction (R7), so an offered slot never starts or ends flush against
    /// a meeting. Pure; runs only on already-filtered blocking events, so
    /// non-blocking ones (all-day, declined, free) are never padded into false
    /// busy time. `subtractEvents` clamps the expanded intervals back to
    /// `[workStart, workEnd]`, so an event abutting the window edge can't leave
    /// an overhang or a negative-duration slot; overlapping pads subtract
    /// cleanly (same interval-difference path as ordinary overlapping events).
    func paddedBlockingEvents(_ events: [TimeSlot], byMinutes bufferMinutes: Int) -> [TimeSlot] {
        guard bufferMinutes > 0 else { return events }
        let pad = TimeInterval(bufferMinutes * 60)
        return events.map {
            TimeSlot(start: $0.start.addingTimeInterval(-pad), end: $0.end.addingTimeInterval(pad))
        }
    }

    // MARK: - Slot Subtraction

    func subtractEvents(
        from freeBlock: TimeSlot,
        events: [TimeSlot],
        workStart: Date,
        workEnd: Date
    ) -> [TimeSlot] {
        var freeBlocks = [freeBlock]
        let sorted = events.sorted { $0.start < $1.start }

        for event in sorted {
            // Clamp event to working hours
            let clampedStart = max(event.start, workStart)
            let clampedEnd = min(event.end, workEnd)
            guard clampedStart < clampedEnd else { continue }

            var newBlocks: [TimeSlot] = []
            for block in freeBlocks {
                // No overlap
                if clampedEnd <= block.start || clampedStart >= block.end {
                    newBlocks.append(block)
                    continue
                }
                // Left remainder
                if clampedStart > block.start {
                    newBlocks.append(TimeSlot(start: block.start, end: clampedStart))
                }
                // Right remainder
                if clampedEnd < block.end {
                    newBlocks.append(TimeSlot(start: clampedEnd, end: block.end))
                }
            }
            freeBlocks = newBlocks
        }

        return freeBlocks
    }

    // MARK: - Rounding

    /// Rounds a date up to the next multiple of `minutes`. Returns the date unchanged if already on a boundary.
    func roundUp(_ date: Date, toMinutes minutes: Int) -> Date {
        guard minutes > 0 else { return date }
        let comps = calendar.dateComponents([.minute], from: calendar.startOfDay(for: date), to: date)
        let totalMinutes = comps.minute ?? 0
        let remainder = totalMinutes % minutes
        if remainder == 0 { return date }
        let minutesToAdd = minutes - remainder
        return calendar.date(byAdding: .minute, value: minutesToAdd, to: date)!
    }

    /// Rounds a date down to the previous multiple of `minutes`. Returns the date unchanged if already on a boundary.
    func roundDown(_ date: Date, toMinutes minutes: Int) -> Date {
        guard minutes > 0 else { return date }
        let comps = calendar.dateComponents([.minute], from: calendar.startOfDay(for: date), to: date)
        let totalMinutes = comps.minute ?? 0
        let remainder = totalMinutes % minutes
        if remainder == 0 { return date }
        return calendar.date(byAdding: .minute, value: -remainder, to: date)!
    }

    // MARK: - Helpers

    func isEffectivelyAllDay(_ event: some BlockableEvent) -> Bool {
        let startMidnight = calendar.startOfDay(for: event.eventStart) == event.eventStart
        let endMidnight = calendar.startOfDay(for: event.eventEnd) == event.eventEnd
        // Compare by day span, not fixed seconds: a DST spring-forward day is
        // only 23 hours, and a midnight-to-midnight event on it is still all-day.
        return startMidnight && endMidnight
            && (calendar.dateComponents([.day], from: event.eventStart, to: event.eventEnd).day ?? 0) >= 1
    }

    func dateFromMinutes(_ minutes: Int, on day: Date) -> Date {
        let hour = minutes / 60
        let minute = minutes % 60
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func groupEventsByDay(_ events: [EKEvent], clampedTo range: Range<Date>) -> [Date: [TimeSlot]] {
        var grouped: [Date: [TimeSlot]] = [:]

        for event in events {
            let slices = sliceEventIntoDays(event, clampedTo: range)
            for (day, start, end) in slices {
                grouped[day, default: []].append(TimeSlot(start: start, end: end))
            }
        }

        return grouped
    }

    private func sliceEventIntoDays(_ event: EKEvent, clampedTo range: Range<Date>) -> [(day: Date, start: Date, end: Date)] {
        var slices: [(Date, Date, Date)] = []
        // range.lowerBound is a startOfDay, so the cursor stays day-aligned.
        var cursor = max(calendar.startOfDay(for: event.startDate), range.lowerBound)
        let endLimit = min(event.endDate, range.upperBound)

        while cursor < endLimit {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let sliceStart = max(event.startDate, cursor)
            let sliceEnd = min(event.endDate, nextDay)
            if sliceStart < sliceEnd {
                slices.append((cursor, sliceStart, sliceEnd))
            }
            cursor = nextDay
        }

        return slices
    }
}
