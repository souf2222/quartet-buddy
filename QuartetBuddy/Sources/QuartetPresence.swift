import Foundation
import IOKit

/// Watches for the Quartet's USB presence (VID 0x0C60, PID 0x0014)
/// via IOKit publish/terminate notifications — no polling.
final class QuartetPresence {

    static let vendorID = 0x0C60
    static let productID = 0x14

    /// Called on the main thread whenever the presence changes.
    var onChange: ((Bool) -> Void)?

    private(set) var isConnected = false
    private var notifyPort: IONotificationPortRef?
    private var retainedIterators: [io_iterator_t] = []

    func start() {
        isConnected = Self.scan()
        onChange?(isConnected)

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }
        if let source = IONotificationPortGetRunLoopSource(notifyPort)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()

        var publishIter: io_iterator_t = 0
        let publishStatus = IOServiceAddMatchingNotification(
            notifyPort, kIOFirstPublishNotification, Self.matchingDict(),
            { ctx, iterator in
                let myself = Unmanaged<QuartetPresence>.fromOpaque(ctx!).takeUnretainedValue()
                myself.consume(iterator)
                myself.update()
            }, ctx, &publishIter)
        if publishStatus == KERN_SUCCESS {
            retainedIterators.append(publishIter)
            consume(publishIter)
        }

        var goneIter: io_iterator_t = 0
        let goneStatus = IOServiceAddMatchingNotification(
            notifyPort, kIOTerminatedNotification, Self.matchingDict(),
            { ctx, iterator in
                let myself = Unmanaged<QuartetPresence>.fromOpaque(ctx!).takeUnretainedValue()
                myself.consume(iterator)
                myself.update()
            }, ctx, &goneIter)
        if goneStatus == KERN_SUCCESS {
            retainedIterators.append(goneIter)
            consume(goneIter)
        }
        update()
    }

    /// One-shot scan: is a Quartet attached right now?
    static func scan() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict(),
                                           &iterator) == KERN_SUCCESS else {
            return false
        }
        var found = false
        while IOIteratorNext(iterator) != 0 {
            found = true
            break
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

    private func consume(_ iterator: io_iterator_t) {
        while IOIteratorNext(iterator) != 0 {}
    }

    private func update() {
        let now = Self.scan()
        if now != isConnected {
            isConnected = now
            onChange?(now)
        }
    }
}
