import SwiftUI
import AppKit
import EventKit

struct CalendarPickerView: View {
    @State private var calendars: [EKCalendar] = []
    @State private var selectedIDs: Set<String> = Set(AppSettings.selectedCalendarIDs)
    @State private var showLastCalendarCaption = false
    @State private var captionHideTask: Task<Void, Never>?

    static let lastCalendarCaption = "At least one calendar stays selected"

    var body: some View {
        SettingsSection("Calendars Enabled") {
            if calendars.isEmpty {
                Text(
                    CalendarService.shared.isAuthorized
                        ? "No calendars found. Add calendar accounts in System Settings."
                        : "Calendar access not granted. Enable it in System Settings > Privacy & Security > Calendars."
                )
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .topLeading),
                        GridItem(.flexible(), alignment: .topLeading),
                    ],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: binding(for: calendar.calendarIdentifier)) {
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color(cgColor: calendar.cgColor))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 4)
                                Text(calendar.title)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityHint(
                            isLastSelected(calendar.calendarIdentifier) ? Self.lastCalendarCaption : ""
                        )
                    }
                }

                if showLastCalendarCaption {
                    Text(Self.lastCalendarCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
        .onAppear { refreshCalendars() }
        .onReceive(
            NotificationCenter.default.publisher(for: .EKEventStoreChanged)
        ) { _ in
            refreshCalendars()
        }
    }

    /// Pure toggle logic (KTD2): a never-customized `[]` expands to the full
    /// ID set on first touch, explicit IDs persist from then on (no collapse
    /// back to `[]`), and unchecking the last selected calendar is blocked.
    /// Returns nil when the change is blocked.
    static func updatedSelection(
        togglingID id: String,
        isOn: Bool,
        current: Set<String>,
        allIDs: [String]
    ) -> Set<String>? {
        var selection = current.isEmpty ? Set(allIDs) : current
        if isOn {
            selection.insert(id)
        } else {
            guard selection != [id] else { return nil }
            selection.remove(id)
        }
        return selection
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                selectedIDs.isEmpty || selectedIDs.contains(id)
            },
            set: { isOn in
                guard let updated = Self.updatedSelection(
                    togglingID: id,
                    isOn: isOn,
                    current: selectedIDs,
                    allIDs: calendars.map(\.calendarIdentifier)
                ) else {
                    showBlockedUncheckFeedback()
                    return
                }
                selectedIDs = updated
                UserDefaults.standard.set(Array(updated), forKey: AppSettings.selectedCalendarIDsKey)
            }
        )
    }

    private func isLastSelected(_ id: String) -> Bool {
        let effective = selectedIDs.isEmpty
            ? Set(calendars.map(\.calendarIdentifier))
            : selectedIDs
        return effective == [id]
    }

    /// Transient caption (OQ14): appears on the blocked attempt, fades after
    /// a few seconds. VoiceOver gets the same text as an announcement (OQ6).
    private func showBlockedUncheckFeedback() {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: Self.lastCalendarCaption,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }

        withAnimation { showLastCalendarCaption = true }
        captionHideTask?.cancel()
        captionHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { showLastCalendarCaption = false }
        }
    }

    private func refreshCalendars() {
        Task { @MainActor in
            calendars = CalendarService.shared.allCalendars
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            selectedIDs = Set(AppSettings.selectedCalendarIDs)
        }
    }
}
