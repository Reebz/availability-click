import AppKit

@MainActor
final class GlobalShortcutManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var registeredKeyCode: UInt16?
    private var registeredModifiers: NSEvent.ModifierFlags?
    private var action: (() -> Void)?

    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        unregister()

        self.registeredKeyCode = keyCode
        self.registeredModifiers = modifiers
        self.action = action

        // Mask to only compare device-independent modifier flags
        let mask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let targetModifiers = modifiers.intersection(mask)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventKeyCode = event.keyCode
            let eventModifiers = event.modifierFlags.intersection(mask)
            MainActor.assumeIsolated {
                guard let self,
                      eventKeyCode == keyCode,
                      eventModifiers == targetModifiers else { return }
                self.action?()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventKeyCode = event.keyCode
            let eventModifiers = event.modifierFlags.intersection(mask)
            let matched = eventKeyCode == keyCode && eventModifiers == targetModifiers
            MainActor.assumeIsolated {
                guard let self else { return }
                if matched {
                    self.action?()
                }
            }
            return matched ? nil : event
        }
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        registeredKeyCode = nil
        registeredModifiers = nil
        action = nil
    }

    // MARK: - Human-Readable Display

    static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []

        if modifiers.contains(.control) { parts.append("\u{2303}") }
        if modifiers.contains(.option) { parts.append("\u{2325}") }
        if modifiers.contains(.shift) { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }

        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".",
            36: "\u{21A9}", // Return
            48: "\u{21E5}", // Tab
            49: "\u{2423}", // Space
            51: "\u{232B}", // Delete
            53: "\u{238B}", // Escape
            115: "\u{2196}", // Home
            119: "\u{2198}", // End
            116: "\u{21DE}", // Page Up
            121: "\u{21DF}", // Page Down
            123: "\u{2190}", // Left Arrow
            124: "\u{2192}", // Right Arrow
            125: "\u{2193}", // Down Arrow
            126: "\u{2191}", // Up Arrow
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return keyMap[keyCode] ?? "Key\(keyCode)"
    }
}
