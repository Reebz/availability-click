import AppKit
import Carbon.HIToolbox
import os

extension Notification.Name {
    /// Posted by ShortcutRecorderView when key capture starts/stops so the
    /// active hotkey can be suspended -- Carbon would otherwise consume the
    /// keystroke before AppKit delivers it to the recorder field.
    static let shortcutRecordingBegan = Notification.Name("AvailabilityClick.shortcutRecordingBegan")
    static let shortcutRecordingEnded = Notification.Name("AvailabilityClick.shortcutRecordingEnded")
    /// Posted after every registration attempt so the recorder can reflect
    /// an inactive shortcut (registration refused by macOS).
    static let shortcutRegistrationStateChanged = Notification.Name("AvailabilityClick.shortcutRegistrationStateChanged")
}

/// FourCharCode "AVCK" -- identifies this app's hotkey in the Carbon callback.
private let hotKeySignature: FourCharCode = 0x4156_434B
private let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)

/// Top-level C-convention callback (Swift 6 bridge): Unmanaged round-trip of
/// the @MainActor manager, MainActor.assumeIsolated after a main-thread
/// check -- the dispatcher target delivers hotkey events on the main run loop.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var pressedID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &pressedID
    )
    guard status == noErr,
          pressedID.signature == hotKeySignature,
          Thread.isMainThread else {
        return OSStatus(eventNotHandledErr)
    }

    let kind = GetEventKind(event)
    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        if kind == UInt32(kEventHotKeyReleased) {
            manager.handleHotKeyReleased()
        } else {
            manager.handleHotKeyPressed()
        }
    }
    return noErr
}

/// Global hotkey via Carbon `RegisterEventHotKey` -- sandbox-safe, needs no
/// Accessibility or Input Monitoring grant (unlike the NSEvent global monitor
/// this replaced, which silently never fired without Accessibility trust).
@MainActor
final class GlobalShortcutManager {
    private static let logger = Logger(
        subsystem: "com.availabilityclick.AvailabilityClick",
        category: "GlobalShortcutManager"
    )

    /// True when the most recent registration attempt was refused by macOS
    /// (e.g. the macOS 15.0-15.1 Option-only-modifier regression). Static so
    /// the Settings recorder, which has no reference to the app's manager
    /// instance, can render the inactive state.
    private(set) static var lastRegistrationFailed = false

    /// The Carbon event kinds this manager listens for (U9): a hold needs the
    /// release event too, not only the press. Source of truth for the handler
    /// installation below; asserted by a test.
    static let handledEventKinds: [Int] = [kEventHotKeyPressed, kEventHotKeyReleased]

    private var hotKeyRef: EventHotKeyRef?
    // nonisolated(unsafe) only so deinit (nonisolated) can remove it; every
    // other access stays on the MainActor.
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?
    private var pressAction: (() -> Void)?
    private var releaseAction: (() -> Void)?

    deinit {
        // The handler's userData is an unretained self -- it must not
        // outlive the manager (test-created managers are short-lived).
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// Retained registration parameters so suspend/resume (recorder capture)
    /// can restore the hotkey even when the re-recorded combo is identical
    /// and the UserDefaults-observer dedupe never re-applies it.
    private var currentKeyCode: UInt16?
    private var currentModifiers: NSEvent.ModifierFlags?
    private var isSuspended = false

    /// Injectable Carbon seams so unit tests can drive the failure path and
    /// count registrations without touching the real hotkey table.
    var registerHotKeyFn: (UInt32, UInt32) -> (OSStatus, EventHotKeyRef?) = { keyCode, carbonModifiers in
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        return (status, ref)
    }
    var unregisterHotKeyFn: (EventHotKeyRef) -> Void = {
        UnregisterEventHotKey($0)
    }

    var isActive: Bool { hotKeyRef != nil }

    func register(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        onPress: @escaping () -> Void,
        onRelease: (() -> Void)? = nil
    ) {
        unregisterCarbonHotKey()

        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers
        self.pressAction = onPress
        self.releaseAction = onRelease
        self.isSuspended = false

        registerRetainedShortcut()
    }

    func unregister() {
        unregisterCarbonHotKey()
        currentKeyCode = nil
        currentModifiers = nil
        pressAction = nil
        releaseAction = nil
        isSuspended = false
        setRegistrationFailed(false)
    }

    /// Drops the Carbon registration but keeps the retained parameters so
    /// `resume()` can restore it. Called while the recorder captures keys.
    func suspend() {
        guard currentKeyCode != nil else { return }
        unregisterCarbonHotKey()
        isSuspended = true
    }

    /// Restores a suspended registration. No-op when a `register` call
    /// already landed a new combo (register clears the suspended flag).
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        registerRetainedShortcut()
    }

    // Internal (not private) so tests can simulate a hotkey press/release.
    func handleHotKeyPressed() {
        pressAction?()
    }

    func handleHotKeyReleased() {
        releaseAction?()
    }

    // MARK: - Carbon Plumbing

    private func registerRetainedShortcut() {
        guard let keyCode = currentKeyCode, let modifiers = currentModifiers else { return }

        installEventHandlerIfNeeded()

        let (status, ref) = registerHotKeyFn(UInt32(keyCode), Self.carbonModifiers(from: modifiers))
        guard status == noErr, let ref else {
            // Refused registrations must not crash or leave half-state: stay
            // consistently unregistered and let the recorder show "inactive".
            Self.logger.error("RegisterEventHotKey failed with status \(status, privacy: .public)")
            currentKeyCode = nil
            currentModifiers = nil
            pressAction = nil
            releaseAction = nil
            setRegistrationFailed(true)
            return
        }

        hotKeyRef = ref
        setRegistrationFailed(false)
    }

    private func unregisterCarbonHotKey() {
        if let hotKeyRef {
            unregisterHotKeyFn(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        // Both press and release, so a held key can open the preview (U9).
        var eventTypes = Self.handledEventKinds.map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    private func setRegistrationFailed(_ failed: Bool) {
        guard Self.lastRegistrationFailed != failed else { return }
        Self.lastRegistrationFailed = failed
        NotificationCenter.default.post(name: .shortcutRegistrationStateChanged, object: nil)
    }

    // MARK: - Modifier Mapping

    static func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
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
