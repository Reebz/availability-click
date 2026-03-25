import Testing
import Foundation
@testable import CalendarClick

// MARK: - Test Helpers

private let cal = Calendar.current

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    DateComponents(calendar: cal, year: year, month: month, day: day, hour: hour, minute: minute).date!
}

private func slot(_ day: Int, _ startHour: Int, _ startMin: Int, _ endHour: Int, _ endMin: Int, month: Int = 3) -> TimeSlot {
    TimeSlot(
        start: date(2026, month, day, startHour, startMin),
        end: date(2026, month, day, endHour, endMin)
    )
}

// ============================================================================
// MARK: - TimeSlot Tests
// ============================================================================

@Suite("TimeSlot")
struct TimeSlotTests {
    @Test func duration_calculatesCorrectly() {
        let s = slot(25, 9, 0, 10, 30)
        #expect(s.duration == 5400) // 1.5 hours
    }

    @Test func duration_zeroDuration() {
        let s = TimeSlot(start: date(2026, 3, 25, 9, 0), end: date(2026, 3, 25, 9, 0))
        #expect(s.duration == 0)
    }

    @Test func duration_fullDay() {
        let s = slot(25, 9, 0, 17, 0)
        #expect(s.duration == 28800) // 8 hours
    }
}

// ============================================================================
// MARK: - AvailabilityFormatter Tests
// ============================================================================

@Suite("AvailabilityFormatter")
struct FormatterTests {
    let formatter = AvailabilityFormatter()

    // MARK: - Time Range: AM/PM Suffix Elision

    @Test func sameAMPeriod_elideStartSuffix() {
        #expect(formatter.formatTimeRange(slot(25, 9, 0, 10, 30)) == "9-10:30am")
    }

    @Test func samePMPeriod_elideStartSuffix() {
        #expect(formatter.formatTimeRange(slot(25, 14, 0, 15, 0)) == "2-3pm")
    }

    @Test func crossAMPM_showBothSuffixes() {
        #expect(formatter.formatTimeRange(slot(25, 9, 0, 13, 0)) == "9am-1pm")
    }

    @Test func crossAMPM_morningToAfternoon() {
        #expect(formatter.formatTimeRange(slot(25, 11, 0, 14, 30)) == "11am-2:30pm")
    }

    // MARK: - Time Range: Noon / Midnight

    @Test func noonIsPM_crossFromAM() {
        #expect(formatter.formatTimeRange(slot(25, 11, 30, 12, 0)) == "11:30am-12pm")
    }

    @Test func noonToOnePM_samePeriod() {
        #expect(formatter.formatTimeRange(slot(25, 12, 0, 13, 0)) == "12-1pm")
    }

    @Test func noonTo5PM_samePeriod() {
        #expect(formatter.formatTimeRange(slot(25, 12, 0, 17, 0)) == "12-5pm")
    }

    @Test func earlyMorning_AMsuffix() {
        #expect(formatter.formatTimeRange(slot(25, 6, 0, 7, 30)) == "6-7:30am")
    }

    // MARK: - Time Range: Minutes Handling

    @Test func onTheHour_dropMinutes() {
        #expect(formatter.formatTimeRange(slot(25, 9, 0, 17, 0)) == "9am-5pm")
    }

    @Test func hasMinutes_keepMinutes() {
        #expect(formatter.formatTimeRange(slot(25, 9, 30, 10, 15)) == "9:30-10:15am")
    }

    @Test func startOnHour_endHasMinutes() {
        #expect(formatter.formatTimeRange(slot(25, 9, 0, 10, 45)) == "9-10:45am")
    }

    @Test func startHasMinutes_endOnHour() {
        #expect(formatter.formatTimeRange(slot(25, 9, 30, 11, 0)) == "9:30-11am")
    }

    @Test func minutesFiveMinutePadding() {
        #expect(formatter.formatTimeRange(slot(25, 9, 5, 10, 5)) == "9:05-10:05am")
    }

    // MARK: - Time Range: Brainstorm Spec

    @Test func brainstormExample_elidesSuffix() {
        #expect(formatter.formatTimeRange(slot(25, 14, 0, 15, 0)) == "2-3pm")
    }

    // MARK: - Full Output: Day Grouping

    @Test func fullDayOutput_groupedByDay_sortedChronologically() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 27): [slot(27, 9, 0, 17, 0)],
            date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)],
            date(2026, 3, 26): [slot(26, 10, 0, 12, 0)],
        ]

        let result = formatter.format(slots: slots)
        let lines = result.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == "Wed Mar 25: 9-10:30am, 2-3pm")
        #expect(lines[1] == "Thu Mar 26: 10am-12pm")
        #expect(lines[2] == "Fri Mar 27: 9am-5pm")
    }

    @Test func singleSlotDay() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 14, 0, 16, 0)],
        ]
        let result = formatter.format(slots: slots)
        #expect(result == "Wed Mar 25: 2-4pm")
    }

    @Test func manySlotsInOneDay() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [
                slot(25, 9, 0, 10, 0),
                slot(25, 11, 0, 12, 0),
                slot(25, 14, 0, 15, 0),
                slot(25, 16, 0, 17, 0),
            ],
        ]
        let result = formatter.format(slots: slots)
        #expect(result == "Wed Mar 25: 9-10am, 11am-12pm, 2-3pm, 4-5pm")
    }

    @Test func slotsWithinDayAreSorted() {
        // Pass slots out of order — formatter should sort them
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [
                slot(25, 14, 0, 15, 0),
                slot(25, 9, 0, 10, 0),
            ],
        ]
        let result = formatter.format(slots: slots)
        #expect(result == "Wed Mar 25: 9-10am, 2-3pm")
    }

    // MARK: - Full Output: Empty

    @Test func emptySlots_returnsEmpty() {
        #expect(formatter.format(slots: [:]) == "")
    }

    // MARK: - Full Output: Timezone

    @Test func withTimeZone_appendsSuffix() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0)],
        ]
        let result = formatter.format(slots: slots, showTimeZone: true)
        let lines = result.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("("))
        #expect(lines[1].hasSuffix(")"))
        #expect(lines[1].contains("GMT"))
    }

    @Test func withoutTimeZone_noSuffix() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0)],
        ]
        let result = formatter.format(slots: slots, showTimeZone: false)
        #expect(!result.contains("GMT"))
    }

    @Test func timezoneString_containsAbbreviationAndGMT() {
        let tz = AvailabilityFormatter.timezoneString()
        #expect(tz.contains("GMT"))
        #expect(tz.contains(", "))
    }
}

// ============================================================================
// MARK: - Slot Subtraction Tests (Core Algorithm)
// ============================================================================

@Suite("Slot Subtraction")
struct SlotSubtractionTests {
    let service = AvailabilityService()

    private func workday(_ day: Int) -> (start: Date, end: Date) {
        (date(2026, 3, day, 9, 0), date(2026, 3, day, 17, 0))
    }

    // MARK: - Basic Subtraction

    @Test func noEvents_fullWorkingHours() {
        let work = workday(25)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].start == work.start)
        #expect(result[0].end == work.end)
    }

    @Test func oneEventInMiddle_twoFreeSlots() {
        let work = workday(25)
        let meeting = slot(25, 11, 0, 12, 0)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 2)
        // Before meeting: 9am-11am
        #expect(result[0].start == date(2026, 3, 25, 9, 0))
        #expect(result[0].end == date(2026, 3, 25, 11, 0))
        // After meeting: 12pm-5pm
        #expect(result[1].start == date(2026, 3, 25, 12, 0))
        #expect(result[1].end == date(2026, 3, 25, 17, 0))
    }

    @Test func eventAtStartOfDay_oneFreeSlotAtEnd() {
        let work = workday(25)
        let meeting = slot(25, 9, 0, 10, 0)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].start == date(2026, 3, 25, 10, 0))
        #expect(result[0].end == date(2026, 3, 25, 17, 0))
    }

    @Test func eventAtEndOfDay_oneFreeSlotAtStart() {
        let work = workday(25)
        let meeting = slot(25, 16, 0, 17, 0)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].start == date(2026, 3, 25, 9, 0))
        #expect(result[0].end == date(2026, 3, 25, 16, 0))
    }

    @Test func eventSpansFullDay_noFreeSlots() {
        let work = workday(25)
        let meeting = slot(25, 9, 0, 17, 0)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.isEmpty)
    }

    // MARK: - Overlapping and Adjacent Events

    @Test func overlappingEvents_mergedSubtraction() {
        let work = workday(25)
        let meeting1 = slot(25, 10, 0, 12, 0)
        let meeting2 = slot(25, 11, 0, 13, 0) // overlaps with first
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting1, meeting2],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 2)
        // Before: 9-10am
        #expect(result[0].end == date(2026, 3, 25, 10, 0))
        // After: 1-5pm
        #expect(result[1].start == date(2026, 3, 25, 13, 0))
    }

    @Test func backToBackEvents_noGapBetween() {
        let work = workday(25)
        let meeting1 = slot(25, 10, 0, 11, 0)
        let meeting2 = slot(25, 11, 0, 12, 0)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting1, meeting2],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 2)
        #expect(result[0].end == date(2026, 3, 25, 10, 0))
        #expect(result[1].start == date(2026, 3, 25, 12, 0))
    }

    @Test func threeEvents_fourFreeSlots() {
        let work = workday(25)
        let events = [
            slot(25, 9, 30, 10, 0),
            slot(25, 12, 0, 13, 0),
            slot(25, 15, 0, 16, 0),
        ]
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: events,
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 4)
    }

    // MARK: - Clamping to Working Hours

    @Test func eventOutsideWorkingHours_noEffect() {
        let work = workday(25)
        // Meeting at 7am-8am — before working hours
        let earlyMeeting = TimeSlot(
            start: date(2026, 3, 25, 7, 0),
            end: date(2026, 3, 25, 8, 0)
        )
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [earlyMeeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].duration == 28800) // Full 8 hours
    }

    @Test func eventStraddlingStartOfDay_clampedToWorkStart() {
        let work = workday(25)
        // Meeting from 8am-10am — starts before work, ends during
        let meeting = TimeSlot(
            start: date(2026, 3, 25, 8, 0),
            end: date(2026, 3, 25, 10, 0)
        )
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].start == date(2026, 3, 25, 10, 0))
    }

    @Test func eventStraddlingEndOfDay_clampedToWorkEnd() {
        let work = workday(25)
        // Meeting from 4pm-7pm — starts during work, ends after
        let meeting = TimeSlot(
            start: date(2026, 3, 25, 16, 0),
            end: date(2026, 3, 25, 19, 0)
        )
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: [meeting],
            workStart: work.start,
            workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].end == date(2026, 3, 25, 16, 0))
    }

    // MARK: - Small Gaps (minimum slot filtering happens in calculateAvailability)

    @Test func tinyGap_stillReturned_filteringIsExternal() {
        let work = workday(25)
        // Two events leaving a 15-minute gap (10:45-11:00)
        let events = [
            slot(25, 10, 0, 10, 45),
            slot(25, 11, 0, 12, 0),
        ]
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: events,
            workStart: work.start,
            workEnd: work.end
        )
        // subtractEvents returns all gaps; filtering is done by calculateAvailability
        let smallGap = result.first { $0.start == date(2026, 3, 25, 10, 45) }
        #expect(smallGap != nil)
        #expect(smallGap!.duration == 900) // 15 minutes
    }
}

// ============================================================================
// MARK: - Date Range Calculation Tests
// ============================================================================

@Suite("Date Range Calculation")
struct RangeTests {
    let service = AvailabilityService()
    let monFri: Set<Int> = [2, 3, 4, 5, 6]

    // MARK: - This Week

    @Test func thisWeek_fromMonday_fiveDays() {
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.thisWeek, from: mon, workingDays: monFri)
        #expect(days.count == 5)
    }

    @Test func thisWeek_fromWednesday_threeDays() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.thisWeek, from: wed, workingDays: monFri)
        #expect(days.count == 3)
    }

    @Test func thisWeek_fromFriday_oneDay() {
        let fri = date(2026, 3, 27, 12)
        let days = service.businessDaysForRange(.thisWeek, from: fri, workingDays: monFri)
        #expect(days.count == 1)
    }

    @Test func thisWeek_fromSaturday_autoRollsToNextWeek() {
        let sat = date(2026, 3, 28, 12)
        let days = service.businessDaysForRange(.thisWeek, from: sat, workingDays: monFri)
        #expect(days.count == 5)
        let firstWeekday = cal.component(.weekday, from: days[0])
        #expect(firstWeekday == 2) // Monday
    }

    @Test func thisWeek_fromSunday_autoRollsToNextWeek() {
        let sun = date(2026, 3, 29, 12)
        let days = service.businessDaysForRange(.thisWeek, from: sun, workingDays: monFri)
        #expect(days.count == 5)
    }

    // MARK: - Next Week

    @Test func nextWeek_fromWednesday_startsFollowingMonday() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.nextWeek, from: wed, workingDays: monFri)
        #expect(days.count == 5)
        let firstWeekday = cal.component(.weekday, from: days[0])
        #expect(firstWeekday == 2) // Monday
        // Should be March 30, 2026 (next Monday)
        #expect(cal.component(.day, from: days[0]) == 30)
    }

    @Test func nextWeek_fromMonday_skipsCurrentWeek() {
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.nextWeek, from: mon, workingDays: monFri)
        #expect(days.count == 5)
        // Should be March 30, not March 23
        #expect(cal.component(.day, from: days[0]) == 30)
    }

    @Test func nextWeek_allDaysAreWorkingDays() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.nextWeek, from: wed, workingDays: monFri)
        for day in days {
            let wd = cal.component(.weekday, from: day)
            #expect(monFri.contains(wd))
        }
    }

    // MARK: - Business Days

    @Test func businessDays_3days() {
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.businessDays(3), from: mon, workingDays: monFri)
        #expect(days.count == 3)
    }

    @Test func businessDays_5days() {
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.businessDays(5), from: mon, workingDays: monFri)
        #expect(days.count == 5)
    }

    @Test func businessDays_2days_minimum() {
        let thu = date(2026, 3, 26, 12)
        let days = service.businessDaysForRange(.businessDays(2), from: thu, workingDays: monFri)
        #expect(days.count == 2)
    }

    @Test func businessDays_skipsWeekends() {
        // Start on Thursday, request 3 business days: Thu, Fri, Mon
        let thu = date(2026, 3, 26, 12)
        let days = service.businessDaysForRange(.businessDays(3), from: thu, workingDays: monFri)
        #expect(days.count == 3)
        for day in days {
            let wd = cal.component(.weekday, from: day)
            #expect(monFri.contains(wd))
        }
    }

    // MARK: - Fortnight

    @Test func fortnight_10businessDays() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.nextFortnight, from: wed, workingDays: monFri)
        #expect(days.count == 10)
    }

    @Test func fortnight_startsNextMonday() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.nextFortnight, from: wed, workingDays: monFri)
        let firstWeekday = cal.component(.weekday, from: days[0])
        #expect(firstWeekday == 2) // Monday
    }

    @Test func fortnight_allWorkingDays() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.nextFortnight, from: wed, workingDays: monFri)
        for day in days {
            let wd = cal.component(.weekday, from: day)
            #expect(monFri.contains(wd))
        }
    }

    // MARK: - Next 30 Days

    @Test func next30Days_excludesWeekends() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.next30Days, from: wed, workingDays: monFri)
        #expect(days.count >= 20)
        #expect(days.count <= 23)
        for day in days {
            let wd = cal.component(.weekday, from: day)
            #expect(monFri.contains(wd))
        }
    }

    @Test func next30Days_startsTomorrow() {
        let wed = date(2026, 3, 25, 12)
        let days = service.businessDaysForRange(.next30Days, from: wed, workingDays: monFri)
        // Should not include today (Mar 25)
        let firstDay = cal.component(.day, from: days[0])
        #expect(firstDay == 26)
    }

    // MARK: - Custom Working Days

    @Test func customWorkingDays_includeSaturday() {
        let customDays: Set<Int> = [2, 3, 4, 5, 6, 7] // Mon-Sat
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.thisWeek, from: mon, workingDays: customDays)
        #expect(days.count == 6)
    }

    @Test func noWorkingDays_emptyResult() {
        let emptyDays: Set<Int> = []
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.thisWeek, from: mon, workingDays: emptyDays)
        #expect(days.isEmpty)
    }
}

// ============================================================================
// MARK: - AppSettings Validation Tests
// ============================================================================

@Suite("AppSettings Validation")
struct AppSettingsTests {
    // Use unique keys per test to avoid cross-test state and registerDefaults interference
    @Test func clampedInt_withinRange_returnsValue() {
        let key = "test_clamp_\(UUID().uuidString)"
        UserDefaults.standard.set(10, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let result = AppSettings.clampedInt(forKey: key, min: 0, max: 20, fallback: 5)
        #expect(result == 10)
    }

    @Test func clampedInt_belowRange_returnsFallback() {
        let key = "test_clamp_\(UUID().uuidString)"
        UserDefaults.standard.set(-5, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let result = AppSettings.clampedInt(forKey: key, min: 0, max: 20, fallback: 5)
        #expect(result == 5)
    }

    @Test func clampedInt_aboveRange_returnsFallback() {
        let key = "test_clamp_\(UUID().uuidString)"
        UserDefaults.standard.set(999, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let result = AppSettings.clampedInt(forKey: key, min: 0, max: 20, fallback: 5)
        #expect(result == 5)
    }

    @Test func clampedInt_atMinBoundary_returnsValue() {
        let key = "test_clamp_\(UUID().uuidString)"
        UserDefaults.standard.set(1, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let result = AppSettings.clampedInt(forKey: key, min: 1, max: 20, fallback: 5)
        #expect(result == 1)
    }

    @Test func clampedInt_atMaxBoundary_returnsValue() {
        let key = "test_clamp_\(UUID().uuidString)"
        UserDefaults.standard.set(20, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let result = AppSettings.clampedInt(forKey: key, min: 0, max: 20, fallback: 5)
        #expect(result == 20)
    }

    @Test func defaults_workingHoursStartIs9AM() {
        #expect(AppSettings.defaultWorkingHoursStart == 540) // 9 * 60
    }

    @Test func defaults_workingHoursEndIs5PM() {
        #expect(AppSettings.defaultWorkingHoursEnd == 1020) // 17 * 60
    }

    @Test func defaults_workingDaysAreMonFri() {
        #expect(AppSettings.defaultWorkingDays == [2, 3, 4, 5, 6])
    }

    @Test func defaults_todayBufferIs60() {
        #expect(AppSettings.defaultTodayBuffer == 60)
    }

    @Test func defaults_minimumSlotIs30() {
        #expect(AppSettings.defaultMinimumSlot == 30)
    }
}

// ============================================================================
// MARK: - DateFromMinutes Helper Tests
// ============================================================================

@Suite("dateFromMinutes")
struct DateFromMinutesTests {
    let service = AvailabilityService()

    @Test func midnight() {
        let day = date(2026, 3, 25)
        let result = service.dateFromMinutes(0, on: day)
        #expect(cal.component(.hour, from: result) == 0)
        #expect(cal.component(.minute, from: result) == 0)
    }

    @Test func nineAM() {
        let day = date(2026, 3, 25)
        let result = service.dateFromMinutes(540, on: day)
        #expect(cal.component(.hour, from: result) == 9)
        #expect(cal.component(.minute, from: result) == 0)
    }

    @Test func eightThirtyAM() {
        let day = date(2026, 3, 25)
        let result = service.dateFromMinutes(510, on: day)
        #expect(cal.component(.hour, from: result) == 8)
        #expect(cal.component(.minute, from: result) == 30)
    }

    @Test func fivePM() {
        let day = date(2026, 3, 25)
        let result = service.dateFromMinutes(1020, on: day)
        #expect(cal.component(.hour, from: result) == 17)
        #expect(cal.component(.minute, from: result) == 0)
    }

    @Test func endOfDay() {
        let day = date(2026, 3, 25)
        let result = service.dateFromMinutes(1439, on: day)
        #expect(cal.component(.hour, from: result) == 23)
        #expect(cal.component(.minute, from: result) == 59)
    }
}
