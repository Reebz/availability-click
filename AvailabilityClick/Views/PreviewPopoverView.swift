import SwiftUI

struct PreviewPopoverView: View {
    let slots: [Date: [TimeSlot]]
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var selectedFormat: FormatTemplate = AppSettings.defaultFormatTemplate
    @State private var selectedTimezone: TimeZone? = nil
    @State private var searchText = ""

    private let formatter = AvailabilityFormatter()

    private var formattedText: String {
        formatter.format(
            slots: slots,
            showTimeZone: true,
            template: selectedFormat,
            timezone: selectedTimezone
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Preview text
            ScrollView {
                Text(formattedText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            Divider()

            // Controls
            HStack(spacing: 16) {
                // Format picker
                Picker("Format", selection: $selectedFormat) {
                    Text("Plain Text").tag(FormatTemplate.plainText)
                    Text("Markdown").tag(FormatTemplate.markdown)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            // Timezone picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Recipient timezone")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                timezonePicker
            }

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Copy") {
                    // Write through the shared writer with the selection the
                    // user is looking at, so rich flavors match the preview.
                    PasteboardWriter.write(
                        slots: slots,
                        showTimeZone: true,
                        timezone: selectedTimezone,
                        template: selectedFormat,
                        asOf: AppSettings.showAsOfStamp ? Date() : nil
                    )
                    onCopy()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, height: 420)
    }

    // MARK: - Timezone Picker

    private var timezonePicker: some View {
        VStack(spacing: 0) {
            // Search field
            TextField("Search city or timezone...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            // Timezone list
            ScrollView {
                VStack(spacing: 0) {
                    // "My timezone" option
                    timezoneRow(label: "My timezone (\(localTzLabel))", timezone: nil)

                    // Recent timezones
                    let recents = AppSettings.recentTimezones.compactMap { TimeZone(identifier: $0) }
                    if !recents.isEmpty && searchText.isEmpty {
                        ForEach(recents, id: \.identifier) { tz in
                            timezoneRow(label: tzDisplayName(tz), timezone: tz)
                        }
                        Divider().padding(.vertical, 2)
                    }

                    // Filtered timezone list
                    ForEach(filteredTimezones, id: \.identifier) { tz in
                        timezoneRow(label: tzDisplayName(tz), timezone: tz)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    private func timezoneRow(label: String, timezone: TimeZone?) -> some View {
        Button(action: {
            selectedTimezone = timezone
            if let tz = timezone {
                AppSettings.addRecentTimezone(tz.identifier)
            }
            searchText = ""
        }) {
            HStack {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedTimezone?.identifier == timezone?.identifier {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            selectedTimezone?.identifier == timezone?.identifier
                ? Color.accentColor.opacity(0.1)
                : Color.clear
        )
        .cornerRadius(4)
    }

    // MARK: - Helpers

    private var localTzLabel: String {
        AvailabilityFormatter.timezoneString()
    }

    private func tzDisplayName(_ tz: TimeZone) -> String {
        let name = tz.localizedName(for: .standard, locale: .current) ?? tz.identifier
        return "\(name) (\(AvailabilityFormatter.timezoneString(for: tz)))"
    }

    /// Every known zone, sorted by GMT offset, each with its three search fields
    /// pre-lowercased — built once, not rebuilt on each `body` evaluation (a
    /// format-picker tap or a row selection re-renders the popover). Precomputing
    /// the fields keeps a keystroke from calling the locale-aware `localizedName`
    /// on ~450 zones. The GMT offset and the DST-dependent abbreviation are
    /// sampled at first access, so a DST shift mid-session is a cosmetic ordering
    /// and abbreviation-search difference.
    private static let searchableTimezones: [(zone: TimeZone, id: String, abbr: String, name: String)] =
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

    private var filteredTimezones: [TimeZone] {
        if searchText.isEmpty { return Array(Self.searchableTimezones.prefix(20).map(\.zone)) }

        let query = searchText.lowercased()
        return Self.searchableTimezones
            .filter { $0.id.contains(query) || $0.abbr.contains(query) || $0.name.contains(query) }
            .map(\.zone)
    }
}
