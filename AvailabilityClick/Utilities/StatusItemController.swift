import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var animationTimer: Timer?
    private var settingsWindow: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?
    private var previewPopover: NSPopover?

    /// The permanent menu bar icon. The flash animation restores this constant
    /// instead of whatever the button showed when the flash started, so two
    /// overlapping flashes can't freeze the icon on a checkmark.
    private var baseImage: NSImage?

    /// Called when user left-clicks the icon
    var onLeftClick: (() -> Void)?

    /// Called when user Option+clicks the icon (preview mode)
    var onOptionClick: (() -> Void)?

    /// Called when user selects a range from the right-click menu
    var onRangeSelected: ((DateRangeType) -> Void)?

    func setup() {
        // Use variable length so the icon area is slightly wider (easier to click)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        // ~20% larger than the default 16pt by using a point size config
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Availability Click")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        baseImage = image
        button.image = image

        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Click Handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Dismissed here, not via transient outside-click, so the user's
        // first gesture both closes the coach AND executes (OQ3).
        dismissCoachmark()

        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else if event.modifierFlags.contains(.option) {
            onOptionClick?()
        } else {
            onLeftClick?()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let nextWeekItem = NSMenuItem(title: "Next week", action: #selector(copyNextWeek), keyEquivalent: "")
        nextWeekItem.target = self
        menu.addItem(nextWeekItem)

        let fortnightItem = NSMenuItem(title: "Next fortnight", action: #selector(copyNextFortnight), keyEquivalent: "")
        fortnightItem.target = self
        menu.addItem(fortnightItem)

        let thirtyDaysItem = NSMenuItem(title: "Next 30 days", action: #selector(copyNext30Days), keyEquivalent: "")
        thirtyDaysItem.target = self
        menu.addItem(thirtyDaysItem)

        menu.addItem(.separator())

        // Disabled version line (nil action): what makes the browser-based
        // update check meaningful -- the user can compare against the
        // releases page (KTD9).
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(NSMenuItem(title: "Availability Click v\(version)", action: nil, keyEquivalent: ""))

        let updatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Availability Click", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu Actions

    @objc private func copyNextWeek() {
        onRangeSelected?(.nextWeek)
    }

    @objc private func copyNextFortnight() {
        onRangeSelected?(.nextFortnight)
    }

    @objc private func copyNext30Days() {
        onRangeSelected?(.next30Days)
    }

    @objc private func checkForUpdates() {
        // Honest naming (KTD9): opens the releases page in the browser --
        // the app itself never calls the network.
        if let url = URL(string: "https://github.com/Reebz/availability-click/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        // Reuse existing window if it's still around
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .frame(minWidth: 456, minHeight: 500)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Availability Click Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 504, height: 675))
        window.minSize = NSSize(width: 456, height: 500)
        window.isReleasedWhenClosed = false

        // Always on top
        window.level = .floating

        // Position underneath the menu bar icon
        positionWindowUnderStatusItem(window)

        // Observe close to re-hide Dock icon. Keep the token and remove any
        // previous one -- a discarded token leaks an observer per window.
        if let observer = settingsCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.settingsCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.settingsCloseObserver = nil
                }
                self.settingsWindow = nil
                NSApp.setActivationPolicy(.accessory)
            }
        }

        self.settingsWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionWindowUnderStatusItem(_ window: NSWindow) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            window.center()
            return
        }

        // Get the status item's position in screen coordinates
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        // Position window so its top-right aligns with the status item
        let windowSize = window.frame.size
        let x = screenRect.midX - windowSize.width / 2
        let y = screenRect.minY - 4 // Small gap below menu bar

        window.setFrameTopLeftPoint(NSPoint(x: x, y: y))

        // Ensure the window stays on screen
        if let screen = NSScreen.main {
            var frame = window.frame
            if frame.minX < screen.visibleFrame.minX {
                frame.origin.x = screen.visibleFrame.minX
            }
            if frame.maxX > screen.visibleFrame.maxX {
                frame.origin.x = screen.visibleFrame.maxX - frame.width
            }
            window.setFrame(frame, display: false)
        }
    }

    // MARK: - Preview Popover

    func showPreviewPopover(slots: [Date: [TimeSlot]]) {
        // Dismiss existing popover
        previewPopover?.close()

        let popoverView = PreviewPopoverView(
            slots: slots,
            // The popover writes the pasteboard itself (PasteboardWriter with
            // its selected timezone/template) so rich flavors match what the
            // user previewed; this callback is just close-and-flash.
            onCopy: { [weak self] in
                self?.previewPopover?.close()
                self?.previewPopover = nil
                self?.showOutcome(.copied)
            },
            onDismiss: { [weak self] in
                self?.previewPopover?.close()
                self?.previewPopover = nil
            }
        )

        let hostingController = NSHostingController(rootView: popoverView)

        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 420)

        self.previewPopover = popover

        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - First-Run Coach (KTD8)

    private var coachPopover: NSPopover?
    private var coachDismissMonitor: Any?
    private var coachDismissLocalMonitor: Any?

    func showCoachmark() {
        guard coachPopover == nil, let button = statusItem.button else { return }

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: CoachmarkView())
        // applicationDefined, not transient: a transient popover would eat
        // the first status-item click just to dismiss itself (OQ3).
        popover.behavior = .applicationDefined
        coachPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Any click elsewhere also dismisses. The global monitor covers other
        // apps (mouse monitors need no Accessibility grant, unlike key
        // monitors); the local monitor covers clicks inside this app --
        // including on the coach popover itself.
        coachDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissCoachmark()
            }
        }
        coachDismissLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissCoachmark()
            }
            return event
        }
    }

    private func dismissCoachmark() {
        if let monitor = coachDismissMonitor {
            NSEvent.removeMonitor(monitor)
            coachDismissMonitor = nil
        }
        if let monitor = coachDismissLocalMonitor {
            NSEvent.removeMonitor(monitor)
            coachDismissLocalMonitor = nil
        }
        coachPopover?.close()
        coachPopover = nil
    }

    // MARK: - Feedback Animation

    /// Flashes the outcome symbol and sets the button tooltip to the failure
    /// reason. The tooltip is written on every outcome (nil on success) so
    /// stale failure text never lingers past the next attempt (KTD3).
    func showOutcome(_ outcome: CopyOutcome) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: outcome.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true

        statusItem.button?.image = image
        statusItem.button?.toolTip = outcome.tooltip

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusItem.button?.image = self?.baseImage
            }
        }
    }
}

/// One-time gesture coach shown under the status item (R11).
private struct CoachmarkView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Left-click copies availability", systemImage: "cursorarrow.click")
            Label("Right-click for ranges", systemImage: "filemenu.and.selection")
            Label("Option+click previews", systemImage: "eye")
        }
        .font(.callout)
        .padding(14)
    }
}
