import SwiftUI

struct PreviewPopoverView: View {
    let slots: [Date: [TimeSlot]]
    let onCopy: (String) -> Void
    let onDismiss: () -> Void

    @State private var selectedFormat: FormatTemplate = {
        AppSettings.defaultFormat == "markdown" ? .markdown : .plainText
    }()
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
                    onCopy(formattedText)
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
        let abbrev = tz.abbreviation() ?? ""
        let seconds = tz.secondsFromGMT()
        let hours = seconds / 3600
        let mins = abs(seconds / 60) % 60
        let offset = mins == 0
            ? String(format: "GMT%+d", hours)
            : String(format: "GMT%+d:%02d", hours, mins)
        return "\(name) (\(abbrev), \(offset))"
    }

    private var filteredTimezones: [TimeZone] {
        let all = TimeZone.knownTimeZoneIdentifiers
            .compactMap { TimeZone(identifier: $0) }
            .sorted { $0.secondsFromGMT() < $1.secondsFromGMT() }

        if searchText.isEmpty { return Array(all.prefix(20)) }

        let query = searchText.lowercased()
        return all.filter { tz in
            tz.identifier.lowercased().contains(query)
                || (tz.abbreviation() ?? "").lowercased().contains(query)
                || (tz.localizedName(for: .standard, locale: .current) ?? "").lowercased().contains(query)
        }
    }
}
