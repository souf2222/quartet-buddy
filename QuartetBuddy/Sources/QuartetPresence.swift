import Foundation
import IOKit

/// Watches for the Quartet's USB presence (VID 0x0C60, PID 0x0014).
///
/// Two layers, because USB notification semantics are fiddly:
///  1. IOKit matching notifications (kIOFirstMatchNotification /
///     kIOTerminatedNotification — the canonical pair for USB device matching)
///  2. A cheap 2 s polling scan as a safety net
/// The state only flips when the authoritative scan agrees.
final class QuartetPresence {

    static let vendorID = 0x0C60
    static let productID = 0x14

    /// Called on the main thread whenever the presence changes.
    var onChange: ((Bool) -> Void)?

    private(set) var isConnected = false
    private var notifyPort: IONotificationPortRef?
    private var pollTimer: Timer?
    private var retainedIterators: [io_iterator_t] = []

    func start() {
        update()   // sets initial state + fires onChange once

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else {
            QBLog.log("presence: IONotificationPortCreate failed — polling only")
            startPolling()
            return
        }
        if let source = IONotificationPortGetRunLoopSource(notifyPort) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source.takeRetainedValue(),
                               CFRunLoopMode.commonModes)
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()

        var matchIter: io_iterator_t = 0
        let matchStatus = IOServiceAddMatchingNotification(
            notifyPort, kIOFirstMatchNotification, Self.matchingDict(),
            { ctx, iterator in
                QBLog.log("presence: match notification fired")
                let myself = Unmanaged<QuartetPresence>.fromOpaque(ctx!).takeUnretainedValue()
                myself.drain(iterator)
                myself.update()
            }, ctx, &matchIter)
        if matchStatus == KERN_SUCCESS {
            retainedIterators.append(matchIter)
            drain(matchIter)   // arm the notification
        } else {
            QBLog.log("presence: match notification error \(matchStatus)")
        }

        var goneIter: io_iterator_t = 0
        let goneStatus = IOServiceAddMatchingNotification(
            notifyPort, kIOTerminatedNotification, Self.matchingDict(),
            { ctx, iterator in
                QBLog.log("presence: terminate notification fired")
                let myself = Unmanaged<QuartetPresence>.fromOpaque(ctx!).takeUnretainedValue()
                myself.drain(iterator)
                myself.update()
            }, ctx, &goneIter)
        if goneStatus == KERN_SUCCESS {
            retainedIterators.append(goneIter)
            drain(goneIter)
        } else {
            QBLog.log("presence: terminate notification error \(goneStatus)")
        }

        startPolling()
    }

    /// One-shot scan: is a Quartet attached right now?
    static func scan() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict(),
                                           &iterator) == KERN_SUCCESS else {
            return false
        }
        var found = false
        if IOIteratorNext(iterator) != 0 {
            found = true
        }
        IOObjectRelease(iterator)
        return found
    }

    private static func matchingDict() -> CFMutableDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice")!
        (dict as NSMutableDictionary)["idVendor"] = NSNumber(value: vendorID)
        (dict as NSMutableDictionary)["idProduct"] = NSNumber(value: productID)
        return dict
    }

    private func drain(_ iterator: io_iterator_t) {
        while IOIteratorNext(iterator) != 0 {}
    }

    /// Re-scan and flip state if it changed.
    private func update(quiet: Bool = false) {
        let now = Self.scan()
        if now != isConnected {
            isConnected = now
            if !quiet {
                QBLog.log("presence: \(now ? "connected" : "disconnected")")
            }
            onChange?(now)
        }
    }

    /// Safety net: cheap authoritative scan every 2 s.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.update()
        }
    }
}
