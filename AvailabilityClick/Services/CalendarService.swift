@preconcurrency import EventKit
import os

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()

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

    /// Selection resolution (KTD2), extracted pure so it is unit-testable:
    /// `[]` means "never customized = all calendars"; a saved set whose IDs
    /// are all stale also falls back to all calendars. Nonisolated: pure
    /// function, also called from the picker's binding getter.
    nonisolated static func effectiveSelectedIDs(saved: [String], allIDs: [String]) -> Set<String> {
        let savedSet = Set(saved)
        if savedSet.isEmpty { return Set(allIDs) }

        let valid = savedSet.intersection(allIDs)
        if valid.isEmpty && !allIDs.isEmpty { return Set(allIDs) }

        return valid
    }

    // MARK: - Event Fetching

    // EKEvent/EKEventStore aren't Sendable in Swift 6 but events(matching:) is
    // documented as thread-safe for reads. Suppress the unavoidable warnings.
    @preconcurrency
    func fetchEvents(from start: Date, to end: Date) async -> [EKEvent] {
        guard isAuthorized else { return [] }

        let calendars = selectedCalendars()
        guard !calendars.isEmpty else { return [] }

        nonisolated(unsafe) let unsafeStore = store
        nonisolated(unsafe) let unsafeCalendars = calendars

        return await Task.detached(priority: .userInitiated) {
            let predicate = unsafeStore.predicateForEvents(
                withStart: start,
                end: end,
                calendars: unsafeCalendars
            )
            return unsafeStore.events(matching: predicate)
        }.value
    }
}
