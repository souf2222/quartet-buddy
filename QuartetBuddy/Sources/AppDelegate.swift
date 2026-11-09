import AppKit
import CoreMIDI
import Carbon.HIToolbox
import ServiceManagement

// Path-ids captured from live traffic (see docs/protocol-notes.md).
// They are a deterministic hash of the property path INCLUDING the device
// serial — Apogee's own apps use the same values — so each physical
// Quartet has its OWN id table (verified live: two units side by side
// needed different ids for every device-scoped property). App-scoped
// properties (talkback, under Apps/Apogee Talkback helper) are identical
// on every unit.
//
// The app picks the table by the serial found in the glue tree (see
// AppDelegate.setupGlue). For a NEW Quartet, run the built-in wizard
// (menubar → "Setup New Quartet…"): it captures the ids live and stores
// them in preferences — no code change needed.
enum PathIds {
    struct DeviceTable: Codable {
        var hwout0Gain: [UInt8]   // Main Out fader (double)
        var hwout1Gain: [UInt8]   // Headphones fader (double)
        var hwout0Mute: [UInt8]   // Main Out mute (bool)
        var hwout1Mute: [UInt8]   // Headphones mute (bool)
        var hwout0Dim: [UInt8]    // Main Out dim (bool)

        // Console-window additions (Quartet Console). All optional/defaulted:
        // tables captured before these existed decode with empty values, and
        // every control still works if its id was never captured — the
        // console window shows a Learn button for it instead.

        // Per analog input (key = input index 0…3):
        var hwinRefLevel: [Int: [UInt8]] = [:]   // analogRefLevel (int32)
        var hwinMicGain: [Int: [UInt8]] = [:]    // micSettings.PreModelQuartet.gain (double)
        var hwinInstGain: [Int: [UInt8]] = [:]   // instSettings.PreModelQuartet.gain (double)
        var hwinPhantom: [Int: [UInt8]] = [:]    // micSettings.phantom +48V (bool)
        var hwinSoftLimit: [Int: [UInt8]] = [:]  // softLimit (bool)
        var hwinPolarity: [Int: [UInt8]] = [:]   // polarityInvert (bool)

        // Output extras:
        var hwout0Sum: [UInt8]? = nil            // Main Out sum/mono (bool)
        var hwout1Sum: [UInt8]? = nil            // Headphones sum/mono (bool)
        var hwout1Dim: [UInt8]? = nil            // Headphones dim (bool)

        /// Debug-friendly form: `1f1d4c1d`-style hex.
        func hex(_ id: [UInt8]) -> String { id.map { String(format: "%02x", $0) }.joined() }
        var summary: String {
            "gain0=\(hex(hwout0Gain)) gain1=\(hex(hwout1Gain)) mute0=\(hex(hwout0Mute)) " +
            "mute1=\(hex(hwout1Mute)) dim0=\(hex(hwout0Dim))"
        }

        /// Every id already assigned in this table — used by the console
        /// Learn mode and the wizard to never re-capture a known control.
        var knownIds: [[UInt8]] {
            var ids: [[UInt8]] = [hwout0Gain, hwout1Gain, hwout0Mute, hwout1Mute, hwout0Dim,
                                  hwout0Sum, hwout1Sum, hwout1Dim].compactMap { $0 }
            ids += Array(hwinRefLevel.values) + Array(hwinMicGain.values) + Array(hwinInstGain.values)
            ids += Array(hwinPhantom.values) + Array(hwinSoftLimit.values) + Array(hwinPolarity.values)
            return ids
        }
    }

    /// App-scoped — identical on every device (hashes to the same value by
    /// the formula below; kept as a compile-time constant for the log/tests).
    static let talkbackOn: [UInt8] = [0x8f, 0x0a, 0x6a, 0x00]

    /// The original captured unit's output ids — only used before the first
    /// tree arrives (serial unknown). Once the tree lands, every id is
    /// computed (see `computedTable`).
    static let defaultTable = DeviceTable(
        hwout0Gain: [0xc5, 0xa2, 0xbd, 0xb5],
        hwout1Gain: [0x64, 0x7b, 0x72, 0xb7],
        hwout0Mute: [0x5f, 0xa9, 0xc0, 0xb5],
        hwout1Mute: [0xfe, 0x81, 0x75, 0xb7],
        hwout0Dim:  [0x82, 0x2c, 0x69, 0x37])

    // MARK: - The descriptor hash (CRACKED — see tools/crack_id_hash.py)
    //
    // The path-id of a property is a Java string hash (h = h·31 + UTF-8
    // byte, 32-bit wrapping) of its slash path from the tree root, sent as
    // the 32-bit result little-endian:
    //
    //   device-scoped:  /dev/<serial>/<node>/<node>/…/<property>
    //   app-scoped:     /Apps/Apogee Talkback helper/Talkback/<property>
    //
    // Verified against 22 live-captured pairs across two physical units
    // (outputs, both gain modes, phantom, soft limit, polarity, ref level),
    // plus a live write test against a never-captured id (hwin2.softLimit).
    // Consequence: every id for ANY Quartet is computable from the serial —
    // no capture wizard, no Learn mode, nothing.
    static func hash(_ path: String) -> [UInt8] {
        var h: Int32 = 0
        for b in path.utf8 { h = h &* 31 &+ Int32(b) }
        let v = UInt32(bitPattern: h)
        return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// Path-id of ANY property under the connected Quartet's device node,
    /// computed on the fly — the sample-rate precedent (protocol-notes.md,
    /// "Device sample rate — WRITABLE via Glue"): every path-id is the
    /// java31 hash of the slash path, so nothing beyond the serial is
    /// needed. nil when no device is tree-connected (nothing to hash
    /// against — callers must handle the nil and log).
    static func dev(_ rel: String) -> [UInt8]? {
        guard let serial = activeSerial else { return nil }
        return hash("/dev/\(serial)/" + rel)
    }

    /// Path-id of an app-scoped property — `/Apps/<rel>` (Talkback lives
    /// under `/Apps/Apogee Talkback helper/Talkback/…`; identical on
    /// every unit because it carries no serial).
    static func app(_ rel: String) -> [UInt8] {
        hash("/Apps/" + rel)
    }

    /// The complete id table for a serial — every control the console and
    /// menubar features touch, computed, nothing captured.
    static func computedTable(serial: String) -> DeviceTable {
        func id(_ rel: String) -> [UInt8] { Self.hash("/dev/\(serial)/" + rel) }
        var t = DeviceTable(
            hwout0Gain: id("hwout/hwout0/gain"),
            hwout1Gain: id("hwout/hwout1/gain"),
            hwout0Mute: id("hwout/hwout0/mute"),
            hwout1Mute: id("hwout/hwout1/mute"),
            hwout0Dim:  id("hwout/hwout0/dim"))
        t.hwout0Sum = id("hwout/hwout0/sum")
        t.hwout1Sum = id("hwout/hwout1/sum")
        t.hwout1Dim = id("hwout/hwout1/dim")
        for i in 0..<4 {
            let h = "hwin\(i)"
            t.hwinRefLevel[i] = id("hwin/\(h)/analogRefLevel")
            t.hwinMicGain[i]  = id("hwin/\(h)/micSettings/PreModelQuartet/gain")
            t.hwinInstGain[i] = id("hwin/\(h)/instSettings/PreModelQuartet/gain")
            t.hwinPhantom[i]  = id("hwin/\(h)/micSettings/phantom")
            t.hwinSoftLimit[i] = id("hwin/\(h)/softLimit")
            t.hwinPolarity[i] = id("hwin/\(h)/polarityInvert")
        }
        return t
    }

    /// True when the connected serial has a usable id table — always, now
    /// that every table is computed from the hash formula (kept for the
    /// menu wiring; the serial itself is the only requirement).
    static var isKnownSerial: Bool { activeSerial != nil }

    /// The table for the connected Quartet.
    private(set) static var active = defaultTable

    /// The connected device's serial (from the tree), for the log.
    private(set) static var activeSerial: String?

    /// Pick the id table for the connected Quartet's serial — computed from
    /// the hash formula; works for ANY Quartet, known or brand new.
    static func select(serial: String?) {
        guard serial != activeSerial else { return }
        activeSerial = serial
        if let serial {
            active = computedTable(serial: serial)
            QBLog.log("path-ids: computed table for \(serial): \(active.summary)")
        } else {
            active = defaultTable
        }
    }

    /// Wizard-capture endpoint. The hash formula computes every id now, so
    /// captured tables are no longer stored or consulted — keep the entry
    /// point (PathIdSetup still calls it) but make it a no-op re-select.
    static func adopt(table: DeviceTable, for serial: String) {
        activeSerial = nil   // force a fresh computed pick below
        select(serial: serial)
        QBLog.log("path-ids: wizard table for \(serial) ignored — computed table is authoritative")
    }

    /// Assign a newly captured id to a console-window control and persist it
    /// (Quartet Console Learn mode). Key format: "hwinMicGain.2" for input
    /// controls (input index suffix) or "hwout0Sum" / "hwout0Gain" for output
    /// properties. Unknown keys are ignored.
    static func learn(id: [UInt8], key: String) {
        var t = active
        let parts = key.split(separator: ".").map(String.init)
        let idx = parts.count > 1 ? Int(parts[1]) ?? -1 : -1
        switch parts[0] {
        case "hwinRefLevel" where idx >= 0: t.hwinRefLevel[idx] = id
        case "hwinMicGain" where idx >= 0: t.hwinMicGain[idx] = id
        case "hwinInstGain" where idx >= 0: t.hwinInstGain[idx] = id
        case "hwinPhantom" where idx >= 0: t.hwinPhantom[idx] = id
        case "hwinSoftLimit" where idx >= 0: t.hwinSoftLimit[idx] = id
        case "hwinPolarity" where idx >= 0: t.hwinPolarity[idx] = id
        case "hwout0Sum": t.hwout0Sum = id
        case "hwout1Sum": t.hwout1Sum = id
        case "hwout1Dim": t.hwout1Dim = id
        case "hwout0Gain": t.hwout0Gain = id
        case "hwout1Gain": t.hwout1Gain = id
        case "hwout0Mute": t.hwout0Mute = id
        case "hwout1Mute": t.hwout1Mute = id
        case "hwout0Dim": t.hwout0Dim = id
        default: return
        }
        if let serial = activeSerial {
            adopt(table: t, for: serial)
        } else {
            active = t
        }
        QBLog.log("path-ids: learned \(key) = \(t.hex(id))")
    }
}

enum OutputTarget: String, CaseIterable, Codable {
    case mainOut = "Main Out"
    case headphones = "Headphones"

    var gainId: [UInt8] { self == .mainOut ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain }
    var muteId: [UInt8] { self == .mainOut ? PathIds.active.hwout0Mute : PathIds.active.hwout1Mute }

    /// The vendor-request channel (the wIndex in bRequest 0x33/0x35):
    /// hwout0 = Main Out → ch0, hwout1 = HP → ch1 (verified by read-backs).
    var usbChannel: UInt16 { self == .mainOut ? 0 : 1 }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    let glue = GlueClient()
    /// Direct-USB control (11.6): the vendor-request session on the Quartet
    /// itself — works with ApogeeGlue gone (the exclusive open = ours then).
    let directUSB = DirectUSBClient()
    /// Every keyboard shortcut: bindings, global registration, app-only
    /// matching, conflicts, defaults (see Shortcuts.swift).
    let shortcuts = ShortcutManager()
    let midi = MidiWatcher()
    let deviceMonitor = DefaultDeviceMonitor()
    let quartetPresence = QuartetPresence()
    let osSlider = OSVolumeMirror()

    var statusItem: NSStatusItem!
    var menu = NSMenu()

    /// Which output the macOS volume/mute binding controls. Defaults to
    /// Main Out on every app launch and Quartet (re)connect — never
    /// persisted across sessions.
    var selectedOutput: OutputTarget {
        didSet {
            syncMacSlider(force: true)    // slider follows whichever output is bound
            if gainKnown {
                // macOS mute display follows the newly selected output too
                // (writes the OS mute once — see OSVolumeMirror.syncMuteAfterSwitch)
                osSlider.syncMuteAfterSwitch(to: muted[selectedOutput] ?? false)
            } else {
                osSlider.noteTargetSwitch()   // pre-tree: stale OS mute must not leak
            }
            refreshMenu()
        }
    }
    var gain: [OutputTarget: Double] = [.mainOut: 0, .headphones: 0]
    var muted: [OutputTarget: Bool] = [.mainOut: false, .headphones: false]

    static let minDB: Double = -64
    static let maxDB: Double = 0

    /// A plausible hardware fader level (finite, inside minDB…maxDB plus a
    /// little driver-rounding slack). Anything else — the -255 sentinel a
    /// wedged driver returns, NaN, etc. — must never reach the Quartet:
    /// out-of-range gain writes crashed the whole unit (Oct 19 2026).
    static func isValidDB(_ db: Double) -> Bool {
        db.isFinite && db >= minDB - 1 && db <= maxDB + 1
    }

    var talkbackOn = false
    var talkbackMomentary = false

    /// The mixer register's channel space: 0–11 = the hardware inputs,
    /// 12/13 = the stereo playback pair (VERIFIED 11/8: the mixer planes
    /// = wValue 0/1, the FADER gates a channel).
    static let mixerChannels: [UInt16] = (0...13).map { UInt16($0) }
    /// Hardware dim on the speakers (Out 1‑2), synced from the glue tree.
    var speakerDim = false
    /// Hardware sum/mono on the speakers + dim/sum on the headphones —
    /// shortcut toggles need the current state; synced like speakerDim.
    var speakerSum = false
    var headphoneDim = false
    var headphoneSum = false
    /// Local key monitor for app-only shortcuts (Quartet Control focused).
    private var localMonitor: Any?
    /// True once a tree has given us real hardware gain values (never
    /// enforce the macOS slider from the pre-tree defaults).
    private var gainKnown = false
    private var lastSliderDB: Double?

    /// Copy the selected output's real level onto the macOS volume slider —
    /// the Quartet → macOS half of the binding (see OSVolumeMirror).
    /// RANGE-VALIDATED (see isValidDB): a wedged driver's tree/echo values
    /// must not be pushed onto the slider and re-read back into the fader.
    private func syncMacSlider(force: Bool = false) {
        guard gainKnown else { return }
        let db = gain[selectedOutput] ?? 0
        guard force || lastSliderDB != db else { return }
        guard Self.isValidDB(db) else {
            QBLog.log(String(format: "slider sync: IGNORED bogus hardware level %.1f dB", db))
            return
        }
        lastSliderDB = db
        osSlider.enforce(db)
    }

    /// The macOS slider moved (volume key press, dragged in Sound settings):
    /// apply its level to the Quartet's real fader — the macOS → Quartet
    /// half of the binding. Our own enforce writes land here too and are
    /// filtered out by the value check.
    ///
    // MARK: - transport selection (11.6): the glue tree when connected, the
    // direct-USB vendor requests when the daemon is gone

    /// Try to make sure a direct-USB session exists (opens lazily). The
    /// open fails while ApogeeGlue holds the device exclusively.
    private func ensureDirectUSB() -> Bool {
        if directUSB.opened { return true }
        let ok = directUSB.open()
        if ok {
            QBLog.log("transport: direct-USB session opened")
            armMirrorFromDevice()
        }
        return ok
    }

    /// 11.7 THE OFFLINE-BOOT KEY FIX: the mirror's property listener is
    /// armed only inside enforce(), which was only reached via syncMacSlider
    /// gated on gainKnown — and gainKnown came from the daemon's tree, gone
    /// offline. Result: the macOS volume/mute listeners were NEVER armed and
    /// the volume keys did nothing. Now the session open reads the device's
    /// own faders (0x33) into the app's state, sets gainKnown, and enforces
    /// — which arms the listener. The keys work from the first second.
    private func armMirrorFromDevice() {
        for (target, ch) in [(OutputTarget.mainOut, 0), (.headphones, 1)] {
            if let v = directUSB.readInput(input: UInt16(ch), bRequest: 0x33) {
                gain[target] = -Double(v)
            }
        }
        gainKnown = true
        syncMacSlider(force: true)
    }

    /// The gain write with the transport selection. Returns the dB applied
    /// (for the caller's state bookkeeping) or nil when both transports
    /// are unavailable.
    @discardableResult
    private func writeGain(_ target: OutputTarget, _ db: Double) -> Bool {
        if case .connected = glue.state {
            glue.setDouble(id: target.gainId, db)
            return true
        }
        guard ensureDirectUSB() else {
            QBLog.log("transport: gain write unavailable (no glue, no direct session)")
            return false
        }
        // the vendor protocol takes whole |dB|; keep the sign implicit
        // (the Quartet's fader gains are ≤ 0)
        let whole = Int(db.rounded())
        let ok = directUSB.setGain(channel: target.usbChannel, minusDB: whole)
        if ok { QBLog.log(String(format: "transport: directUSB gain %@ %.0f dB", target.rawValue, db)) }
        return ok
    }

    /// The mute write with the transport selection.
    @discardableResult
    private func writeMute(_ target: OutputTarget, _ m: Bool) -> Bool {
        if case .connected = glue.state {
            glue.setBool(id: target.muteId, m)
            return true
        }
        guard ensureDirectUSB() else { return false }
        let ok = directUSB.setMute(channel: target.usbChannel, on: m)
        if ok { QBLog.log("transport: directUSB mute \(target.rawValue) \(m ? "on" : "off")") }
        return ok
    }

    /// RANGE-VALIDATED: a wedged Apogee driver makes CoreAudio reads return
    /// garbage (a -255 dB sentinel was observed live, Oct 19 2026), which
    /// this path would otherwise echo into the hardware fader in a feedback
    /// loop — an out-of-range write that took the whole unit down (dark
    /// touchscreen). Never forward anything outside the fader's -64…0 dB.
    private func osSliderMoved(to db: Double) {
        guard !PathIdSetupController.shared.sessionActive,
              !QuartetControlController.shared.isLearning else { return }   // a capture is listening
        guard gainKnown || directUSB.opened || ensureDirectUSB() else { return }
        guard Self.isValidDB(db) else {
            QBLog.log(String(format: "slider sync: IGNORED bogus slider level %.1f dB (driver wedge?)", db))
            return
        }
        let target = selectedOutput
        let current = gain[target] ?? 0
        if abs(db - current) <= 0.5 {
            QBLog.log(String(format: "mirror: osSliderMoved %.1f dB == target's current (%@) — own echo, skipped", db, target.rawValue))
        } else {
            QBLog.log(String(format: "mirror: osSliderMoved %.1f dB → target %@ (was %.1f)", db, target.rawValue, current))
        }
        guard abs(db - current) > 0.5 else { return }        // own writes / driver rounding
        QBLog.log(String(format: "slider sync: slider %.1f dB -> Quartet %@ (was %.1f)",
                         db, target.rawValue, current))
        guard writeGain(target, db) else { return }
        gain[target] = db
        lastSliderDB = db
        refreshMenu()
    }

    /// Hardware trims last pushed to the unit (pair → dB) — dedup for
    /// `syncSavedHardwareTrims`: each tree arrival tries once per
    /// connection (the record is cleared on disconnect). The Quartet may
    /// come back from a power cycle at 0, so the app's saved hardware-trim
    /// settings must re-apply, but tree arrivals triggered by other
    /// clients' hellos must not spam identical writes.
    private var pushedHardwareTrims: [Int: Double] = [:]

    /// The DAC strips' firmware trim, pairs 0…2 — mono strips, so a pair
    /// is TWO hwout nodes. The strip numbering starts AT Main Out:
    /// hwoutN feeds jack N−1 (hwout2 = the strip behind the Main jacks
    /// 1-2, hwout4 = jacks 3-4 …), while hwout0/1 are the separate
    /// monitor strips (Main / HP level faders) that the OS fader
    /// binding owns — the tree shows they carry gain/dim/mute, NO trim.
    ///
    ///     pair 0 → hwout2 + hwout3 · pair 1 → hwout4 + hwout5 ·
    ///     pair 2 → hwout6 + hwout7
    ///
    /// (MAPPING, re-corrected Nov 9 2026 against live listening tests —
    /// the Nov 8 table trimmed everything ONE PAIR DOWN: with it the
    /// Out 3-4 slider attenuated Main Out 1-2, Out 5-6 hit jacks 3-4
    /// and Headphones hit jacks 5-6. docs/captures/entire_tree.xml
    /// confirms the unit exposes NO strips beyond hwout7: "Analog Out
    /// 1..6" = the jack pairs 1-2 / 3-4 / 5-6, and the headphone jack's
    /// level rides the hwout1 "HP" monitor strip — the Headphones row
    /// has no trim register and shows its dash.)
    private static let hwoutTrimNodes: [Int: [String]] = [
        0: ["hwout2", "hwout3"],
        1: ["hwout4", "hwout5"],
        2: ["hwout6", "hwout7"],
    ]

    /// Firmware trim hard range: −24…0 dB (attenuation only). Clamped on
    /// EVERY path — settings write, reconnect push, DB readback — so no
    /// write and no saved value can leave the window.
    static let hwoutTrimMin = -24.0
    static let hwoutTrimMax = 0.0

    /// The saved settings-side hardware trims (`hwout.trim.<pair>`, set in
    /// Settings ▸ Quartet ▸ Outputs) → the unit. Called on every
    /// tree arrival; each value writes exactly once per value. A pair with
    /// NO saved key is skipped — the first run after an upgrade must not
    /// stomp trims the unit already carries. Out-of-range saved values are
    /// clamped (the in-range value is rewritten back to the key) so the
    /// push can never leave the window.
    private func syncSavedHardwareTrims() {
        guard case .connected = glue.state, PathIds.activeSerial != nil else { return }
        var pushedAny = false
        for pair in Self.hwoutTrimNodes.keys {
            guard UserDefaults.standard.object(forKey: "hwout.trim.\(pair)") != nil else { continue }
            let raw = UserDefaults.standard.double(forKey: "hwout.trim.\(pair)")
            let db = min(Self.hwoutTrimMax, max(Self.hwoutTrimMin, raw))
            if raw != db {
                UserDefaults.standard.set(db, forKey: "hwout.trim.\(pair)")
                QBLog.log(String(format: "trim: pair %d saved %.1f dB out of range — clamped to %.1f", pair, raw, db))
            }
            guard pushedHardwareTrims[pair] != db else { continue }
            for h in Self.hwoutTrimNodes[pair] ?? [] {
                guard let id = PathIds.dev("hwout/\(h)/trim") else { continue }
                glue.setDouble(id: id, db)
            }
            pushedHardwareTrims[pair] = db
            pushedAny = true
        }
        if pushedAny {
            QBLog.log("trim: saved hardware trims synced to the unit" +
                      pushedHardwareTrims.keys.sorted().map { String(format: " pair%d %.1f", $0, pushedHardwareTrims[$0] ?? 0) }.joined())
        }
    }


    /// The macOS mute changed (F10, Control Center): apply it to the
    /// Quartet's hardware mute. Normally one-way (see OSVolumeMirror's
    /// header); the one exception is a target switch, where the OS mute is
    /// written once so the macOS display matches the newly selected output.
    private func osMuteChanged(to m: Bool) {
        guard !PathIdSetupController.shared.sessionActive,
              !QuartetControlController.shared.isLearning else { return }   // a capture is listening
        guard gainKnown || directUSB.opened || ensureDirectUSB() else { return }
        let target = selectedOutput
        let current = muted[target] ?? false
        guard m != current else { return }
        QBLog.log("mute sync: OS mute \(m ? "on" : "off") -> Quartet \(target.rawValue)")
        guard writeMute(target, m) else { return }
        muted[target] = m
        refreshMenu()
    }

    var midiTrigger: MidiWatcher.Trigger? {
        didSet {
            if let midiTrigger, let data = try? JSONEncoder().encode(midiTrigger) {
                UserDefaults.standard.set(data, forKey: "midiTrigger")
            }
            refreshMenu()
        }
    }
    var learningMidi = false

    override init() {
        self.selectedOutput = .mainOut   // default target; never persisted
        self.talkbackMomentary = UserDefaults.standard.bool(forKey: "momentary")
        if let data = UserDefaults.standard.data(forKey: "midiTrigger") {
            self.midiTrigger = try? JSONDecoder().decode(MidiWatcher.Trigger.self, from: data)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        QBLog.log("=== Quartet Buddy launched ===")
        setupMenu()
        setupGlue()
        setupOSSlider()
        setupMIDI()
        setupInsert()
        setupSettingsWindow()
        setupConsoleWindow()
        // The talkback ear-test probe: walks the HP→Mixer route candidates
        // with read-backs while the user listens (see runTalkbackProbe — the
        // byte "4" was guessed, never ear-verified).
        if ProcessInfo.processInfo.environment["QB_TALKBACK_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runTalkbackProbe()
            }
        }
        // The hardware-mixer probe: dumps both mixer planes' full register
        // state (fader/pan/solo/mute × channels 0-14) and proves/disproves
        // that wValue = 1 selects the MIXER 2 plane (see runMixerProbe).
        if ProcessInfo.processInfo.environment["QB_MIXER_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runMixerProbe()
            }
        }
        // The mixer WATCHER: diff-reads the whole mixer register space
        // (0x4C-0x4F × wValue 0/1 × wIndex 0-14) every ~0.7 s and logs
        // every change — the user operates the TOUCHSCREEN's mixer and
        // the diff reveals the firmware's true register encoding.
        // The mic-channel SCAN: polls the running metering tap's held
        // peaks for 10 s while the user talks; logs which of the 12
        // inputs actually carry signal — ends the "which channel is my
        // mic on" guessing for good.
        if ProcessInfo.processInfo.environment["QB_MIC_SCAN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runMicScan()
            }
        }
        if ProcessInfo.processInfo.environment["QB_MIXER_WATCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runMixerWatch()
            }
        }
        // One-shot sanity restore: factory cells on both monitor mixes,
        // the HP route back to its playback pair (byte 3) and saved.
        if ProcessInfo.processInfo.environment["QB_MIXER_RESTORE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runMixerRestore()
            }
        }
        if ProcessInfo.processInfo.environment["QB_AUTO_UI"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QBLog.log("insert: AUTO-UI debug trigger")
                InsertServer.shared.showPluginUI(0)
            }
        }
        if ProcessInfo.processInfo.environment["QB_AUTO_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QBLog.log("control: AUTO-OPEN debug trigger")
                QuartetControlController.shared.show()
            }
        }
        if ProcessInfo.processInfo.environment["QB_AUTO_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QBLog.log("settings: AUTO-OPEN debug trigger")
                self?.settingsWindow.show()
            }
        }
        if ProcessInfo.processInfo.environment["QB_AUTO_ASSIST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                QBLog.log("control: AUTO-ASSIST debug trigger (ADAT bank + overlay)")
                NSApp.activate(ignoringOtherApps: true)
                // keep the panel up through the headless dumps: the
                // unpinned auto-hide treats any key shift as "the user
                // moved on" and closes the panel (and the assistant)
                QuartetControlController.shared.pinned = true
                UserDefaults.standard.set(1, forKey: "inputsBankPinned")
                QuartetControlController.shared.show()
                // the real path is click → refresh → resize; show() alone
                // doesn't re-fit an already-built window
                QuartetControlController.shared.resizeWindowToFitContent()
                QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_window_adat.png")
                // exercise the per-channel path exactly like a tile's Assist…
                QuartetControlController.shared.assistChannel(0)
                QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_window_listen.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    // the 5 s measurement has finished → result state
                    QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_window_result.png")
                    // DEBUG: force the frozen guidance compositions —
                    // the adjustment amount as the focal number, and
                    // the clipped state without any exact amount
                    AdatGainEngine.shared.debugForceStatus(0, .increase(8.4))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_window_guidance.png")
                        AdatGainEngine.shared.debugForceStatus(0, .clipped(-2.0))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_window_clipped.png")
                            QuartetControlController.shared.adatTiles[0].debugLogGeometry("clipped")
                            AdatGainEngine.shared.debugForceStatus(0, .idle)
                            // now the reverse direction: back to the
                            // ANALOG bank — the grid must reappear
                            // (it was hidden at build time)
                            QuartetControlController.shared.dismissAssistant(0)
                            QuartetControlController.shared.pinned = false   // restore the auto-hide default
                            UserDefaults.standard.set(0, forKey: "inputsBankPinned")
                            QuartetControlController.shared.refresh()
                            // bank switch layout change → the window must shrink
                            // back to the analog content height (top edge pinned)
                            QuartetControlController.shared.resizeWindowToFitContent()
                            QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_window_analog.png")
                            // The USER-path repro: real bank-button presses
                            // (bankClicked) instead of the forced refresh+resize
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                QuartetControlController.shared.debugClickBank(1)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_realpath_adat.png")
                                    QuartetControlController.shared.debugClickBank(0)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        QuartetControlController.shared.dumpWindowSnapshot("/tmp/qb_realpath_analog.png")
                                        // leave the analog bank persisted for the user
                                        UserDefaults.standard.set(0, forKey: "inputsBankPinned")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        deviceMonitor.start()
        quartetPresence.onChange = { [weak self] connected in
            QBLog.log("quartet presence: \(connected ? "connected" : "disconnected")")
            if connected {
                // 11.6: claim the direct-USB session eagerly on arrival so
                // the menubar icon + the offline transport are ready before
                // the first write. When ApogeeGlue is running it wins the
                // exclusive open and the glue path stays primary.
                DispatchQueue.main.async { [weak self] in
                    _ = self?.ensureDirectUSB()   // opens + re-pushes the saved routing
                    self?.refreshMenu()
                }
            }
            if !connected, self?.talkbackOn == true {
                // the TalkbackHelper resets talkback when the device goes away
                QBLog.log("talkback: assumed off (device disconnected)")
                self?.talkbackOn = false
            }
            if connected {
                // Volume target defaults back to Main Out on every
                // (re)connect; the didSet re-binds the macOS slider to it.
                self?.selectedOutput = .mainOut
                // the fader may have moved while unplugged (touchscreen,
                // Control 2) — pull a fresh tree so slider + menu are truth
                self?.glue.requestTree()
                // the AU insert follows the (re)connected Quartet
                if UserDefaults.standard.bool(forKey: "insertEnabled") {
                    InsertServer.shared.start()
                }
            } else {
                // the insert's aggregate is dead without the Quartet
                InsertServer.shared.stop()
            }
            self?.refreshMenu()
        }
        quartetPresence.start()
        syncLoginItem()
    }

    /// Persist hosted plugin settings before the process goes away —
    /// savePluginStatesNow (stop/plugin-swap/editor-close are the other
    /// checkpoints) so the next launch restores them.
    func applicationWillTerminate(_ notification: Notification) {
        InsertServer.shared.savePluginStatesNow()
    }

    // MARK: - Glue

    // MARK: - the tree snapshot (the offline boot + the state recovery)

    private static var treeSnapshotURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuartetBuddy/lastTree.json", isDirectory: true)
    }

    /// Persist the full tree so an offline boot can populate the UI.
    private func saveTreeSnapshot(_ tree: [String: Any]) {
        do {
            let url = Self.treeSnapshotURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: tree)
            try data.write(to: url)
        } catch {
            QBLog.log("tree snapshot save failed: \(error)")
        }
    }

    private static func loadTreeSnapshot() -> [String: Any]? {
        guard let data = try? Data(contentsOf: treeSnapshotURL),
              let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return tree
    }

    /// Apply a tree (live or the saved snapshot) to the app's state model.
    private func applyTree(_ tree: [String: Any]) {
        lastTree = tree
        // The device node's type is its serial — path-ids are hashed
        // per-serial, so pick this unit's id table before anything else.
        PathIds.select(serial: GlueClient.quartetSerial(in: tree))
        if glue.state == .connected { syncSavedHardwareTrims() }
        if let hw0 = GlueClient.findNode(in: tree, type: "hwout0"),
           let hw1 = GlueClient.findNode(in: tree, type: "hwout1") {
            gain[.mainOut] = GlueClient.doubleProp(hw0, "gain") ?? 0
            gain[.headphones] = GlueClient.doubleProp(hw1, "gain") ?? 0
            muted[.mainOut] = (GlueClient.intProp(hw0, "mute") ?? 0) == 1
            speakerDim = (GlueClient.intProp(hw0, "dim") ?? 0) == 1
            speakerSum = (GlueClient.intProp(hw0, "sum") ?? 0) == 1
            muted[.headphones] = (GlueClient.intProp(hw1, "mute") ?? 0) == 1
            headphoneDim = (GlueClient.intProp(hw1, "dim") ?? 0) == 1
            headphoneSum = (GlueClient.intProp(hw1, "sum") ?? 0) == 1
            gainKnown = true
            syncMacSlider(force: true)
        }
        if let tb = GlueClient.findNode(in: tree, type: "Talkback"),
           let props = tb["props"] as? [String: Any],
           let on = props["talkbackOn"] as? Bool {
            talkbackOn = on
        }
        // full-state sync for the Quartet Control window (inputs + monitors)
        QuartetControlController.shared.updateTree(tree)
        refreshMenu()
    }

    private func setupGlue() {
        glue.onState = { [weak self] state in
            self?.refreshMenu()
            if state == .disconnected {
                // per-connection push records reset — the next tree re-applies
                self?.pushedHardwareTrims.removeAll()
                self?.scheduleReconnect()
            }
        }
        glue.onTree = { [weak self] tree in
            guard let self else { return }
            self.applyTree(tree)
        }
        // 11.7 FINAL: the tree snapshot is RETIRED. The device's flash is
        // the settings store (the power-cycle + other-computer tests), the
        // registers answer reads, and a stale snapshot poisoned lastTree so
        // the offline branches never fired (the talkback picker's grey +
        // the dropped writes). lastTree = the LIVE glue tree only (the
        // connected-era path); offline = nil = the offline branches own it.
        try? FileManager.default.removeItem(at: Self.treeSnapshotURL)
        glue.onSetProperty = { [weak self] event in
            guard let self else { return }
            // the setup wizard listens to the same stream (capture steps)
            PathIdSetupController.shared.handle(event)
            // so does the Quartet Control window (live updates + Learn mode)
            QuartetControlController.shared.handle(event)
            switch event.id {
            case PathIds.active.hwout0Gain where event.tag == 4:
                self.gain[.mainOut] = event.value.readDouble()
                self.syncMacSlider()
            case PathIds.active.hwout1Gain where event.tag == 4:
                self.gain[.headphones] = event.value.readDouble()
                self.syncMacSlider()
            case PathIds.active.hwout0Mute where event.tag == 3:
                self.muted[.mainOut] = event.value.first == 1
            case PathIds.active.hwout1Mute where event.tag == 3:
                self.muted[.headphones] = event.value.first == 1
            case PathIds.active.hwout0Dim where event.tag == 3:
                self.speakerDim = event.value.first == 1
            case let id where event.tag == 3 && PathIds.active.hwout0Sum == id:
                self.speakerSum = event.value.first == 1
            case let id where event.tag == 3 && PathIds.active.hwout1Dim == id:
                self.headphoneDim = event.value.first == 1
            case let id where event.tag == 3 && PathIds.active.hwout1Sum == id:
                self.headphoneSum = event.value.first == 1
            case PathIds.talkbackOn where event.tag == 3:
                self.talkbackOn = event.value.first == 1
            default:
                break
            }
            self.refreshMenu()
        }
        glue.connect()
    }

    private var reconnectTimer: Timer?
    private func scheduleReconnect() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reconnectTimer == nil else { return }
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                self?.reconnectTimer = nil
                self?.glue.connect()
            }
        }
    }

    // MARK: - macOS audio controls bridge

    /// Serial we already auto-prompted the setup wizard for (this launch).
    /// Obsolete: ids are computed now, nothing to capture.

    /// Most recent glue tree (seeds the console window with live values
    /// the moment it opens).
    private var lastTree: [String: Any]?

    /// Wire the macOS → Quartet halves of the volume + mute bindings. The
    /// volume keys and F10 are never intercepted — macOS drives its own
    /// controls natively, and OSVolumeMirror delivers every change here.
    private func setupOSSlider() {
        osSlider.onSliderMoved = { [weak self] db in self?.osSliderMoved(to: db) }
        osSlider.onMuteChanged = { [weak self] m in self?.osMuteChanged(to: m) }
        osSlider.start()   // re-bind automatically when the Quartet is replugged
    }

    /// ± dB adjustments (Test menu items).
    private func adjustGain(by delta: Double) {
        let target = selectedOutput
        let new = min(0, max(Self.minDB, (gain[target] ?? 0) + delta))
        glue.setDouble(id: target.gainId, new)
        gain[target] = new
        syncMacSlider()
        refreshMenu()
    }

    // MARK: - Talkback

    func toggleTalkback() {
        setTalkback(!talkbackOn)
    }

    private func setupHotKey() {
        shortcuts.perform = { [weak self] action, keyDown in
            self?.performShortcut(action, keyDown: keyDown)
        }
        shortcuts.registerAll()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // app-only bindings fire just while Quartet Control is focused
            guard QuartetControlController.shared.isKeyWindow else { return event }
            guard let action = self.shortcuts.matchLocal(event) else { return event }
            self.performShortcut(action, keyDown: true)
            return nil
        }
    }

    /// Hotkey action: toggle the volume target Main Out ↔ Headphones.
    func switchVolumeTarget() {
        selectedOutput = selectedOutput == .mainOut ? .headphones : .mainOut
        QBLog.log("hotkey: volume target now \(selectedOutput.rawValue)")
    }

    /// Route a shortcut action to the app — the ONLY dispatcher (a menubar
    /// item, a mouse click and a keystroke all run the same code).
    private func performShortcut(_ action: ShortcutAction, keyDown: Bool) {
        guard keyDown else {
            // key-up: hold actions only (talkback release)
            if action == .talkbackHold { setTalkback(false) }
            return
        }
        let control = QuartetControlController.shared
        switch action {
        // Window & Navigation
        case .showHideWindow: control.toggleShown()
        // ⌘P — app-only (the local monitor fires this just while the
        // control panel is focused); other apps' ⌘P is untouched
        case .pinPanel: control.togglePinned()
        case .openSettings: settingsWindow.show()
        case .selectNextOutput: control.selectAdjacentOutput(1)
        case .selectPreviousOutput: control.selectAdjacentOutput(-1)

        // Speakers (monitor 0)
        case .speakerMute: toggleMute(.mainOut)
        case .speakerDim:
            let on = !speakerDim
            glue.setBool(id: PathIds.active.hwout0Dim, on)
            speakerDim = on
        case .speakerSum:
            if let id = PathIds.active.hwout0Sum {
                let on = !speakerSum
                glue.setBool(id: id, on)
                speakerSum = on
            }
        case .speakerVolumeUp: adjust(.mainOut, shortcuts.volumeStep)
        case .speakerVolumeDown: adjust(.mainOut, -shortcuts.volumeStep)
        case .speakerFineUp: adjust(.mainOut, shortcuts.fineStep)
        case .speakerFineDown: adjust(.mainOut, -shortcuts.fineStep)

        // Headphones (monitor 1)
        case .headphoneMute: toggleMute(.headphones)
        case .headphoneDim:
            if let id = PathIds.active.hwout1Dim {
                let on = !headphoneDim
                glue.setBool(id: id, on)
                headphoneDim = on
            }
        case .headphoneSum:
            if let id = PathIds.active.hwout1Sum {
                let on = !headphoneSum
                glue.setBool(id: id, on)
                headphoneSum = on
            }
        case .headphoneVolumeUp: adjust(.headphones, shortcuts.volumeStep)
        case .headphoneVolumeDown: adjust(.headphones, -shortcuts.volumeStep)
        case .headphoneFineUp: adjust(.headphones, shortcuts.fineStep)
        case .headphoneFineDown: adjust(.headphones, -shortcuts.fineStep)

        // Volume-Control Target
        case .selectSpeakersTarget: selectedOutput = .mainOut
        case .selectHeadphonesTarget: selectedOutput = .headphones
        case .switchTarget: switchVolumeTarget()
        case .targetVolumeUp: adjust(selectedOutput, shortcuts.volumeStep)
        case .targetVolumeDown: adjust(selectedOutput, -shortcuts.volumeStep)

        // Talkback
        case .talkbackHold: setTalkback(true)   // release arrives on key-up
        case .talkbackToggle: toggleTalkback()

        // Plug-ins
        case .bypassAllPlugins:
            InsertServer.shared.setBypassAll(!InsertServer.shared.bypassAll)
        case .toggleInsert:
            let on = !InsertServer.shared.running
            UserDefaults.standard.set(on, forKey: "insertEnabled")
            InsertServer.shared.setRunning(on)
        case .bypassSelectedOutput: control.shortcutBypassSelectedOutput()
        case .openSelectedPlugin: control.shortcutOpenSelectedPlugin()

        // Outputs & Routing (selected card)
        case .selectOutput1: control.selectOutput(0)
        case .selectOutput2: control.selectOutput(1)
        case .selectOutput3: control.selectOutput(2)
        case .selectOutput4: control.selectOutput(3)
        case .outputTrimUp: control.shortcutOutputTrim(up: true, step: 1)
        case .outputTrimDown: control.shortcutOutputTrim(up: false, step: 1)
        case .editOutputTrim: control.shortcutEditOutputTrim()
        case .openSourceSelector: control.shortcutOpenSourceSelector()
        case .cycleStage: control.shortcutCycleStage()

        // Inputs (selected card)
        case .selectInput1: control.selectInput(0)
        case .selectInput2: control.selectInput(1)
        case .selectInput3: control.selectInput(2)
        case .selectInput4: control.selectInput(3)
        case .inputGainUp: control.shortcutInputGain(up: true, step: shortcuts.volumeStep)
        case .inputGainDown: control.shortcutInputGain(up: false, step: shortcuts.volumeStep)
        case .editInputGain: control.shortcutEditInputGain()
        case .autoGainSelectedInput: control.shortcutAutoGainSelected()
        case .autoGainAllInputs: control.shortcutAutoGainAll()
        case .cancelAutoGain: control.shortcutCancelAutoGain()
        case .toggleSoftLimit: control.shortcutToggleSoftLimit()
        case .togglePolarity: control.shortcutTogglePolarity()
        case .toggleInputsBank: control.shortcutToggleInputsBank()

        // Safety
        case .muteAllOutputs:
            // ALWAYS mute — never unmute (a panic command must never
            // make sound by surprise).
            for t in OutputTarget.allCases where muted[t] != true {
                glue.setBool(id: t.muteId, true)
                muted[t] = true
            }
        }
        refreshMenu()
    }

    /// Explicit talkback state (hold-to-talk presses this with true/false).
    /// 11.7 TALKBACK ENGINE — the ApogeeTalkbackHelper's mechanism,
    /// reimplemented on the decoded mixer registers (the helper's strings:
    /// Apogee::TalkbackManager + Apogee::MixerSideEffects = the mixer-side
    /// manipulation; the talkback sources/destinations = the mic channel
    /// into the mix + the mains' dim). ON = the source's mixer channel
    /// unmuted + the Main Out dimmed; OFF = the mic muted again + the dim
    /// released. The mic stays muted in the mix otherwise (the feedback
    /// guard), which is also why the helper's default model mutes it.
    private func setTalkback(_ on: Bool) {
        guard on != talkbackOn else { return }
        if directUSB.opened {
            // 11.7 THE FULL PATH: the outputs are routed from the PLAYBACK
            // pairs — the mic's channel lives in the MIXER, which is not in
            // a PB-sourced output's path at all (the user's "nothing comes
            // out"). The helper's real trick = the DESTINATION's routing
            // switches to a mixer during talkback:
            //   ON:  the mic's channel unmuted + the HP routed to Mixer 1
            //        + the mains dimmed
            //   OFF: the HP's routing restored + the mic muted + the dim off
            let ch = UInt16(max(0, min(11, talkbackSourceInput)))
            let hpRestore = UserDefaults.standard.object(forKey: "hwout.route.3") as? Int ?? 3
            if on {
                _ = directUSB.setRawByte(0x53, index: 3, byte: 5)           // the HP → the monitor mix
                    // (EAR-VERIFIED 11/8: byte 5 = music + the raw inputs —
                    // the ONLY route that carries the mic; bytes 0-3 = pure
                    // playback. The route switch IS the mic gate: normal
                    // listening = a playback pair (no mic), talkback = the
                    // monitor mix. Restored on off.)
                _ = directUSB.setRawByteValue(0x4f, wValue: 1, index: ch, byte: 0)   // the HP's mic cell unmuted
                _ = directUSB.setRawByteValue(0x4c, wValue: 1, index: ch, byte: 48)  // …and open at 0 dB
                _ = directUSB.setMixerMute(channel: ch, mute: false)        // the Main's cell too (belt & braces)
                _ = directUSB.setOutputFlag(0x40, output: 0, on: true)      // the mains' dim
                QBLog.log("talkback: on — HP → monitor mix (0x53=05, mic raw-carried), mains dimmed")
            } else {
                _ = directUSB.setRawByte(0x53, index: 3, byte: UInt8(hpRestore)) // the restore (a playback pair = no mic)
                _ = directUSB.setRawByteValue(0x4f, wValue: 1, index: ch, byte: 1)   // the HP's mic cell muted
                _ = directUSB.setMixerMute(channel: ch, mute: true)         // the Main's cell muted
                _ = directUSB.setOutputFlag(0x40, output: 0, on: false)     // the dim = off
                QBLog.log("talkback: off — HP routing restored (\(hpRestore) = playback, no mic), dim off")
            }
        } else {
            glue.setBool(id: PathIds.talkbackOn, on)
        }
        talkbackOn = on
        refreshMenu()
    }
    /// The talkback's source input (0-3) — the Settings' picker stores it;
    /// default = input 1.
    var talkbackSourceInput: Int {
        get { UserDefaults.standard.integer(forKey: "talkback.sourceInput") }
        set { UserDefaults.standard.set(newValue, forKey: "talkback.sourceInput") }
    }

    // MARK: - The talkback EAR-TEST probe, round 2 (QB_TALKBACK_PROBE=1)

    /// Round 1 learned: every candidate write is accepted, nothing was
    /// heard — but the round had three confounders: the HP sat at −44 dB,
    /// nobody was listening at the windows, and the round-2 relaunch had
    /// the source on Analog 1 while the user's mic lives on Digital 1.
    ///
    /// This round isn't silently-passable: the HP is boosted to −10 dB
    /// (the user's own earlier "LOUD" anchor), the MAIN OUTPUT is muted
    /// for the run (no feedback), and it starts with a POSITIVE CONTROL —
    /// the direct-monitoring matrix cell (input→headphones), the one
    /// routing family that WAS ear-verified. If the control is silent,
    /// the problem is upstream (the ADAT stream / the source itself).
    /// Then it closes the cell and walks the 0x53 source candidates.
    private func runTalkbackProbe() {
        guard directUSB.opened else {
            QBLog.log("tb-probe: no direct-USB session (device away?) — launch again")
            return
        }
        let ch = UInt16(max(0, min(11, talkbackSourceInput)))
        let name = ch < 4 ? "Analog \(ch + 1)" : "Digital \(ch - 3)"
        QBLog.log("tb-probe2: START — source = \(name) (mixer ch \(ch)); the FIRST window (A) starts 45 s from now, then one every 8 s — put the headphones ON and get ready")

        // save
        let savedHPGain = directUSB.readInput(input: 1, bRequest: 0x33)
        let savedMainMute = directUSB.readInput(input: 0, bRequest: 0x35)
        let savedMasterMute = directUSB.readInput(input: 14, bRequest: 0x4f)
        let savedMasterFader = directUSB.readInput(input: 14, bRequest: 0x4c)
        let savedMicMute = directUSB.readInput(input: ch, bRequest: 0x4f)
        let savedMicFader = directUSB.readInput(input: ch, bRequest: 0x4c)
        let savedCellGain = directUSB.readCell(wValue: ch, index: 1, bRequest: 0x4c)
        let savedCellMute = directUSB.readCell(wValue: ch, index: 1, bRequest: 0x4e)
        QBLog.log("tb-probe2: initial — HP |dB| \(savedHPGain.map { String($0) } ?? "nil"), mainMute \(savedMainMute.map { String($0) } ?? "nil"), master(r \(savedMasterFader.map { String($0) } ?? "nil") m \(savedMasterMute.map { String($0) } ?? "nil")), \(name)'s ch(r \(savedMicFader.map { String($0) } ?? "nil") m \(savedMicMute.map { String($0) } ?? "nil")), direct-cell(r \(savedCellGain.map { String($0) } ?? "nil") m \(savedCellMute.map { String($0) } ?? "nil"))")

        // the audible stage: HP −10 dB (LOUD), mains muted, the mic's
        // channel + the master open at 0 dB
        _ = directUSB.setRawByte(0x33, index: 1, byte: 10)   // HP |dB| = 10 (−10 dB)
        _ = directUSB.setRawByte(0x35, index: 0, byte: 1)    // the mains muted for the run
        _ = directUSB.setMixerVolume(channel: ch, db: 0)
        _ = directUSB.setMixerMute(channel: ch, mute: false)
        _ = directUSB.setRawByte(0x4f, index: 14, byte: 0)
        _ = directUSB.setRawByte(0x4c, index: 14, byte: 48)
        QBLog.log("tb-probe2: HP boosted to −10 dB, mains muted, master + \(name)'s mixer channel open at 0 dB")

        // WINDOW A (+18 s, 6 s): the POSITIVE CONTROL — the direct-
        // monitoring matrix cell: this input's audio added straight to
        // the headphones output (wValue = input, wIndex = output 1).
        var t: TimeInterval = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            _ = self?.directUSB.setRawByteValue(0x4c, wValue: ch, index: 1, byte: 48)
            _ = self?.directUSB.setRawByteValue(0x4e, wValue: ch, index: 1, byte: 0)
            let cMute = self?.directUSB.readCell(wValue: ch, index: 1, bRequest: 0x4e)
            QBLog.log("tb-probe2: A — CONTROL: \(name) opened STRAIGHT into the HP via the direct matrix (cell mute rb \(cMute.map { String($0) } ?? "nil")) — LISTEN NOW (6 s): talk into the mic")
        }
        t += 8
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            // close the direct cell again (it would mask the mixer tests)
            _ = self?.directUSB.setRawByteValue(0x4e, wValue: ch, index: 1, byte: 1)
            _ = self?.directUSB.setRawByteValue(0x4c, wValue: ch, index: 1, byte: 48)
            QBLog.log("tb-probe2: A closed — the mixer-route tests begin")
        }
        // the 0x53 candidates: 04/05 (the presumption) + the 0x11–0x16
        // tree-code family the device is known to translate
        let candidates: [UInt8] = [4, 5, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16]
        for (i, c) in candidates.enumerated() {
            t += 8
            let tag = String(UnicodeScalar(65 + 1 + i)!)   // B, C, D …
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                _ = self.directUSB.setRawByte(0x53, index: 3, byte: c)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let v = self.directUSB.readInput(input: 3, bRequest: 0x53)
                    QBLog.log("tb-probe2: \(tag) — HP route ← 0x\(String(c, radix: 16)) (read-back \(v.map { String($0) } ?? "nil")) — LISTEN NOW (6 s): talk into the mic")
                }
            }
        }
        t += 10
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            guard let self else { return }
            // the restore: the HP route to the app's saved slot, the HP
            // fader + main mute + master + mic channel + the direct cell
            let hp = UInt8(UserDefaults.standard.object(forKey: "hwout.route.3") as? Int ?? 3)
            _ = directUSB.setRawByte(0x53, index: 3, byte: hp)
            if let v = savedHPGain { _ = directUSB.setRawByte(0x33, index: 1, byte: v) }
            if let v = savedMainMute { _ = directUSB.setRawByte(0x35, index: 0, byte: v) }
            if let v = savedMicFader { _ = directUSB.setRawByte(0x4c, index: ch, byte: v) }
            else { _ = directUSB.setMixerVolume(channel: ch, db: 0) }
            _ = directUSB.setRawByte(0x4f, index: ch, byte: 1)   // the feedback guard
            if let v = savedMasterMute { _ = directUSB.setRawByte(0x4f, index: 14, byte: v) }
            if let v = savedMasterFader { _ = directUSB.setRawByte(0x4c, index: 14, byte: v) }
            if let v = savedCellGain { _ = directUSB.setRawByteValue(0x4c, wValue: ch, index: 1, byte: v) }
            if let v = savedCellMute { _ = directUSB.setRawByteValue(0x4e, wValue: ch, index: 1, byte: v) }
            QBLog.log("tb-probe2: DONE — everything restored (HP ← \(hp), gains/mutes back, direct cell closed, mic muted)")
        }
    }

    // MARK: - The hardware-mixer probe (QB_MIXER_PROBE=1)

    /// Dumps both monitor outputs' mix cells (fader/pan/solo?/mute? ×
    /// source 0-14) — post-reinterpretation: wValue = the OUTPUT (0 = Main,
    /// 1 = Headphones), wIndex = the source. Read-only, nothing written.
    private func runMixerProbe() {
        guard directUSB.opened else {
            QBLog.log("mix-probe: no direct-USB session (device away?) — launch again")
            return
        }
        DispatchQueue(label: "qb.mixprobe").async { [weak self] in
            guard let self, self.directUSB.opened else { return }
            // THE CELL DUMP (post-reinterpretation): wValue = the OUTPUT
            // (0 = Main, 1 = Headphones), wIndex = the source (0-11 inputs,
            // 12/13 playback, 14 ?). Dump both outputs' cells fully.
            let reqs: [(String, UInt8)] = [("f", 0x4c), ("p", 0x4d), ("s", 0x4e), ("m", 0x4f)]
            let outs: [UInt16] = [0, 1]
            let chans: [UInt16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
            for out in outs {
                var lines: [String] = []
                for chx in chans {
                    let cells = reqs.map { req -> String in
                        let v = self.directUSB.readCell(wValue: out, index: chx, bRequest: req.1)
                        return "\(req.0)\(v.map { String($0) } ?? "?")"
                    }
                    lines.append("ch\(chx)[\(cells.joined(separator: " "))]")
                }
                let label = out == 0 ? "MAIN OUT" : "HEADPHONES"
                QBLog.log("mix-probe: \(label) mix cells (f=fader p=pan s=? m=?): " + lines.joined(separator: " "))
            }
            let routes = (0..<4).map { self.directUSB.readInput(input: UInt16($0), bRequest: 0x53).map { String($0) } ?? "?" }
            QBLog.log("mix-probe: 0x53 routes: \(routes.joined(separator: ","))")
            // THE MUTE/SOLO HUNT: the mic (Digital 1, block-0 s4) open at
            // 0 dB on byte 4. The user talks continuously; each stage flips
            // ONE candidate: the 0x4F mute register (wValue 0-3) or a
            // marker bit. The stage where the voice dies = the mute's home.
            // The app speaks each stage's label; every write rb-verified.
            var speaker: NSSpeechSynthesizer?
            func speak(_ s: String) {
                QBLog.log("mix-probe: 🔊 \"\(s)\"")
                speaker?.startSpeaking(s)
            }
            func setReg(_ reg: UInt8, _ wV: UInt16, _ ch: UInt16, _ v: UInt8) {
                _ = self.directUSB.setRawByteValue(reg, wValue: wV, index: ch, byte: v)
                let r = self.directUSB.readCell(wValue: wV, index: ch, bRequest: reg)
                QBLog.log("mix-probe: 0x\(String(reg, radix: 16)) w\(wV) ch\(ch) ← \(v) — rb \(r.map { String($0) } ?? "nil")")
            }
            func setSlot(_ blockWI: UInt16, _ slot: Int, _ gain: UInt8, _ marker: UInt8) {
                guard var block = self.directUSB.readBlock(index: blockWI,
                                                           bRequest: 0x10, length: 28) else { return }
                block[slot * 2] = gain
                block[slot * 2 + 1] = marker
                let ok = self.directUSB.writeBlock(index: blockWI, bRequest: 0x10, bytes: block)
                let rb = self.directUSB.readBlock(index: blockWI, bRequest: 0x10, length: 28)
                    .map { "g\($0[slot * 2]) m\($0[slot * 2 + 1])" } ?? "nil"
                QBLog.log("mix-probe: block \(blockWI) slot \(slot) ← g\(gain) m\(marker) — \(ok ? "ok" : "FAILED") rb \(rb)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                speaker = NSSpeechSynthesizer()   // main thread
                _ = self.directUSB.setRawByte(0x53, index: 3, byte: 4)   // HP → byte 4 (Mixer 1)
                _ = self.directUSB.setRawByte(0x35, index: 0, byte: 1)   // Main muted
                setSlot(0, 4, 0x30, 0xA1)                                // the mic open, factory marker
                QBLog.log("mix-probe: MUTE-HUNT stage 1 (+10 s) — baseline")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                speak("Stage one. Baseline. Talk.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                guard let self else { return }
                setReg(0x4f, 0, 4, 1)
                speak("Stage two. Mute register, plane zero.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 34) { [weak self] in
                guard let self else { return }
                setReg(0x4f, 0, 4, 0)
                setReg(0x4f, 1, 4, 1)
                speak("Stage three. Mute register, plane one.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 46) { [weak self] in
                guard let self else { return }
                setReg(0x4f, 1, 4, 0)
                setReg(0x4f, 2, 4, 1)
                speak("Stage four. Mute register, plane two.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 58) { [weak self] in
                guard let self else { return }
                setReg(0x4f, 2, 4, 0)
                setReg(0x4f, 3, 4, 1)
                speak("Stage five. Mute register, plane three.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 70) { [weak self] in
                guard let self else { return }
                setReg(0x4f, 3, 4, 0)
                setSlot(0, 4, 0x30, 0xA3)                                // marker bit 1
                speak("Stage six. Marker bit one.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 82) { [weak self] in
                guard let self else { return }
                setSlot(0, 4, 0x30, 0xA5)                                // marker bit 2
                speak("Stage seven. Marker bit two.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 94) { [weak self] in
                guard let self else { return }
                setSlot(0, 4, 0x30, 0x81)                                // clear marker bit 5
                speak("Stage eight. Marker bit five cleared.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 106) { [weak self] in
                guard let self else { return }
                setSlot(0, 4, 0x30, 0xA1)                                // the factory marker
                _ = self.directUSB.setRawByte(0x53, index: 3, byte: 5)   // HP → byte 5
                _ = self.directUSB.setRawByte(0x35, index: 0, byte: 0)   // Main unmuted
                QBLog.log("mix-probe: MUTE-HUNT DONE — marker restored, HP → byte 5")
            }
            QBLog.log("mix-probe: DONE — dump only, nothing written")
        }
    }

    /// The mic-channel SCAN (QB_MIC_SCAN=1): polls the metering tap's
    /// held peaks for 10 s while the user talks; ranks the 12 inputs by
    /// their max dBFS and flags the channels that carry the mic.
    private func runMicScan() {
        QBLog.log("mic-scan: START — TALK into the mic CONTINUOUSLY for the next 10 s")
        AdatGainEngine.shared.windowVisible = true
        AdatGainEngine.shared.refreshChannelCount()
        var best = [Double?](repeating: nil, count: 12)
        var elapsed = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            elapsed += 0.5
            for ch in 0...11 {
                if let db = AdatGainEngine.shared.heldPeakDBFS(ch),
                   best[ch] == nil || db > best[ch]! {
                    best[ch] = db
                }
            }
            if elapsed >= 10 {
                timer.invalidate()
                var lines: [String] = []
                for ch in 0...11 {
                    let name = ch < 4 ? "Analog \(ch + 1)" : "Digital \(ch - 3)"
                    if let db = best[ch] {
                        lines.append("mic-scan:   \(name): \(Int(db)) dBFS\(db > -50 ? "   ← SIGNAL" : "")")
                    } else {
                        lines.append("mic-scan:   \(name): silent")
                    }
                }
                QBLog.log("mic-scan: RESULT over 10 s:\n" + lines.joined(separator: "\n"))
                QBLog.log("mic-scan: DONE")
            }
        }
    }

    /// One-shot sanity restore (QB_MIXER_RESTORE=1): both monitor mixes'
    /// cells to the factory state, the HP route back to its playback pair
    /// (byte 3, mic-free) and saved. Everything logged with read-backs.
    private func runMixerRestore() {
        guard directUSB.opened else {
            QBLog.log("mix-restore: no direct-USB session — relaunch with the device present")
            return
        }
        DispatchQueue(label: "qb.mixrestore").async { [weak self] in
            guard let self, self.directUSB.opened else { return }
            QBLog.log("mix-restore: START")
            // MAIN's mix (wValue 0): the inputs closed (fader −48, unmute —
            // the factory state), the playback cells open.
            for ch in UInt16(0)...11 {
                _ = self.directUSB.setRawByteValue(0x4c, wValue: 0, index: ch, byte: 0)
                _ = self.directUSB.setRawByteValue(0x4f, wValue: 0, index: ch, byte: 0)
            }
            for ch in [UInt16(12), 13, 14] {
                _ = self.directUSB.setRawByteValue(0x4c, wValue: 0, index: ch, byte: 48)
                _ = self.directUSB.setRawByteValue(0x4f, wValue: 0, index: ch, byte: 0)
            }
            // HP's mix (wValue 1): everything open at 0 dB (the factory).
            for ch in UInt16(0)...14 {
                _ = self.directUSB.setRawByteValue(0x4c, wValue: 1, index: ch, byte: 48)
                _ = self.directUSB.setRawByteValue(0x4f, wValue: 1, index: ch, byte: 0)
            }
            // the route: HP → its playback pair (byte 3, no mic) + saved
            _ = self.directUSB.setRawByte(0x53, index: 3, byte: 3)
            UserDefaults.standard.set(3, forKey: "hwout.route.3")
            let r = self.directUSB.readInput(input: 3, bRequest: 0x53)
            let f4 = self.directUSB.readCell(wValue: 1, index: 4, bRequest: 0x4c)
            QBLog.log("mix-restore: DONE — HP route ← 3 (rb \(r.map { String($0) } ?? "nil")), saved = 3; HP's Digital-1 cell fader rb \(f4.map { String($0) } ?? "nil") = 0 dB (open, but byte 3 carries no inputs)")
        }
    }

    /// The mixer register WATCHER (QB_MIXER_WATCH=1): diff-reads the whole
    /// mixer space every ~0.7 s for ~3 minutes and logs every change as
    /// `reg/wValue/wIndex: old → new`. The user performs touchscreen mixer
    /// actions in parallel; the diffs = the firmware's true encoding.
    private func runMixerWatch() {
        guard directUSB.opened else {
            QBLog.log("mix-watch: no direct-USB session — relaunch with the device present")
            return
        }
        DispatchQueue(label: "qb.mixwatch").async { [weak self] in
            guard let self, self.directUSB.opened else { return }
            QBLog.log("mix-watch: START — watching 0x4C/0x4D/0x4E/0x4F × wValue 0-1 × wIndex 0-14; do the touchscreen mixer actions NOW")
            let regs: [UInt8] = [0x4c, 0x4d, 0x4e, 0x4f]
            var snapshot: [String: UInt8] = [:]
            let key = { (r: UInt8, wV: UInt16, wI: UInt16) -> String in
                String(format: "%02x-%d-%d", r, wV, wI)
            }
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 180 {
                var now: [String: UInt8] = [:]
                for r in regs {
                    for wV in [UInt16(0), 1] {
                        for wI in UInt16(0)...14 {
                            if let v = self.directUSB.readCell(wValue: wV, index: wI, bRequest: r) {
                                now[key(r, wV, wI)] = v
                            }
                        }
                    }
                }
                if !snapshot.isEmpty {
                    for (k, v) in now where snapshot[k] != v {
                        QBLog.log("mix-watch: \(k): \(snapshot[k].map { String($0) } ?? "?") → \(v)")
                    }
                }
                snapshot = now
                Thread.sleep(forTimeInterval: 0.7)
            }
            QBLog.log("mix-watch: DONE (3 min elapsed)")
        }
    }

    /// ± dB adjustment on one output (hardware fader, range-clamped).
    private func adjust(_ t: OutputTarget, _ delta: Double) {
        let new = min(0, max(Self.minDB, (gain[t] ?? 0) + delta))
        guard abs(new - (gain[t] ?? 0)) > 0.01 else { return }
        glue.setDouble(id: t.gainId, new)
        gain[t] = new
        syncMacSlider()
    }

    /// Hardware mute toggle per output target.
    private func toggleMute(_ t: OutputTarget) {
        let new = !(muted[t] ?? false)
        glue.setBool(id: t.muteId, new)
        muted[t] = new
    }

    // MARK: - MIDI

    private func setupMIDI() {
        setupHotKey()
        midi.onAnyEvent = { [weak self] event in
            guard let self else { return }
            QBLog.log("midi: ch=\(event.channel + 1) \(event.kind == .note ? "note" : "cc") \(event.number) value=\(event.value)")
            if self.learningMidi {
                self.learningMidi = false
                self.midiTrigger = MidiWatcher.Trigger(channel: event.channel,
                                                       kind: event.kind,
                                                       number: event.number)
                return
            }
            guard let t = self.midiTrigger,
                  t.channel == event.channel, t.kind == event.kind, t.number == event.number else { return }
            if self.talkbackMomentary {
                self.setTalkback(event.isDown)
            } else if event.isDown {
                self.toggleTalkback()
            }
        }
        if !midi.start(matchingSourceNamed: "Quartet") {
            print("[QuartetBuddy] no 'Quartet' MIDI source — keyboard attached to the Quartet's MIDI port?")
        }
    }

    // MARK: - AU insert

    /// Restore the insert (and its plugin) on launch if it was enabled.
    private func setupInsert() {
        let server = InsertServer.shared
        server.onStateChange = { [weak self] in self?.refreshMenu() }
        let enabled = UserDefaults.standard.bool(forKey: "insertEnabled")
        QBLog.log("insert: launch, insertEnabled=\(enabled)")
        if enabled {
            server.start()
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The Apogee logo is now a plain BUTTON: clicking it opens the
        // Quartet Control window (the window carries everything the old
        // menubar menu did — no dropdown). The menu object still exists
        // only as the target of rebuildMenu's tooltip/dot bookkeeping.
        statusItem.menu = nil
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusClicked(_:))
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        rebuildMenu()
    }

    /// Clicking the menubar Apogee logo — TOGGLE the Quartet Control
    /// window: closed → open it, open → close it. Nothing else lives up
    /// here anymore.
    @objc private func statusClicked(_ sender: Any?) {
        QuartetControlController.shared.toggleShown()
    }

    /// Rebuild the menu + menubar state. Coalesced: bursts of state changes
    /// (slider drags, key repeats, echo + local update for the same event)
    /// collapse into a single rebuild per runloop turn.
    private var menuRefreshPending = false

    private func refreshMenu() {
        guard !menuRefreshPending else { return }
        menuRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuRefreshPending = false
            self.rebuildMenu()
            self.settingsWindow.refresh()
            QuartetControlController.shared.refresh()
        }
    }

    /// The last menubar-icon state — the image is only swapped when either
    /// dimension changes (rebuilding the image on every reconnect attempt
    /// made the icon flicker grey/white).
    private var lastIconActive: Bool?
    private var lastIconHeadphones: Bool?

    /// The device's real availability: the glue tree when the daemon runs,
    /// otherwise the direct-USB session (11.6).
    private func deviceUsable() -> Bool {
        if quartetPresence.isConnected && glue.state == .connected { return true }
        return quartetPresence.isConnected && directUSB.opened
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // menubar icon + tooltip — only swap the image when the state flips
        statusItem?.button?.title = ""
        let appActive = deviceUsable()
        let headphonesSelected = selectedOutput == .headphones
        if appActive != lastIconActive || headphonesSelected != lastIconHeadphones {
            statusItem?.button?.image = LogoIcon.image(headphonesSelected: headphonesSelected,
                                                        active: appActive)
            lastIconActive = appActive
            lastIconHeadphones = headphonesSelected
        }
        updateTalkbackDot()
        let mainGain = gain[.mainOut] ?? 0
        let hpGain = gain[.headphones] ?? 0
        statusItem?.button?.toolTip =
            "Main Out \(String(format: "%.1f", mainGain)) dB · HP \(String(format: "%.1f", hpGain)) dB · Talkback \(talkbackOn ? "on" : "off")"

        // header — name + live connection state
        menu.addItem(sectionHeader("Quartet Buddy"))
        let stateLine: String
        if !quartetPresence.isConnected { stateLine = "Quartet Not Connected" }
        else if glue.state != .connected { stateLine = "Quartet Connected (direct USB)" }
        else { stateLine = "Quartet Connected" }
        let stateItem = menu.addItem(withTitle: stateLine, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false

        menu.addItem(.separator())

        // Control Volume ▸ Speakers / Headphones (the fader binding target)
        let volItem = menu.addItem(withTitle: "Control Volume", action: nil, keyEquivalent: "")
        volItem.submenu = NSMenu()
        for target in OutputTarget.allCases {
            let item = volItem.submenu!.addItem(withTitle: target.rawValue,
                                                action: #selector(pickOutput(_:)), keyEquivalent: "")
            item.representedObject = target.rawValue
            item.state = target == selectedOutput ? .on : .off
        }

        // live levels, one line each
        let server = InsertServer.shared
        let mainMuted = muted[.mainOut] ?? false
        let hpMuted = muted[.headphones] ?? false
        menu.addItem(withTitle: "Speakers\(String(format: "  %.1f dB", mainGain))\(mainMuted ? "  (muted)" : "")",
                      action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Headphones\(String(format: "  %.1f dB", hpGain))\(hpMuted ? "  (muted)" : "")",
                      action: nil, keyEquivalent: "").isEnabled = false

        menu.addItem(.separator())

        // mutes + dim (hardware, via ApogeeGlue)
        let muteMain = menu.addItem(withTitle: "Mute Speakers", action: #selector(toggleMuteTarget(_:)), keyEquivalent: "")
        muteMain.representedObject = OutputTarget.mainOut.rawValue
        muteMain.state = mainMuted ? .on : .off
        applyKeyEquivalent(muteMain, combo: shortcuts.bindings[.speakerMute]?.combo)
        let muteHP = menu.addItem(withTitle: "Mute Headphones", action: #selector(toggleMuteTarget(_:)), keyEquivalent: "")
        muteHP.representedObject = OutputTarget.headphones.rawValue
        muteHP.state = hpMuted ? .on : .off
        applyKeyEquivalent(muteHP, combo: shortcuts.bindings[.headphoneMute]?.combo)
        let dimItem = menu.addItem(withTitle: "Dim Speakers", action: #selector(toggleDim(_:)), keyEquivalent: "")
        dimItem.state = speakerDim ? .on : .off
        applyKeyEquivalent(dimItem, combo: shortcuts.bindings[.speakerDim]?.combo)

        menu.addItem(.separator())

        // talkback + AU insert + global plug-in bypass
        let tbTitle = talkbackOn ? "Stop Talkback" : "Start Talkback"
        let tbItem = menu.addItem(withTitle: tbTitle, action: #selector(talkbackNow(_:)), keyEquivalent: "")
        applyKeyEquivalent(tbItem, combo: shortcuts.bindings[.talkbackToggle]?.combo)
        let insertTitle = server.running ? "Stop Plug-in Insert" : "Start Plug-in Insert"
        let insertItem = menu.addItem(withTitle: insertTitle,
                                      action: #selector(toggleInsert(_:)), keyEquivalent: "")
        insertItem.state = server.running ? .on : .off
        applyKeyEquivalent(insertItem, combo: shortcuts.bindings[.toggleInsert]?.combo)
        let bypassItem = menu.addItem(withTitle: "Bypass All Plug-ins",
                                       action: #selector(toggleBypassAll(_:)), keyEquivalent: "")
        bypassItem.state = server.bypassAll ? .on : .off
        applyKeyEquivalent(bypassItem, combo: shortcuts.bindings[.bypassAllPlugins]?.combo)

        menu.addItem(.separator())

        // windows
        menu.addItem(withTitle: "Quartet Control…", action: #selector(openControl(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")

        // warnings (only when something needs attention)
        if glue.state != .connected {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Reconnect to ApogeeGlue",
                          action: #selector(reconnect(_:)), keyEquivalent: "")
        }
        if server.running && server.tapSilent {
            menu.addItem(.separator())
            menu.addItem(withTitle: "⚠️ Tap silent — allow Quartet Buddy in",
                          action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "System Settings → Privacy → System Audio Recording",
                          action: #selector(openPrivacySettings(_:)), keyEquivalent: "")
        }
        if OSVolumeMirror.volumeControlMissing {
            menu.addItem(.separator())
            menu.addItem(withTitle: "⚠️ macOS volume control missing — power-cycle the Quartet",
                          action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Volume keys are dead until the Quartet is restarted (unplug/replug USB)",
                          action: nil, keyEquivalent: "").isEnabled = false
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quartet Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: Talkback indicator (animated red dot over the icon)

    private var talkbackDot: NSView?

    /// A layer-backed red circle over the icon's top-right corner, with a
    /// breathing opacity animation while talkback is on.
    private func updateTalkbackDot() {
        guard let button = statusItem?.button else { return }
        let show = talkbackOn && quartetPresence.isConnected
        if show {
            let size: CGFloat = 8
            if talkbackDot == nil {
                let dot = NSView(frame: .zero)
                dot.wantsLayer = true
                dot.layer?.backgroundColor = NSColor.systemRed.cgColor
                dot.layer?.cornerRadius = size / 2
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1.0
                breathe.toValue = 0.25
                breathe.duration = 0.65
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.layer?.add(breathe, forKey: "breathe")
                button.addSubview(dot, positioned: .above, relativeTo: nil)
                talkbackDot = dot
            }
            let b = button.bounds
            // NOTE: NSButtonCell.imageRect returns FLIPPED coordinates (y from
            // top) — feeding them into the button's normal bottom-origin view
            // coordinates mirrors the dot to the bottom. Compute the centered
            // icon frame directly instead.
            let iconFrame = NSRect(x: (b.width - 20) / 2, y: (b.height - 16) / 2,
                                   width: 20, height: 16)
            talkbackDot?.frame = NSRect(x: iconFrame.maxX - size + 3.5,
                                        y: iconFrame.maxY - size + 3,
                                        width: size, height: size)
        } else if let dot = talkbackDot {
            dot.removeFromSuperview()
            talkbackDot = nil
        }
    }

    // MARK: menu helpers (macOS HIG styling)

    /// Bold section header, like system menubar extras use.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        item.isEnabled = false
        return item
    }

    /// Show a registered hotkey as the item's key equivalent (when printable).
    private func applyKeyEquivalent(_ item: NSMenuItem, combo: HotKeyManager.Combo?) {
        guard let combo, let char = HotKeyManager.Combo.plainChar(combo.keyCode) else { return }
        var mask: NSEvent.ModifierFlags = []
        if combo.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if combo.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if combo.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if combo.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        item.keyEquivalent = char.lowercased()
        item.keyEquivalentModifierMask = mask
    }

    // MARK: - Actions

    @objc private func pickOutput(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let t = OutputTarget(rawValue: raw) {
            selectedOutput = t
        }
    }

    @objc private func clearMidiTrigger(_ sender: NSMenuItem) {
        midiTrigger = nil
        UserDefaults.standard.removeObject(forKey: "midiTrigger")
        refreshMenu()
    }

    // MARK: Launch at login

    private var wantsLaunchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "launchAtLogin") }
        set { UserDefaults.standard.set(newValue, forKey: "launchAtLogin") }
    }

    /// Re-register automatically if the user wants it but the registration
    /// is missing (e.g. after the app moved or was renamed).
    private func syncLoginItem() {
        guard wantsLaunchAtLogin, SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            QBLog.log("login item: re-registered automatically")
        } catch {
            QBLog.log("login item re-register error: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                wantsLaunchAtLogin = false
                QBLog.log("login item: unregistered")
            } else {
                try service.register()
                wantsLaunchAtLogin = true
                QBLog.log("login item: registered")
            }
        } catch {
            QBLog.log("login item error: \(error.localizedDescription)")
        }
        refreshMenu()
    }

    @objc private func reconnect(_ sender: NSMenuItem) {
        glue.connect()
    }

    @objc private func talkbackNow(_ sender: NSMenuItem) {
        toggleTalkback()
    }

    @objc private func toggleMidiMode(_ sender: NSMenuItem) {
        talkbackMomentary.toggle()
        UserDefaults.standard.set(talkbackMomentary, forKey: "momentary")
        refreshMenu()
    }

    @objc private func learnMIDI(_ sender: NSMenuItem) {
        learningMidi = true
        refreshMenu()
    }

    // Shortcut recording lives in the Settings window (Shortcuts pane) —
    // ShortcutManager owns registration and persistence.

    // MARK: - Mute / Dim (hardware, via ApogeeGlue)

    /// Hardware mute per output target (Speakers / Headphones).
    @objc private func toggleMuteTarget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = OutputTarget(rawValue: raw) else { return }
        let new = !(muted[t] ?? false)
        QBLog.log("mute: \(t.rawValue) \(new ? "on" : "off")")
        glue.setBool(id: t.muteId, new)
        muted[t] = new
        refreshMenu()
    }

    /// Hardware dim on the speakers (Out 1‑2), via the glue.
    @objc private func toggleDim(_ sender: NSMenuItem) {
        let new = !speakerDim
        QBLog.log("dim: speakers \(new ? "on" : "off")")
        glue.setBool(id: PathIds.active.hwout0Dim, new)
        speakerDim = new
        refreshMenu()
    }

    // MARK: - Device node flags (touchscreen settings + identify)

    /// The connected Quartet's own node from the latest glue tree (the
    /// node's type IS the serial — see PathIds.dev).
    /// The pad-action enum — COMPLETE, sweep-verified 11/7 (the daemon's
    /// own writes): the tree code (actionType<<16)|param → the device byte
    /// at 0x49 (wIndex = the pad 0-2) / 0x4b (wIndex 0 = the encoder push).
    // THE TRUE ENUMS — 1-BASED SEQUENTIAL, SEPARATE PER REGISTER (the
    // user's two tests + the live rule: THE TOGGLES ARE ENCODER-ONLY —
    // the pads can't do them, so 0x49's menu = the mute/dim/sum/sets
    // family and 0x4b's = the short mute+toggle list):
    //  • 0x49 (the pads A/B/C): 01=MuteSpk 02=MuteHP 03=MuteAll
    //    04=DimSpk 05=DimHP 06=DimAll 07=SumSpk 08=SumHP 09=SumAll
    //    0a=Clear 0b=Set1 0c=Set2 0d=Set3
    //  • 0x4b (the encoder push): 01=MuteSpk 02=MuteHP 03=MuteAll
    //    04=ToggleMuteSpkHP  (the byte 04 = the toggle — the capture!)
    static let padCodeToByte: [Int: UInt8] = [
        0x20002: 0x01, 0x20003: 0x02, 0x20004: 0x03,          // Mute Spk/HP/All
        0x30002: 0x04, 0x30003: 0x05, 0x30004: 0x06,          // Dim Spk/HP/All
        0x40002: 0x07, 0x40003: 0x08, 0x40004: 0x09,          // Sum Spk/HP/All
        0x60001: 0x0a,                                        // Clear Meters
        0x70005: 0x0b, 0x70006: 0x0c, 0x70007: 0x0d,          // Engage Set 1/2/3
    ]
    static let encoderCodeToByte: [Int: UInt8] = [
        0x20002: 0x01, 0x20003: 0x02, 0x20004: 0x03,          // Mute Spk/HP/All
        0x5000B: 0x04,                                        // Toggle Mute Spk/HP
    ]
    static let padByteToCode: [UInt8: Int] =
        Dictionary(uniqueKeysWithValues: padCodeToByte.map { ($1, $0) })
    static let encoderByteToCode: [UInt8: Int] =
        Dictionary(uniqueKeysWithValues: encoderCodeToByte.map { ($1, $0) })
    /// The pad's register: 0x49 wIndex = the pad (0-2); the encoder = 0x4b wI=0.
    static func padRegister(slot: Int) -> (reg: UInt8, index: UInt16) {
        slot < 3 ? (0x49, UInt16(slot)) : (0x4b, 0)
    }

    /// The device-node flag registers (11/7 sweep): peakHold=0x1f,
    /// overHold=0x20, lockHomeScreen=0x4a, keyboardVolumeControls=0x51.
    static func flagRegister(_ name: String) -> UInt8? {
        switch name {
        case "peakHold": return 0x1f
        case "overHold": return 0x20
        case "lockHomeScreen": return 0x4a
        case "keyboardVolumeControls": return 0x51
        default: return nil
        }
    }

    private func deviceNode() -> [String: Any]? {
        guard let tree = lastTree,
              let serial = GlueClient.quartetSerial(in: tree) else { return nil }
        return GlueClient.findNode(in: tree, type: serial)
    }

    /// Current boolean state of a device-node property (`peakHold`,
    /// `overHold`, `lockHomeScreen`, `identify`, …) for the Settings
    /// checkboxes. nil when no tree has arrived (checkboxes stay disabled).
    func deviceFlag(_ name: String) -> Bool? {
        guard let node = deviceNode(),
              let v = GlueClient.intProp(node, name) else { return nil }
        return v == 1
    }

    /// Write a device-node flag. Everything here is a 0/1 hardware
    /// preference (the touchscreen's settings page) — no level quantities,
    /// so the dB range-validation story doesn't apply.
    func setDeviceFlag(_ name: String, on: Bool) {
        // identify rides the direct-USB vendor request when the device is
        // reachable (no daemon needed — 11.6); the glue path stays the
        // fallback while ApogeeGlue holds the device exclusively.
        if name == "identify" {
            if tryDirectIdentify(on: on) { return }
        }
        guard let id = PathIds.dev(name) else {
            QBLog.log("device: \(name) — no serial connected, write dropped")
            return
        }
        QBLog.log("device: \(name) \(on ? "1" : "0")")
        glue.setBool(id: id, on)
    }

    /// The direct-USB identify blink (vendor request 0xB6): on now, off
    /// after 6 s (the daemon's timing). Returns false when the device
    /// can't be opened (the glue fallback applies).
    private func tryDirectIdentify(on: Bool) -> Bool {
        if !directUSB.opened && !directUSB.open() {
            QBLog.log("directUSB: unavailable — \(directUSB.lastError); falling back to glue")
            return false
        }
        guard directUSB.identify(on: on) else { return false }
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                _ = self?.directUSB.identify(on: false)
            }
        }
        return true
    }

    // MARK: - Talkback source (the "who's talking" input the helper uses)

    struct TalkbackSourceDescription {
        /// The selectable sources, in tree order — device name + its
        /// numberOfInputChannels.
        var sources: [(device: String, channels: Int)]
        /// Currently selected device name ("" when unknown).
        var selectedDevice: String
        /// Currently selected channel index.
        var selectedChannel: Int
    }

    /// Read the talkback subtree for the Settings ▸ Talkback picker.
    /// nil while no tree has arrived or the helper app section is absent.
    ///
    /// Tree layout (verified live): the source devices live UNDER the
    /// `talkbackSources` container node — Talkback → talkbackSources →
    /// Quartet / MacBook Air Microphone / … — not as Talkback's direct
    /// children. Reading Talkback's own children yielded the container
    /// itself as one bogus "source" (its `numberOfInputChannels` absent →
    /// always 1 channel → grayed channel picker).
    func talkbackDescription() -> TalkbackSourceDescription? {
        // 11.7 offline: the app's OWN model — the source = this Quartet,
        // 4 analog + 8 optical inputs; the selection = the stored engine
        // input. (The tree's Talkback node = the daemon's/helpers' — gone
        // offline.)
        if lastTree == nil {
            let saved = talkbackSourceInput
            // 12 inputs total: 4 analog + 8 optical (the mixer channels
            // 0-11 = exactly these — the talkback source = any of them)
            return TalkbackSourceDescription(sources: [("Quartet", 12)],
                                             selectedDevice: "Quartet",
                                             selectedChannel: saved)
        }
        guard let tree = lastTree,
              let talkback = GlueClient.findNode(in: tree, type: "Talkback"),
              let props = talkback["props"] as? [String: Any] else { return nil }
        // the container node, else the Talkback node itself (tolerates a
        // layout where the sources ARE direct children)
        var container = talkback
        if let srcNode = GlueClient.findNode(in: talkback, type: "talkbackSources") {
            container = srcNode
        }
        var sources: [(String, Int)] = []
        if let children = container["children"] as? [[String: Any]] {
            for child in children where (child["type"] as? String) != "talkbackSources" {
                guard let name = child["type"] as? String else { continue }
                let channels = GlueClient.intProp(child, "numberOfInputChannels") ?? 1
                sources.append((name, channels))
            }
        }
        let selected = props["selectedTalkbackSourceDevice"] as? String ?? ""
        let channel = props["selectedTalkbackSourceChannel"] as? Int ?? 0
        return TalkbackSourceDescription(sources: sources.map { ($0.0, $0.1) },
                                         selectedDevice: selected,
                                         selectedChannel: channel)
    }

    /// Pick a talkback source device (+ channel): writes the helper app's
    /// `selectedTalkbackSourceDevice` (string) and
    /// `selectedTalkbackSourceChannel` — the exact properties Apogee
    /// Control 2's Talkback pane edits. Verified against the capture's
    /// live values ("Quartet" + channel 0); the sources' own `active`
    /// flags are presence bits — never written.
    func selectTalkbackSource(device: String, channel: Int) {
        // 11.7 offline: the app's engine stores the source INPUT directly
        if lastTree == nil {
            talkbackSourceInput = max(0, min(11, channel))
            QBLog.log("talkback: source '\(device)' channel \(channel) stored (the engine's input \(talkbackSourceInput + 1))")
            return
        }
        let devId = PathIds.app("Apogee Talkback helper/Talkback/selectedTalkbackSourceDevice")
        let chId = PathIds.app("Apogee Talkback helper/Talkback/selectedTalkbackSourceChannel")
        QBLog.log("talkback: source '\(device)' channel \(channel)")
        glue.setString(id: devId, device)
        glue.setInt(id: chId, Int32(channel))
    }

    // MARK: - Windows

    private lazy var settingsWindow = SettingsWindowController()

    /// The single unified audio-control window ("Quartet Control").
    @objc private func openControl(_ sender: NSMenuItem) {
        QuartetControlController.shared.show()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        settingsWindow.show()
    }

    /// Wire the Quartet Control window's callbacks to this delegate's plumbing.
    private func setupConsoleWindow() {
        let control = QuartetControlController.shared
        control.onWriteDouble = { [weak self] id, value in
            guard let self else { return }
            if self.glue.state == .connected { self.glue.setDouble(id: id, value); return }
            // offline: the known path-ids translate to the vendor requests
            let active = PathIds.active
            if id == active.hwout0Gain { _ = self.writeGain(.mainOut, value); return }
            if id == active.hwout1Gain { _ = self.writeGain(.headphones, value); return }
            // the input preamp gains: mic + instrument = the same vendor command
            for (input, ids) in active.hwinMicGain where ids == id {
                _ = self.directUSB.setInputGain(input: UInt16(input), db: value); return
            }
            for (input, ids) in active.hwinInstGain where ids == id {
                _ = self.directUSB.setInputGain(input: UInt16(input), db: value); return
            }
            // 11.7 sweep: the dim LEVEL doesn't exist on the wire (dim is a
            // bool at 0x40) — the old float writes were a misdecode; drop them
            QBLog.log("transport: no direct mapping for double write (glue offline) — dropped")
            QBLog.log("transport: no direct mapping for double write (glue offline) — dropped")
        }
        // (The routing cards' trim knobs are SOFTWARE trim, applied inside
        // InsertServer's chain. The firmware's line-out trim lives in
        // Settings ▸ Quartet ▸ Outputs, wired in setupSettingsWindow.)
        control.onWriteBool = { [weak self] id, value in
            guard let self else { return }
            if self.glue.state == .connected { self.glue.setBool(id: id, value); return }
            let active = PathIds.active
            if id == active.hwout0Mute { _ = self.writeMute(.mainOut, value); return }
            if id == active.hwout1Mute { _ = self.writeMute(.headphones, value); return }
            if id == PathIds.dev("identify") { _ = self.tryDirectIdentify(on: value); return }
            // 11.7 sweep-verified: dim = 0x40, sum = 0x46 (wIndex = the output)
            if id == active.hwout0Dim { _ = self.directUSB.setOutputFlag(0x40, output: 0, on: value); return }
            if id == active.hwout1Dim { _ = self.directUSB.setOutputFlag(0x40, output: 1, on: value); return }
            if let sum0 = active.hwout0Sum, id == sum0 { _ = self.directUSB.setOutputFlag(0x46, output: 0, on: value); return }
            if let sum1 = active.hwout1Sum, id == sum1 { _ = self.directUSB.setOutputFlag(0x46, output: 1, on: value); return }
            // the input-side bools — sweep-verified registers, no ids needed:
            for (input, ids) in active.hwinPhantom where ids == id {
                _ = self.directUSB.setInputFlag(0x15, input: UInt16(input), on: value); return
            }
            for (input, ids) in active.hwinSoftLimit where ids == id {
                _ = self.directUSB.setInputFlag(0x11, input: UInt16(input), on: value); return
            }
            for (input, ids) in active.hwinPolarity where ids == id {
                _ = self.directUSB.setInputFlag(0x13, input: UInt16(input), on: value); return
            }
            QBLog.log("transport: no direct mapping for bool write (glue offline) — dropped")
        }
        control.onWriteInt = { [weak self] id, value in
            guard let self else { return }
            // offline: the captured refLevel ids translate to the 0x36 writes
            if self.glue.state != .connected {
                for (input, ids) in PathIds.active.hwinRefLevel where ids == id {
                    if let raw = DirectUSBClient.deviceByte(forAppMode: Int(value)) {
                        _ = self.directUSB.setInputType(input: UInt16(input), raw: raw)
                    }
                    return
                }
            }
            self.glue.setInt(id: id, value)
        }
        control.onWriteString = { [weak self] id, value in self?.glue.setString(id: id, value) }
        control.onRequestTree = { [weak self] in self?.glue.requestTree() }
        control.onSeedTree = { [weak self] in self?.lastTree }
        control.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        // Talkback chip in the monitor strip — same path as the hotkeys.
        control.onTalkback = { [weak self] on in self?.setTalkback(on) }
        control.talkbackState = { [weak self] in self?.talkbackOn ?? false }
        // OS volume-target readback — drives the blue marker on the
        // monitor groups (selectedOutput has a didSet → refreshMenu →
        // controller.refresh → updateCardHighlights, so it stays live)
        control.volumeTarget = { [weak self] in
            guard let self else { return 0 }
            return self.selectedOutput == .headphones ? 1 : 0
        }
        control.readStatusDirect = { [weak self] in self?.directUSB.readStatus() }
        control.readChangeBitmapDirect = { [weak self] in self?.directUSB.readChangeBitmap() }
        // the HID push: the encoder/touchscreen events → the instant sweep
        // (control = this function's local — the shared singleton)
        directUSB.startHIDWatcher { [weak control] in
            control?.triggerDeviceSweep()
        }
        control.readInputDirect = { [weak self] i, bReq in
            // i ≥ 100 = the monitor slot (i-100); below = the input index
            let idx = i >= 100 ? UInt16(i - 100) : UInt16(i)
            return self?.directUSB.readInput(input: idx, bRequest: bReq)
        }
        control.isDirectMode = { [weak self] in
            guard let self else { return false }
            return self.glue.state != .connected && self.directUSB.hasSession
        }
        control.onDirectPhantom = { [weak self] i, on in
            guard let self else { return false }
            if self.glue.state == .connected, let id = PathIds.active.hwinPhantom[i] {
                self.glue.setBool(id: id, on); return true
            }
            return self.directUSB.setPhantom(input: UInt16(i), on: on)
        }
        control.onDirectInputFlag = { [weak self] reg, i, on in
            guard let self else { return false }
            return self.directUSB.setInputFlag(reg, input: UInt16(i), on: on)
        }
        control.onDirectInputGain = { [weak self] i, v in
            guard let self else { return false }
            if self.glue.state == .connected, let id = PathIds.active.hwinMicGain[i] {
                self.glue.setDouble(id: id, v); return true
            }
            let ok = self.directUSB.setInputGain(input: UInt16(i), db: v)
            if !ok { QBLog.log("directUSB: input gain write failed: \(self.directUSB.lastError ?? "?")") }
            return ok
        }
        control.onDirectInputType = { [weak self] i, v in
            guard let self else { return false }
            // Line modes (+4/−10): the device register is untouched (pending decode)
            guard let raw = DirectUSBClient.deviceByte(forAppMode: Int(v)) else {
                QBLog.log("transport: input \(i + 1) mode \(v) = Line — 0x36 not involved (pending)")
                return true
            }
            let ok = self.directUSB.setInputType(input: UInt16(i), raw: raw)
            QBLog.log("transport: directUSB input \(i + 1) mode \(v) → 0x36=\(raw) \(ok ? "ok" : "FAILED")")
            return ok
        }
        control.isGlueConnected = { [weak self] in
            guard let self else { return false }
            if self.glue.state == .connected, self.quartetPresence.isConnected { return true }
            // offline: the direct-USB session makes the device controllable
            return self.quartetPresence.isConnected && self.ensureDirectUSB()
        }
        // Auto Gain: the engine writes the preamp through the control
        // window's plumbing and reports its status in the status line
        // (failures auto-clear, the success line lingers a while).
        let engine = AutoGainEngine.shared
        engine.writeGain = { i, v in QuartetControlController.shared.applyAutoGain(i, v) }
        engine.onStatus = { _, line, detail, remaining in
            QuartetControlController.shared.showAutoStatus(line, clearAfter: nil, detail: detail,
                                                           remaining: remaining)
        }
        engine.onFinished = { input, line, detail, gain, outcome in
            QuartetControlController.shared.showAutoGainResult(line, detail: detail,
                                                               gain: gain, input: input,
                                                               outcome: outcome)
        }
    }

    /// Wire the Settings window's callbacks to this delegate's plumbing.
    /// (Shortcut bindings are handled by ShortcutManager directly — the
    /// Settings window holds a reference to it and assigns through it.)
    private func setupSettingsWindow() {
        settingsWindow.shortcuts = shortcuts
        settingsWindow.onMidiLearn = { [weak self] in
            self?.learningMidi = true
            self?.refreshMenu()
        }
        settingsWindow.onMidiClear = { [weak self] in
            self?.learningMidi = false
            self?.midiTrigger = nil
            UserDefaults.standard.removeObject(forKey: "midiTrigger")
        }
        // Learn state + cancel (the MIDI watcher is owned here).
        settingsWindow.isMidiLearning = { [weak self] in self?.learningMidi ?? false }
        settingsWindow.onMidiCancel = { [weak self] in
            guard self?.learningMidi == true else { return }
            self?.learningMidi = false
            self?.refreshMenu()
        }
        // Device-node flags (Settings ▸ Quartet ▸ Controls): the
        // window reads raw dev-node props and asks us for each write.
        settingsWindow.readDeviceProps = { [weak self] in
            guard let self else { return nil }
            if let node = self.deviceNode(), let props = node["props"] as? [String: Any] {
                return props
            }
            // 11.6 offline: the tree is gone (no daemon) but the direct USB
            // session owns the device — report PRESENT with no tree props.
            // The tree-fed flags degrade to disabled; the page shows connected.
            return self.directUSB.hasSession ? [:] : nil
        }
        settingsWindow.writeDeviceFlag = { [weak self] name, on in
            self?.setDeviceFlag(name, on: on)
        }
        // 11.7: the device-flag registers (sweep-verified) — the offline path
        settingsWindow.readFlagDirect = { [weak self] name in
            guard let self, let reg = Self.flagRegister(name) else { return nil }
            return self.directUSB.readInput(input: 0, bRequest: reg)
        }
        settingsWindow.writeFlagDirect = { [weak self] name, on in
            guard let self, let reg = Self.flagRegister(name) else { return false }
            let ok = self.directUSB.setInputFlag(reg, input: 0, on: on)
            QBLog.log("settings: flag \(name) → 0x\(String(reg, radix: 16))=\(on ? 1 : 0) \(ok ? "ok" : "FAILED")")
            return ok
        }
        // Talkback source picker (Settings ▸ Talkback).
        settingsWindow.readTalkback = { [weak self] in self?.talkbackDescription() }
        settingsWindow.writeTalkbackSource = { [weak self] device, channel in
            self?.selectTalkbackSource(device: device, channel: channel)
        }
        // Hardware mixers (Settings ▸ Quartet ▸ Hardware Mixers):
        // VERIFIED 11/8 — Mixer 1 = route byte 4, Mixer 2 = byte 5. The
        // mixers' channel gains live in the 0x10 blocks, ONE BLOCK PER
        // STEREO SIDE, 14 slots of (gain, marker): slots 0-11 = the
        // inputs, SLOT 12 = THE PLAYBACK (the tree's playback.mixerChannel
        // = 12!) — the stereo playback spans the side blocks: L block's
        // slot 12 = playback L, R block's slot 13 = playback R (factory
        // 0x20 = −16 dB). Mixer 1 = blocks 0 (L) + 1 (R), Mixer 2 = 2 (L)
        // + 3 (R). PAN = the L/R gain difference. The 0x4C cells gate
        // NOTHING on the mixer routes (the playback-gating matrix v2:
        // sealing w0/w1 ch12/13 never silenced the bus).
        settingsWindow.readMixer = { [weak self] plane in
            guard let self, self.directUSB.opened else { return nil }
            let lWI = UInt16(plane == 0 ? 0 : 2)
            let rWI = UInt16(plane == 0 ? 1 : 3)
            let lBlock = self.directUSB.readBlock(index: lWI, bRequest: 0x10, length: 28)
            let rBlock = self.directUSB.readBlock(index: rWI, bRequest: 0x10, length: 28)
            return (0...12).map { ch -> (ch: Int, lFader: Int, rFader: Int, present: Bool) in
                let present = lBlock != nil
                if ch <= 11 {
                    return (ch: ch, lFader: lBlock.flatMap { Int($0[ch * 2]) } ?? 0,
                            rFader: rBlock.flatMap { Int($0[ch * 2]) } ?? 0, present: present)
                }
                // the Playback row = slot 12 of each side block
                return (ch: ch, lFader: lBlock.flatMap { Int($0[24]) } ?? 0,
                        rFader: rBlock.flatMap { Int($0[26]) } ?? 0, present: present)
            }
        }
        settingsWindow.writeMixerGains = { [weak self] plane, ch, lByte, rByte in
            guard let self else { return }
            let lWI = UInt16(plane == 0 ? 0 : 2)
            let rWI = UInt16(plane == 0 ? 1 : 3)
            // the channel's slot per side block: inputs 0-11; the playback
            // = the L block's slot 12 and the R block's slot 13 (stereo
            // channel spanning the two side blocks)
            let lSlot = Int(ch) * 2
            let rSlot = (ch == 12 ? 13 : Int(ch)) * 2
            for (wI, byte, side, slot) in [(lWI, lByte, "L", lSlot), (rWI, rByte, "R", rSlot)] {
                guard var block = self.directUSB.readBlock(index: wI,
                                                           bRequest: 0x10, length: 28) else { continue }
                block[slot] = byte   // the marker byte stays verbatim
                let ok = self.directUSB.writeBlock(index: wI, bRequest: 0x10, bytes: block)
                let rb = self.directUSB.readBlock(index: wI, bRequest: 0x10, length: 28)
                    .map { String($0[slot]) } ?? "nil"
                QBLog.log("mixer \(plane) \(ch == 12 ? "playback" : "in \(ch + 1)") \(side) slot \(slot / 2) ← \(byte) (\(Int(byte) - 48) dB) \(ok ? "ok" : "FAILED") rb \(rb)")
            }
        }
        // Line-out hardware levels (Settings ▸ Quartet ▸ Outputs):
        // read the tree's hwout2..7 analogRefLevel, write int32 via glue.
        settingsWindow.readLineOutLevels = { [weak self] in
            guard let self else { return [] }
            // 11.7: with the glue down the tree is a STALE snapshot — the
            // device registers are the truth
            if self.glue.state != .connected {
                return (0..<6).map { i -> (name: String, refLevel: Int?) in
                    let v = self.directUSB.readInput(input: UInt16(i), bRequest: 0xb6)
                    return ("Analog Out \(i + 1)", v.map { $0 == 0 ? 2 : 3 })
                }
            }
            if let dev = self.deviceNode() {
                return (0..<6).map { i -> (name: String, refLevel: Int?) in
                    guard let node = GlueClient.findNode(in: dev, type: "hwout\(i + 2)") else {
                        return ("Analog Out \(i + 1)", nil)
                    }
                    let name = (node["props"] as? [String: Any])?["name"] as? String
                        ?? "Analog Out \(i + 1)"
                    return (name, GlueClient.intProp(node, "analogRefLevel"))
                }
            }
            // 11.7 offline: the ref-level bit per output (0xb6, wIndex = out−2;
            // sweep-verified on Analog Out 1, +4=0/−10=1)
            return (0..<6).map { i -> (name: String, refLevel: Int?) in
                let v = self.directUSB.readInput(input: UInt16(i), bRequest: 0xb6)
                return ("Analog Out \(i + 1)", v.map { $0 == 0 ? 2 : 3 })
            }
        }
        settingsWindow.writeLineOutLevel = { [weak self] i, v in
            guard let self else { return }
            if self.glue.state == .connected, let id = PathIds.dev("hwout/hwout\(i + 2)/analogRefLevel") {
                QBLog.log("settings: hwout\(i + 2).analogRefLevel = \(v)")
                self.glue.setInt(id: id, Int32(v))
                return
            }
            // 11.7 offline: 0xb6 wIndex = out−2, +4dBu=0 / −10dBV=1
            let ok = self.directUSB.setOutputFlag(0xb6, output: UInt16(i), on: v == 3)
            QBLog.log("settings: hwout\(i + 2).analogRefLevel = \(v) via directUSB (\(ok ? "ok" : "FAILED"))")
        }
        // Line-out firmware TRIM (Settings ▸ Quartet ▸ Outputs).
        // The strips' `trim` is a dB double applied by the firmware at the
        // DAC — downstream of everything macOS sends — so it listens to
        // ALL apps, not just this one's chain. Rows are PAIRS of the mono
        // strips (Main 1-2 = hwout2+hwout3, Out 3-4 = hwout4+hwout5,
        // Out 5-6 = hwout6+hwout7 — the strip behind jack N is
        // hwoutN+1, and the tree exposes no strips beyond hwout7, so the
        // headphone jack has no trim); a write goes to BOTH strips so the
        // pair tracks together. Reads take the left strip's value: a pair
        // whose strips were trimmed apart on the touchscreen shows the
        // left one until touched.
        settingsWindow.readHwoutTrims = { [weak self] in
            guard let self else { return [] }
            // 11.7: the glue down ⇒ the registers, never the stale snapshot
            if self.glue.state != .connected {
                return (0...2).map { pair -> (name: String, trim: Double?) in
                    let idx = 2 * pair      // hwout2, hwout4, hwout6 → 0, 2, 4
                    let v = self.directUSB.readInput(input: UInt16(idx), bRequest: 0x18)
                    return ("Out \(2 * pair + 1) / \(2 * pair + 2)",
                            v.map { -Double(Int($0)) / 10.0 })
                }
            }
            guard let dev = self.deviceNode() else {
                // 11.7 offline: the trim registers (0x18, |dB|×10); the pair's
                // value = the LEFT strip's byte
                return (0...2).map { pair -> (name: String, trim: Double?) in
                    let idx = 2 * pair      // hwout2, hwout4, hwout6 → 0, 2, 4
                    let v = self.directUSB.readInput(input: UInt16(idx), bRequest: 0x18)
                    return ("Out \(2 * pair + 1) / \(2 * pair + 2)",
                            v.map { -Double(Int($0)) / 10.0 })
                }
            }
            return (0...2).map { pair -> (name: String, trim: Double?) in
                let left = GlueClient.findNode(in: dev, type: "hwout\(2 * pair + 2)")
                let right = GlueClient.findNode(in: dev, type: "hwout\(2 * pair + 3)")
                let propsL = left.flatMap { $0["props"] as? [String: Any] }
                let propsR = right.flatMap { $0["props"] as? [String: Any] }
                let nameL = (propsL?["name"] as? String) ?? "Out \(2 * pair + 1)"
                let nameR = (propsR?["name"] as? String) ?? "Out \(2 * pair + 2)"
                return ("\(nameL) / \(nameR)", left.flatMap { GlueClient.doubleProp($0, "trim") })
            }
        }
        settingsWindow.writeHwoutTrim = { [weak self] pair, db in
            guard let self else { return }
            let db = min(AppDelegate.hwoutTrimMax, max(AppDelegate.hwoutTrimMin, db))
            if self.glue.state == .connected {
                for h in Self.hwoutTrimNodes[pair] ?? [] {
                    guard let id = PathIds.dev("hwout/\(h)/trim") else { continue }
                    self.glue.setDouble(id: id, db)
                }
            } else {
                // 11.7 offline: 0x18 wIndex = out−2, value = |dB|×10 (attenuation)
                for h in Self.hwoutTrimNodes[pair] ?? [] {
                    let idx = Int(h.dropFirst("hwout".count)) ?? 0
                    let ok = self.directUSB.setOutputTrim(output: UInt16(max(0, idx - 2)), db: db)
                    QBLog.log("settings: \(h).trim = \(db) via directUSB (\(ok ? "ok" : "FAILED"))")
                }
            }
            self.pushedHardwareTrims[pair] = db
            UserDefaults.standard.set(db, forKey: "hwout.trim.\(pair)")
            QBLog.log(String(format: "settings: hardware trim pair %d → %.1f dB", pair, db))
        }
        // Settings ▸ Quartet ▸ Channel Names — hardware inputs/outputs
        // (glue string writes) and the app-side stereo-pair names.
        settingsWindow.readNames = { [weak self] in
            guard let self, let dev = self.deviceNode() else { return nil }
            var out: [String] = []
            for i in 0..<4 {
                out.append(GlueClient.findNode(in: dev, type: "hwin\(i)")
                    .flatMap { ($0["props"] as? [String: Any])?["name"] as? String } ?? "")
            }
            for i in 0..<8 {
                out.append(GlueClient.findNode(in: dev, type: "hwout\(i)")
                    .flatMap { ($0["props"] as? [String: Any])?["name"] as? String } ?? "")
            }
            out.append(contentsOf: (0..<4).map { QuartetControlController.savedName($0) })
            out.append(contentsOf: (0..<8).map { AdatGainEngine.adatName($0) })
            return out
        }
        settingsWindow.writeName = { [weak self] i, name in
            guard let self else { return }
            switch i {
            case 0..<4:
                if let id = PathIds.dev("hwin/hwin\(i)/name") {
                    self.glue.setString(id: id, name)
                    QBLog.log("settings: hwin\(i).name = '\(name)'")
                }
            case 4..<12:
                let o = i - 4
                if let id = PathIds.dev("hwout/hwout\(o)/name") {
                    self.glue.setString(id: id, name)
                    QBLog.log("settings: hwout\(o).name = '\(name)'")
                }
            case 12..<16:
                let p = i - 12
                QuartetControlController.setSavedName(p, name)
                QBLog.log("settings: pair \(p) name = '\(name)'")
            default:
                let a = i - 16
                guard a >= 0, a < 8 else { return }
                AdatGainEngine.setAdatName(a, name)
                QBLog.log("settings: ADAT \(a + 1) name = '\(name)'")
                QuartetControlController.shared.refresh()
            }
        }
        // Front-panel pad assignments (Settings ▸ Quartet ▸ Controls):
        // the tree's actionButtons children — the remap path
        // live-verified Oct 26 2026 (probe write → pad followed).
        settingsWindow.readPadAssignments = { [weak self] in
            // 11.7 POWER-CYCLE VERIFIED: the device's flash = the store —
            // the 0x49/0x4b registers hold the assignments across reboots
            // and even moving the unit to another computer. The registers
            // ARE the truth; the read = the live display.
            guard let self else { return [Int?](repeating: nil, count: 4) }
            return (0..<4).map { slot in
                let (reg, idx) = Self.padRegister(slot: slot)
                // the encoder's reverse map = its own short enum
                return self.directUSB.readInput(input: idx, bRequest: reg)
                    .flatMap { slot < 3 ? Self.padByteToCode[$0] : Self.encoderByteToCode[$0] }
            }
        }
        settingsWindow.writePadAssignment = { [weak self] slot, value in
            guard let self else { return }
            let names = ["Touchpad_A", "Touchpad_B", "Touchpad_C", "Encoder_Push"]
            guard slot >= 0, slot < names.count else { return }
            // 11.7: ONE write — the device's flash commits it (the
            // power-cycle test verified the persistence). The encoder's
            // enum = its own short list (the toggles live there only).
            let byte = slot < 3 ? Self.padCodeToByte[value]
                                : Self.encoderCodeToByte[value]
            guard let byte else {
                QBLog.log("settings: pad code \(String(value, radix: 16)) has no device enum byte for this slot")
                return
            }
            let (reg, idx) = Self.padRegister(slot: slot)
            let ok = self.directUSB.setRawByte(reg, index: idx, byte: byte)
            QBLog.log("settings: pad \(names[slot]) ← \(String(value, radix: 16)) (0x\(String(reg, radix: 16))=\(String(byte, radix: 16))) \(ok ? "ok — the device remembers" : "FAILED")")
        }
        // 11.7: HARDWARE OUTPUT ROUTING — the 0x53 register, the 0-based
        // source index (0=PB1-2 … 3=PB7-8, 4=Mixer1, 5=Mixer2). The HP's
        // slot = 3 in the monitor space (the daemon's own writes); the
        // analog pairs = out−2 on BOTH strips. The state = the app's saved
        // value (the device's 0x53 read-back doesn't parse as the index).
        settingsWindow.readHwoutRouting = { [weak self] in
            guard let self else { return [] }
            return (0..<4).map { slot in
                let v = UserDefaults.standard.object(forKey: "hwout.route.\(slot)") as? Int
                return v ?? (slot == 3 ? 3 : slot)   // the HP's default = PB 7-8; the pairs = their own PB
            }
        }
        settingsWindow.writeHwoutRouting = { [weak self] slot, source in
            guard let self else { return }
            // the PAIR slots (the user's live mapping): 0=Out1-2(Main),
            // 1=Out3-4, 2=Out5-6, 3=Headphones — ONE write per pair
            let indexes: [UInt16] = [UInt16(slot)]
            for wI in indexes {
                let ok = self.directUSB.setRawByte(0x53, index: wI, byte: UInt8(source))
                QBLog.log("settings: routing slot \(slot) → 0x53 wI=\(wI) =\(source) \(ok ? "ok" : "FAILED")")
            }
            UserDefaults.standard.set(source, forKey: "hwout.route.\(slot)")
        }
        // (the routing's boot push lives in pushSavedRouting() — called
        // from the direct-session open)
        settingsWindow.writePadAssignment = { [weak self] slot, value in
            guard let self else { return }
            let names = ["Touchpad_A", "Touchpad_B", "Touchpad_C", "Encoder_Push"]
            guard slot >= 0, slot < names.count else { return }
            // 11.7: ONE write — the device's flash commits it (the
            // power-cycle test verified the persistence). The encoder's
            // enum = its own short list (the toggles live there only).
            let byte = slot < 3 ? Self.padCodeToByte[value]
                                : Self.encoderCodeToByte[value]
            guard let byte else {
                QBLog.log("settings: pad code \(String(value, radix: 16)) has no device enum byte for this slot")
                return
            }
            let (reg, idx) = Self.padRegister(slot: slot)
            let ok = self.directUSB.setRawByte(reg, index: idx, byte: byte)
            QBLog.log("settings: pad \(names[slot]) ← \(String(value, radix: 16)) (0x\(String(reg, radix: 16))=\(String(byte, radix: 16))) \(ok ? "ok — the device remembers" : "FAILED")")
        }
        NotificationCenter.default.addObserver(forName: .init("qb.momentaryChanged"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.talkbackMomentary = UserDefaults.standard.bool(forKey: "momentary")
        }
    }

    // MARK: - Insert shortcuts

    /// Start/stop the AU insert and persist the choice — the ONLY writer of
    /// "insertEnabled" (launch + Quartet (re)connect read it back). Restored
    /// from the pre-redesign menu; losing it left no way to start the insert
    /// (routing stayed greyed out on machines that never had the old build).
    @objc private func toggleInsert(_ sender: NSMenuItem) {
        let on = !InsertServer.shared.running
        UserDefaults.standard.set(on, forKey: "insertEnabled")
        InsertServer.shared.setRunning(on)
    }

    @objc private func toggleBypassAll(_ sender: NSMenuItem) {
        InsertServer.shared.setBypassAll(!InsertServer.shared.bypassAll)
    }

    @objc private func openPrivacySettings(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording")!)
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(QBLog.url)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // apply any coalesced rebuild now — never rebuild while a menu is open
        if menuRefreshPending {
            menuRefreshPending = false
            rebuildMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // state may change while the menu is open; refresh after close
        DispatchQueue.main.async { self.refreshMenu() }
    }
}

private extension Data {
    func readDouble() -> Double {
        guard count >= 8 else { return 0 }
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(self[startIndex + i])
        }
        return Double(bitPattern: v)
    }
}
