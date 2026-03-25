@preconcurrency import EventKit
import Foundation

enum DateRangeType {
    case thisWeek
    case businessDays(Int)
    case nextWeek
    case nextFortnight
    case next30Days
}

struct AvailabilityService {
    private let calendar = Calendar.current

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
        let minimumSlot = TimeInterval(AppSettings.minimumSlotMinutes * 60)

        guard endMinutes > startMinutes else { return [:] }

        let days = businessDaysForRange(rangeType, from: now, workingDays: workingDays)
        let filteredEvents = events.filter { shouldBlockTime($0) }
        let eventsByDay = groupEventsByDay(filteredEvents)

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

            let dayEvents = eventsByDay[dayStart] ?? []
            let freeSlots = subtractEvents(
                from: TimeSlot(start: workStart, end: workEnd),
                events: dayEvents,
                workStart: dateFromMinutes(startMinutes, on: dayStart),
                workEnd: workEnd
            )

            let viable = freeSlots.filter { $0.duration >= minimumSlot }
            if !viable.isEmpty {
                result[dayStart] = viable
            }
        }

        return result
    }

    // MARK: - Event Filtering

    func shouldBlockTime(_ event: EKEvent) -> Bool {
        if event.isAllDay { return false }
        if isEffectivelyAllDay(event) { return false }
        if event.status == .canceled { return false }
        if event.availability == .free { return false }

        if let attendees = event.attendees, !attendees.isEmpty,
           let me = attendees.first(where: { $0.isCurrentUser }),
           me.participantStatus == .declined {
            return false
        }

        return true
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
        var days: [Date] = []
        var cursor = today
        let bufferMinutes = AppSettings.todayBufferMinutes
        let endMinutes = AppSettings.workingHoursEnd

        while days.count < n {
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

    // MARK: - Helpers

    private func isEffectivelyAllDay(_ event: EKEvent) -> Bool {
        let startMidnight = calendar.startOfDay(for: event.startDate) == event.startDate
        let endMidnight = calendar.startOfDay(for: event.endDate) == event.endDate
        return startMidnight && endMidnight
            && event.endDate.timeIntervalSince(event.startDate) >= 86400
    }

    func dateFromMinutes(_ minutes: Int, on day: Date) -> Date {
        let hour = minutes / 60
        let minute = minutes % 60
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func groupEventsByDay(_ events: [EKEvent]) -> [Date: [TimeSlot]] {
        var grouped: [Date: [TimeSlot]] = [:]

        for event in events {
            let slices = sliceEventIntoDays(event)
            for (day, start, end) in slices {
                grouped[day, default: []].append(TimeSlot(start: start, end: end))
            }
        }

        return grouped
    }

    private func sliceEventIntoDays(_ event: EKEvent) -> [(day: Date, start: Date, end: Date)] {
        var slices: [(Date, Date, Date)] = []
        var cursor = calendar.startOfDay(for: event.startDate)

        while cursor < event.endDate {
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
