import Foundation
import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey registered via RegisterEventHotKey (no TCC needed).
/// Create one instance per hotkey; each distinguishes itself by signature+id.
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

        /// Single printable character for the key (for menu key equivalents).
        static func plainChar(_ code: UInt32) -> String? {
            guard let s = UCKeyTranslateForDisplay(code), s.count == 1 else { return nil }
            return s
        }
    }

    var onHotKey: (() -> Void)?

    private let signature: OSType
    private let hotKeyId: UInt32
    private var ref: EventHotKeyRef?
    private var combo: Combo?
    private static var handlerInstalled = false
    private static var eventHandler: EventHandlerRef?

    init(signature: OSType, id: UInt32) {
        self.signature = signature
        self.hotKeyId = id
        Self.installHandlerIfNeeded()
        HotKeyRegistry.register(self, signature: signature, id: id)
    }

    func register(_ combo: Combo) {
        unregister()
        var hotKeyID = EventHotKeyID(signature: signature, id: hotKeyId)
        var outRef: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &outRef)
        if status == noErr, let outRef {
            ref = outRef
            self.combo = combo
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

    /// Shared low-level handler; dispatches by signature+id via refcon.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let proc: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, UInt32(kEventParamDirectObject),
                              UInt32(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            NotificationCenter.default.post(
                name: Notification.Name("QBHotKey"),
                object: nil,
                userInfo: ["sig": hkID.signature, "id": hkID.id])
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), proc, 1, &eventType,
                           nil, &eventHandler)
        handlerInstalled = true
        NotificationCenter.default.addObserver(
            forName: Notification.Name("QBHotKey"), object: nil, queue: .main) { note in
            guard let sig = note.userInfo?["sig"] as? OSType,
                  let id = note.userInfo?["id"] as? UInt32 else { return }
            HotKeyRegistry.dispatch(sig: sig, id: id)
        }
    }
}

/// Maps (signature, id) → the owning HotKeyManager. Kept simple for a handful of hotkeys.
enum HotKeyRegistry {
    private static var map: [String: WeakBox] = [:]
    private struct WeakBox { weak var mgr: HotKeyManager? }

    static func register(_ mgr: HotKeyManager, signature: OSType, id: UInt32) {
        map["\(signature):\(id)"] = WeakBox(mgr: mgr)
    }

    static func dispatch(sig: OSType, id: UInt32) {
        map["\(sig):\(id)"]?.mgr?.onHotKey?()
    }
}

func UCKeyTranslateForDisplay(_ keyCode: UInt32) -> String? {
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
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return nil
    }
    // TISGetInputSourceProperty returns a CFDataRef as an opaque pointer —
    // it must be rewrapped, not bridged.
    let cfData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(cfData) else { return nil }
    return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
}
