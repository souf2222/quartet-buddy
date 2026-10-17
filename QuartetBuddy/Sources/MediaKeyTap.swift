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

    /// Called for each media key press (key, keyIsDown, optionHeld).
    /// Return true to SWALLOW the event, false to pass it through.
    var onKey: ((Key, Bool, Bool) -> Bool)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var lastError: String?

    func start() -> Bool {
        stop()
        guard InputMonitoring.check() == .granted else {
            lastError = "Input Monitoring not granted"
            QBLog.log("media keys: tap NOT created — Input Monitoring not granted")
            return false
        }
        let mask = CGEventMask(1 << Self.systemDefinedRaw)
        // Try an active (filtering) tap first — it lets us swallow the event.
        // Some macOS versions refuse active taps; fall back to listen-only.
        for (options, name) in [(CGEventTapOptions.defaultTap, "defaultTap"),
                                (.listenOnly, "listenOnly")] {
            guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                    guard type.rawValue == MediaKeyTap.systemDefinedRaw else {
                        return Unmanaged.passRetained(event)
                    }
                    guard let nsEvent = NSEvent(cgEvent: event) else {
                        QBLog.log("media keys: NSEvent conversion failed for systemDefined event")
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
                    guard let key = Key(rawValue: Int(keyCode)) else {
                        QBLog.log("media keys: systemDefined data1=\(data1) — not a volume key, passing through")
                        return Unmanaged.passRetained(event)
                    }
                    guard let myself = refcon.map({ Unmanaged<MediaKeyTap>.fromOpaque($0).takeUnretainedValue() }),
                          let handler = myself.onKey else {
                        return Unmanaged.passRetained(event)
                    }
                    QBLog.log("media keys: got key=\(key) isDown=\(keyIsDown) opt=\(event.flags.contains(.maskAlternate)) data1=\(data1)")
                    let optionHeld = event.flags.contains(.maskAlternate)
                    let swallow = handler(key, keyIsDown, optionHeld)
                    QBLog.log("media keys: key=\(key) handled=\(swallow) canSwallow=\(myself.canSwallow)")
                    return (swallow && myself.canSwallow) ? nil : Unmanaged.passRetained(event)
                },
                userInfo: Unmanaged.passRetained(self).toOpaque()) else {
                QBLog.log("media keys: CGEvent.tapCreate failed for \(name)")
                continue
            }
            tap = eventTap
            canSwallow = options == .defaultTap
            let src = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, CFRunLoopMode.commonModes)
            runLoopSource = src
            CGEvent.tapEnable(tap: eventTap, enable: true)
            lastError = nil
            QBLog.log("media keys: event tap created OK (\(name))")
            return true
        }
        lastError = "CGEvent.tapCreate failed for all modes"
        return false
    }

    var isActive: Bool { tap != nil }
    private(set) var canSwallow = false

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
