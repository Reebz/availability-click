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
                if isAllStale {
                    Text("Your selected calendars are no longer available — pick calendars to resume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// Pure toggle logic (KTD2): a never-customized `[]` (or an all-stale
    /// set, which resolves to "all" on the read path) expands to the full ID
    /// set on first touch, explicit IDs persist from then on (no collapse
    /// back to `[]`), and unchecking the last VISIBLE calendar is blocked --
    /// the guard compares against present IDs so stale ones (deleted or
    /// offline accounts) can't smuggle the picker into a zero-checked state.
    /// Returns nil when the change is blocked.
    static func updatedSelection(
        togglingID id: String,
        isOn: Bool,
        current: Set<String>,
        allIDs: [String]
    ) -> Set<String>? {
        let allSet = Set(allIDs)
        let valid = current.intersection(allSet)

        let base: Set<String>
        if current.isEmpty {
            // Never customized: first touch materializes the full set so
            // unchecking one leaves the rest.
            base = allSet
        } else if valid.isEmpty {
            // Customized but every saved ID is stale (R11 recovery): start from
            // an empty selection so re-picking adds ONLY the toggled calendar
            // and never silently re-selects all.
            base = []
        } else {
            base = valid
        }

        var selection = base
        if isOn {
            selection.insert(id)
        } else {
            guard selection.intersection(allSet) != [id] else { return nil }
            selection.remove(id)
        }
        return selection
    }

    /// True when the stored selection is customized but every ID is stale (R11)
    /// -- drives the explanatory notice, distinct from the never-customized
    /// state which also renders unchecked but needs no notice.
    private var isAllStale: Bool {
        CalendarService.selectionIsAllStale(
            saved: Array(selectedIDs),
            allIDs: calendars.map(\.calendarIdentifier)
        )
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                // Mirror the read path exactly: never-customized resolves to
                // "all" (all checked); an all-stale set resolves to empty (all
                // unchecked, with the notice above prompting a re-pick).
                CalendarService.effectiveSelectedIDs(
                    saved: Array(selectedIDs),
                    allIDs: calendars.map(\.calendarIdentifier)
                ).contains(id)
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
                // Let the app re-evaluate the persistent unavailable badge (R11).
                NotificationCenter.default.post(name: .calendarSelectionChanged, object: nil)
            }
        )
    }

    private func isLastSelected(_ id: String) -> Bool {
        CalendarService.effectiveSelectedIDs(
            saved: Array(selectedIDs),
            allIDs: calendars.map(\.calendarIdentifier)
        ) == [id]
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
