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

/// Non-blocking mutual exclusion for settings-pinning tests. An NSLock here
/// deadlocked Swift Testing's cooperative thread pool (reproduced locally
/// twice and on CI): waiters park pool threads while the holder's
/// UserDefaults write can itself wait on the blocked main thread. Suspending
/// via continuations instead of blocking breaks the cycle.
private final class AsyncGate: @unchecked Sendable {
    // Guards only the tiny state transitions below, never held across body.
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// Swift Testing runs suites in parallel, and every pinned key lives in the
/// app's ONE real defaults domain -- unsynchronized pins from two suites
/// would clobber each other (and could leak wrong values into the
/// developer's live settings on restore).
private let settingsGate = AsyncGate()

/// Pins AppSettings-backed defaults to known values for the duration of
/// `body`, then restores whatever was there before. TEST_HOST is the real
/// app bundle, so UserDefaults.standard is the developer's live settings --
/// tests that read AppSettings must not depend on (or clobber) them.
/// Inherits the caller's isolation so MainActor suites can pass their
/// closures without a Sendable hop.
private func withPinnedSettings(
    _ overrides: [String: Any],
    isolation: isolated (any Actor)? = #isolation,
    run body: () -> Void
) async {
    await settingsGate.acquire()
    defer { settingsGate.release() }

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
    // Pinned locale: golden strings are en_US byte-exact (KTD5/OQ8).
    let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_US"))

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
// MARK: - Event Buffer Padding Tests (R7)
// ============================================================================

@Suite("Event Buffer Padding")
struct EventBufferTests {
    let service = AvailabilityService()

    private func workday(_ day: Int) -> (start: Date, end: Date) {
        (date(2026, 3, day, 9, 0), date(2026, 3, day, 17, 0))
    }

    // MARK: - Pure padding transform

    @Test func padsBothSidesByBuffer() {
        let padded = service.paddedBlockingEvents([slot(25, 13, 0, 14, 0)], byMinutes: 10)
        #expect(padded.count == 1)
        #expect(padded[0].start == date(2026, 3, 25, 12, 50))
        #expect(padded[0].end == date(2026, 3, 25, 14, 10))
    }

    @Test func zeroBuffer_returnsEventsUnchanged() {
        let events = [slot(25, 13, 0, 14, 0), slot(25, 15, 0, 16, 0)]
        let padded = service.paddedBlockingEvents(events, byMinutes: 0)
        #expect(padded.count == 2)
        #expect(padded[0].start == events[0].start && padded[0].end == events[0].end)
        #expect(padded[1].start == events[1].start && padded[1].end == events[1].end)
    }

    // MARK: - Through subtractEvents

    @Test func buffer10_slotsEndBeforeAndStartAfterMeeting() {
        let work = workday(25)
        let padded = service.paddedBlockingEvents([slot(25, 13, 0, 14, 0)], byMinutes: 10)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: padded, workStart: work.start, workEnd: work.end
        )
        #expect(result.count == 2)
        #expect(result[0].end == date(2026, 3, 25, 12, 50))
        #expect(result[1].start == date(2026, 3, 25, 14, 10))
    }

    @Test func padSwallowsShortGap_gapDropsOut() {
        // 10:00-10:30 and 10:45-11:30 leave a 15-min gap; buffer 10 pads the
        // first to ...-10:40 and the second to 10:35-..., overlapping the gap
        // away. No slot may survive between 10:30 and 10:45.
        let work = workday(25)
        let padded = service.paddedBlockingEvents(
            [slot(25, 10, 0, 10, 30), slot(25, 10, 45, 11, 30)], byMinutes: 10
        )
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: padded, workStart: work.start, workEnd: work.end
        )
        let gapSurvivor = result.first {
            $0.start >= date(2026, 3, 25, 10, 30) && $0.start < date(2026, 3, 25, 10, 45)
        }
        #expect(gapSurvivor == nil)
    }

    @Test func eventAbuttingWorkEnd_paddedPastWindow_clampedNoOverhang() {
        let work = workday(25)
        let padded = service.paddedBlockingEvents([slot(25, 16, 0, 17, 0)], byMinutes: 10)
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: padded, workStart: work.start, workEnd: work.end
        )
        #expect(result.count == 1)
        #expect(result[0].start == date(2026, 3, 25, 9, 0))
        #expect(result[0].end == date(2026, 3, 25, 15, 50))
        for s in result { #expect(s.duration > 0) }
    }

    @Test func overlappingPaddedIntervals_subtractCleanly() {
        // OQ1: adjacent events whose pads overlap must subtract without error.
        let work = workday(25)
        let padded = service.paddedBlockingEvents(
            [slot(25, 10, 0, 11, 0), slot(25, 11, 10, 12, 0)], byMinutes: 10
        )
        let result = service.subtractEvents(
            from: TimeSlot(start: work.start, end: work.end),
            events: padded, workStart: work.start, workEnd: work.end
        )
        #expect(result.contains { $0.start == date(2026, 3, 25, 9, 0) && $0.end == date(2026, 3, 25, 9, 50) })
        #expect(result.contains { $0.start == date(2026, 3, 25, 12, 10) && $0.end == date(2026, 3, 25, 17, 0) })
        #expect(!result.contains { $0.start >= date(2026, 3, 25, 11, 0) && $0.start < date(2026, 3, 25, 12, 10) })
    }

    // MARK: - End-to-end through calculateAvailability

    @Test func endToEnd_bufferShiftsSlotEdges() async {
        var pinned: [String: Any] = stockWorkingSettings
        pinned[AppSettings.eventBufferMinutesKey] = 10
        pinned[AppSettings.roundingGranularityKey] = 0  // isolate the buffer effect
        await withPinnedSettings(pinned) {
            let store = EKEventStore()
            let meeting = EKEvent(eventStore: store)
            meeting.startDate = date(2026, 3, 25, 13, 0)
            meeting.endDate = date(2026, 3, 25, 14, 0)
            let wedMorning = date(2026, 3, 25, 8, 0)
            let result = service.calculateAvailability(
                events: [meeting], rangeType: .businessDays(1), now: wedMorning
            )
            let slots = result[date(2026, 3, 25)]!
            #expect(slots.contains { $0.end == date(2026, 3, 25, 12, 50) })
            #expect(slots.contains { $0.start == date(2026, 3, 25, 14, 10) })
        }
    }

    @Test func defaultZeroBuffer_matchesNoBufferBaseline() async {
        var pinned: [String: Any] = stockWorkingSettings  // rounding 30
        pinned[AppSettings.eventBufferMinutesKey] = 0
        await withPinnedSettings(pinned) {
            let store = EKEventStore()
            let meeting = EKEvent(eventStore: store)
            meeting.startDate = date(2026, 3, 25, 13, 0)
            meeting.endDate = date(2026, 3, 25, 14, 0)
            let wedMorning = date(2026, 3, 25, 8, 0)
            let result = service.calculateAvailability(
                events: [meeting], rangeType: .businessDays(1), now: wedMorning
            )
            let slots = result[date(2026, 3, 25)]!
            // Edges land exactly on the meeting boundaries — no padding.
            #expect(slots.contains { $0.end == date(2026, 3, 25, 13, 0) })
            #expect(slots.contains { $0.start == date(2026, 3, 25, 14, 0) })
        }
    }

    @Test func nonBlockingEvents_notPadded() async {
        var pinned: [String: Any] = stockWorkingSettings
        pinned[AppSettings.eventBufferMinutesKey] = 15
        await withPinnedSettings(pinned) {
            // An all-day event is non-blocking (EKEvent.availability = .free
            // won't stick without a supporting calendar; isAllDay reliably
            // does). It must be filtered before padding — no 15-min carve-out.
            let store = EKEventStore()
            let allDay = EKEvent(eventStore: store)
            allDay.isAllDay = true
            allDay.startDate = date(2026, 3, 25)
            allDay.endDate = date(2026, 3, 26)
            let wedMorning = date(2026, 3, 25, 8, 0)
            let result = service.calculateAvailability(
                events: [allDay], rangeType: .businessDays(1), now: wedMorning
            )
            let slots = result[date(2026, 3, 25)]!
            #expect(slots.count == 1)
            #expect(slots[0].start == date(2026, 3, 25, 9, 0))
            #expect(slots[0].end == date(2026, 3, 25, 17, 0))
        }
    }

    @Test func bufferRoundMinSlotTriple_gapExactlyAtMinimum_survives() async {
        var pinned: [String: Any] = stockWorkingSettings  // rounding 30, minSlot 30
        pinned[AppSettings.eventBufferMinutesKey] = 5
        await withPinnedSettings(pinned) {
            let store = EKEventStore()
            let a = EKEvent(eventStore: store)
            a.startDate = date(2026, 3, 25, 9, 0)
            a.endDate = date(2026, 3, 25, 10, 40)
            let b = EKEvent(eventStore: store)
            b.startDate = date(2026, 3, 25, 11, 40)
            b.endDate = date(2026, 3, 25, 17, 0)
            let wedMorning = date(2026, 3, 25, 8, 0)
            let result = service.calculateAvailability(
                events: [a, b], rangeType: .businessDays(1), now: wedMorning
            )
            // pad(5): free 10:45-11:35 → round(30): 11:00-11:30 = exactly the
            // 30-min minimum, so the slot survives as the day's only slot.
            let slots = result[date(2026, 3, 25)]!
            #expect(slots.count == 1)
            #expect(slots[0].start == date(2026, 3, 25, 11, 0))
            #expect(slots[0].end == date(2026, 3, 25, 11, 30))
        }
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

    // MARK: - Next 30 Days Including Today (U4 proposal window)

    @Test func next30DaysIncludingToday_startsToday_whenViable() async {
        await withPinnedSettings(stockWorkingSettings) {
            let wedMorning = date(2026, 3, 25, 8, 0)
            let days = service.businessDaysForRange(
                .next30DaysIncludingToday, from: wedMorning, workingDays: monFri
            )
            #expect(days.first == cal.startOfDay(for: wedMorning))
            for d in days { #expect(monFri.contains(cal.component(.weekday, from: d))) }
            #expect(days.count >= 20 && days.count <= 23)
        }
    }

    @Test func next30DaysIncludingToday_skipsToday_whenBufferedPastWorkEnd() async {
        await withPinnedSettings(stockWorkingSettings) {
            // 4:30pm + 1h buffer clears 5pm work end, so today drops.
            let wedLate = date(2026, 3, 25, 16, 30)
            let days = service.businessDaysForRange(
                .next30DaysIncludingToday, from: wedLate, workingDays: monFri
            )
            #expect(days.first == date(2026, 3, 26))
        }
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
    @Test func thisWeek_fridayEvening_rollsToNextWeek() async {
        await withPinnedSettings(stockWorkingSettings) {
            let friEvening = date(2026, 3, 27, 18)
            let days = service.businessDaysForRange(.thisWeek, from: friEvening, workingDays: monFri)
            #expect(days.count == 5)
            #expect(cal.component(.weekday, from: days[0]) == 2) // Monday
            #expect(cal.component(.day, from: days[0]) == 30)
        }
    }

    @Test func thisWeek_fridayNoon_stillIncludesFriday() async {
        await withPinnedSettings(stockWorkingSettings) {
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
    @Test func emptyEvents_todayIsBuffered() async {
        await withPinnedSettings(stockWorkingSettings) {
            let monNoon = date(2026, 3, 23, 12)
            let result = service.calculateAvailability(events: [], rangeType: .businessDays(1), now: monNoon)
            let today = cal.startOfDay(for: monNoon)
            #expect(result.count == 1)
            #expect(result[today]?.count == 1)
            #expect(result[today]?.first?.start == date(2026, 3, 23, 13, 0))
            #expect(result[today]?.first?.end == date(2026, 3, 23, 17, 0))
        }
    }

    @Test func emptyEvents_futureDayGetsFullWindow() async {
        await withPinnedSettings(stockWorkingSettings) {
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
    let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_US"))

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

    @Test func slotDropped_whenRoundingMakesStartGteEnd_dayAbsentEndToEnd() async {
        await withPinnedSettings(stockWorkingSettings) {
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
    @Test func roundingGranularity_invalidValue_fallsBackToDefault() async {
        await withPinnedSettings([AppSettings.roundingGranularityKey: 7]) {
            #expect(AppSettings.roundingGranularity == AppSettings.defaultRoundingGranularity)
        }
    }

    @Test func roundingGranularity_validValues_pass() async {
        for valid in AppSettings.validRoundingValues {
            await withPinnedSettings([AppSettings.roundingGranularityKey: valid]) {
                #expect(AppSettings.roundingGranularity == valid)
            }
        }
    }

    @Test func minimumSlotMinutes_outOfBounds_fallsBackToDefault() async {
        await withPinnedSettings([AppSettings.minimumSlotMinutesKey: 5]) {
            #expect(AppSettings.minimumSlotMinutes == AppSettings.defaultMinimumSlot)
        }
        await withPinnedSettings([AppSettings.minimumSlotMinutesKey: 999]) {
            #expect(AppSettings.minimumSlotMinutes == AppSettings.defaultMinimumSlot)
        }
    }

    @Test func minimumSlotMinutes_boundaryValues_pass() async {
        await withPinnedSettings([AppSettings.minimumSlotMinutesKey: 15]) {
            #expect(AppSettings.minimumSlotMinutes == 15)
        }
        await withPinnedSettings([AppSettings.minimumSlotMinutesKey: 120]) {
            #expect(AppSettings.minimumSlotMinutes == 120)
        }
    }

    @Test func defaultFormat_unknownValue_fallsBackToPlainText() async {
        await withPinnedSettings([AppSettings.defaultFormatKey: "yaml"]) {
            #expect(AppSettings.defaultFormat == "plainText")
            #expect(AppSettings.defaultFormatTemplate == .plainText)
        }
    }

    @Test func defaultFormat_markdown_passes() async {
        await withPinnedSettings([AppSettings.defaultFormatKey: "markdown"]) {
            #expect(AppSettings.defaultFormat == "markdown")
            #expect(AppSettings.defaultFormatTemplate == .markdown)
        }
    }

    @Test func eventBufferMinutes_invalidValue_fallsBackToZero() async {
        await withPinnedSettings([AppSettings.eventBufferMinutesKey: 7]) {
            #expect(AppSettings.eventBufferMinutes == 0)
        }
    }

    @Test func eventBufferMinutes_validValues_pass() async {
        for valid in AppSettings.validEventBufferValues {
            await withPinnedSettings([AppSettings.eventBufferMinutesKey: valid]) {
                #expect(AppSettings.eventBufferMinutes == valid)
            }
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
// MARK: - First-Run Coach Tests (KTD8)
// ============================================================================

@Suite("First-Run Coach")
@MainActor
struct FirstRunCoachTests {
    @Test func coachNeeded_onlyOnUserVisibleLaunch_onlyOnce() {
        // Permission outcome is deliberately not an input: the gestures
        // matter whether access was granted or denied.
        #expect(AppDelegate.coachmarkNeeded(hasShownCoachmark: false, intentDrivenLaunch: false))
        #expect(!AppDelegate.coachmarkNeeded(hasShownCoachmark: true, intentDrivenLaunch: false))
        #expect(!AppDelegate.coachmarkNeeded(hasShownCoachmark: false, intentDrivenLaunch: true))
        #expect(!AppDelegate.coachmarkNeeded(hasShownCoachmark: true, intentDrivenLaunch: true))
    }

    @Test func coachFlag_persistsOnceSet() async {
        await withPinnedSettings([AppSettings.hasShownCoachmarkKey: false]) {
            #expect(!AppSettings.hasShownCoachmark)
            AppSettings.setHasShownCoachmark()
            #expect(AppSettings.hasShownCoachmark)
        }
    }
}

// ============================================================================
// MARK: - App Intent Mapping Tests (KTD6)
// ============================================================================

@Suite("App Intent Mapping", .serialized)
struct AppIntentMappingTests {
    @Test func explicitRanges_mapToMenuEquivalents() {
        #expect(AvailabilityRange.nextWeek.dateRangeType == .nextWeek)
        #expect(AvailabilityRange.nextFortnight.dateRangeType == .nextFortnight)
        #expect(AvailabilityRange.next30Days.dateRangeType == .next30Days)
    }

    @Test func defaultRange_followsBusinessDaysSetting() async {
        await withPinnedSettings([
            AppSettings.defaultRangeModeKey: "businessDays",
            AppSettings.defaultBusinessDaysKey: 7,
        ]) {
            #expect(AvailabilityRange.defaultRange.dateRangeType == .businessDays(7))
        }
    }

    @Test func defaultRange_followsThisWeekSetting() async {
        await withPinnedSettings([AppSettings.defaultRangeModeKey: "thisWeek"]) {
            #expect(AvailabilityRange.defaultRange.dateRangeType == .thisWeek)
        }
    }

    @Test func fetchWindow_coversSameDayListAsAvailabilityMath() async {
        var pinned: [String: Any] = stockWorkingSettings
        pinned[AppSettings.workingDaysKey] = [2, 3, 4, 5, 6]
        await withPinnedSettings(pinned) {
            let service = AvailabilityService()
            let wedNoon = date(2026, 3, 25, 12)
            let window = service.fetchWindow(for: .businessDays(3), now: wedNoon)
            let days = service.businessDaysForRange(
                .businessDays(3), from: wedNoon, workingDays: [2, 3, 4, 5, 6]
            )
            #expect(window.start == cal.startOfDay(for: wedNoon))
            #expect(window.end == cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: days.last!)))
        }
    }

    @Test func fetchWindow_emptyDayList_fallsBackToOneWeek() async {
        await withPinnedSettings([AppSettings.workingDaysKey: [Int]()]) {
            let service = AvailabilityService()
            let wedNoon = date(2026, 3, 25, 12)
            let window = service.fetchWindow(for: .businessDays(3), now: wedNoon)
            let today = cal.startOfDay(for: wedNoon)
            #expect(window.start == today)
            #expect(window.end == cal.date(byAdding: .day, value: 7, to: today))
        }
    }
}

// ============================================================================
// MARK: - Locale-Aware Formatting Tests (KTD5/OQ8)
// ============================================================================

@Suite("Locale-Aware Formatting")
struct LocaleFormattingTests {
    private let enUS = Locale(identifier: "en_US")

    /// en_US names and label order with a forced 24-hour cycle -- fully
    /// deterministic regardless of the machine locale.
    private var forced24: Locale {
        var components = Locale.Components(identifier: "en_US")
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }

    @Test func enUS_reproducesGoldenOutput() {
        let formatter = AvailabilityFormatter(locale: enUS)
        let slots = [date(2026, 3, 25): [slot(25, 9, 0, 10, 30), slot(25, 14, 0, 15, 0)]]
        #expect(formatter.format(slots: slots) == "Wed Mar 25: 9-10:30am, 2-3pm")
    }

    @Test func forced24h_onTheHour_noPeriodsNoElision() {
        let formatter = AvailabilityFormatter(locale: forced24)
        #expect(formatter.formatTimeRange(slot(25, 14, 0, 15, 0)) == "14-15")
    }

    @Test func forced24h_withMinutes_bothSidesCarryMinutes() {
        let formatter = AvailabilityFormatter(locale: forced24)
        #expect(formatter.formatTimeRange(slot(25, 14, 30, 16, 0)) == "14:30-16:00")
        #expect(formatter.formatTimeRange(slot(25, 9, 0, 10, 45)) == "9:00-10:45")
    }

    @Test func forced24h_crossNoon() {
        let formatter = AvailabilityFormatter(locale: forced24)
        #expect(formatter.formatTimeRange(slot(25, 9, 0, 14, 0)) == "9-14")
    }

    @Test func forced24h_midnightAndNoonBoundaries() {
        let formatter = AvailabilityFormatter(locale: forced24)
        #expect(formatter.formatTimeRange(slot(25, 0, 0, 9, 0)) == "0-9")
        #expect(formatter.formatTimeRange(slot(25, 12, 0, 17, 0)) == "12-17")
    }

    @Test func twelveHour_midnightAndNoonBoundaries_unchanged() {
        let formatter = AvailabilityFormatter(locale: enUS)
        #expect(formatter.formatTimeRange(slot(25, 0, 0, 9, 0)) == "12-9am")
        #expect(formatter.formatTimeRange(slot(25, 11, 30, 12, 0)) == "11:30am-12pm")
    }

    @Test func forced24h_fullOutput_noPeriods() {
        let formatter = AvailabilityFormatter(locale: forced24)
        let slots = [date(2026, 3, 25): [slot(25, 9, 30, 10, 15), slot(25, 14, 0, 15, 0)]]
        #expect(formatter.format(slots: slots) == "Wed Mar 25: 9:30-10:15, 14-15")
    }

    @Test func dayPrecedesMonth_handlesBothMonthSymbols() {
        #expect(!AvailabilityFormatter.dayPrecedesMonth(inTemplate: "MMM d"))
        #expect(AvailabilityFormatter.dayPrecedesMonth(inTemplate: "d MMM"))
        // Persian answers the MMMd skeleton with the standalone month
        // symbol: "d LLL" is day-first and must be detected as such.
        #expect(AvailabilityFormatter.dayPrecedesMonth(inTemplate: "d LLL"))
        #expect(!AvailabilityFormatter.dayPrecedesMonth(inTemplate: "LLL d"))
        #expect(!AvailabilityFormatter.dayPrecedesMonth(inTemplate: ""))
    }

    @Test func dayFirstLocale_labelOrderLocalizes() {
        // en_AU orders day before month ("Wed 25 Mar") with English names,
        // so the assertion is deterministic across machines.
        let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_AU"))
        let slots = [date(2026, 3, 25): [slot(25, 14, 0, 15, 0)]]
        #expect(formatter.format(slots: slots) == "Wed 25 Mar: 2-3pm")
    }

    @Test func timezonePlusLocale_combinedPathConsistent() throws {
        // 14:00-15:00 UTC is 10-11 in New York; a 24h locale must render the
        // converted times with the New York day label.
        let utcCal: Calendar = {
            var c = Calendar.current
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }()
        let start = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 14))!
        let end = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 15))!
        let dayKey = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 25))!
        let newYork = try #require(TimeZone(identifier: "America/New_York"))

        let formatter = AvailabilityFormatter(locale: forced24)
        let output = formatter.format(
            slots: [dayKey: [TimeSlot(start: start, end: end)]],
            timezone: newYork
        )
        #expect(output == "Wed Mar 25: 10-11")
    }
}

// ============================================================================
// MARK: - PasteboardWriter Tests (KTD4)
// ============================================================================

@Suite("PasteboardWriter")
@MainActor
struct PasteboardWriterTests {
    /// Pinned so golden strings stay en_US byte-exact (OQ2).
    private let enUS = Locale(identifier: "en_US")

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
            slots: sampleSlots, showTimeZone: false, template: .plainText,
            locale: enUS, pasteboard: pb
        )
        #expect(wrote)

        let expected = AvailabilityFormatter(locale: enUS).format(
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
            slots: sampleSlots, showTimeZone: false, template: .markdown,
            locale: enUS, pasteboard: pb
        )
        #expect(pb.string(forType: .string) == "- **Wed Mar 25:** 9-10:30am, 2-3pm")
        #expect(pb.data(forType: .rtf) == nil)
        #expect(pb.data(forType: .html) == nil)
    }

    @Test func rtf_roundTripsWithBoldDayLabelsAndPlainTimes() throws {
        let pb = testPasteboard()
        PasteboardWriter.write(
            slots: sampleSlots, showTimeZone: false, template: .plainText,
            locale: enUS, pasteboard: pb
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
            template: .plainText, locale: enUS, pasteboard: pb
        )

        #expect(pb.string(forType: .string)?.contains("10-11am") == true)

        let rtfData = try #require(pb.data(forType: .rtf))
        let fromRTF = try #require(NSAttributedString(rtf: rtfData, documentAttributes: nil))
        #expect(fromRTF.string.contains("10-11am"))

        let htmlData = try #require(pb.data(forType: .html))
        let html = try #require(String(data: htmlData, encoding: .utf8))
        #expect(html.contains("10-11am"))
    }

    @Test func asOfStamp_passesThroughToAllFlavors() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = utc.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 18))!
        let pb = testPasteboard()
        PasteboardWriter.write(
            slots: sampleSlots, showTimeZone: false,
            timezone: TimeZone(identifier: "America/New_York"),
            template: .plainText, locale: enUS, asOf: instant, pasteboard: pb
        )
        #expect(pb.string(forType: .string)?.hasSuffix("(as of Mar 25, 2026, 2:00 PM)") == true)
        let rtf = try #require(pb.data(forType: .rtf))
        let attributed = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(attributed.string.contains("(as of Mar 25, 2026, 2:00 PM)"))
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

    // MARK: - writeText (U4 proposal path)

    @Test func writeText_writesAllThreeFlavors() throws {
        let pb = testPasteboard()
        let text = "Here are a few times — reply with a number: 1) A; 2) B; 3) C."
        #expect(PasteboardWriter.writeText(text, pasteboard: pb))
        #expect(pb.string(forType: .string) == text)
        #expect(pb.data(forType: .rtf) != nil)
        #expect(pb.data(forType: .html) != nil)
    }

    @Test func writeText_empty_returnsFalse_pasteboardUntouched() {
        let pb = testPasteboard()
        pb.clearContents()
        pb.setString("sentinel", forType: .string)
        #expect(!PasteboardWriter.writeText("", pasteboard: pb))
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

    // MARK: - Stale IDs vs the last-calendar guard (review finding)

    @Test func staleIDAlongsideLastRealCalendar_uncheckStillBlocked() {
        // {real, stale}: only "work" is visible, so unchecking it must be
        // blocked -- the stale ID must not smuggle in a zero-checked state.
        let result = CalendarPickerView.updatedSelection(
            togglingID: "work", isOn: false, current: ["work", "deleted-cal"], allIDs: allIDs
        )
        #expect(result == nil)
    }

    @Test func allStaleStoredSet_behavesAsAllSelected() {
        // All-stale resolves to "all calendars" on the read path; the write
        // path must expand the same way, so one uncheck yields all-minus-one.
        let result = CalendarPickerView.updatedSelection(
            togglingID: "home", isOn: false, current: ["deleted-1", "deleted-2"], allIDs: allIDs
        )
        #expect(result == ["work", "shared"])
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

    @Test func attentionAndOutcomeSymbols_allDistinct() {
        // The persistent-badge layer must never look like an outcome flash.
        let outcomeSymbols = [CopyOutcome.copied, .noAccess, .noCalendars, .noSlots].map(\.symbolName)
        let attentionSymbols = [AttentionState.calendarsUnavailable, .copiedSlotStale].compactMap(\.symbolName)
        let all = outcomeSymbols + attentionSymbols
        #expect(all.count == 6)
        #expect(Set(all).count == all.count)
    }

    @Test func attentionStates_tooltipsAndSymbols() {
        #expect(AttentionState.none.tooltip == nil)
        #expect(AttentionState.none.symbolName == nil)
        #expect(AttentionState.calendarsUnavailable.tooltip?.isEmpty == false)
        #expect(AttentionState.copiedSlotStale.tooltip?.isEmpty == false)
    }
}

// ============================================================================
// MARK: - Attention State Tests (U5, KTD7)
// ============================================================================

@Suite("Attention State")
@MainActor
struct AttentionStateTests {
    @Test func setThenClear_updatesState() {
        let c = StatusItemController()
        #expect(c.attentionState == .none)
        c.setAttention(.calendarsUnavailable)
        #expect(c.attentionState == .calendarsUnavailable)
        c.clearAttention()
        #expect(c.attentionState == .none)
    }

    @Test func settingSameStateTwice_idempotent() {
        let c = StatusItemController()
        c.setAttention(.copiedSlotStale)
        c.setAttention(.copiedSlotStale)
        #expect(c.attentionState == .copiedSlotStale)
    }

    @Test func clearWhenNone_isNoOp() {
        let c = StatusItemController()
        c.clearAttention()
        #expect(c.attentionState == .none)
    }

    @Test func badgedImage_builtForSetStates_nilForNone_template() {
        #expect(StatusItemController.attentionSymbolImage(for: .none) == nil)
        let cal = StatusItemController.attentionSymbolImage(for: .calendarsUnavailable)
        let stale = StatusItemController.attentionSymbolImage(for: .copiedSlotStale)
        #expect(cal != nil && cal?.isTemplate == true)
        #expect(stale != nil && stale?.isTemplate == true)
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
    let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_US"))

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

// ============================================================================
// MARK: - Timezone Label Tests (U2/R3)
// ============================================================================

@Suite("Timezone Label")
struct TimezoneLabelTests {
    // Names are locale-dependent ("ET" vs "New York Time", "Germany Time"),
    // and timezoneString reads the system locale, so these assert STRUCTURE,
    // not exact strings: one GMT offset, and a readable name that is not
    // itself an offset. That is exactly what R3 promises.

    /// Number of "GMT+"/"GMT-" offset tokens in a label. The shipped bug
    /// produced two ("GMT+2, GMT+2"); the fix produces one.
    private func offsetTokenCount(_ s: String) -> Int {
        (s.components(separatedBy: "GMT+").count - 1) + (s.components(separatedBy: "GMT-").count - 1)
    }

    @Test func easternZones_oneOffsetToken_readableName() throws {
        for id in ["Europe/Berlin", "Asia/Kolkata", "Australia/Sydney"] {
            let tz = try #require(TimeZone(identifier: id))
            let label = AvailabilityFormatter.timezoneString(for: tz)
            #expect(offsetTokenCount(label) == 1, "\(id): \(label)")
            let name = label.components(separatedBy: ", ").first ?? ""
            #expect(!name.isEmpty, "\(id): \(label)")
            #expect(!name.hasPrefix("GMT+") && !name.hasPrefix("GMT-"), "\(id): \(label)")
        }
    }

    @Test func newYork_keepsSensibleLabel() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        let label = AvailabilityFormatter.timezoneString(for: tz)
        #expect(offsetTokenCount(label) == 1)
        #expect(label.contains("GMT-"))  // New York is west of GMT year-round
        let name = label.components(separatedBy: ", ").first ?? ""
        #expect(!name.isEmpty)
    }

    @Test func fixedOffsetZone_fallsThroughChainWithoutCrash() throws {
        // A bare fixed-offset zone has no human name — .shortGeneric may be
        // nil or itself an offset. The point of the seam is that the chain
        // never crashes and always yields a non-empty string (named zones the
        // picker actually offers get the readable name tested above). Such a
        // synthetic zone is not selectable in the app.
        let tz = try #require(TimeZone(secondsFromGMT: 5 * 3600))
        let name = AvailabilityFormatter.localizedZoneName(for: tz)
        #expect(!name.isEmpty)
        #expect(AvailabilityFormatter.timezoneString(for: tz).contains("GMT+5"))
    }

    @Test func plainAndAttributedRenderers_shareTimezoneLabel() {
        let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_US"))
        let slots: [Date: [TimeSlot]] = [date(2026, 3, 25): [slot(25, 9, 0, 10, 0)]]
        let plainLast = formatter.format(slots: slots, showTimeZone: true)
            .split(separator: "\n").map(String.init).last ?? ""
        let attrLast = formatter.formatAttributed(slots: slots, showTimeZone: true)
            .string.split(separator: "\n").map(String.init).last ?? ""
        #expect(attrLast == plainLast)
        #expect(plainLast.hasPrefix("(") && plainLast.hasSuffix(")"))
        #expect(offsetTokenCount(plainLast) == 1)
    }
}

// ============================================================================
// MARK: - As-Of Stamp Tests (U3/R4)
// ============================================================================

@Suite("As-Of Stamp")
struct AsOfStampTests {
    let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_US"))

    /// Fixture instant: 2026-03-25 18:00:00 UTC (= 2:00 PM EDT in New York).
    private var instant: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 18))!
    }
    private var slots: [Date: [TimeSlot]] {
        [date(2026, 3, 25): [slot(25, 9, 0, 10, 0)]]
    }

    @Test func stampOff_outputByteIdenticalToPreU3() {
        #expect(formatter.format(slots: slots) == "Wed Mar 25: 9-10am")
    }

    @Test func stampOn_lastLineIsAsOf_enUSGolden() {
        let out = formatter.format(
            slots: slots, timezone: TimeZone(identifier: "America/New_York"), asOf: instant
        )
        #expect(out.split(separator: "\n").map(String.init).last == "(as of Mar 25, 2026, 2:00 PM)")
    }

    @Test func stampAndTimezone_orderDaysThenZoneThenStamp_bothRenderers() {
        let ny = TimeZone(identifier: "America/New_York")!
        let plain = formatter.format(slots: slots, showTimeZone: true, timezone: ny, asOf: instant)
        let lines = plain.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(!lines[0].hasPrefix("("))                                 // day line
        #expect(lines[1].hasPrefix("(") && lines[1].contains("GMT") && !lines[1].hasPrefix("(as of"))  // zone line
        #expect(lines[2] == "(as of Mar 25, 2026, 2:00 PM)")             // stamp line
        // Attributed renderer must carry the identical trailing lines.
        let attr = formatter.formatAttributed(slots: slots, showTimeZone: true, timezone: ny, asOf: instant)
        #expect(attr.string == plain)
    }

    @Test func stampFollowsRecipientTimezone() {
        let ny = formatter.format(slots: slots, timezone: TimeZone(identifier: "America/New_York"), asOf: instant)
            .split(separator: "\n").map(String.init).last
        let la = formatter.format(slots: slots, timezone: TimeZone(identifier: "America/Los_Angeles"), asOf: instant)
            .split(separator: "\n").map(String.init).last
        #expect(ny == "(as of Mar 25, 2026, 2:00 PM)")
        #expect(la == "(as of Mar 25, 2026, 11:00 AM)")  // 18:00 UTC = 11:00 PDT
    }
}

// ============================================================================
// MARK: - Proposal Mode Tests (U4/R1/R2)
// ============================================================================

@Suite("Proposal Mode")
struct ProposalModeTests {
    let service = AvailabilityService()
    let formatter = AvailabilityFormatter(locale: Locale(identifier: "en_US"))

    // MARK: - selectProposalSlots (KTD6)

    @Test func fiveDays_picksEarliestOnFirstThreeDistinctDays() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 23): [slot(23, 9, 0, 10, 0), slot(23, 14, 0, 15, 0)],
            date(2026, 3, 24): [slot(24, 11, 0, 12, 0)],
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0), slot(25, 15, 0, 16, 0)],
            date(2026, 3, 26): [slot(26, 9, 0, 10, 0)],
            date(2026, 3, 27): [slot(27, 9, 0, 10, 0)],
        ]
        let chosen = AvailabilityService.selectProposalSlots(from: slots, count: 3)
        #expect(chosen.map(\.start) == [
            date(2026, 3, 23, 9, 0), date(2026, 3, 24, 11, 0), date(2026, 3, 25, 9, 0),
        ])
    }

    @Test func oneDayThreeSlots_sameDayFallbackFillsToThree() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0), slot(25, 11, 0, 12, 0), slot(25, 14, 0, 15, 0)],
        ]
        let chosen = AvailabilityService.selectProposalSlots(from: slots, count: 3)
        #expect(chosen.map(\.start) == [
            date(2026, 3, 25, 9, 0), date(2026, 3, 25, 11, 0), date(2026, 3, 25, 14, 0),
        ])
    }

    @Test func twoSlotsTotal_returnsTwo() {
        let slots: [Date: [TimeSlot]] = [
            date(2026, 3, 25): [slot(25, 9, 0, 10, 0)],
            date(2026, 3, 26): [slot(26, 9, 0, 10, 0)],
        ]
        #expect(AvailabilityService.selectProposalSlots(from: slots, count: 3).count == 2)
    }

    @Test func oneSlotTotal_returnsOne() {
        let slots: [Date: [TimeSlot]] = [date(2026, 3, 25): [slot(25, 9, 0, 10, 0)]]
        #expect(AvailabilityService.selectProposalSlots(from: slots, count: 3).count == 1)
    }

    @Test func zeroSlots_returnsEmpty() {
        #expect(AvailabilityService.selectProposalSlots(from: [:], count: 3).isEmpty)
    }

    @Test func countZero_returnsEmpty() {
        let slots: [Date: [TimeSlot]] = [date(2026, 3, 25): [slot(25, 9, 0, 10, 0)]]
        #expect(AvailabilityService.selectProposalSlots(from: slots, count: 0).isEmpty)
    }

    @Test func selectionInheritsBuffer_noReDerivation() async {
        var pinned: [String: Any] = stockWorkingSettings
        pinned[AppSettings.roundingGranularityKey] = 0
        pinned[AppSettings.eventBufferMinutesKey] = 10
        await withPinnedSettings(pinned) {
            let store = EKEventStore()
            let m = EKEvent(eventStore: store)
            m.startDate = date(2026, 3, 25, 10, 0)
            m.endDate = date(2026, 3, 25, 11, 0)
            let wedMorning = date(2026, 3, 25, 8, 0)
            let slots = service.calculateAvailability(
                events: [m], rangeType: .businessDays(1), now: wedMorning
            )
            let chosen = AvailabilityService.selectProposalSlots(from: slots, count: 3)
            // Earliest slot ends at 9:50 (10:00 minus the 10-min buffer):
            // the proposal consumes the padded pipeline output as-is.
            #expect(chosen.first?.end == date(2026, 3, 25, 9, 50))
        }
    }

    // MARK: - formatProposal (R1/R2 golden strings)

    @Test func threeSlots_enUSGolden() {
        let out = formatter.formatProposal(slots: [slot(25, 9, 0, 10, 30), slot(26, 14, 0, 15, 0), slot(27, 10, 0, 12, 0)])
        #expect(out == "Here are a few times that could work — reply with a number: 1) Wed Mar 25, 9-10:30am; 2) Thu Mar 26, 2-3pm; 3) Fri Mar 27, 10am-12pm.")
    }

    @Test func twoSlots_keepsReplyWithNumber() {
        let out = formatter.formatProposal(slots: [slot(25, 9, 0, 10, 0), slot(26, 14, 0, 15, 0)])
        #expect(out == "Here are a few times that could work — reply with a number: 1) Wed Mar 25, 9-10am; 2) Thu Mar 26, 2-3pm.")
    }

    @Test func oneSlot_dropsReplyWithNumber() {
        let out = formatter.formatProposal(slots: [slot(25, 9, 0, 10, 30)])
        #expect(out == "Here's a time that could work: Wed Mar 25, 9-10:30am.")
    }

    @Test func emptySlots_returnsEmptyString() {
        #expect(formatter.formatProposal(slots: []) == "")
    }

    @Test func withTimezone_appendsLabelLine() {
        let out = formatter.formatProposal(slots: [slot(25, 9, 0, 10, 0)], showTimeZone: true)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("Here's a time"))
        #expect(lines[1].hasPrefix("(") && lines[1].contains("GMT"))
    }

    @Test func withStamp_appendsAsOfLine() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = utc.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 18))!
        let out = formatter.formatProposal(slots: [slot(25, 9, 0, 10, 0)], asOf: instant)
        #expect(out.split(separator: "\n").map(String.init).last?.hasPrefix("(as of ") == true)
    }
}

// ============================================================================
// MARK: - Proposal Menu Wiring Tests (U4)
// ============================================================================

@Suite("Proposal Menu")
@MainActor
struct ProposalMenuTests {
    @Test func contextMenu_containsProposalItem_wiredToAction() {
        let controller = StatusItemController()
        let menu = controller.contextMenu()
        let item = menu.items.first { $0.title == "Copy 3 Suggested Times" }
        #expect(item != nil)
        #expect(item?.action == #selector(StatusItemController.copySuggestedTimes))
        #expect(item?.target === controller)
    }

    @Test func copySuggestedTimes_invokesOnProposalCallback() {
        let controller = StatusItemController()
        var fired = false
        controller.onProposal = { fired = true }
        controller.copySuggestedTimes()
        #expect(fired)
    }
}
