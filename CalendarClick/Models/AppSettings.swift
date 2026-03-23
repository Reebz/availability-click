import Foundation

enum AppSettings {
    // Working hours stored as minutes since midnight (supports 30-min granularity)
    static let workingHoursStartKey = "workingHoursStart"
    static let workingHoursEndKey = "workingHoursEnd"
    static let workingDaysKey = "workingDays"
    static let todayBufferMinutesKey = "todayBufferMinutes"
    static let minimumSlotMinutesKey = "minimumSlotMinutes"
    static let defaultRangeModeKey = "defaultRangeMode"
    static let defaultBusinessDaysKey = "defaultBusinessDays"
    static let showTimeZoneKey = "showTimeZone"
    static let selectedCalendarIDsKey = "selectedCalendarIDs"
    static let launchAtLoginKey = "launchAtLogin"

    // Defaults
    static let defaultWorkingHoursStart = 540   // 9:00 AM
    static let defaultWorkingHoursEnd = 1020    // 5:00 PM
    static let defaultWorkingDays = [2, 3, 4, 5, 6] // Mon-Fri (Calendar weekday: 1=Sun)
    static let defaultTodayBuffer = 60          // 1 hour
    static let defaultMinimumSlot = 30          // 30 minutes
    static let defaultRangeModeValue = "businessDays"
    static let defaultBusinessDayCount = 5

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            workingHoursStartKey: defaultWorkingHoursStart,
            workingHoursEndKey: defaultWorkingHoursEnd,
            workingDaysKey: defaultWorkingDays,
            todayBufferMinutesKey: defaultTodayBuffer,
            minimumSlotMinutesKey: defaultMinimumSlot,
            defaultRangeModeKey: defaultRangeModeValue,
            defaultBusinessDaysKey: defaultBusinessDayCount,
            showTimeZoneKey: false,
            selectedCalendarIDsKey: [String](),
            launchAtLoginKey: false,
        ])
    }

    // MARK: - Validated Reads

    static func clampedInt(forKey key: String, min: Int, max: Int, fallback: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        if value < min || value > max { return fallback }
        return value
    }

    static var workingHoursStart: Int {
        clampedInt(forKey: workingHoursStartKey, min: 0, max: 1439, fallback: defaultWorkingHoursStart)
    }

    static var workingHoursEnd: Int {
        clampedInt(forKey: workingHoursEndKey, min: 0, max: 1439, fallback: defaultWorkingHoursEnd)
    }

    static var todayBufferMinutes: Int {
        clampedInt(forKey: todayBufferMinutesKey, min: 0, max: 480, fallback: defaultTodayBuffer)
    }

    static var defaultBusinessDays: Int {
        clampedInt(forKey: defaultBusinessDaysKey, min: 2, max: 5, fallback: defaultBusinessDayCount)
    }

    static var minimumSlotMinutes: Int {
        clampedInt(forKey: minimumSlotMinutesKey, min: 15, max: 120, fallback: defaultMinimumSlot)
    }

    static var workingDays: [Int] {
        let value = UserDefaults.standard.array(forKey: workingDaysKey) as? [Int]
        return value ?? defaultWorkingDays
    }

    static var defaultRangeMode: String {
        UserDefaults.standard.string(forKey: defaultRangeModeKey) ?? "businessDays"
    }

    static var showTimeZone: Bool {
        UserDefaults.standard.bool(forKey: showTimeZoneKey)
    }

    static var selectedCalendarIDs: [String] {
        UserDefaults.standard.stringArray(forKey: selectedCalendarIDsKey) ?? []
    }

    static var launchAtLogin: Bool {
        UserDefaults.standard.bool(forKey: launchAtLoginKey)
    }
}
