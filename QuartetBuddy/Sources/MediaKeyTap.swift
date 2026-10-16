import Foundation
import CoreGraphics
import AppKit

/// Intercepts system media keys (volume up/down/mute) via a CGEventTap on
/// NX_SYSDEFINED events (subtype kNX_SUBTYPE_AUX_CONTROL_BUTTONS).
/// Requires the "Input Monitoring" TCC grant for the app.
final class MediaKeyTap {

    /// NX_SYSDEFINED (no Swift enum case; raw value 14)
    private static let systemDefinedType = CGEventType(rawValue: 14)!
    private static let systemDefinedRaw: UInt32 = 14
    private static let auxControlSubtype: Int = 8


    enum Key: Int {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
    }

    /// Called for each media key press (key, keyIsDown). Return true to
    /// SWALLOW the event, false to pass it through.
    var onKey: ((Key, Bool) -> Bool)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << Self.systemDefinedRaw)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard type.rawValue == MediaKeyTap.systemDefinedRaw,
                      let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passRetained(event)
                }
                // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                guard nsEvent.subtype.rawValue == MediaKeyTap.auxControlSubtype else {
                    return Unmanaged.passRetained(event)
                }
                let data1 = nsEvent.data1
                let keyCode = (data1 & 0xFFFF0000) >> 16
                let keyFlags = data1 & 0xFFFF
                let keyIsDown = (keyFlags & 0x100) == 0
                guard let key = Key(rawValue: Int(keyCode)),
                      let myself = refcon.map({ Unmanaged<MediaKeyTap>.fromOpaque($0).takeUnretainedValue() }),
                      let handler = myself.onKey else {
                    return Unmanaged.passRetained(event)
                }
                let swallow = handler(key, keyIsDown)
                return swallow ? nil : Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passRetained(self).toOpaque()) else {
            return false
        }
        tap = eventTap
        let src = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, CFRunLoopMode.commonModes)
        runLoopSource = src
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
            self.runLoopSource = nil
        }
    }
}
