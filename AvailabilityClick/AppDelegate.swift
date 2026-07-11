import AppKit

/// Outcome of a copy attempt (KTD3). Replaces the old success boolean so a
/// failed click can say why: distinct symbol per failure (OQ11) plus a
/// tooltip as the detail layer.
enum CopyOutcome: Equatable {
    case copied
    case noAccess
    case noCalendars
    case noSlots

    var symbolName: String {
        switch self {
        case .copied: "checkmark.circle.fill"
        case .noAccess: "lock.circle"
        case .noCalendars: "calendar.badge.exclamationmark"
        case .noSlots: "xmark.circle"
        }
    }

    /// One-line failure reason; nil on success so a stale failure tooltip
    /// never outlives the outcome that set it.
    var tooltip: String? {
        switch self {
        case .copied: nil
        case .noAccess: "Calendar access not granted - open Settings"
        case .noCalendars: "No calendars available"
        case .noSlots: "No free slots in this range"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController!
    private let calendarService = CalendarService.shared
    private let availabilityService = AvailabilityService()
    private var shortcutManager: GlobalShortcutManager!
    private var shortcutObserver: NSObjectProtocol?
    private var recordingObservers: [NSObjectProtocol] = []

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
        statusItemController.onOptionClick = { [weak self] in
            self?.showPreview()
        }
        statusItemController.setup()

        // Set up global keyboard shortcut
        shortcutManager = GlobalShortcutManager()
        registerSavedShortcut()
        observeShortcutChanges()
        observeRecordingState()

        // Request calendar access on first launch
        Task {
            if calendarService.authorizationStatus == .notDetermined {
                _ = await calendarService.requestAccess()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutManager.unregister()
        if let observer = shortcutObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in recordingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        recordingObservers = []
    }

    // MARK: - Keyboard Shortcut

    /// Last shortcut state handed to applyShortcut. The defaults observer
    /// fires for every settings write, so this is what keeps unrelated
    /// changes from churning (or killing) the registered monitor.
    private var lastAppliedShortcut: [String: Int]?

    private func registerSavedShortcut() {
        applyShortcut(AppSettings.globalShortcut)
    }

    /// Shortcut state encoding: nil or empty dict = never customized (use the
    /// default Ctrl+Shift+C); keyCode 0 + modifiers 0 = explicitly cleared by
    /// the user (stay unregistered); anything else = the recorded shortcut.
    private func applyShortcut(_ saved: [String: Int]?) {
        lastAppliedShortcut = saved

        guard let saved,
              let keyCode = saved["keyCode"],
              let modifiers = saved["modifiers"] else {
            // Never customized -- register default: Ctrl+Shift+C
            shortcutManager.register(
                keyCode: 8,
                modifiers: [.control, .shift]
            ) { [weak self] in
                self?.copyDefault()
            }
            return
        }

        if keyCode == 0 && modifiers == 0 {
            shortcutManager.unregister()
            return
        }

        shortcutManager.register(
            keyCode: UInt16(clamping: keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers))
        ) { [weak self] in
            self?.copyDefault()
        }
    }

    private func observeShortcutChanges() {
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleShortcutChange()
            }
        }
    }

    private func handleShortcutChange() {
        // Fires on every UserDefaults write; only re-apply on real changes.
        let saved = AppSettings.globalShortcut
        guard saved != lastAppliedShortcut else { return }
        applyShortcut(saved)
    }

    /// Explicit recorder-to-manager channel (not the defaults observer): the
    /// dedupe guard above would swallow re-recording the identical combo,
    /// leaving a suspended hotkey dead. resume() is a no-op when a register
    /// call already landed the new combo.
    private func observeRecordingState() {
        let center = NotificationCenter.default
        recordingObservers.append(center.addObserver(
            forName: .shortcutRecordingBegan, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcutManager.suspend() }
        })
        recordingObservers.append(center.addObserver(
            forName: .shortcutRecordingEnded, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcutManager.resume() }
        })
    }

    // MARK: - Preview

    private func showPreview() {
        guard calendarService.isAuthorized else {
            statusItemController.showOutcome(.noAccess)
            maybeShowPermissionAlert()
            return
        }

        let rangeType = defaultRangeType

        Task { @MainActor in
            guard !calendarService.selectedCalendars().isEmpty else {
                statusItemController.showOutcome(.noCalendars)
                return
            }

            let dateRange = calculateDateRange(for: rangeType)
            let events = await calendarService.fetchEvents(from: dateRange.start, to: dateRange.end)

            let slots = availabilityService.calculateAvailability(
                events: events,
                rangeType: rangeType
            )

            if slots.isEmpty {
                statusItemController.showOutcome(.noSlots)
            } else {
                statusItemController.showPreviewPopover(slots: slots)
            }
        }
    }

    // MARK: - Copy Pipeline

    private var defaultRangeType: DateRangeType {
        if AppSettings.defaultRangeMode == "thisWeek" {
            return .thisWeek
        }
        return .businessDays(AppSettings.defaultBusinessDays)
    }

    private func copyDefault() {
        copyRange(defaultRangeType)
    }

    /// Gate ordering for the copy pipeline, extracted pure so it is
    /// unit-testable. Authorization precedes the debounce (OQ4): failure
    /// feedback always fires, the debounce only swallows authorized repeat
    /// clicks (nil = ignore silently). Keep copyRange's guards in sync.
    static func copyDecision(
        isAuthorized: Bool,
        debouncePassed: Bool,
        hasCalendars: Bool,
        hasSlots: Bool
    ) -> CopyOutcome? {
        guard isAuthorized else { return .noAccess }
        guard debouncePassed else { return nil }
        guard hasCalendars else { return .noCalendars }
        guard hasSlots else { return .noSlots }
        return .copied
    }

    private func copyRange(_ rangeType: DateRangeType) {
        // Authorization before debounce (OQ4) -- see copyDecision above.
        guard calendarService.isAuthorized else {
            statusItemController.showOutcome(.noAccess)
            maybeShowPermissionAlert()
            return
        }

        // Debounce rapid clicks
        let now = Date()
        guard now.timeIntervalSince(lastCopyTime) > 0.5 else { return }
        lastCopyTime = now

        Task { @MainActor in
            guard !calendarService.selectedCalendars().isEmpty else {
                statusItemController.showOutcome(.noCalendars)
                return
            }

            let dateRange = calculateDateRange(for: rangeType)
            let events = await calendarService.fetchEvents(from: dateRange.start, to: dateRange.end)

            let slots = availabilityService.calculateAvailability(
                events: events,
                rangeType: rangeType,
                now: now
            )

            if slots.isEmpty {
                statusItemController.showOutcome(.noSlots)
            } else {
                PasteboardWriter.write(
                    slots: slots,
                    showTimeZone: AppSettings.showTimeZone,
                    template: AppSettings.defaultFormatTemplate
                )
                statusItemController.showOutcome(.copied)
            }
        }
    }

    // MARK: - Date Range Calculation

    private func calculateDateRange(for rangeType: DateRangeType) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        // Derive the fetch window from the same day list the availability math
        // will report on. A fixed window can undershoot it (an evening click or
        // sparse working days push the Nth business day past today+7) and a day
        // with no fetched events reads as fully free.
        let days = availabilityService.businessDaysForRange(
            rangeType,
            from: now,
            workingDays: Set(AppSettings.workingDays)
        )

        guard let first = days.first, let last = days.last,
              let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) else {
            let fallbackEnd = cal.date(byAdding: .day, value: 7, to: today) ?? today
            return (today, fallbackEnd)
        }

        return (min(today, cal.startOfDay(for: first)), end)
    }

    // MARK: - Permission

    private var hasShownPermissionAlert = false

    /// One-shot per launch; the caller has already flashed `.noAccess`, so
    /// repeat unauthorized clicks still get visible feedback without
    /// re-modal-ing the alert.
    private func maybeShowPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        let alert = NSAlert()
        alert.messageText = "Calendar Access Required"
        alert.informativeText = "Availability Click needs access to your calendars to show availability. Please enable it in System Settings > Privacy & Security > Calendars."
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
