import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var animationTimer: Timer?
    private var settingsWindow: NSWindow?
    private var previewPopover: NSPopover?

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
        button.image = image

        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Click Handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
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

    @objc private func openSettings() {
        // Reuse existing window if it's still around
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .frame(minWidth: 380, minHeight: 400)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Availability Click Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 540))
        window.minSize = NSSize(width: 380, height: 400)
        window.isReleasedWhenClosed = false

        // Always on top
        window.level = .floating

        // Position underneath the menu bar icon
        positionWindowUnderStatusItem(window)

        // Observe close to re-hide Dock icon
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWindow = nil
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
            onCopy: { [weak self] text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.previewPopover?.close()
                self?.previewPopover = nil
                self?.flashConfirmation(success: true)
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

    // MARK: - Feedback Animation

    func flashConfirmation(success: Bool) {
        let symbolName = success ? "checkmark.circle.fill" : "xmark.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true

        let originalImage = statusItem.button?.image

        statusItem.button?.image = image

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusItem.button?.image = originalImage
            }
        }
    }
}
