import Testing
import Foundation
import AppKit
import EventKit
@testable import AvailabilityClick

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

/// Pins AppSettings-backed defaults to known values for the duration of
/// `body`, then restores whatever was there before. TEST_HOST is the real
/// app bundle, so UserDefaults.standard is the developer's live settings --
/// tests that read AppSettings must not depend on (or clobber) them.
private func withPinnedSettings(_ overrides: [String: Any], run body: () -> Void) {
    let defaults = UserDefaults.standard
    let originals = overrides.keys.map { ($0, defaults.object(forKey: $0)) }
    for (key, value) in overrides { defaults.set(value, forKey: key) }
    body()
    for (key, original) in originals {
        if let original {
            defaults.set(original, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private let stockWorkingSettings: [String: Int] = [
    AppSettings.workingHoursStartKey: 540,   // 9:00 AM
    AppSettings.workingHoursEndKey: 1020,    // 5:00 PM
    AppSettings.todayBufferMinutesKey: 60,
    AppSettings.minimumSlotMinutesKey: 30,
    AppSettings.roundingGranularityKey: 30,
]

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

    // MARK: - Termination Guards (businessDays mode)

    // Regression: an empty working-days set used to spin nextNBusinessDays
    // forever on the main actor (the Settings toggles allow unchecking all
    // seven days).
    @Test func businessDays_noWorkingDays_returnsEmpty() {
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.businessDays(5), from: mon, workingDays: [])
        #expect(days.isEmpty)
    }

    @Test func businessDays_unknownWeekdayValues_returnsEmpty() {
        let mon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.businessDays(5), from: mon, workingDays: [8, 9])
        #expect(days.isEmpty)
    }

    // MARK: - This Week: Evening Auto-Roll

    // Regression: a Friday-evening click in this-week mode used to return an
    // empty result (failure flash) instead of rolling to next week as the
    // README promises. Relies on registered defaults (work end 5pm, buffer 1h).
    @Test func thisWeek_fridayEvening_rollsToNextWeek() {
        withPinnedSettings(stockWorkingSettings) {
            let friEvening = date(2026, 3, 27, 18)
            let days = service.businessDaysForRange(.thisWeek, from: friEvening, workingDays: monFri)
            #expect(days.count == 5)
            #expect(cal.component(.weekday, from: days[0]) == 2) // Monday
            #expect(cal.component(.day, from: days[0]) == 30)
        }
    }

    @Test func thisWeek_fridayNoon_stillIncludesFriday() {
        withPinnedSettings(stockWorkingSettings) {
            let friNoon = date(2026, 3, 27, 12)
            let days = service.businessDaysForRange(.thisWeek, from: friNoon, workingDays: monFri)
            #expect(days.count == 1)
        }
    }
}

// ============================================================================
// MARK: - Availability Calculation Tests
// ============================================================================

@Suite("Availability Calculation")
struct AvailabilityCalculationTests {
    let service = AvailabilityService()

    // End-to-end with no events: today is buffered, future days get the full
    // working window. Relies on registered defaults (9-5, buffer 1h,
    // rounding 30, minimum slot 30).
    @Test func emptyEvents_todayIsBuffered() {
        withPinnedSettings(stockWorkingSettings) {
            let monNoon = date(2026, 3, 23, 12)
            let result = service.calculateAvailability(events: [], rangeType: .businessDays(1), now: monNoon)
            let today = cal.startOfDay(for: monNoon)
            #expect(result.count == 1)
            #expect(result[today]?.count == 1)
            #expect(result[today]?.first?.start == date(2026, 3, 23, 13, 0))
            #expect(result[today]?.first?.end == date(2026, 3, 23, 17, 0))
        }
    }

    @Test func emptyEvents_futureDayGetsFullWindow() {
        withPinnedSettings(stockWorkingSettings) {
            let monNoon = date(2026, 3, 23, 12)
            let result = service.calculateAvailability(events: [], rangeType: .businessDays(2), now: monNoon)
            let tuesday = date(2026, 3, 24)
            #expect(result[tuesday]?.first?.start == date(2026, 3, 24, 9, 0))
            #expect(result[tuesday]?.first?.end == date(2026, 3, 24, 17, 0))
        }
    }

    @Test func emptyEvents_emptyWorkingDays_returnsEmptyPromptly() {
        let monNoon = date(2026, 3, 23, 12)
        let days = service.businessDaysForRange(.businessDays(3), from: monNoon, workingDays: [])
        #expect(days.isEmpty)
    }
}

// ============================================================================
// MARK: - Timezone Day-Label Tests
// ============================================================================

@Suite("Timezone Day Labels")
struct TimezoneDayLabelTests {
    let formatter = AvailabilityFormatter()

    // Regression: recipient-timezone output used to convert times but keep
    // sender-local day labels, pairing a converted evening time with the
    // wrong weekday. Expected label computed dynamically so the test passes
    // in any machine timezone.
    @Test func dayLabelFollowsRecipientTimezone() throws {
        let honolulu = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        let start = date(2026, 3, 25, 9, 0)
        let end = date(2026, 3, 25, 10, 0)
        let slots = [cal.startOfDay(for: start): [TimeSlot(start: start, end: end)]]

        let output = formatter.format(slots: slots, timezone: honolulu)

        let df = DateFormatter()
        df.dateFormat = "EEE MMM d"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = honolulu
        let expectedLabel = df.string(from: start)
        #expect(output.hasPrefix(expectedLabel))
    }

    @Test func nilTimezone_keepsLocalDayLabel() {
        let start = date(2026, 3, 25, 9, 0)
        let end = date(2026, 3, 25, 10, 0)
        let slots = [cal.startOfDay(for: start): [TimeSlot(start: start, end: end)]]

        let output = formatter.format(slots: slots)
        #expect(output == "Wed Mar 25: 9-10am")
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
// MARK: - Slot Rounding Tests
// ============================================================================

@Suite("Slot Rounding")
struct SlotRoundingTests {
    let service = AvailabilityService()

    // MARK: - roundUp

    @Test func roundUp_10_47am_to_11am_30minGranularity() {
        let input = date(2026, 3, 25, 10, 47)
        let result = service.roundUp(input, toMinutes: 30)
        #expect(cal.component(.hour, from: result) == 11)
        #expect(cal.component(.minute, from: result) == 0)
    }

    @Test func roundUp_alreadyOnBoundary_unchanged() {
        let input = date(2026, 3, 25, 9, 0)
        let result = service.roundUp(input, toMinutes: 30)
        #expect(result == input)
    }

    @Test func roundUp_10_47am_to_10_50am_10minGranularity() {
        let input = date(2026, 3, 25, 10, 47)
        let result = service.roundUp(input, toMinutes: 10)
        #expect(cal.component(.hour, from: result) == 10)
        #expect(cal.component(.minute, from: result) == 50)
    }

    @Test func roundUp_granularityZero_unchanged() {
        let input = date(2026, 3, 25, 10, 47)
        let result = service.roundUp(input, toMinutes: 0)
        #expect(result == input)
    }

    // MARK: - roundDown

    @Test func roundDown_2_08pm_to_2pm_30minGranularity() {
        let input = date(2026, 3, 25, 14, 8)
        let result = service.roundDown(input, toMinutes: 30)
        #expect(cal.component(.hour, from: result) == 14)
        #expect(cal.component(.minute, from: result) == 0)
    }

    @Test func roundDown_alreadyOnBoundary_unchanged() {
        let input = date(2026, 3, 25, 9, 0)
        let result = service.roundDown(input, toMinutes: 30)
        #expect(result == input)
    }

    @Test func roundDown_granularityZero_unchanged() {
        let input = date(2026, 3, 25, 14, 8)
        let result = service.roundDown(input, toMinutes: 0)
        #expect(result == input)
    }

    // MARK: - Rounding Integration (slot becomes invalid after rounding)

    @Test func slotDropped_whenRoundingMakesStartGteEnd() {
        // Slot from 10:47 to 10:52 — with 30-min granularity, start rounds up to 11:00
        // and end rounds down to 10:30, so start >= end → dropped
        let start = date(2026, 3, 25, 10, 47)
        let end = date(2026, 3, 25, 10, 52)
        let roundedStart = service.roundUp(start, toMinutes: 30)
        let roundedEnd = service.roundDown(end, toMinutes: 30)
        #expect(roundedStart >= roundedEnd)
    }

    @Test func granularityOff_noRounding() {
        // When granularity is 0, roundUp and roundDown return the input unchanged
        let start = date(2026, 3, 25, 10, 47)
        let end = date(2026, 3, 25, 14, 8)
        #expect(service.roundUp(start, toMinutes: 0) == start)
        #expect(service.roundDown(end, toMinutes: 0) == end)
    }

    // MARK: - Rounding Integration (end-to-end through calculateAvailability)

    @Test func slotDropped_whenRoundingMakesStartGteEnd_dayAbsentEndToEnd() {
        withPinnedSettings(stockWorkingSettings) {
            // Busy 9:00-10:47 and 10:52-17:00 leave only a 5-minute gap;
            // 30-min rounding collapses it (start 11:00 >= end 10:30), so the
            // whole day must be absent from the result, not just the slot.
            let store = EKEventStore()
            let first = EKEvent(eventStore: store)
            first.startDate = date(2026, 3, 25, 9, 0)
            first.endDate = date(2026, 3, 25, 10, 47)
            let second = EKEvent(eventStore: store)
            second.startDate = date(2026, 3, 25, 10, 52)
            second.endDate = date(2026, 3, 25, 17, 0)

            let wedMorning = date(2026, 3, 25, 8, 0)
            let result = service.calculateAvailability(
                events: [first, second],
                rangeType: .businessDays(1),
                now: wedMorning
            )
            #expect(result[date(2026, 3, 25)] == nil)
            #expect(result.isEmpty)
        }
    }
}

// ============================================================================
// MARK: - Event Filter Matrix Tests (R4, via BlockableEvent seam)
// ============================================================================

/// Test double for the branches EKEvent cannot express in tests (its
/// `status` and `attendees` are read-only).
private struct StubEvent: BlockableEvent {
    var isAllDay = false
    var eventStart: Date
    var eventEnd: Date
    var isCanceled = false
    var isFreeAvailability = false
    var isDeclinedByCurrentUser = false
}

@Suite("Event Filter Matrix")
struct EventFilterMatrixTests {
    let service = AvailabilityService()

    private func busyHour(_ day: Int = 25) -> (Date, Date) {
        (date(2026, 3, day, 10, 0), date(2026, 3, day, 11, 0))
    }

    @Test func ordinaryBusyEvent_blocks() {
        let (start, end) = busyHour()
        #expect(service.shouldBlockTime(StubEvent(eventStart: start, eventEnd: end)))
    }

    @Test func allDayFlag_blocksNothing() {
        let (start, end) = busyHour()
        let event = StubEvent(isAllDay: true, eventStart: start, eventEnd: end)
        #expect(!service.shouldBlockTime(event))
    }

    @Test func midnightToMidnight_oneDay_blocksNothing() {
        let event = StubEvent(eventStart: date(2026, 3, 25), eventEnd: date(2026, 3, 26))
        #expect(!service.shouldBlockTime(event))
        #expect(service.isEffectivelyAllDay(event))
    }

    @Test func midnightToMidnight_multiDay_blocksNothing() {
        let event = StubEvent(eventStart: date(2026, 3, 25), eventEnd: date(2026, 3, 28))
        #expect(!service.shouldBlockTime(event))
    }

    @Test func midnightToMidnight_dstSpringForwardDay_blocksNothing() {
        // 2026-10-04 is the AEDT spring-forward date (a 23-hour day) when the
        // machine observes Australian DST; elsewhere it is an ordinary day.
        // The day-span comparison must call it effectively-all-day either way.
        let event = StubEvent(eventStart: date(2026, 10, 4), eventEnd: date(2026, 10, 5))
        #expect(!service.shouldBlockTime(event))
        #expect(service.isEffectivelyAllDay(event))
    }

    @Test func midnightStart_partialDay_blocks() {
        let event = StubEvent(eventStart: date(2026, 3, 25), eventEnd: date(2026, 3, 25, 12, 0))
        #expect(service.shouldBlockTime(event))
        #expect(!service.isEffectivelyAllDay(event))
    }

    @Test func lateEvening_endingAtMidnight_blocks() {
        let event = StubEvent(eventStart: date(2026, 3, 25, 22, 0), eventEnd: date(2026, 3, 26))
        #expect(service.shouldBlockTime(event))
    }

    @Test func canceledEvent_blocksNothing() {
        let (start, end) = busyHour()
        let event = StubEvent(eventStart: start, eventEnd: end, isCanceled: true)
        #expect(!service.shouldBlockTime(event))
    }

    @Test func freeAvailabilityEvent_blocksNothing() {
        let (start, end) = busyHour()
        let event = StubEvent(eventStart: start, eventEnd: end, isFreeAvailability: true)
        #expect(!service.shouldBlockTime(event))
    }

    @Test func declinedByCurrentUser_blocksNothing() {
        let (start, end) = busyHour()
        let event = StubEvent(eventStart: start, eventEnd: end, isDeclinedByCurrentUser: true)
        #expect(!service.shouldBlockTime(event))
    }
}

// ============================================================================
// MARK: - Real-Key Settings Bounds Tests
// ============================================================================

@Suite("Real-Key Settings Bounds", .serialized)
struct RealKeySettingsBoundsTests {
    @Test func roundingGranularity_invalidValue_fallsBackToDefault() {
        withPinnedSettings([AppSettings.roundingGranularityKey: 7]) {
            #expect(AppSettings.roundingGranularity == AppSettings.defaultRoundingGranularity)
        }
    }

    @Test func roundingGranularity_validValues_pass() {
        for valid in AppSettings.validRoundingValues {
            withPinnedSettings([AppSettings.roundingGranularityKey: valid]) {
                #expect(AppSettings.roundingGranularity == valid)
            }
        }
    }

    @Test func minimumSlotMinutes_outOfBounds_fallsBackToDefault() {
        withPinnedSettings([AppSettings.minimumSlotMinutesKey: 5]) {
            #expect(AppSettings.minimumSlotMinutes == AppSettings.defaultMinimumSlot)
        }
        withPinnedSettings([AppSettings.minimumSlotMinutesKey: 999]) {
            #expect(AppSettings.minimumSlotMinutes == AppSettings.defaultMinimumSlot)
        }
    }

    @Test func minimumSlotMinutes_boundaryValues_pass() {
        withPinnedSettings([AppSettings.minimumSlotMinutesKey: 15]) {
            #expect(AppSettings.minimumSlotMinutes == 15)
        }
        withPinnedSettings([AppSettings.minimumSlotMinutesKey: 120]) {
            #expect(AppSettings.minimumSlotMinutes == 120)
        }
    }

    @Test func defaultFormat_unknownValue_fallsBackToPlainText() {
        withPinnedSettings([AppSettings.defaultFormatKey: "yaml"]) {
            #expect(AppSettings.defaultFormat == "plainText")
            #expect(AppSettings.defaultFormatTemplate == .plainText)
        }
    }

    @Test func defaultFormat_markdown_passes() {
        withPinnedSettings([AppSettings.defaultFormatKey: "markdown"]) {
            #expect(AppSettings.defaultFormat == "markdown")
            #expect(AppSettings.defaultFormatTemplate == .markdown)
        }
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

// ============================================================================
// MARK: - PasteboardWriter Tests (KTD4)
// ============================================================================

@Suite("PasteboardWriter")
@MainActor
struct PasteboardWriterTests {
    /// Uniquely named pasteboard so tests never touch the user's clipboard.
    private func testPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("test.availabilityclick.\(UUID().uuidString)"))
    }

    private var sampleSlots: [Date: [TimeSlot]] {
        [date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)]]
    }

    @Test func plainText_writesAllThreeFlavors_stringByteIdentical() {
        let pb = testPasteboard()
        let wrote = PasteboardWriter.write(
            slots: sampleSlots, showTimeZone: false, template: .plainText, pasteboard: pb
        )
        #expect(wrote)

        let expected = AvailabilityFormatter().format(
            slots: sampleSlots, showTimeZone: false, template: .plainText
        )
        #expect(pb.string(forType: .string) == expected)
        #expect(pb.string(forType: .string) == "Wed Mar 25: 9-10:30am, 2-3pm")
        #expect(pb.data(forType: .rtf) != nil)
        #expect(pb.data(forType: .html) != nil)
    }

    @Test func markdown_writesExactlyOneFlavor() {
        let pb = testPasteboard()
        PasteboardWriter.write(
            slots: sampleSlots, showTimeZone: false, template: .markdown, pasteboard: pb
        )
        #expect(pb.string(forType: .string) == "- **Wed Mar 25:** 9-10:30am, 2-3pm")
        #expect(pb.data(forType: .rtf) == nil)
        #expect(pb.data(forType: .html) == nil)
    }

    @Test func rtf_roundTripsWithBoldDayLabelsAndPlainTimes() throws {
        let pb = testPasteboard()
        PasteboardWriter.write(
            slots: sampleSlots, showTimeZone: false, template: .plainText, pasteboard: pb
        )

        let rtfData = try #require(pb.data(forType: .rtf))
        let attributed = try #require(NSAttributedString(rtf: rtfData, documentAttributes: nil))
        #expect(attributed.string.hasPrefix("Wed Mar 25:"))

        let labelFont = try #require(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        #expect(labelFont.fontDescriptor.symbolicTraits.contains(.bold))

        let timesLocation = ("Wed Mar 25: " as NSString).length
        let timesFont = try #require(
            attributed.attribute(.font, at: timesLocation, effectiveRange: nil) as? NSFont
        )
        #expect(!timesFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func timezoneConvertedCopy_embedsConvertedTimesInAllFlavors() throws {
        // 14:00-15:00 UTC is 10-11am in New York; every flavor must carry
        // the converted time, not the sender-local one.
        let utcCal: Calendar = {
            var c = Calendar.current
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()
        let start = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 14))!
        let end = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 15))!
        let dayKey = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25))!
        let slots = [dayKey: [TimeSlot(start: start, end: end)]]
        let newYork = try #require(TimeZone(identifier: "America/New_York"))

        let pb = testPasteboard()
        PasteboardWriter.write(
            slots: slots, showTimeZone: false, timezone: newYork,
            template: .plainText, pasteboard: pb
        )

        #expect(pb.string(forType: .string)?.contains("10-11am") == true)

        let rtfData = try #require(pb.data(forType: .rtf))
        let fromRTF = try #require(NSAttributedString(rtf: rtfData, documentAttributes: nil))
        #expect(fromRTF.string.contains("10-11am"))

        let htmlData = try #require(pb.data(forType: .html))
        let html = try #require(String(data: htmlData, encoding: .utf8))
        #expect(html.contains("10-11am"))
    }

    @Test func emptySlots_writesNothing_pasteboardUntouched() {
        let pb = testPasteboard()
        pb.clearContents()
        pb.setString("sentinel", forType: .string)

        let wrote = PasteboardWriter.write(
            slots: [:], showTimeZone: false, template: .plainText, pasteboard: pb
        )
        #expect(!wrote)
        #expect(pb.string(forType: .string) == "sentinel")
    }
}

// ============================================================================
// MARK: - Calendar Selection Tests (KTD2)
// ============================================================================

@Suite("Calendar Selection")
@MainActor
struct CalendarSelectionTests {
    let allIDs = ["work", "home", "shared"]

    // MARK: - effectiveSelectedIDs (read path)

    @Test func emptySelection_resolvesToAllCalendars() {
        let result = CalendarService.effectiveSelectedIDs(saved: [], allIDs: allIDs)
        #expect(result == Set(allIDs))
    }

    @Test func storedSubset_behaviorUnchanged() {
        let result = CalendarService.effectiveSelectedIDs(saved: ["work"], allIDs: allIDs)
        #expect(result == ["work"])
    }

    @Test func allStaleIDs_fallsBackToAllCalendars() {
        let result = CalendarService.effectiveSelectedIDs(saved: ["deleted-1", "deleted-2"], allIDs: allIDs)
        #expect(result == Set(allIDs))
    }

    @Test func partiallyStaleIDs_keepsValidOnly() {
        let result = CalendarService.effectiveSelectedIDs(saved: ["work", "deleted"], allIDs: allIDs)
        #expect(result == ["work"])
    }

    @Test func emptyStore_resolvesEmpty() {
        let result = CalendarService.effectiveSelectedIDs(saved: ["work"], allIDs: [])
        #expect(result.isEmpty)
    }

    // MARK: - updatedSelection (write path)

    @Test func fullSelection_persistsExplicitIDs_neverCollapsesToEmpty() {
        // Uncheck then re-check: the stored set stays explicit (KTD2 -- the
        // old write path collapsed a full selection back to []).
        let afterUncheck = CalendarPickerView.updatedSelection(
            togglingID: "home", isOn: false, current: [], allIDs: allIDs
        )
        #expect(afterUncheck == ["work", "shared"])

        let afterRecheck = CalendarPickerView.updatedSelection(
            togglingID: "home", isOn: true, current: afterUncheck!, allIDs: allIDs
        )
        #expect(afterRecheck == Set(allIDs))
        #expect(afterRecheck?.isEmpty == false)
    }

    @Test func firstTouch_expandsNeverCustomizedToFullSet() {
        let result = CalendarPickerView.updatedSelection(
            togglingID: "work", isOn: false, current: [], allIDs: allIDs
        )
        #expect(result == ["home", "shared"])
    }

    @Test func uncheckLastSelected_blocked_selectionUnchanged() {
        let result = CalendarPickerView.updatedSelection(
            togglingID: "work", isOn: false, current: ["work"], allIDs: allIDs
        )
        #expect(result == nil)
    }

    @Test func uncheckOnlyCalendar_neverCustomized_blocked() {
        let result = CalendarPickerView.updatedSelection(
            togglingID: "solo", isOn: false, current: [], allIDs: ["solo"]
        )
        #expect(result == nil)
    }

    @Test func recheckWhileBlockedStateIntact_addsNormally() {
        let result = CalendarPickerView.updatedSelection(
            togglingID: "home", isOn: true, current: ["work"], allIDs: allIDs
        )
        #expect(result == ["work", "home"])
    }
}

// ============================================================================
// MARK: - Copy Outcome Tests (KTD3)
// ============================================================================

@Suite("Copy Outcome")
@MainActor
struct CopyOutcomeTests {
    // MARK: - Gate Ordering (OQ4: authorization precedes debounce)

    @Test func noAccess_whenUnauthorized_regardlessOfDebounceState() {
        #expect(
            AppDelegate.copyDecision(
                isAuthorized: false, debouncePassed: false, hasCalendars: true, hasSlots: true
            ) == .noAccess
        )
        #expect(
            AppDelegate.copyDecision(
                isAuthorized: false, debouncePassed: true, hasCalendars: true, hasSlots: true
            ) == .noAccess
        )
    }

    @Test func debounce_swallowsOnlyAuthorizedRepeatClicks() {
        #expect(
            AppDelegate.copyDecision(
                isAuthorized: true, debouncePassed: false, hasCalendars: true, hasSlots: true
            ) == nil
        )
    }

    @Test func noCalendars_whenSelectionResolvesEmpty() {
        #expect(
            AppDelegate.copyDecision(
                isAuthorized: true, debouncePassed: true, hasCalendars: false, hasSlots: true
            ) == .noCalendars
        )
    }

    @Test func noSlots_whenAuthorizedFetchYieldsNothingViable() {
        #expect(
            AppDelegate.copyDecision(
                isAuthorized: true, debouncePassed: true, hasCalendars: true, hasSlots: false
            ) == .noSlots
        )
    }

    @Test func copied_whenAllGatesPass() {
        #expect(
            AppDelegate.copyDecision(
                isAuthorized: true, debouncePassed: true, hasCalendars: true, hasSlots: true
            ) == .copied
        )
    }

    // MARK: - Feedback Mapping (OQ11 distinct symbols, tooltip lifecycle)

    @Test func failureOutcomes_carryOneLineReasons() {
        #expect(CopyOutcome.noAccess.tooltip == "Calendar access not granted - open Settings")
        #expect(CopyOutcome.noCalendars.tooltip == "No calendars available")
        #expect(CopyOutcome.noSlots.tooltip == "No free slots in this range")
    }

    @Test func successOutcome_clearsTooltip() {
        // showOutcome writes the tooltip on every outcome; nil on .copied is
        // what guarantees a failure tooltip is cleared by a later success.
        #expect(CopyOutcome.copied.tooltip == nil)
    }

    @Test func eachOutcome_hasDistinctSymbol() {
        let symbols = Set(
            [CopyOutcome.copied, .noAccess, .noCalendars, .noSlots].map(\.symbolName)
        )
        #expect(symbols.count == 4)
    }
}

// ============================================================================
// MARK: - GlobalShortcutManager Tests
// ============================================================================

@Suite("GlobalShortcutManager")
@MainActor
struct GlobalShortcutManagerTests {
    /// Manager with stubbed Carbon seams counting register/unregister calls.
    private func stubbedManager(
        status: OSStatus = 0
    ) -> (manager: GlobalShortcutManager, registers: () -> Int, unregisters: () -> Int) {
        let manager = GlobalShortcutManager()
        var registers = 0
        var unregisters = 0
        manager.registerHotKeyFn = { _, _ in
            registers += 1
            return status == 0 ? (0, OpaquePointer(bitPattern: 0x1)) : (status, nil)
        }
        manager.unregisterHotKeyFn = { _ in unregisters += 1 }
        return (manager, { registers }, { unregisters })
    }

    // MARK: - Modifier Mapping (NSEvent -> Carbon constants)

    @Test func carbonModifiers_mapsEachFlag() {
        #expect(GlobalShortcutManager.carbonModifiers(from: .command) == 256)
        #expect(GlobalShortcutManager.carbonModifiers(from: .shift) == 512)
        #expect(GlobalShortcutManager.carbonModifiers(from: .option) == 2048)
        #expect(GlobalShortcutManager.carbonModifiers(from: .control) == 4096)
    }

    @Test func carbonModifiers_composesCombinations() {
        #expect(GlobalShortcutManager.carbonModifiers(from: [.control, .shift]) == 4096 + 512)
        #expect(GlobalShortcutManager.carbonModifiers(from: [.command, .option]) == 256 + 2048)
        #expect(
            GlobalShortcutManager.carbonModifiers(from: [.command, .shift, .option, .control])
                == 256 + 512 + 2048 + 4096
        )
        #expect(GlobalShortcutManager.carbonModifiers(from: []) == 0)
    }

    @Test func carbonModifiers_ignoresNonHotkeyFlags() {
        let flags: NSEvent.ModifierFlags = [.control, .capsLock, .function]
        #expect(GlobalShortcutManager.carbonModifiers(from: flags) == 4096)
    }

    // MARK: - Registration Success / Action

    @Test func register_success_isActiveAndFiresAction() {
        let (manager, registers, _) = stubbedManager()
        var fired = false
        manager.register(keyCode: 8, modifiers: [.control, .shift]) { fired = true }

        #expect(manager.isActive)
        #expect(!GlobalShortcutManager.lastRegistrationFailed)
        #expect(registers() == 1)

        manager.handleHotKeyPressed()
        #expect(fired)
    }

    @Test func unregister_clearsStateAndAction() {
        let (manager, registers, unregisters) = stubbedManager()
        var fired = false
        manager.register(keyCode: 8, modifiers: [.control, .shift]) { fired = true }
        manager.unregister()

        #expect(!manager.isActive)
        #expect(registers() == 1)
        #expect(unregisters() == 1)

        manager.handleHotKeyPressed()
        #expect(!fired)
    }

    // MARK: - Registration Failure

    @Test func registrationFailure_leavesConsistentUnregisteredState() {
        let (manager, registers, unregisters) = stubbedManager(status: -50)
        var fired = false
        manager.register(keyCode: 8, modifiers: [.control, .shift]) { fired = true }

        #expect(!manager.isActive)
        #expect(GlobalShortcutManager.lastRegistrationFailed)
        #expect(registers() == 1)
        #expect(unregisters() == 0)

        // Action must not survive a refused registration.
        manager.handleHotKeyPressed()
        #expect(!fired)

        // resume() after a failed register must not resurrect anything.
        manager.resume()
        #expect(registers() == 1)

        // unregister() stays safe and clears the failure flag.
        manager.unregister()
        #expect(!manager.isActive)
        #expect(!GlobalShortcutManager.lastRegistrationFailed)
    }

    // MARK: - Recorder Suspend / Resume (OQ5)

    @Test func suspendResume_sameComboRerecord_holdsExactlyOneRegistration() {
        let (manager, registers, unregisters) = stubbedManager()
        manager.register(keyCode: 8, modifiers: [.control, .shift]) {}

        // Record-start suspends; re-recording the identical combo is deduped
        // by the defaults observer, so only the ended signal (resume) arrives.
        manager.suspend()
        #expect(!manager.isActive)
        manager.resume()

        #expect(manager.isActive)
        #expect(registers() == 2)
        #expect(unregisters() == 1)
        #expect(registers() - unregisters() == 1)
    }

    @Test func resume_afterNewComboRegistered_doesNotDoubleRegister() {
        let (manager, registers, unregisters) = stubbedManager()
        manager.register(keyCode: 8, modifiers: [.control, .shift]) {}

        manager.suspend()
        // Capture wrote a different combo: the defaults observer registers it
        // before the recordingEnded resume() lands.
        manager.register(keyCode: 9, modifiers: [.command]) {}
        manager.resume()

        #expect(manager.isActive)
        #expect(registers() == 2)
        #expect(unregisters() == 1)
    }

    @Test func suspend_withoutRegistration_isNoOp() {
        let (manager, registers, unregisters) = stubbedManager()
        manager.suspend()
        manager.resume()
        #expect(!manager.isActive)
        #expect(registers() == 0)
        #expect(unregisters() == 0)
    }

    // MARK: - Display String (unchanged behavior)

    @Test func displayString_unchangedForExistingKeyCodes() {
        #expect(
            GlobalShortcutManager.displayString(keyCode: 8, modifiers: [.control, .shift])
                == "\u{2303}\u{21E7}C"
        )
        #expect(
            GlobalShortcutManager.displayString(keyCode: 126, modifiers: [.command])
                == "\u{2318}\u{2191}"
        )
        #expect(
            GlobalShortcutManager.displayString(keyCode: 122, modifiers: [.option])
                == "\u{2325}F1"
        )
        #expect(GlobalShortcutManager.displayString(keyCode: 999, modifiers: []) == "Key999")
    }
}

// ============================================================================
// MARK: - Markdown Format & Timezone Conversion Tests
// ============================================================================

@Suite("Markdown Format & Timezone")
struct MarkdownFormatTests {
    let formatter = AvailabilityFormatter()

    // MARK: - Markdown Single Day

    @Test func markdown_singleDay_bulletAndBoldHeader() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)],
        ]
        let result = formatter.format(slots: slots, template: .markdown)
        #expect(result == "- **Wed Mar 25:** 9-10:30am, 2-3pm")
    }

    // MARK: - Markdown Multiple Days

    @Test func markdown_multipleDays_eachOnOwnBullet() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 27): [slot(27, 9, 0, 17, 0)],
            date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)],
            date(2026, 3, 26): [slot(26, 10, 0, 12, 0)],
        ]
        let result = formatter.format(slots: slots, template: .markdown)
        let lines = result.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == "- **Wed Mar 25:** 9-10:30am, 2-3pm")
        #expect(lines[1] == "- **Thu Mar 26:** 10am-12pm")
        #expect(lines[2] == "- **Fri Mar 27:** 9am-5pm")
    }

    // MARK: - Markdown With Timezone (timezone line NOT bulleted)

    @Test func markdown_withTimezone_tzLineNotBulleted() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0)],
        ]
        let result = formatter.format(slots: slots, showTimeZone: true, template: .markdown)
        let lines = result.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("- **"))
        // Timezone line should NOT start with "- "
        #expect(lines[1].hasPrefix("("))
        #expect(lines[1].hasSuffix(")"))
        #expect(lines[1].contains("GMT"))
        #expect(!lines[1].hasPrefix("- "))
    }

    // MARK: - Plain Text Backward Compatible

    @Test func plainText_defaultTemplate_unchanged() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)],
        ]
        let result = formatter.format(slots: slots)
        #expect(result == "Wed Mar 25: 9-10:30am, 2-3pm")
    }

    @Test func plainText_explicitTemplate_unchanged() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 27): [slot(27, 9, 0, 17, 0)],
            date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)],
            date(2026, 3, 26): [slot(26, 10, 0, 12, 0)],
        ]
        let result = formatter.format(slots: slots, template: .plainText)
        let lines = result.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == "Wed Mar 25: 9-10:30am, 2-3pm")
        #expect(lines[1] == "Thu Mar 26: 10am-12pm")
        #expect(lines[2] == "Fri Mar 27: 9am-5pm")
    }

    // MARK: - Timezone Conversion

    @Test func timezoneConversion_timesChangeForDifferentTimezone() {
        // Create slots at specific UTC times, then format with two different timezones.
        // The displayed times should differ.
        let utcCal: Calendar = {
            var c = Calendar.current
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()
        // Create a slot at 14:00-15:00 UTC on Mar 25
        let start = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 14, minute: 0))!
        let end = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 15, minute: 0))!
        let dayKey = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25))!
        let slots: [Date: [TimeSlot]] = [
            dayKey: [TimeSlot(start: start, end: end)],
        ]

        let utcResult = formatter.format(slots: slots, timezone: TimeZone(identifier: "UTC")!)
        let estResult = formatter.format(slots: slots, timezone: TimeZone(identifier: "America/New_York")!)

        // UTC shows 2-3pm, EST shows 10-11am (5 hours behind)
        #expect(utcResult.contains("2-3pm"))
        #expect(estResult.contains("10-11am"))
    }

    // MARK: - timezoneString(for:)

    @Test func timezoneString_forSpecificTimezone_showsCorrectLabel() {
        let utc = TimeZone(identifier: "UTC")!
        let tz = AvailabilityFormatter.timezoneString(for: utc)
        // UTC's abbreviation is "GMT" on Apple platforms
        #expect(tz.contains("GMT"))
        #expect(tz.contains("+0") || tz.contains("-0") || tz == "GMT, GMT+0")
    }

    @Test func timezoneString_forNil_showsLocalTimezone() {
        // When nil, should match the system timezone behavior
        let fromNil = AvailabilityFormatter.timezoneString(for: nil)
        let fromCurrent = AvailabilityFormatter.timezoneString(for: TimeZone.current)
        #expect(fromNil == fromCurrent)
    }

    @Test func timezoneString_forNonLocalTimezone_showsAbbreviationAndOffset() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let tz = AvailabilityFormatter.timezoneString(for: tokyo)
        #expect(tz.contains("GMT"))
        #expect(tz.contains(", "))
        // Tokyo is GMT+9
        #expect(tz.contains("+9"))
    }
}
