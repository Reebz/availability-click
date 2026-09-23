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

    /// Resolves the effective range for both intents (R9): an explicit
    /// business-day count overrides the enum choice and is clamped to 2...30 in
    /// code, so the result is well-defined whether the parameter's
    /// `inclusiveRange` clamps or rejects out-of-range programmatic values.
    static func dateRangeType(for range: AvailabilityRange, businessDays: Int?) -> DateRangeType {
        if let businessDays {
            return .businessDays(min(30, max(2, businessDays)))
        }
        return range.dateRangeType
    }
}

enum GetAvailabilityError: Error, CustomLocalizedStringResourceConvertible {
    case calendarAccessNotGranted
    case noCalendarsAvailable
    /// Additive under KTD3: the timezone input named no zone the app accepts
    /// (R17). Carries the trimmed text so the message can name it.
    case unknownTimeZone(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .calendarAccessNotGranted:
            "Availability Click doesn't have calendar access. Open the Availability Click app and click its menu bar icon to trigger the permission prompt, then run this action again."
        case .noCalendarsAvailable:
            "No calendars are available on this Mac. Add a calendar account in System Settings, then run this action again."
        case .unknownTimeZone(let value):
            "Availability Click doesn't recognize the time zone \"\(value)\". Use a name such as Europe/Berlin or America/New_York, or leave the time zone empty to use this Mac's own."
        }
    }
}

/// Shared pipeline for both Shortcuts intents. Marks the headless launch,
/// enforces the auth and no-calendars guards, then runs the same computation
/// the click path uses and returns the post-pipeline slot dictionary — each
/// intent shapes its own result (formatted text vs structured entities). One
/// place so the two intents' guards and pipeline can never drift.
@MainActor
func resolveAvailabilitySlots(range: AvailabilityRange, businessDays: Int?) async throws -> [Date: [TimeSlot]] {
    // A cold Shortcuts run launches the app headless; mark the launch so its
    // user-visible side effects (TCC auto-request, first-run coach) stay
    // quiet (OQ10).
    AppDelegate.intentDidRunThisLaunch = true

    // Shortcuts runs are frequently unattended: never trigger the system
    // permission prompt from here -- throw a descriptive error instead.
    guard CalendarService.shared.isAuthorized else {
        throw GetAvailabilityError.calendarAccessNotGranted
    }
    // An empty selection (empty store, or an all-stale selection under R11)
    // throws, never a silent all-calendars read.
    guard !CalendarService.shared.selectedCalendars().isEmpty else {
        throw GetAvailabilityError.noCalendarsAvailable
    }

    let rangeType = AvailabilityRange.dateRangeType(for: range, businessDays: businessDays)
    let service = AvailabilityService()
    // Capture `now` once and pass it to BOTH the window derivation and the slot
    // math (the click path already does this). Otherwise each defaults to its
    // own `Date()` with the EventKit fetch between them; a clock crossing
    // midnight or the today-buffer cutoff mid-fetch shifts calculateAvailability's
    // day list off the fetched window, and the trailing day — having no fetched
    // events — reads as falsely fully free.
    let now = Date()
    let window = service.fetchWindow(for: rangeType, now: now)
    let events = await CalendarService.shared.fetchEvents(from: window.start, to: window.end)
    return service.calculateAvailability(events: events, rangeType: rangeType, now: now)
}

/// Options for the Get Availability timezone input (KTD7): every known zone
/// identifier. The input stays free text, so a Shortcut can also pass a zone
/// in a variable, and the resolver catches typos (R17). No default is set, so
/// an input left unset stays empty (R15).
struct TimeZoneOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        TimeZoneCatalog.identifiers
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

    /// Additive under KTD3: an optional business-day override, bounded 2...30.
    /// nil leaves the Range parameter governing. Frozen once shipped.
    @Parameter(
        title: "Business days",
        description: "Optional. Overrides the range with this many business days (2–30).",
        inclusiveRange: (2, 30)
    )
    var businessDays: Int?

    /// Additive under KTD3: an optional zone for the output, such as
    /// Europe/Berlin. Empty or blank leaves the output as it was without the
    /// input (R15). A zone always adds the timezone line (R16). Frozen once
    /// shipped.
    @Parameter(
        title: "Time zone",
        description: "Optional. Lists the times in this time zone, such as Europe/Berlin, and adds a time zone line.",
        optionsProvider: TimeZoneOptionsProvider()
    )
    var timeZone: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Mark the headless launch before resolving the zone, the way
        // resolveAvailabilitySlots does, so a mistyped zone on a cold
        // unattended run fails without the permission prompt or the coach.
        AppDelegate.intentDidRunThisLaunch = true
        let zone = try TimeZoneCatalog.resolve(timeZone)
        let slots = try await resolveAvailabilitySlots(range: range, businessDays: businessDays)
        return .result(value: Self.composeText(slots: slots, timezone: zone, showTimeZone: AppSettings.showTimeZone))
    }

    /// The text step after slot resolution (KTD9). Pure, so R15, R16, and R20
    /// are testable with fixed slots. Always the plain-text template:
    /// markdown syntax is unwanted mid-automation (KTD6). A given zone forces
    /// the timezone line on, and no slots give empty text.
    static func composeText(slots: [Date: [TimeSlot]], timezone: TimeZone?, showTimeZone: Bool) -> String {
        AvailabilityFormatter().format(
            slots: slots,
            showTimeZone: showTimeZone || timezone != nil,
            template: .plainText,
            timezone: timezone
        )
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
        AppShortcut(
            intent: GetAvailabilitySlotsIntent(),
            phrases: ["Get availability slots from \(.applicationName)"],
            shortTitle: "Get Availability Slots",
            systemImageName: "calendar"
        )
    }
}
