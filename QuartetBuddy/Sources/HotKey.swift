import Foundation
import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey registered via RegisterEventHotKey (no TCC needed).
final class HotKeyManager {

    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey)

        var displayString: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + Self.keyString(keyCode)
        }

        static func keyString(_ code: UInt32) -> String {
            switch code {
            case 122: return "F1"; case 120: return "F2"; case 99: return "F3"
            case 118: return "F4"; case 96: return "F5"; case 97: return "F6"
            case 98: return "F7"; case 100: return "F8"; case 101: return "F9"
            case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
            case 105: return "F13"; case 107: return "F14"; case 113: return "F15"
            case 106: return "F16"; case 64: return "F17"
            case 36: return "↩"; case 53: return "Esc"; case 48: return "Tab"
            case 51: return "⌫"; case 49: return "Space"
            default:
                if let chars = UCKeyTranslateForDisplay(code) { return chars }
                return "Key \(code)"
            }
        }
    }

    var onHotKey: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var combo: Combo?

    func register(_ combo: Combo) {
        unregister()
        guard let keyCode = UInt32(exactly: combo.keyCode) else { return }
        var hotKeyID = EventHotKeyID(signature: OSType(0x5142544B /* 'QBTK' */), id: 1)
        var outRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &outRef)
        if status == noErr, let outRef {
            ref = outRef
            self.combo = combo
            installHandlerIfNeeded()
        }
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        combo = nil
    }

    var current: Combo? { combo }

    private var handlerInstalled = false
    private var eventHandler: EventHandlerRef?

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let proc: EventHandlerUPP = { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, UInt32(kEventParamDirectObject),
                              UInt32(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.signature == 0x5142544B {
                let myself = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
                myself.onHotKey?()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), proc, 1, &eventType,
                           Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        handlerInstalled = true
    }
}

private func UCKeyTranslateForDisplay(_ keyCode: UInt32) -> String? {
    guard let layoutData = TISGetInputSourcePropertySafe() else { return nil }
    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length: Int = 0
    let status = UCKeyTranslate(layoutData, UInt16(keyCode), UInt16(kUCKeyActionDown),
                                0, UInt32(LMGetKbdType()), 0, &deadKeyState,
                                4, &length, &chars)
    guard status == noErr, length > 0 else { return nil }
    let isPrintable = chars[0] > 0x1F && chars[0] != 0x7F
    guard isPrintable else { return nil }
    return String(utf16CodeUnits: chars, count: length).uppercased()
}

private func TISGetInputSourcePropertySafe() -> UnsafePointer<UCKeyboardLayout>? {
    let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    guard let cfData = ptr as? Data else { return nil }
    return cfData.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) }
}
