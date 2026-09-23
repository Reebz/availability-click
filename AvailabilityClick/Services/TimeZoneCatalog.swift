import Foundation

/// The zone list shared by the preview's recipient picker and the Get
/// Availability timezone input (KTD7), and the resolver that turns Shortcut
/// input into a zone (KTD8).
enum TimeZoneCatalog {
    /// Every known zone, sorted by GMT offset, each with its three search fields
    /// pre-lowercased — built once, not rebuilt on each `body` evaluation (a
    /// format-picker tap or a row selection re-renders the popover). Precomputing
    /// the fields keeps a keystroke from calling the locale-aware `localizedName`
    /// on ~450 zones. The GMT offset and the DST-dependent abbreviation are
    /// sampled at first access, so a DST shift mid-session is a cosmetic ordering
    /// and abbreviation-search difference.
    static let searchableTimezones: [(zone: TimeZone, id: String, abbr: String, name: String)] =
        TimeZone.knownTimeZoneIdentifiers
            .compactMap { TimeZone(identifier: $0) }
            .sorted { $0.secondsFromGMT() < $1.secondsFromGMT() }
            .map { tz in
                (
                    tz,
                    tz.identifier.lowercased(),
                    (tz.abbreviation() ?? "").lowercased(),
                    (tz.localizedName(for: .standard, locale: .current) ?? "").lowercased()
                )
            }

    /// The preview picker's search: the first 20 zones when the field is
    /// empty, otherwise every zone whose identifier, abbreviation, or name
    /// contains the text.
    static func search(_ text: String) -> [TimeZone] {
        if text.isEmpty { return Array(searchableTimezones.prefix(20).map(\.zone)) }

        let query = text.lowercased()
        return searchableTimezones
            .filter { $0.id.contains(query) || $0.abbr.contains(query) || $0.name.contains(query) }
            .map(\.zone)
    }

    /// Zone identifiers for the Shortcuts picker, in alphabetical order so
    /// the list reads by region.
    static let identifiers: [String] = searchableTimezones.map(\.zone.identifier).sorted()

    private static let identifiersByLowercase: [String: String] = Dictionary(
        identifiers.map { ($0.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Turns the Shortcut's timezone text into a zone (KTD8). Pure and free of
    /// the main actor, so it runs before any calendar work and tests reach it
    /// without EventKit.
    ///
    /// Empty or blank text means no zone (R15). A known identifier matches in
    /// any capitalization. A legacy alias the system still resolves is
    /// accepted only as a region and city name containing "/", such as
    /// US/Pacific, or as UTC or GMT with an optional offset, such as UTC+10.
    /// Anything else throws an error naming the trimmed text (R17). That
    /// includes bare abbreviations, because the system resolves "BST" to
    /// Bangladesh and "IST" to India.
    static func resolve(_ input: String?) throws -> TimeZone? {
        let trimmed = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let identifier = identifiersByLowercase[trimmed.lowercased()],
           let zone = TimeZone(identifier: identifier) {
            return zone
        }
        if trimmed.contains("/"), let zone = TimeZone(identifier: trimmed) {
            return zone
        }
        if trimmed.wholeMatch(of: /(?i)(UTC|GMT)([+-]\d{1,2}(:?\d{2})?)?/) != nil,
           let zone = TimeZone(identifier: trimmed.uppercased()) {
            return zone
        }
        throw GetAvailabilityError.unknownTimeZone(trimmed)
    }
}
