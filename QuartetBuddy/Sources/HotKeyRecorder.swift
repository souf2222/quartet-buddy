import AppKit
import Carbon.HIToolbox

/// A tiny panel that records the next key combination for the hotkey.
enum HotKeyRecorder {

    final class CaptureView: NSView {
        var onCombo: ((UInt32, UInt32) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let carbonMods = carbonModifiers(from: event.modifierFlags)
            let needsModifier = carbonMods & UInt32(cmdKey | optionKey | controlKey) == 0
            if needsModifier && event.keyCode != UInt32(kVK_Escape) {
                NSSound.beep()
                return
            }
            if event.keyCode == UInt32(kVK_Escape) {
                onCancel?()
            } else {
                onCombo?(UInt32(event.keyCode), carbonMods)
            }
            window?.close()
        }

        override func flagsChanged(with event: NSEvent) {
            // keep focus visuals fresh
            needsDisplay = true
        }
    }

    static func record(onCombo: @escaping (HotKeyManager.Combo?) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "Talkback Hotkey"
        panel.isFloatingPanel = true

        let view = CaptureView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        view.onCombo = { keyCode, mods in
            onCombo(HotKeyManager.Combo(keyCode: keyCode, modifiers: mods))
        }
        view.onCancel = { onCombo(nil) }
        panel.contentView = view

        let label = NSTextField(labelWithString: "Press the key combination for Talkback\n(⌘/⌥/⌃ + key, Esc to cancel)")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 40, width: 280, height: 60)
        view.addSubview(label)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeFirstResponder(view)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}
