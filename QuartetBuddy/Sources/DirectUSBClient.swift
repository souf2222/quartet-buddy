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
    /// True while a direct session owns the device (the app's offline mode).
    var hasSession: Bool { device != nil }
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

    /// An input's preamp gain (bRequest 0x10, address = input + 2, the
    /// clamp(dB+48) byte). The device applies it to the input preamp.
    @discardableResult
    func setInputGain(input: UInt16, db: Double) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x34             // the per-INPUT gain (sibling of the output's 0x33)
        req.wValue = 0
        req.wIndex = input
        req.wLength = 1
        // the preamp range is 0…75 dB UP, so the byte = |dB| (NOT the mixer's
        // dB+48): live-verified 11/7 — in0 read 0x21 = 33 dB, in1 0x2b = 43 dB
        let clamped = Swift.max(0, Swift.min(75, Int(db.rounded())))
        let d = NSMutableData(bytes: [UInt8(clamped)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "input gain: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The app's input-mode enum (1=Mic 2=+4dBu 3=−10dBV 4=Instrument) →
    /// the device's 0x16 TYPE byte. COMPLETE, touchscreen-verified 11/7
    /// across three hardware switches: 0=+4dBu, 1=−10dBV, 2=Mic, 3=Instrument.
    static func deviceByte(forAppMode app: Int) -> UInt8? {
        switch app { case 1: return 2; case 2: return 0; case 3: return 1; case 4: return 3; default: return nil }
    }
    static func appMode(forDeviceByte b: UInt8) -> Int {
        switch b { case 0: return 2; case 1: return 3; case 2: return 1; case 3: return 4; default: return 1 }
    }

    /// The 7-byte status poll (bRequest 0x29, wIndex = 0) — the device's
    /// change broadcast; byte3 flips on activity (the captures show
    /// 0x40 ↔ 0x00). The change-gate reads ONLY this when idle.
    func readStatus() -> [UInt8]? {
        guard let dev = device else { return nil }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0
        req.bRequest = 0x29
        req.wLength = 7
        let d = NSMutableData(data: Data(repeating: 0, count: 7))
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.3)
            return (d as Data).map { $0 }
        } catch { return nil }
    }

    /// A raw 1-byte register write — the general form of every decoded
    /// register (bRequest, wIndex, one byte). Used by the pad enum, the
    /// routing register and any future single-byte setting.
    @discardableResult
    func setRawByte(_ reg: UInt8, index: UInt16, byte: UInt8) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = reg
        req.wValue = 0
        req.wIndex = index
        req.wLength = 1
        let d = NSMutableData(bytes: [byte], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "raw \(reg): \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The per-input BOOL flags — sweep-VERIFIED 11/7: softLimit = 0x11
    /// (default ON), polarityInvert Ø = 0x13, phantom = 0x15. wIndex = input.
    @discardableResult
    func setInputFlag(_ reg: UInt8, input: UInt16, on: Bool) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = reg
        req.wValue = 0
        req.wIndex = input
        req.wLength = 1
        let d = NSMutableData(bytes: [on ? UInt8(1) : UInt8(0)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "input flag \(reg): \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// +48V phantom power per input (bRequest 0x15, wIndex = the input) —
    /// VERIFIED 11/7: the user's touchscreen 48V toggle flipped in0's 0x15
    /// from 0x00 to 0x01 (the only register that moved).
    @discardableResult
    func setPhantom(input: UInt16, on: Bool) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x15
        req.wValue = 0
        req.wIndex = input
        req.wLength = 1
        let d = NSMutableData(bytes: [on ? UInt8(1) : UInt8(0)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "phantom: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// An input's TYPE — bRequest 0x16, wIndex = the input, 1 byte.
    /// COMPLETE enum, touchscreen-verified 11/7: 0=+4dBu, 1=−10dBV,
    /// 2=Mic, 3=Instrument. (0x36 is writable but NOT the type — parked.)
    @discardableResult
    func setInputType(input: UInt16, raw: UInt8) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x16
        req.wValue = 0
        req.wIndex = input
        req.wLength = 1
        let d = NSMutableData(bytes: [raw], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "input type: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The read-back for an input property (bmReq 0xC0, 1-byte response;
    /// wValue = 0, wIndex = the input — verified 11/7 with 0x34/0x36).
    func readInput(input: UInt16, bRequest: UInt8) -> UInt8? {
        guard let dev = device else { return nil }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0
        req.bRequest = bRequest
        req.wValue = 0
        req.wIndex = input
        req.wLength = 1
        let d = NSMutableData(data: Data(repeating: 0, count: 1))
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return (d as Data).first
        } catch {
            lastError = "input read: \(error.localizedDescription)"
            return nil
        }
    }

    /// The monitor-output flags — sweep-VERIFIED 11/7 (the daemon's own
    /// writes): dim = bRequest 0x40, sum = 0x46, wIndex = the output
    /// (0 = Main, 1 = HP), wValue = 0, 1 byte 0/1. (The old 0x4E/0x4F-at-
    /// register-0x0C guesses were wrong; 0x4E/0x4F are the mixer's
    /// solo/mute, 0x4C/0x4D the fader/pan.)
    @discardableResult
    func setOutputFlag(_ reg: UInt8, output: UInt16, on: Bool) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = reg
        req.wValue = 0
        req.wIndex = output
        req.wLength = 1
        let d = NSMutableData(bytes: [on ? UInt8(1) : UInt8(0)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "output flag: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The mixer channel fader — sweep-VERIFIED: 0x4C, wIndex = the channel
    /// (0…12, 14 = master), value = clamp(dB + 48, 0…54).
    @discardableResult
    func setMixerVolume(channel: UInt16, db: Double) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x4C
        req.wValue = 0
        req.wIndex = channel
        req.wLength = 1
        let clamped = Swift.max(0, Swift.min(54, Int(db.rounded()) + 48))
        let d = NSMutableData(bytes: [UInt8(clamped)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "mixer volume: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The mixer channel pan — sweep-VERIFIED: 0x4D, wIndex = the channel,
    /// value = round(pan × 128) (0.5 = center = 0x40).
    @discardableResult
    func setMixerPan(channel: UInt16, pan: Double) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x4D
        req.wValue = 0
        req.wIndex = channel
        req.wLength = 1
        let clamped = Swift.max(0, Swift.min(128, Int((pan * 128).rounded())))
        let d = NSMutableData(bytes: [UInt8(clamped)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "mixer pan: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The analog-output TRIM — sweep-VERIFIED: 0x18, wIndex = out−2
    /// (hwout2…7 → 0…5), value = |dB| × 10, attenuation-only (0…240).
    @discardableResult
    func setOutputTrim(output: UInt16, db: Double) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = 0x18
        req.wValue = 0
        req.wIndex = output
        req.wLength = 1
        let atten = Swift.max(0, Swift.min(240, Int((-db * 10).rounded())))
        let d = NSMutableData(bytes: [UInt8(atten)], length: 1)
        do {
            try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
            return true
        } catch {
            lastError = "output trim: \(error.localizedDescription)"
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
