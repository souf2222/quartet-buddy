import Foundation
import IOUSBHost
import IOKit

/// Direct USB control of the Quartet — no ApogeeGlue daemon required (11.6).
///
/// Uses the public IOUSBHost framework (the modern app-level USB API):
/// vendor requests on the control endpoint, per the decoded command table
/// (docs/standalone-plan.md — verified by the live identify blink):
///
///   bRequest 0x33  hwout gain, 1 B = |dB|, wIndex = output channel 0-3
///   bRequest 0x35  mute, 1 B (1 = on, 0 = off), wIndex = channel
///   bRequest 0xB6  identify (front-panel blink), 1 B (1 = on, 0 = off)
///   bRequest 0x29  state poll (IN), 7-byte response
///
/// bmRequestType: 0x40 = OUT|vendor|device, 0xC0 = IN|vendor|device.
///
/// Notes from the reverse-engineering battle (see the plan doc):
/// * the device has no USB Serial Number registry property — the serial
///   comes from the vendor protocol itself,
/// * the NS_REFINED_FOR_SWIFT members surface as the `__`-prefixed variants,
/// * the request's data buffer needs length ≥ wLength,
/// * if ApogeeGlue is running it holds the device exclusively — the init
///   fails with "Another client likely has exclusive access".
final class DirectUSBClient {

    /// The last error, for the UI/logging.
    private(set) var lastError: String = ""

    /// The device session, created in open().
    private var device: IOUSBHostDevice?
    private let queue = DispatchQueue(label: "quartetbuddy.directusb")
    private(set) var opened = false

    // MARK: - open / close

    /// Find the Quartet and open a session. Returns false (and logs) when
    /// the device is absent, or the open is refused/already-held.
    @discardableResult
    func open() -> Bool {
        close()
        guard let dict = IOServiceMatching("IOUSBHostDevice") else { return false }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator)
        guard kr == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        var found: io_service_t = 0
        repeat {
            let s = IOIteratorNext(iterator)
            if s == 0 { break }
            var name = ""
            var prop: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(s, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = prop?.takeRetainedValue() as? [String: Any] {
                name = props["USB Product Name"] as? String ?? ""
            }
            if name == "Quartet" { found = s; break }
            IOObjectRelease(s)
        } while true
        guard found != 0 else {
            lastError = "Quartet not present"
            return false
        }
        defer { IOObjectRelease(found) }

        do {
            device = try IOUSBHostDevice(__ioService: found, options: [], queue: queue)
        } catch {
            lastError = "IOUSBHostDevice: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
        opened = true
        QBLog.log("directUSB: session open")
        return true
    }

    func close() {
        device?.destroy()
        device = nil
        opened = false
    }

    var isAvailable: Bool { opened }

    // MARK: - commands

    /// The front-panel identify blink. The daemon sends the on/off pair
    /// ~6 s apart; we mirror that so the blink terminates.
    @discardableResult
    func identify(on: Bool) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0xB6
        req.wLength = 1
        let d = NSMutableData(bytes: [on ? UInt8(1) : UInt8(0)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "identify: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// An output's gain in whole dB (negative = attenuation), 1 byte = |dB|.
    @discardableResult
    func setGain(channel: UInt16, minusDB: Int) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x33
        req.wIndex = channel
        req.wLength = 1
        let clamped = Swift.max(0, Swift.min(255, abs(minusDB)))
        let d = NSMutableData(bytes: [UInt8(clamped)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "gain: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// An output's mute.
    @discardableResult
    func setMute(channel: UInt16, on: Bool) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x35
        req.wIndex = channel
        req.wLength = 1
        let d = NSMutableData(bytes: [on ? UInt8(1) : UInt8(0)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "mute: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The device state poll — the 7-byte response block (nil on error).
    func poll() -> [UInt8]? {
        guard let dev = device else { return nil }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0
        req.bRequest = 0x29
        req.wLength = 7
        let d = NSMutableData(data: Data(repeating: 0, count: 7))
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return (d as Data).map { $0 }
        } catch {
            lastError = "poll: \(error.localizedDescription)"
            return nil
        }
    }
}
