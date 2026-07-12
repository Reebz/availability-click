@preconcurrency import EventKit
import Foundation
import os

extension Notification.Name {
    /// Posted by the calendar picker when the user changes their selection, so
    /// the app can re-evaluate the persistent calendars-unavailable badge (R11).
    static let calendarSelectionChanged = Notification.Name("AvailabilityClick.calendarSelectionChanged")
}

/// Carries a non-Sendable value across an isolation boundary the surrounding
/// code has independently verified safe (documented-thread-safe EventKit
/// reads).
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    private init() {
        AppSettings.registerDefaults()
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            // A thrown error is a system failure, not a user denial -- leave a
            // trace in Console.app so support isn't debugging a silent false.
            Logger(subsystem: "com.availabilityclick.AvailabilityClick", category: "CalendarService")
                .error("requestFullAccessToEvents failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Calendars

    var allCalendars: [EKCalendar] {
        store.calendars(for: .event)
    }

    func selectedCalendars() -> [EKCalendar] {
        let all = allCalendars
        let effective = Self.effectiveSelectedIDs(
            saved: AppSettings.selectedCalendarIDs,
            allIDs: all.map(\.calendarIdentifier)
        )
        return all.filter { effective.contains($0.calendarIdentifier) }
    }

    /// Selection resolution (KTD2/KTD12), extracted pure so it is
    /// unit-testable. Nonisolated: pure function, also called from the picker's
    /// binding getter.
    ///
    /// `[]` (never customized) = all calendars, the first-run behavior. A
    /// customized set is honored intersected with what still exists; when every
    /// saved ID is stale that intersection is EMPTY -- the app then computes
    /// from NO calendars and shows a persistent notice rather than silently
    /// widening back to all (R11). The two empty-ish cases must stay distinct
    /// or first-run breaks.
    nonisolated static func effectiveSelectedIDs(saved: [String], allIDs: [String]) -> Set<String> {
        let savedSet = Set(saved)
        if savedSet.isEmpty { return Set(allIDs) }
        return savedSet.intersection(allIDs)
    }

    /// True when the user customized their selection but every saved ID is now
    /// stale (deleted or offline account) -- distinct from an empty store and
    /// from the never-customized first-run state. Drives the persistent
    /// calendars-unavailable badge and the picker notice (R11). Pure.
    nonisolated static func selectionIsAllStale(saved: [String], allIDs: [String]) -> Bool {
        guard !saved.isEmpty, !allIDs.isEmpty else { return false }
        return Set(saved).isDisjoint(with: allIDs)
    }

    /// `selectionIsAllStale` over the live settings and store.
    var savedSelectionIsAllStale: Bool {
        Self.selectionIsAllStale(
            saved: AppSettings.selectedCalendarIDs,
            allIDs: allCalendars.map(\.calendarIdentifier)
        )
    }

    // MARK: - Event Fetching

    // EKEvent/EKEventStore aren't Sendable in Swift 6 but events(matching:)
    // is documented as thread-safe for reads. Boxes carry the store in and
    // the results out so every closure capture is Sendable -- newer Swift
    // compilers (CI's Xcode) reject nonisolated(unsafe) local captures in a
    // sending closure as region violations where older ones only warned.
    func fetchEvents(from start: Date, to end: Date) async -> [EKEvent] {
        guard isAuthorized else { return [] }

        let calendars = selectedCalendars()
        guard !calendars.isEmpty else { return [] }

        let storeBox = UncheckedSendableBox(store)
        let calendarsBox = UncheckedSendableBox(calendars)

        let resultBox = await Task.detached(priority: .userInitiated) { () -> UncheckedSendableBox<[EKEvent]> in
            let predicate = storeBox.value.predicateForEvents(
                withStart: start,
                end: end,
                calendars: calendarsBox.value
            )
            return UncheckedSendableBox(storeBox.value.events(matching: predicate))
        }.value
        return resultBox.value
    }
}
