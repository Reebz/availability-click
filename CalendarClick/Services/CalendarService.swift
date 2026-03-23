import EventKit

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()

    private init() {}

    // MARK: - Placeholder for Phase 2
}
