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
        statusItemController.onProposal = { [weak self] in
            self?.copyProposal()
        }
        statusItemController.setup()

        // Set up global keyboard shortcut
        shortcutManager = GlobalShortcutManager()
        registerSavedShortcut()
        observeShortcutChanges()
        observeRecordingState()

        // User-visible launch side effects are deferred: a cold Shortcuts run
        // launches the app headless and performs the intent right away, and
        // unattended runs must never pop the permission sheet (OQ10). The
        // intent marks the launch before this fires.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.runUserVisibleLaunchSideEffects()
        }
    }

    /// Set by GetAvailabilityIntent so a headless Shortcuts-driven launch
    /// skips the TCC auto-request (and the first-run coach).
    static var intentDidRunThisLaunch = false

    private func runUserVisibleLaunchSideEffects() {
        guard !Self.intentDidRunThisLaunch else { return }

        if calendarService.authorizationStatus == .notDetermined {
            Task { @MainActor in
                _ = await calendarService.requestAccess()
                // Coach only after the sheet resolves -- grant or deny, the
                // gestures matter regardless. Raw launch timing would race
                // the system permission sheet (KTD8).
                showCoachmarkIfNeeded()
            }
        } else {
            // v1.0.0 upgraders: permission already determined, no sheet to
            // race -- show immediately after status-item setup (OQ12).
            showCoachmarkIfNeeded()
        }
    }

    /// Coach gating: only on a user-visible launch, only ever once,
    /// independent of the permission outcome.
    static func coachmarkNeeded(hasShownCoachmark: Bool, intentDrivenLaunch: Bool) -> Bool {
        !intentDrivenLaunch && !hasShownCoachmark
    }

    private func showCoachmarkIfNeeded() {
        guard Self.coachmarkNeeded(
            hasShownCoachmark: AppSettings.hasShownCoachmark,
            intentDrivenLaunch: Self.intentDidRunThisLaunch
        ) else { return }

        // Flag set immediately when shown -- a crash mid-display must not
        // re-show it on the next launch (KTD8).
        AppSettings.setHasShownCoachmark()
        statusItemController.showCoachmark()
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
        // A refused registration must not leave the dedupe guard holding the
        // failed combo: re-recording the identical combo is a retry, and the
        // guard would otherwise swallow it into a silent no-op (OQ5).
        recordingObservers.append(center.addObserver(
            forName: .shortcutRegistrationStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard GlobalShortcutManager.lastRegistrationFailed else { return }
                self?.lastAppliedShortcut = nil
            }
        })
    }

    // MARK: - Preview

    private func showPreview() {
        guard calendarService.isAuthorized else {
            handleUnauthorizedInteraction()
            return
        }

        let rangeType = defaultRangeType

        Task { @MainActor in
            guard !calendarService.selectedCalendars().isEmpty else {
                statusItemController.showOutcome(.noCalendars)
                return
            }

            let dateRange = availabilityService.fetchWindow(for: rangeType)
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
        AppSettings.defaultRangeType
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
            handleUnauthorizedInteraction()
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

            let dateRange = availabilityService.fetchWindow(for: rangeType, now: now)
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
                    template: AppSettings.defaultFormatTemplate,
                    asOf: AppSettings.showAsOfStamp ? now : nil
                )
                statusItemController.showOutcome(.copied)
            }
        }
    }

    // MARK: - Proposal Mode (U4)

    /// Copies a numbered one-sentence proposal of up to 3 well-spread times
    /// over the today-inclusive 30-day window. Same auth/debounce/no-calendars
    /// gates as copyRange; an empty proposal is the ordinary no-slots outcome.
    private func copyProposal() {
        guard calendarService.isAuthorized else {
            handleUnauthorizedInteraction()
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastCopyTime) > 0.5 else { return }
        lastCopyTime = now

        Task { @MainActor in
            guard !calendarService.selectedCalendars().isEmpty else {
                statusItemController.showOutcome(.noCalendars)
                return
            }

            let rangeType: DateRangeType = .next30DaysIncludingToday
            let dateRange = availabilityService.fetchWindow(for: rangeType, now: now)
            let events = await calendarService.fetchEvents(from: dateRange.start, to: dateRange.end)
            let slots = availabilityService.calculateAvailability(
                events: events, rangeType: rangeType, now: now
            )

            let proposal = AvailabilityService.selectProposalSlots(from: slots, count: 3)
            guard !proposal.isEmpty else {
                statusItemController.showOutcome(.noSlots)
                return
            }

            let text = AvailabilityFormatter().formatProposal(
                slots: proposal,
                showTimeZone: AppSettings.showTimeZone,
                asOf: AppSettings.showAsOfStamp ? now : nil
            )
            PasteboardWriter.writeText(text)
            statusItemController.showOutcome(.copied)
        }
    }

    // MARK: - Permission

    private var hasShownPermissionAlert = false

    /// An unauthorized click or hotkey press. When the status is still
    /// .notDetermined the system prompt was never requested this session --
    /// a headless intent-first launch suppresses the launch-time request
    /// (OQ10) and the app then never appears in Privacy & Security >
    /// Calendars, making the alert's instructions unfollowable. A click IS a
    /// user-visible moment, so fire the real request now; the coach follows
    /// its resolution (KTD8).
    private func handleUnauthorizedInteraction() {
        statusItemController.showOutcome(.noAccess)

        if calendarService.authorizationStatus == .notDetermined {
            // The click makes this session user-visible again, so the
            // intent-launch suppression no longer applies (to the coach
            // either).
            Self.intentDidRunThisLaunch = false
            Task { @MainActor in
                _ = await calendarService.requestAccess()
                showCoachmarkIfNeeded()
            }
        } else {
            maybeShowPermissionAlert()
        }
    }

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
