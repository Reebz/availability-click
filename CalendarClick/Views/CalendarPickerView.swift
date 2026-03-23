import SwiftUI
import EventKit

struct CalendarPickerView: View {
    @State private var calendars: [EKCalendar] = []
    @State private var selectedIDs: Set<String> = Set(AppSettings.selectedCalendarIDs)

    var body: some View {
        Section("Calendars") {
            if calendars.isEmpty {
                Text("No calendars found. Add calendar accounts in System Settings.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    Toggle(isOn: binding(for: calendar.calendarIdentifier)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(cgColor: calendar.cgColor))
                                .frame(width: 10, height: 10)
                            Text(calendar.title)
                        }
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
                // Empty selectedIDs means "all selected"
                selectedIDs.isEmpty || selectedIDs.contains(id)
            },
            set: { isOn in
                // If currently empty (all selected), initialize with all IDs
                if selectedIDs.isEmpty {
                    selectedIDs = Set(calendars.map(\.calendarIdentifier))
                }

                if isOn {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }

                // If all are now selected, store empty (means "all")
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
