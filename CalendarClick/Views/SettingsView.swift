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
        ScrollView {
            VStack(spacing: 0) {
                keyboardShortcutSection
                workingHoursSection
                workingDaysSection
                defaultRangeSection
                todayBufferSection
                CalendarPickerView()
                optionsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onChange(of: workingDays) { _, newValue in
            UserDefaults.standard.set(Array(newValue), forKey: AppSettings.workingDaysKey)
        }
    }

    // MARK: - Keyboard Shortcut

    private var keyboardShortcutSection: some View {
        SettingsSection("Keyboard Shortcut") {
            HStack {
                ShortcutRecorderView()
                Spacer()
            }
        }
    }

    // MARK: - Working Hours

    private var workingHoursSection: some View {
        SettingsSection("Working Hours") {
            HStack {
                Picker("From", selection: $workingHoursStart) {
                    ForEach(timeOptions, id: \.self) { minutes in
                        Text(formatMinutes(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)

                Text("to")
                    .foregroundStyle(.secondary)

                Picker("To", selection: $workingHoursEnd) {
                    ForEach(timeOptions.filter { $0 > workingHoursStart }, id: \.self) { minutes in
                        Text(formatMinutes(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)

                Spacer()
            }
        }
    }

    // MARK: - Working Days

    private var workingDaysSection: some View {
        SettingsSection("Working Days") {
            HStack(spacing: 6) {
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
                    .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    // MARK: - Default Range

    private var defaultRangeSection: some View {
        SettingsSection("Default Range") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $rangeMode) {
                    Text("This week (Mon-Fri)").tag("thisWeek")
                    Text("Next \(businessDays) business days").tag("businessDays")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if rangeMode == "businessDays" {
                    HStack {
                        Text("Days:")
                            .foregroundStyle(.secondary)
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
    }

    // MARK: - Today Buffer

    private var todayBufferSection: some View {
        SettingsSection("Today Buffer") {
            Picker("Minimum lead time", selection: $todayBufferMinutes) {
                Text("None").tag(0)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("4 hours").tag(240)
            }
            .frame(maxWidth: 200)
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        SettingsSection("Options") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Append time zone (\(timezoneLabel))",
                    isOn: $showTimeZone
                )

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLoginItem(enabled: newValue)
                    }
            }
        }
    }

    // MARK: - Helpers

    private var timezoneLabel: String {
        let tz = TimeZone.current
        let abbrev = tz.abbreviation() ?? "UTC"
        let seconds = tz.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        let gmtOffset: String
        if minutes == 0 {
            gmtOffset = String(format: "GMT%+d", hours)
        } else {
            gmtOffset = String(format: "GMT%+d:%02d", hours, minutes)
        }
        return "\(abbrev), \(gmtOffset)"
    }

    private var timeOptions: [Int] {
        stride(from: 0, through: 1410, by: 30).map { $0 }
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
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Section Component

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            content

            Divider()
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
}
