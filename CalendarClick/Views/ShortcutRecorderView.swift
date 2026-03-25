import SwiftUI
import AppKit

struct ShortcutRecorderView: View {
    @State private var displayText: String = ""
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            ShortcutCaptureField(
                displayText: $displayText,
                isRecording: $isRecording
            )
            .frame(width: 120, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )

            if !displayText.isEmpty {
                Button("Clear") {
                    displayText = ""
                    UserDefaults.standard.set([String: Int](), forKey: AppSettings.globalShortcutKey)
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            loadSavedShortcut()
        }
    }

    private func loadSavedShortcut() {
        guard let saved = AppSettings.globalShortcut,
              let keyCode = saved["keyCode"],
              let modifiers = saved["modifiers"] else { return }

        displayText = GlobalShortcutManager.displayString(
            keyCode: UInt16(keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        )
    }
}

// MARK: - NSViewRepresentable Capture Field

private struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var displayText: String
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutNSView {
        let view = ShortcutNSView()
        view.onShortcutCaptured = { keyCode, modifiers in
            let dict: [String: Int] = [
                "keyCode": Int(keyCode),
                "modifiers": Int(modifiers.rawValue),
            ]
            UserDefaults.standard.set(dict, forKey: AppSettings.globalShortcutKey)

            displayText = GlobalShortcutManager.displayString(keyCode: keyCode, modifiers: modifiers)
            isRecording = false
        }
        view.onRecordingChanged = { recording in
            isRecording = recording
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutNSView, context: Context) {
        nsView.displayText = displayText
        nsView.needsDisplay = true
    }
}

// MARK: - Custom NSView for Key Capture

private final class ShortcutNSView: NSView {
    var displayText: String = ""
    var onShortcutCaptured: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let text: String
        if isRecording {
            text = "Type shortcut..."
        } else if displayText.isEmpty {
            text = "Click to record"
        } else {
            text = displayText
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isRecording
                ? NSColor.controlAccentColor
                : (displayText.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor),
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let size = attrString.size()
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        attrString.draw(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        onRecordingChanged?(true)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Require at least one modifier (no bare keys)
        let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let pressedModifiers = event.modifierFlags.intersection(modifierMask)

        guard !pressedModifiers.isEmpty else { return }

        // Ignore standalone modifier key presses
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierKeyCodes.contains(event.keyCode) else { return }

        isRecording = false
        onShortcutCaptured?(event.keyCode, pressedModifiers)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
            needsDisplay = true
        }
        return super.resignFirstResponder()
    }
}
