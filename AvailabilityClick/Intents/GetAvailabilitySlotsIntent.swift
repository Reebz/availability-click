import AppIntents
import Foundation

/// A single free slot returned to Shortcuts as structured data (KTD1/KTD2).
/// TransientAppEntity, not AppEntity: slots are computed and ephemeral, need no
/// EntityQuery, and can't be cached-by-id across runs — which kills the
/// stale-entity risk. The value fields are RAW dates so downstream automation
/// composes its own output; formatting lives only in the display card.
struct AvailabilitySlot: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Availability Slot")

    @Property(title: "Start")
    var startDate: Date

    @Property(title: "End")
    var endDate: Date

    @Property(title: "Duration (minutes)")
    var durationMinutes: Double

    var id = UUID()

    init() {
        self.startDate = Date()
        self.endDate = Date()
        self.durationMinutes = 0
    }

    init(slot: TimeSlot) {
        self.startDate = slot.start
        self.endDate = slot.end
        self.durationMinutes = slot.duration / 60
    }

    /// Formatted title + timezone subtitle for the Shortcuts result card
    /// (KTD2). Presentation only — the raw dates above stay the value fields.
    var displayRepresentation: DisplayRepresentation {
        let title = AvailabilityFormatter().formatTimeRange(TimeSlot(start: startDate, end: endDate))
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(AvailabilityFormatter.timezoneString())"
        )
    }
}

/// Structured-slots sibling of GetAvailabilityIntent (R8). Same computation
/// pipeline as the click path; returns raw start/end slots instead of prose so
/// agents compose their own output. A new intent type can't break existing
/// shortcuts (KTD3).
struct GetAvailabilitySlotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Availability Slots"
    static let description = IntentDescription(
        "Returns your free calendar slots as structured start/end times for automation. Never opens the app's UI and never touches the clipboard."
    )
    /// Calendar-derived data must not be readable from a locked Mac (OQ9): the
    /// AppIntents default is `.alwaysAllowed`, so this must be set explicitly.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Range", default: .defaultRange)
    var range: AvailabilityRange

    /// Optional business-day override, bounded 2...30 (R9). Frozen once shipped.
    @Parameter(
        title: "Business days",
        description: "Optional. Overrides the range with this many business days (2–30).",
        inclusiveRange: (2, 30)
    )
    var businessDays: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AvailabilitySlot]> {
        let slots = try await resolveAvailabilitySlots(range: range, businessDays: businessDays)

        // Empty availability is a valid answer (a booked week), not an error;
        // throws are reserved for auth/no-calendars.
        let entities = slots.values.flatMap { $0 }
            .sorted { $0.start < $1.start }
            .map(AvailabilitySlot.init)
        return .result(value: entities)
    }
}
