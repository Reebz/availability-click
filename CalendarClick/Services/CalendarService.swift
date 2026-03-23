@preconcurrency import EventKit
import Combine

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()

    private var changeObserver: AnyCancellable?
    private var debouncedRefresh: AnyCancellable?
    private let changeSubject = PassthroughSubject<Void, Never>()

    /// Called when calendar data changes externally
    var onStoreChanged: (() -> Void)?

    private init() {
        AppSettings.registerDefaults()
        observeStoreChanges()
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess || status == .authorized
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Calendars

    var allCalendars: [EKCalendar] {
        store.calendars(for: .event)
    }

    func selectedCalendars() -> [EKCalendar] {
        let savedIDs = Set(AppSettings.selectedCalendarIDs)
        let all = allCalendars

        // Empty selection means "all calendars"
        if savedIDs.isEmpty { return all }

        let valid = all.filter { savedIDs.contains($0.calendarIdentifier) }

        // If all saved IDs are stale, fall back to all calendars
        if valid.isEmpty && !all.isEmpty { return all }

        return valid
    }

    // MARK: - Event Fetching

    func fetchEvents(from start: Date, to end: Date) async -> [EKEvent] {
        guard isAuthorized else { return [] }

        let calendars = selectedCalendars()
        guard !calendars.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) { [store] in
            let predicate = store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: calendars
            )
            return store.events(matching: predicate)
        }.value
    }

    // MARK: - Store Change Observation

    private func observeStoreChanges() {
        changeObserver = NotificationCenter.default
            .publisher(for: .EKEventStoreChanged, object: store)
            .sink { [weak self] _ in
                self?.changeSubject.send()
            }

        debouncedRefresh = changeSubject
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.store.reset()
                self?.onStoreChanged?()
            }
    }
}
