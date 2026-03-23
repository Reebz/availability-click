import AppKit

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private var animationTimer: Timer?

    /// Called when user left-clicks the icon
    var onLeftClick: (() -> Void)?

    /// Called when user selects a range from the right-click menu
    var onRangeSelected: ((DateRangeType) -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar Click")
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

        let quitItem = NSMenuItem(title: "Quit Calendar Click", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        NSApp.setActivationPolicy(.regular)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Feedback Animation

    func flashConfirmation(success: Bool) {
        let symbolName = success ? "checkmark.circle.fill" : "xmark.circle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true

        let originalImage = statusItem.button?.image

        statusItem.button?.image = image

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.statusItem.button?.image = originalImage
        }
    }
}
