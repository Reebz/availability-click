import SwiftUI
import EventKit
import ServiceManagement

struct SettingsView: View {
    @AppStorage(AppSettings.workingHoursStartKey)
    private var workingHoursStart = AppSettings.defaultWorkingHoursStart

    @AppStorage(AppSettings.workingHoursEndKey)
    private var workingHoursEnd = AppSettings.defaultWorkingHoursEnd

    @AppStorage(AppSettings.todayBufferMinutesKey)
    private var todayBufferMinutes = AppSettings.defaultTodayBuffer

    @AppStorage(AppSettings.defaultRangeModeKey)
    private var rangeMode = AppSettings.defaultRangeModeValue

    @AppStorage(AppSettings.defaultBusinessDaysKey)
    private var businessDays = AppSettings.defaultBusinessDayCount

    @AppStorage(AppSettings.showTimeZoneKey)
    private var showTimeZone = false

    @AppStorage(AppSettings.launchAtLoginKey)
    private var launchAtLogin = false

    @State private var workingDays: Set<Int> = Set(AppSettings.workingDays)

    var body: some View {
        Form {
            workingHoursSection
            workingDaysSection
            defaultRangeSection
            todayBufferSection
            CalendarPickerView()
            optionsSection
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 520)
        .onChange(of: workingDays) { _, newValue in
            UserDefaults.standard.set(Array(newValue), forKey: AppSettings.workingDaysKey)
        }
    }

    // MARK: - Working Hours

    private var workingHoursSection: some View {
        Section("Working Hours") {
            HStack {
                Picker("From", selection: $workingHoursStart) {
                    ForEach(timeOptions, id: \.self) { minutes in
                        Text(formatMinutes(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()

                Text("to")

                Picker("To", selection: $workingHoursEnd) {
                    ForEach(timeOptions.filter { $0 > workingHoursStart }, id: \.self) { minutes in
                        Text(formatMinutes(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Working Days

    private var workingDaysSection: some View {
        Section("Working Days") {
            HStack(spacing: 8) {
                ForEach(dayOptions, id: \.weekday) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { workingDays.contains(option.weekday) },
                        set: { isOn in
                            if isOn {
                                workingDays.insert(option.weekday)
                            } else {
                                workingDays.remove(option.weekday)
                            }
                        }
                    ))
                    .toggleStyle(.button)
                }
            }
        }
    }

    // MARK: - Default Range

    private var defaultRangeSection: some View {
        Section("Default Range") {
            Picker("Mode", selection: $rangeMode) {
                Text("This week (Mon-Fri)").tag("thisWeek")
                Text("Next \(businessDays) business days").tag("businessDays")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if rangeMode == "businessDays" {
                HStack {
                    Text("Days:")
                    Slider(
                        value: Binding(
                            get: { Double(businessDays) },
                            set: { businessDays = Int($0) }
                        ),
                        in: 2...5,
                        step: 1
                    )
                    Text("\(businessDays)")
                        .monospacedDigit()
                        .frame(width: 20)
                }
            }
        }
    }

    // MARK: - Today Buffer

    private var todayBufferSection: some View {
        Section("Today Buffer") {
            Picker("Minimum lead time", selection: $todayBufferMinutes) {
                Text("None").tag(0)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("4 hours").tag(240)
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        Section {
            Toggle(
                "Append time zone (\(TimeZone.current.abbreviation() ?? "UTC"))",
                isOn: $showTimeZone
            )

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }
        }
    }

    // MARK: - Helpers

    private var timeOptions: [Int] {
        stride(from: 0, through: 1410, by: 30).map { $0 } // every 30 min
    }

    private var dayOptions: [(weekday: Int, label: String)] {
        [
            (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"),
            (6, "Fri"), (7, "Sat"), (1, "Sun"),
        ]
    }

    private func formatMinutes(_ total: Int) -> String {
        let hour = total / 60
        let minute = total % 60
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let period = hour >= 12 ? "PM" : "AM"
        if minute == 0 {
            return "\(displayHour):00 \(period)"
        }
        return "\(displayHour):\(String(format: "%02d", minute)) \(period)"
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // If registration fails, revert the toggle
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
