import AppKit

/// Outcome of a copy attempt (KTD3). Replaces the old success boolean so a
/// failed click can say why: distinct symbol per failure (OQ11) plus a
/// tooltip as the detail layer.
enum CopyOutcome: Equatable {
    case copied
    case noAccess
    case noCalendars
    case noSlots
    /// The overwrite guard (R6): our clipboard output is untouched but
    /// availability changed since; this click confirms instead of overwriting.
    case availabilityChanged

    var symbolName: String {
        switch self {
        case .copied: "checkmark.circle.fill"
        case .noAccess: "lock.circle"
        case .noCalendars: "calendar.badge.exclamationmark"
        case .noSlots: "xmark.circle"
        case .availabilityChanged: "clock.arrow.circlepath"
        }
    }

    /// One-line reason; nil on success so a stale failure tooltip never
    /// outlives the outcome that set it. `.availabilityChanged` reads as
    /// guidance, not a failure.
    var tooltip: String? {
        switch self {
        case .copied: nil
        case .noAccess: "Calendar access not granted - open Settings"
        case .noCalendars: "No calendars available"
        case .noSlots: "No free slots in this range"
        case .availabilityChanged: "Availability changed since your last copy — click again to overwrite"
        }
    }

    /// VoiceOver announcement (R13): the tooltip where one exists, and an
    /// explicit success line since `.copied`'s tooltip is nil by design. The
    /// icon stays the primary channel; this is additive.
    var announcementText: String {
        tooltip ?? "Availability copied"
    }
}

/// Persistent status-icon state that outlives the 1.5s outcome flash (U5,
/// KTD7). The flash reverts TO this baseline, never past it. Its symbols must
/// stay distinct from every `CopyOutcome` symbol so the two layers never look
/// alike (`calendar.badge.exclamationmark` is already taken by `.noCalendars`).
enum AttentionState: Equatable {
    case none
    case calendarsUnavailable   // every saved calendar went stale (R11)
    case copiedSlotStale        // a copied slot is no longer free (R5)

    /// nil for `.none` (the icon falls back to its plain base image);
    /// otherwise a badged SF Symbol drawn in template mode.
    var symbolName: String? {
        switch self {
        case .none: nil
        case .calendarsUnavailable: "calendar.badge.minus"
        case .copiedSlotStale: "exclamationmark.circle"
        }
    }

    /// The explanation shown while the badge stands; nil for `.none`.
    var tooltip: String? {
        switch self {
        case .none: nil
        case .calendarsUnavailable: "Your selected calendars are no longer available — pick calendars in Settings"
        case .copiedSlotStale: "A time you copied is no longer free — copy again for current availability"
        }
    }

    /// VoiceOver announcement for a passive state change (R13); nil for `.none`.
    var announcementText: String? { tooltip }
}

/// Trailing-debounce coalescer keyed by a monotonic generation token (KTD11):
/// N rapid triggers within the delay collapse to one delivery. Uses Task
/// cancellation-by-generation, never a lock on the cooperative pool. The
/// generation logic is pure and unit-tested; `schedule` adds only the delay.
@MainActor
final class TrailingDebouncer {
    private var generation = 0
    private let delay: Duration

    init(delay: Duration) { self.delay = delay }

    /// Advances the generation and returns the token for this trigger.
    func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// True only for the newest generation, so a superseded scheduled body
    /// bails out — this is the debounce.
    func isCurrent(_ token: Int) -> Bool { token == generation }

    /// Runs `body` after the delay unless a newer trigger superseded it.
    func schedule(_ body: @escaping @MainActor () async -> Void) {
        let token = nextGeneration()
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard isCurrent(token) else { return }
            await body()
        }
    }
}

/// Tap-vs-hold reducer for the global hotkey (U9, KTD9). Pure state machine,
/// clock-injected, so it is unit-testable without timers: press starts the
/// hold; a release before the threshold is a tap (copy), the threshold timer
/// firing is a hold (open the preview), and a release after the hold already
/// fired is ignored so the open preview stays put. A hold never auto-copies.
enum HoldOutcome: Equatable { case none, copy, openPreview }

@MainActor
final class HoldGestureMachine {
    private let threshold: TimeInterval
    private var pressTime: Date?
    private var previewOpen = false

    init(threshold: TimeInterval) { self.threshold = threshold }

    func press(at time: Date) -> HoldOutcome {
        pressTime = time
        previewOpen = false
        return .none
    }

    /// The threshold timer fired: a hold. Returns `.openPreview` once; further
    /// calls are no-ops.
    func timerFired() -> HoldOutcome {
        guard pressTime != nil, !previewOpen else { return .none }
        previewOpen = true
        return .openPreview
    }

    func release(at time: Date) -> HoldOutcome {
        guard let pressTime else { return .none }
        self.pressTime = nil
        if previewOpen { return .none }  // late release; preview already open
        return time.timeIntervalSince(pressTime) < threshold ? .copy : .openPreview
    }
}

/// What the app last copied, so a calendar change can be checked against it
/// (R5 watch) and the next copy can detect a silent clobber (R6 guard). The
/// original `now` is retained so the recompute lands on the SAME days, not a
/// window re-derived from a later clock (KTD11).
private struct CopyWatch {
    let slots: Set<TimeSlot>
    let rangeType: DateRangeType
    let now: Date
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController!
    private let calendarService = CalendarService.shared
    private let availabilityService = AvailabilityService()
    private var shortcutManager: GlobalShortcutManager!
    private var shortcutObserver: NSObjectProtocol?
    private var recordingObservers: [NSObjectProtocol] = []
    private var calendarSelectionObserver: NSObjectProtocol?
    private var calendarStoreObserver: NSObjectProtocol?

    /// Debounce: ignore clicks within 500ms of previous
    private var lastCopyTime: Date = .distantPast

    // MARK: - Stale-Copy Watch + Overwrite Guard (U7)

    /// The last copy's slot set + range + clock, watched for staleness (R5) and
    /// compared by the overwrite guard (R6). In-memory only; a relaunch clears
    /// it by design.
    private var copyWatch: CopyWatch?

    /// Bumped on every recorded copy so an in-flight stale recheck that started
    /// against an older copy bails out after its await instead of re-badging a
    /// superseded set (R5 "next copy clears").
    private var copyWatchGeneration = 0

    /// True after the overwrite guard has fired once for the current situation,
    /// so the following click writes normally (R6).
    private var confirmationPending = false

    /// ~400ms trailing debounce over the bursty, payload-free EKEventStoreChanged
    /// notification (KTD11).
    private let staleDebouncer = TrailingDebouncer(delay: .milliseconds(400))

    /// Hold gesture (U9): a press held ~400ms opens the preview instead of
    /// copying. Threshold sits in the researched 350-450ms band.
    static let holdThreshold: TimeInterval = 0.4
    /// The hold-opened preview auto-dismisses after this if untouched — the
    /// backstop for a swallowed release degrading to an open popover (KTD9).
    static let holdPreviewSafetyTimeout: TimeInterval = 30
    private lazy var holdMachine = HoldGestureMachine(threshold: Self.holdThreshold)
    private var holdTimer: Timer?

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
        observeCalendarSelectionChanges()
        observeCalendarStoreChanges()

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
        if let calendarSelectionObserver {
            NotificationCenter.default.removeObserver(calendarSelectionObserver)
        }
        if let calendarStoreObserver {
            NotificationCenter.default.removeObserver(calendarStoreObserver)
        }
    }

    // MARK: - Calendar-Selection Safety (U6)

    /// Re-evaluate the persistent calendars-unavailable badge whenever the user
    /// re-picks in Settings, so recovery clears the notice (R11).
    private func observeCalendarSelectionChanges() {
        calendarSelectionObserver = NotificationCenter.default.addObserver(
            forName: .calendarSelectionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCalendarAttention() }
        }
    }

    /// Sets the calendars-unavailable badge when every saved calendar is stale,
    /// clears it on recovery. Targeted so it never disturbs a stale-copy badge.
    private func refreshCalendarAttention() {
        if calendarService.savedSelectionIsAllStale {
            statusItemController.setAttention(.calendarsUnavailable)
        } else {
            statusItemController.clearAttention(ifShowing: .calendarsUnavailable)
        }
    }

    // MARK: - Stale-Copy Watch + Overwrite Guard (U7)

    /// The overwrite guard (R6, KTD10) fires only when our last write still
    /// sits on the pasteboard AND the fresh slots differ from what we copied —
    /// and only on the first such click; a pending confirmation means the user
    /// already saw it, so this click writes. Pure, unit-tested without MainActor.
    static func overwriteGuardTriggers(
        pasteboardUnchanged: Bool,
        slotsChanged: Bool,
        confirmationPending: Bool
    ) -> Bool {
        guard !confirmationPending else { return false }
        return pasteboardUnchanged && slotsChanged
    }

    /// The guard's "availability changed" input (R6). It is true only when this
    /// copy is the SAME range as the watched copy AND its slots differ —
    /// switching to a different range or the proposal is a deliberate new copy,
    /// not a silent clobber, so it must not trip the confirmation. Pure.
    static func overwriteGuardSlotsDiffer(
        watchedRange: DateRangeType?,
        watchedSlots: Set<TimeSlot>?,
        range: DateRangeType,
        offered: Set<TimeSlot>
    ) -> Bool {
        guard let watchedRange, let watchedSlots else { return false }
        return watchedRange == range && watchedSlots != offered
    }

    /// A copied slot is stale once it is no longer EXACTLY among the freshly
    /// computed slots (R5): a shrink or split drops the exact interval.
    /// Additions never trigger it — extra fresh slots leave the watched ones
    /// intact (subset holds). Pure.
    static func copiedSlotsBecameStale(watched: Set<TimeSlot>, fresh: Set<TimeSlot>) -> Bool {
        !watched.isSubset(of: fresh)
    }

    /// Records what we just copied and clears any stale badge — a new copy
    /// replaces the watched set (R5). The pasteboard `changeCount` snapshot is
    /// taken inside PasteboardWriter by the write itself (KTD10).
    private func recordCopy(slots: Set<TimeSlot>, rangeType: DateRangeType, now: Date) {
        copyWatch = CopyWatch(slots: slots, rangeType: rangeType, now: now)
        copyWatchGeneration += 1
        confirmationPending = false
        statusItemController.clearAttention(ifShowing: .copiedSlotStale)
    }

    /// Recompute-on-change watch (R5, KTD11). Same publisher the picker uses,
    /// debounced so a sync storm collapses to one recompute.
    private func observeCalendarStoreChanges() {
        calendarStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.staleDebouncer.schedule { [weak self] in
                    await self?.recheckCopiedSlotsStale()
                }
            }
        }
    }

    /// Recomputes the watched copy over the SAME days (its stored `now`) and
    /// badges when any copied slot is no longer free. Additions never badge.
    private func recheckCopiedSlotsStale() async {
        guard let watch = copyWatch,
              calendarService.isAuthorized,
              !calendarService.selectedCalendars().isEmpty else { return }

        let generation = copyWatchGeneration
        let window = availabilityService.fetchWindow(for: watch.rangeType, now: watch.now)
        let events = await calendarService.fetchEvents(from: window.start, to: window.end)
        // A copy that landed during the fetch superseded this watch and already
        // cleared the badge; don't re-badge the old set (R5 "next copy clears").
        guard generation == copyWatchGeneration else { return }

        let fresh = availabilityService.calculateAvailability(
            events: events, rangeType: watch.rangeType, now: watch.now
        )
        let freshSet = Set(fresh.values.flatMap { $0 })
        if Self.copiedSlotsBecameStale(watched: watch.slots, fresh: freshSet) {
            statusItemController.setAttention(.copiedSlotStale)
        }
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
                modifiers: [.control, .shift],
                onPress: { [weak self] in self?.handleHotkeyPress() },
                onRelease: { [weak self] in self?.handleHotkeyRelease() }
            )
            return
        }

        if keyCode == 0 && modifiers == 0 {
            shortcutManager.unregister()
            return
        }

        shortcutManager.register(
            keyCode: UInt16(clamping: keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers)),
            onPress: { [weak self] in self?.handleHotkeyPress() },
            onRelease: { [weak self] in self?.handleHotkeyRelease() }
        )
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
        presentPreview(holdInitiated: false)
    }

    // MARK: - Hold-to-Preview (U9)

    /// Hotkey pressed: start the hold timer. A tap (release before threshold)
    /// copies; the timer firing opens the preview.
    private func handleHotkeyPress() {
        _ = holdMachine.press(at: Date())
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimer = nil
                if self.holdMachine.timerFired() == .openPreview {
                    self.presentPreview(holdInitiated: true)
                }
            }
        }
    }

    /// Hotkey released: a quick release copies; a release after the hold fired
    /// is ignored so the open preview stays put (KTD9). A swallowed release
    /// never arrives, so the timer's hold covers it.
    private func handleHotkeyRelease() {
        holdTimer?.invalidate()
        holdTimer = nil
        switch holdMachine.release(at: Date()) {
        case .copy: copyDefault()
        case .openPreview: presentPreview(holdInitiated: true)
        case .none: break
        }
    }

    /// Shared preview flow for Option+click (`holdInitiated: false`) and a held
    /// hotkey (`true`). A hold-opened popover is made key and gets a safety
    /// timeout; an unauthorized/no-calendars hold shows the same outcome a copy
    /// would, never an empty popover.
    private func presentPreview(holdInitiated: Bool) {
        guard calendarService.isAuthorized else {
            handleUnauthorizedInteraction()
            return
        }

        let rangeType = defaultRangeType

        Task { @MainActor in
            refreshCalendarAttention()
            guard !calendarService.selectedCalendars().isEmpty else {
                statusItemController.showOutcome(.noCalendars)
                return
            }

            let now = Date()
            let dateRange = availabilityService.fetchWindow(for: rangeType, now: now)
            let events = await calendarService.fetchEvents(from: dateRange.start, to: dateRange.end)
            let slots = availabilityService.calculateAvailability(events: events, rangeType: rangeType, now: now)

            if slots.isEmpty {
                statusItemController.showOutcome(.noSlots)
            } else {
                let offered = Set(slots.values.flatMap { $0 })
                statusItemController.showPreviewPopover(slots: slots, holdInitiated: holdInitiated) { [weak self] in
                    // The preview's Copy is the app's own output: record it so a
                    // later booking badges it (R5) and the next click can't
                    // silently clobber it (R6).
                    self?.recordCopy(slots: offered, rangeType: rangeType, now: now)
                }
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
            refreshCalendarAttention()
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
                let offered = Set(slots.values.flatMap { $0 })
                if overwriteGuardWouldFire(against: offered, rangeType: rangeType) {
                    confirmationPending = true
                    statusItemController.showOutcome(.availabilityChanged)
                    return
                }
                PasteboardWriter.write(
                    slots: slots,
                    showTimeZone: AppSettings.showTimeZone,
                    template: AppSettings.defaultFormatTemplate,
                    asOf: AppSettings.showAsOfStamp ? now : nil
                )
                recordCopy(slots: offered, rangeType: rangeType, now: now)
                statusItemController.showOutcome(.copied)
            }
        }
    }

    /// Evaluates the overwrite guard for a copy about to write `offered`
    /// against the last watched set (R6). Extracted so copyRange and
    /// copyProposal share one call.
    private func overwriteGuardWouldFire(against offered: Set<TimeSlot>, rangeType: DateRangeType) -> Bool {
        let slotsChanged = Self.overwriteGuardSlotsDiffer(
            watchedRange: copyWatch?.rangeType,
            watchedSlots: copyWatch?.slots,
            range: rangeType,
            offered: offered
        )
        return Self.overwriteGuardTriggers(
            pasteboardUnchanged: PasteboardWriter.pasteboardHoldsOurLastWrite(),
            slotsChanged: slotsChanged,
            confirmationPending: confirmationPending
        )
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
            refreshCalendarAttention()
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

            let offered = Set(proposal)
            if overwriteGuardWouldFire(against: offered, rangeType: rangeType) {
                confirmationPending = true
                statusItemController.showOutcome(.availabilityChanged)
                return
            }

            let text = AvailabilityFormatter().formatProposal(
                slots: proposal,
                showTimeZone: AppSettings.showTimeZone,
                asOf: AppSettings.showAsOfStamp ? now : nil
            )
            PasteboardWriter.writeText(text)
            recordCopy(slots: offered, rangeType: rangeType, now: now)
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
