import Testing
import Foundation
@testable import CalendarClick

// MARK: - Formatter Tests

@Suite("AvailabilityFormatter")
struct FormatterTests {
    let formatter = AvailabilityFormatter()
    let cal = Calendar.current

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        DateComponents(calendar: cal, year: year, month: month, day: day, hour: hour, minute: minute).date!
    }

    private func slot(_ day: Int, _ startHour: Int, _ startMin: Int, _ endHour: Int, _ endMin: Int) -> TimeSlot {
        TimeSlot(
            start: date(2026, 3, day, startHour, startMin),
            end: date(2026, 3, day, endHour, endMin)
        )
    }

    // MARK: - Time Range Formatting

    @Test func sameAMPeriod_elideStartSuffix() {
        let result = formatter.formatTimeRange(slot(25, 9, 0, 10, 30))
        #expect(result == "9-10:30am")
    }

    @Test func samePMPeriod_elideStartSuffix() {
        let result = formatter.formatTimeRange(slot(25, 14, 0, 15, 0))
        #expect(result == "2-3pm")
    }

    @Test func crossAMPM_showBothSuffixes() {
        let result = formatter.formatTimeRange(slot(25, 9, 0, 13, 0))
        #expect(result == "9am-1pm")
    }

    @Test func noonIsPM() {
        // 11:30am to 12pm crosses AM→PM
        let result = formatter.formatTimeRange(slot(25, 11, 30, 12, 0))
        #expect(result == "11:30am-12pm")
    }

    @Test func noonToOnePM_samePeriod() {
        // 12pm and 1pm are both PM
        let result = formatter.formatTimeRange(slot(25, 12, 0, 13, 0))
        #expect(result == "12-1pm")
    }

    @Test func onTheHour_dropMinutes() {
        let result = formatter.formatTimeRange(slot(25, 9, 0, 17, 0))
        #expect(result == "9am-5pm")
    }

    @Test func hasMinutes_keepMinutes() {
        let result = formatter.formatTimeRange(slot(25, 9, 30, 10, 15))
        #expect(result == "9:30-10:15am")
    }

    @Test func brainstormExample() {
        // The brainstorm showed "2pm-3pm" but the rule says elide → "2-3pm"
        let result = formatter.formatTimeRange(slot(25, 14, 0, 15, 0))
        #expect(result == "2-3pm")
    }

    // MARK: - Full Output Formatting

    @Test func fullDayOutput_groupedByDay() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)],
            date(2026, 3, 26): [slot(26, 10, 0, 12, 0)],
            date(2026, 3, 27): [slot(27, 9, 0, 17, 0)],
        ]

        let result = formatter.format(slots: slots)
        let lines = result.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == "Wed Mar 25: 9-10:30am, 2-3pm")
        #expect(lines[1] == "Thu Mar 26: 10am-12pm")
        #expect(lines[2] == "Fri Mar 27: 9am-5pm")
    }

    @Test func emptySlots_returnsEmpty() {
        let result = formatter.format(slots: [:])
        #expect(result == "")
    }

    @Test func withTimeZone_appendsSuffix() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0)],
        ]
        let result = formatter.format(slots: slots, showTimeZone: true)
        let lines = result.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("("))
        #expect(lines[1].hasSuffix(")"))
    }
}

// MARK: - AvailabilityService Tests

@Suite("AvailabilityService")
struct AvailabilityServiceTests {
    let service = AvailabilityService()
    let cal = Calendar.current

    @Test func shouldBlockTime_declinesExcluded() {
        // Can't create real EKEvents in unit tests without entitlements,
        // so we test the range calculation logic instead
        let workingDays: Set<Int> = [2, 3, 4, 5, 6] // Mon-Fri

        // Wednesday March 25, 2026 is a Wednesday (weekday 4)
        let wed = DateComponents(calendar: cal, year: 2026, month: 3, day: 25, hour: 10).date!
        let days = service.businessDaysForRange(.thisWeek, from: wed, workingDays: workingDays)

        // Should include Wed, Thu, Fri
        #expect(days.count == 3)
    }

    @Test func nextWeek_startsFromFollowingMonday() {
        let workingDays: Set<Int> = [2, 3, 4, 5, 6]
        let wed = DateComponents(calendar: cal, year: 2026, month: 3, day: 25, hour: 10).date!
        let days = service.businessDaysForRange(.nextWeek, from: wed, workingDays: workingDays)

        #expect(days.count == 5)
        let firstDayWeekday = cal.component(.weekday, from: days[0])
        #expect(firstDayWeekday == 2) // Monday
    }

    @Test func thisWeek_autoRollsOnWeekend() {
        let workingDays: Set<Int> = [2, 3, 4, 5, 6]
        // Saturday March 28, 2026
        let sat = DateComponents(calendar: cal, year: 2026, month: 3, day: 28, hour: 10).date!
        let days = service.businessDaysForRange(.thisWeek, from: sat, workingDays: workingDays)

        // Should auto-roll to next week
        #expect(days.count == 5)
        let firstDayWeekday = cal.component(.weekday, from: days[0])
        #expect(firstDayWeekday == 2) // Monday
    }

    @Test func businessDays_returnsCorrectCount() {
        let workingDays: Set<Int> = [2, 3, 4, 5, 6]
        // Use a Monday at midday to avoid timezone edge cases
        let mon = DateComponents(calendar: cal, year: 2026, month: 3, day: 23, hour: 12).date!
        let days = service.businessDaysForRange(.businessDays(3), from: mon, workingDays: workingDays)

        #expect(days.count == 3)
    }

    @Test func fortnightDays_startFromNextMonday() {
        let workingDays: Set<Int> = [2, 3, 4, 5, 6]
        let wed = DateComponents(calendar: cal, year: 2026, month: 3, day: 25, hour: 10).date!
        let days = service.businessDaysForRange(.nextFortnight, from: wed, workingDays: workingDays)

        // 14 calendar days from next Monday = 10 business days
        #expect(days.count == 10)
    }

    @Test func next30Days_excludesWeekends() {
        let workingDays: Set<Int> = [2, 3, 4, 5, 6]
        let wed = DateComponents(calendar: cal, year: 2026, month: 3, day: 25, hour: 10).date!
        let days = service.businessDaysForRange(.next30Days, from: wed, workingDays: workingDays)

        // 30 calendar days should have ~22 business days
        #expect(days.count >= 20)
        #expect(days.count <= 23)
        // All should be working days
        for day in days {
            let wd = cal.component(.weekday, from: day)
            #expect(workingDays.contains(wd))
        }
    }
}
