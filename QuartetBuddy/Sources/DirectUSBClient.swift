import Foundation
import IOUSBHost
import IOKit.hid
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

    /// Nov 26 THE POWER-ON STALE HANDLE: a session opened while the Quartet
    /// is still BOOTING (it enumerates seconds before its firmware is up)
    /// dies the moment the device finishes — every later transfer fails with
    /// "Unable to send device request." while the device NEVER leaves the
    /// bus (no presence event → the close-on-arrival logic never runs; the
    /// Nov 26 log: opened +0 s, dead +14 s, 19 failed writes until relaunch).
    /// The client classifies that failure and fires this ONCE per session;
    /// the AppDelegate closes + reopens on it (the reopen's mirror re-read
    /// re-pins the macOS slider to the card's REAL level).
    var onSessionDead: (() -> Void)?
    /// True after a death-classified failure fired on THIS session (a fresh
    /// open() resets it). The AppDelegate's sync chain checks it so the
    /// mirror's retry steps never fight the recovery step for the schedule.
    private(set) var dead = false
    /// TRUTHFUL AVAILABILITY (Nov 26): a session that is merely OPEN says
    /// nothing — during the power-on boot window the handle opens fine and
    /// then every transfer fails. healthy flips true on the FIRST successful
    /// transfer and false on a death-classified failure. The menubar icon,
    /// the menu state line and the control window's connected state all gate
    /// on this, so the app only claims "connected" when the card answers.
    private(set) var healthy = false

    /// EVERY control transfer funnels through this serial queue. Concurrent
    /// __send calls on one IOUSBHostDevice race the device object
    /// (EXC_BAD_ACCESS — the Nov 7 sweep crash): the window's sweep reads
    /// arrive on a global queue while the main thread reads and writes.
    /// Sync dispatch — every caller needs the result — so a call only waits
    /// when a transfer is already in flight (~10 ms each).
    private func sendSync(_ dev: IOUSBHostDevice, _ req: IOUSBDeviceRequest,
                          data: NSMutableData, timeout: Double) throws {
        do {
            try queue.sync {
                try dev.__send(req, data: data, bytesTransferred: nil, completionTimeout: timeout)
            }
            healthy = true   // the card actually answered — it is usable
        } catch {
            noteDead(error as NSError)   // a dead handle announces itself here
            throw error
        }
    }

    /// True when an error means THIS handle is dead (the device finished
    /// booting under us / another client took the interfaces over) — as
    /// opposed to a mere busy/timeout. The dead handle's text is stable:
    /// "Unable to send device request." (Nov 26 log). A few detach-worded
    /// variants ride along for the other stale-handle flavors.
    private func classifiesDeadSession(_ error: NSError) -> Bool {
        let s = error.localizedDescription.lowercased()
        return s.contains("unable to send device request")
            || s.contains("device detached")
            || s.contains("not attached")
            || s.contains("no connection")
            || s.contains("exclusive access")
    }

    /// Fire onSessionDead once per session (reads swallow their errors and
    /// return nil, writes log theirs — BOTH call this so the recovery sees
    /// the death through whichever path touched the handle first).
    private func noteDead(_ error: NSError) {
        healthy = false
        guard classifiesDeadSession(error), !dead else { return }
        dead = true
        QBLog.log("directUSB: session DEAD (\(error.localizedDescription)) — recovery requested")
        DispatchQueue.main.async { [weak self] in self?.onSessionDead?() }
    }

    // MARK: - open / close

    /// Find the Quartet and open a session. Returns false (and logs) when
    /// the device is absent, or the open is refused/already-held.
    @discardableResult
    func open() -> Bool {
        close()
        dead = false        // a fresh session re-arms the death detector
        healthy = false     // …and is UNPROVEN until its first transfer lands
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

    /// Nov 26 THE WEDGE SELF-HEAL. The card's control plane can go
    /// permanently unresponsive — "Unable to send device request." for
    /// EVERY client (the 11:34 independent probe proved it with the app
    /// fully quit; only a manual power cycle used to clear it). This asks
    /// the system to reset + re-enumerate the USB device from software:
    /// "Terminate the device and attempt to reenumerate it" — the current
    /// object dies, a NEW IOUSBHostDevice appears, the presence monitor
    /// sees the terminate/match pair and the app's sync chain reopens
    /// fresh. Audio drops for the re-enum's few seconds, so the callers
    /// fire it only in the boot-phase wedge (or explicitly from the menu).
    @discardableResult
    func resetDevice() -> Bool {
        guard let dev = device else {
            QBLog.log("directUSB: device RESET skipped — no session")
            return false
        }
        QBLog.log("directUSB: device RESET requested — the card will re-enumerate (audio drops briefly)")
        do { try dev.reset(); return true }
        catch {
            QBLog.log("directUSB: device RESET failed: \(error.localizedDescription)")
            return false
        }
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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

    // MARK: HID event watcher — the encoder + touchscreen are a HID device
    // inside the Quartet; macOS PUSHES their input reports the instant
    // something moves. We don't decode them: any report = "something
    // changed" → the poll sweep fires immediately. Zero-CPU, zero-latency.

    private var hidManager: IOHIDManager?

    /// Subscribe to the Quartet's HID reports (the shared HID access —
    /// no conflict with the vendor session or CoreAudio).
    func startHIDWatcher(onChange: @escaping () -> Void) {
        guard hidManager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // the string-literal keys (the HID's CFString keys — the Swift
        // overlay doesn't export the kIOHID* constants on this SDK)
        let match: [String: Any] = ["VendorID": 0x0C60,
                                    "ProductID": 0x14]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        // the closure boxed as an NSMutableArray holding one item (the
        // Swift closures aren't AnyObject; the box sidesteps the cast)
        let box = NSMutableArray(object: onChange)
        let ctx = Unmanaged.passRetained(box)
        IOHIDManagerRegisterInputReportCallback(
            mgr,
            { ctx, _, _, reportType, reportID, report, reportLen in
                guard let ctx else { return }
                // (ctx, result, sender, type, reportID, report*, reportLength)
                let box = Unmanaged<NSMutableArray>.fromOpaque(ctx).takeUnretainedValue()
                // 11.7 decode session: the report's bytes → the log (the
                // encoder/touch event format); the callback fires too
                // the report = UnsafeMutablePointer<UInt8>, the len = CFIndex
                let bytes = (0..<min(Int(reportLen), 12)).map {
                    String(format: "%02x", report[$0])
                }.joined(separator: " ")
                QBLog.log("hid: type=\(reportType.rawValue) id=\(reportID) len=\(reportLen) [\(bytes)]")
                if let cb = box.firstObject as? () -> Void { cb() }
            },
            ctx.toOpaque())
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if r == kIOReturnSuccess {
            hidManager = mgr
            QBLog.log("directUSB: HID watcher live (the device pushes its events)")
        } else {
            ctx.release()
            QBLog.log("directUSB: HID watcher failed \(r)")
        }
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
            try sendSync(dev, req, data: d, timeout: 0.3)
            return (d as Data).map { $0 }
        } catch {
            noteDead(error as NSError)
            return nil
        }
    }

    /// The 60-byte CHANGE-BITMAP (bRequest 0x14) — the device's event
    /// summary: all-zero when nothing changed; the set bits = the changed
    /// registers (read-to-clear). The decode session logs the bitmap.
    func readChangeBitmap() -> [UInt8]? {
        guard let dev = device else { return nil }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0
        req.bRequest = 0x14
        req.wLength = 60
        let d = NSMutableData(data: Data(repeating: 0, count: 60))
        do {
            try sendSync(dev, req, data: d, timeout: 0.3)
            return (d as Data).map { $0 }
        } catch {
            noteDead(error as NSError)
            return nil
        }
    }

    /// A raw 1-byte register write with a non-zero wValue — the monitor
    /// MATRIX's addressing (wValue = input, wIndex = output) needs it.
    @discardableResult
    func setRawByteValue(_ reg: UInt8, wValue: UInt16, index: UInt16, byte: UInt8) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = reg
        req.wValue = wValue
        req.wIndex = index
        req.wLength = 1
        let d = NSMutableData(bytes: [byte], length: 1)
        do {
            try sendSync(dev, req, data: d, timeout: 0.5)
            return true
        } catch {
            lastError = "raw \(reg): \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
            return (d as Data).first
        } catch {
            noteDead(error as NSError)
            lastError = "input read: \(error.localizedDescription)"
            return nil
        }
    }

    /// The read-back for a matrix cell (bmReq 0xC0, 1-byte response;
    /// wValue = the input, wIndex = the output).
    func readCell(wValue input: UInt16, index: UInt16, bRequest: UInt8) -> UInt8? {
        guard let dev = device else { return nil }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0
        req.bRequest = bRequest
        req.wValue = input
        req.wIndex = index
        req.wLength = 1
        let d = NSMutableData(data: Data(repeating: 0, count: 1))
        do {
            try sendSync(dev, req, data: d, timeout: 0.5)
            return (d as Data).first
        } catch {
            noteDead(error as NSError)
            lastError = "cell read: \(error.localizedDescription)"
            return nil
        }
    }

    /// The read-back for a multi-byte block (bmReq 0xC0; wIndex = the
    /// block selector) — the 0x10 mixer snapshot blocks (28 bytes).
    func readBlock(index: UInt16, bRequest: UInt8, length: Int) -> [UInt8]? {
        guard let dev = device else { return nil }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0
        req.bRequest = bRequest
        req.wValue = 0
        req.wIndex = index
        req.wLength = UInt16(length)
        let d = NSMutableData(data: Data(repeating: 0, count: length))
        do {
            try sendSync(dev, req, data: d, timeout: 0.5)
            return (d as Data).map { $0 }
        } catch {
            noteDead(error as NSError)
            lastError = "block read: \(error.localizedDescription)"
            return nil
        }
    }

    /// The write for a multi-byte block (bmReq 0x40; wIndex = the block
    /// selector) — the 0x10 mixer snapshot blocks (28 bytes).
    @discardableResult
    func writeBlock(index: UInt16, bRequest: UInt8, bytes: [UInt8]) -> Bool {
        guard let dev = device else { return false }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x40
        req.bRequest = bRequest
        req.wValue = 0
        req.wIndex = index
        req.wLength = UInt16(bytes.count)
        let d = NSMutableData(bytes: bytes, length: bytes.count)
        do {
            try sendSync(dev, req, data: d, timeout: 0.5)
            return true
        } catch {
            lastError = "block write: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
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
            try sendSync(dev, req, data: d, timeout: 0.5)
            return true
        } catch {
            lastError = "output flag: \(error.localizedDescription)"
            QBLog.log("directUSB: \(lastError)")
            return false
        }
    }

    /// The mixer channel fader — sweep-VERIFIED: 0x4C, wIndex = the channel
    /// (0…12, 14 = master), value = clamp(dB + 48, 0…54).
    /// The MIXER PLANE = wValue (0 = Mixer 1, 1 = Mixer 2 — ear/back-verified
    /// with the distinguishing-write probe: the planes read back separately).
    @discardableResult
    func setMixerVolume(mixer: UInt16, channel: UInt16, db: Double) -> Bool {
        let clamped = Swift.max(0, Swift.min(54, Int(db.rounded()) + 48))
        return setRawByteValue(0x4C, wValue: mixer, index: channel, byte: UInt8(clamped))
    }

    @discardableResult
    func setMixerVolume(channel: UInt16, db: Double) -> Bool {
        setMixerVolume(mixer: 0, channel: channel, db: db)
    }

    func readMixerCell(mixer: UInt16, channel: UInt16, bRequest: UInt8) -> UInt8? {
        readCell(wValue: mixer, index: channel, bRequest: bRequest)
    }

    /// The mixer channel MUTE — sweep-VERIFIED: 0x4F, wIndex = the channel
    /// (0…12, 14 = the master), 1 byte 0/1. The plane = wValue (see the
    /// fader).
    @discardableResult
    func setMixerMute(mixer: UInt16, channel: UInt16, mute: Bool) -> Bool {
        setRawByteValue(0x4F, wValue: mixer, index: channel, byte: mute ? 1 : 0)
    }

    @discardableResult
    func setMixerMute(channel: UInt16, mute: Bool) -> Bool {
        setMixerMute(mixer: 0, channel: channel, mute: mute)
    }

    /// The mixer channel pan — sweep-VERIFIED: 0x4D, wIndex = the channel,
    /// value = round(pan × 128) (0.5 = center = 0x40). The plane = wValue.
    @discardableResult
    func setMixerPan(mixer: UInt16, channel: UInt16, pan: Double) -> Bool {
        let clamped = Swift.max(0, Swift.min(128, Int((pan * 128).rounded())))
        return setRawByteValue(0x4D, wValue: mixer, index: channel, byte: UInt8(clamped))
    }

    @discardableResult
    func setMixerPan(channel: UInt16, pan: Double) -> Bool {
        setMixerPan(mixer: 0, channel: channel, pan: pan)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
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
            try sendSync(dev, req, data: d, timeout: 0.5)
            return (d as Data).map { $0 }
        } catch {
            noteDead(error as NSError)
            lastError = "poll: \(error.localizedDescription)"
            return nil
        }
    }
}
