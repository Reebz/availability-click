import SwiftUI
import EventKit

struct CalendarPickerView: View {
    @State private var calendars: [EKCalendar] = []
    @State private var selectedIDs: Set<String> = Set(AppSettings.selectedCalendarIDs)

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
                    }
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

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                selectedIDs.isEmpty || selectedIDs.contains(id)
            },
            set: { isOn in
                if selectedIDs.isEmpty {
                    selectedIDs = Set(calendars.map(\.calendarIdentifier))
                }

                if isOn {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }

                let allIDs = Set(calendars.map(\.calendarIdentifier))
                let toStore = selectedIDs == allIDs ? [String]() : Array(selectedIDs)
                UserDefaults.standard.set(toStore, forKey: AppSettings.selectedCalendarIDsKey)
            }
        )
    }

    private func refreshCalendars() {
        Task { @MainActor in
            calendars = CalendarService.shared.allCalendars
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            selectedIDs = Set(AppSettings.selectedCalendarIDs)
        }
    }
}
