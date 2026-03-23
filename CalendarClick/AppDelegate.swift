import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController!
    private let calendarService = CalendarService.shared
    private let availabilityService = AvailabilityService()
    private let formatter = AvailabilityFormatter()

    /// Debounce: ignore clicks within 500ms of previous
    private var lastCopyTime: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()

        statusItemController = StatusItemController()
        statusItemController.onLeftClick = { [weak self] in
            self?.copyDefault()
        }
        statusItemController.onRangeSelected = { [weak self] rangeType in
            self?.copyRange(rangeType)
        }
        statusItemController.setup()

        // Request calendar access on first launch
        Task {
            if calendarService.authorizationStatus == .notDetermined {
                _ = await calendarService.requestAccess()
            }
        }
    }

    // MARK: - Copy Pipeline

    private func copyDefault() {
        let rangeType: DateRangeType
        if AppSettings.defaultRangeMode == "thisWeek" {
            rangeType = .thisWeek
        } else {
            rangeType = .businessDays(AppSettings.defaultBusinessDays)
        }
        copyRange(rangeType)
    }

    private func copyRange(_ rangeType: DateRangeType) {
        // Debounce rapid clicks
        let now = Date()
        guard now.timeIntervalSince(lastCopyTime) > 0.5 else { return }
        lastCopyTime = now

        // Check authorization
        guard calendarService.isAuthorized else {
            showPermissionAlert()
            return
        }

        Task { @MainActor in
            let dateRange = calculateDateRange(for: rangeType)
            let events = await calendarService.fetchEvents(from: dateRange.start, to: dateRange.end)

            let slots = availabilityService.calculateAvailability(
                events: events,
                rangeType: rangeType,
                now: now
            )

            if slots.isEmpty {
                statusItemController.flashConfirmation(success: false)
            } else {
                let text = formatter.format(
                    slots: slots,
                    showTimeZone: AppSettings.showTimeZone
                )

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)

                statusItemController.flashConfirmation(success: true)
            }
        }
    }

    // MARK: - Date Range Calculation

    private func calculateDateRange(for rangeType: DateRangeType) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        switch rangeType {
        case .thisWeek, .businessDays:
            let start = today
            let end = cal.date(byAdding: .day, value: 7, to: today)!
            return (start, end)

        case .nextWeek:
            let weekday = cal.component(.weekday, from: today)
            let daysUntilNextMonday = (9 - weekday) % 7
            let offset = daysUntilNextMonday == 0 ? 7 : daysUntilNextMonday
            let nextMonday = cal.date(byAdding: .day, value: offset, to: today)!
            let end = cal.date(byAdding: .day, value: 7, to: nextMonday)!
            return (nextMonday, end)

        case .nextFortnight:
            let weekday = cal.component(.weekday, from: today)
            let daysUntilNextMonday = (9 - weekday) % 7
            let offset = daysUntilNextMonday == 0 ? 7 : daysUntilNextMonday
            let nextMonday = cal.date(byAdding: .day, value: offset, to: today)!
            let end = cal.date(byAdding: .day, value: 14, to: nextMonday)!
            return (nextMonday, end)

        case .next30Days:
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            let end = cal.date(byAdding: .day, value: 30, to: tomorrow)!
            return (tomorrow, end)
        }
    }

    // MARK: - Permission

    private var hasShownPermissionAlert = false

    private func showPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        let alert = NSAlert()
        alert.messageText = "Calendar Access Required"
        alert.informativeText = "Calendar Click needs access to your calendars to show availability. Please enable it in System Settings > Privacy & Security > Calendars."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
