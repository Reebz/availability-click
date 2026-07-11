import AppIntents
import Foundation

/// Range parameter for the Shortcuts action (KTD6). `defaultRange` follows
/// the user's configured default (defaultRangeMode / defaultBusinessDays).
enum AvailabilityRange: String, AppEnum {
    case defaultRange
    case nextWeek
    case nextFortnight
    case next30Days

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Availability Range")
    static let caseDisplayRepresentations: [AvailabilityRange: DisplayRepresentation] = [
        .defaultRange: "Default range",
        .nextWeek: "Next week",
        .nextFortnight: "Next fortnight",
        .next30Days: "Next 30 days",
    ]

    var dateRangeType: DateRangeType {
        switch self {
        case .defaultRange: AppSettings.defaultRangeType
        case .nextWeek: .nextWeek
        case .nextFortnight: .nextFortnight
        case .next30Days: .next30Days
        }
    }
}

enum GetAvailabilityError: Error, CustomLocalizedStringResourceConvertible {
    case calendarAccessNotGranted
    case noCalendarsAvailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .calendarAccessNotGranted:
            "Availability Click doesn't have calendar access. Open the Availability Click app and click its menu bar icon to trigger the permission prompt, then run this action again."
        case .noCalendarsAvailable:
            "No calendars are available on this Mac. Add a calendar account in System Settings, then run this action again."
        }
    }
}

/// Read-only, interactive-safe (KTD6): returns the formatted availability
/// string without opening UI, flashing the icon, touching the clipboard, or
/// triggering the system permission prompt.
struct GetAvailabilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Availability"
    static let description = IntentDescription(
        "Returns your free calendar slots as formatted text. Never opens the app's UI and never touches the clipboard."
    )
    /// Calendar-derived data must not be readable from a locked Mac (OQ9),
    /// so fully unattended runs require the device to be unlocked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Range", default: .defaultRange)
    var range: AvailabilityRange

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // A cold Shortcuts run launches the app headless; mark the launch so
        // its user-visible side effects (TCC auto-request, first-run coach)
        // stay quiet (OQ10).
        AppDelegate.intentDidRunThisLaunch = true

        // Shortcuts runs are frequently unattended: never trigger the system
        // permission prompt from here -- throw a descriptive error instead.
        guard CalendarService.shared.isAuthorized else {
            throw GetAvailabilityError.calendarAccessNotGranted
        }

        // Mirror the click pipeline's .noCalendars outcome: an empty store
        // must error, not report a fully-free week computed from zero events.
        guard !CalendarService.shared.selectedCalendars().isEmpty else {
            throw GetAvailabilityError.noCalendarsAvailable
        }

        let rangeType = range.dateRangeType
        let service = AvailabilityService()
        let window = service.fetchWindow(for: rangeType)
        let events = await CalendarService.shared.fetchEvents(from: window.start, to: window.end)
        let slots = service.calculateAvailability(events: events, rangeType: rangeType)

        // Always the plain-text template: markdown syntax is unwanted
        // mid-automation (KTD6).
        let text = AvailabilityFormatter().format(
            slots: slots,
            showTimeZone: AppSettings.showTimeZone,
            template: .plainText
        )
        return .result(value: text)
    }
}

struct AvailabilityClickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetAvailabilityIntent(),
            phrases: ["Get availability from \(.applicationName)"],
            shortTitle: "Get Availability",
            systemImageName: "calendar"
        )
    }
}
