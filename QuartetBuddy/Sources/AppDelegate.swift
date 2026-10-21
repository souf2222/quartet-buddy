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
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    let glue = GlueClient()
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
    /// RANGE-VALIDATED: a wedged Apogee driver makes CoreAudio reads return
    /// garbage (a -255 dB sentinel was observed live, Oct 19 2026), which
    /// this path would otherwise echo into the hardware fader in a feedback
    /// loop — an out-of-range write that took the whole unit down (dark
    /// touchscreen). Never forward anything outside the fader's -64…0 dB.
    private func osSliderMoved(to db: Double) {
        guard !PathIdSetupController.shared.sessionActive,
              !QuartetControlController.shared.isLearning else { return }   // a capture is listening
        guard gainKnown else { return }
        guard case .connected = glue.state else { return }   // bridge down: let tree re-sync later
        guard Self.isValidDB(db) else {
            QBLog.log(String(format: "slider sync: IGNORED bogus slider level %.1f dB (driver wedge?)", db))
            return
        }
        let target = selectedOutput
        let current = gain[target] ?? 0
        guard abs(db - current) > 0.5 else { return }        // own writes / driver rounding
        QBLog.log(String(format: "slider sync: slider %.1f dB -> Quartet %@ (was %.1f)",
                         db, target.rawValue, current))
        glue.setDouble(id: target.gainId, db)
        gain[target] = db
        lastSliderDB = db
        refreshMenu()
    }

    /// The macOS mute changed (F10, Control Center): apply it to the
    /// Quartet's hardware mute. Normally one-way (see OSVolumeMirror's
    /// header); the one exception is a target switch, where the OS mute is
    /// written once so the macOS display matches the newly selected output.
    private func osMuteChanged(to m: Bool) {
        guard !PathIdSetupController.shared.sessionActive,
              !QuartetControlController.shared.isLearning else { return }   // a capture is listening
        guard gainKnown else { return }
        guard case .connected = glue.state else { return }
        let target = selectedOutput
        let current = muted[target] ?? false
        guard m != current else { return }
        QBLog.log("mute sync: OS mute \(m ? "on" : "off") -> Quartet \(target.rawValue)")
        glue.setBool(id: target.muteId, m)
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
        deviceMonitor.start()
        quartetPresence.onChange = { [weak self] connected in
            QBLog.log("quartet presence: \(connected ? "connected" : "disconnected")")
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

    private func setupGlue() {
        glue.onState = { [weak self] state in
            self?.refreshMenu()
            if state == .disconnected {
                self?.scheduleReconnect()
            }
        }
        glue.onTree = { [weak self] tree in
            guard let self else { return }
            self.lastTree = tree
            // The device node's type is its serial — path-ids are hashed
            // per-serial, so pick this unit's id table before anything else.
            PathIds.select(serial: GlueClient.quartetSerial(in: tree))
            if let hw0 = GlueClient.findNode(in: tree, type: "hwout0"),
               let hw1 = GlueClient.findNode(in: tree, type: "hwout1") {
                self.gain[.mainOut] = GlueClient.doubleProp(hw0, "gain") ?? 0
                self.gain[.headphones] = GlueClient.doubleProp(hw1, "gain") ?? 0
                self.muted[.mainOut] = (GlueClient.intProp(hw0, "mute") ?? 0) == 1
                self.speakerDim = (GlueClient.intProp(hw0, "dim") ?? 0) == 1
                self.speakerSum = (GlueClient.intProp(hw0, "sum") ?? 0) == 1
                self.muted[.headphones] = (GlueClient.intProp(hw1, "mute") ?? 0) == 1
                self.headphoneDim = (GlueClient.intProp(hw1, "dim") ?? 0) == 1
                self.headphoneSum = (GlueClient.intProp(hw1, "sum") ?? 0) == 1
                self.gainKnown = true
                self.syncMacSlider(force: true)
            }
            if let tb = GlueClient.findNode(in: tree, type: "Talkback"),
               let props = tb["props"] as? [String: Any],
               let on = props["talkbackOn"] as? Bool {
                self.talkbackOn = on
            }
            // full-state sync for the Quartet Control window (inputs + monitors)
            QuartetControlController.shared.updateTree(tree)
            self.refreshMenu()
        }
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
        glue.setBool(id: PathIds.talkbackOn, !talkbackOn)
        talkbackOn = !talkbackOn
        refreshMenu()
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
        case .toggleIncludeSource: control.shortcutToggleIncludeSource()

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
    private func setTalkback(_ on: Bool) {
        guard on != talkbackOn else { return }
        glue.setBool(id: PathIds.talkbackOn, on)
        talkbackOn = on
        refreshMenu()
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
                self.glue.setBool(id: PathIds.talkbackOn, event.isDown)
                self.talkbackOn = event.isDown
                self.refreshMenu()
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
        statusItem.menu = menu
        menu.delegate = self
        rebuildMenu()
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

    private func rebuildMenu() {
        menu.removeAllItems()

        // menubar icon + tooltip
        statusItem?.button?.title = ""
        let appActive = quartetPresence.isConnected && glue.state == .connected
        statusItem?.button?.image = LogoIcon.image(headphonesSelected: selectedOutput == .headphones,
                                                    active: appActive)
        updateTalkbackDot()
        let mainGain = gain[.mainOut] ?? 0
        let hpGain = gain[.headphones] ?? 0
        statusItem?.button?.toolTip =
            "Main Out \(String(format: "%.1f", mainGain)) dB · HP \(String(format: "%.1f", hpGain)) dB · Talkback \(talkbackOn ? "on" : "off")"

        // header — name + live connection state
        menu.addItem(sectionHeader("Quartet Buddy"))
        let stateLine: String
        if !quartetPresence.isConnected { stateLine = "Quartet Not Connected" }
        else if glue.state != .connected { stateLine = "Glue Offline" }
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
        control.onWriteDouble = { [weak self] id, value in self?.glue.setDouble(id: id, value) }
        control.onWriteBool = { [weak self] id, value in self?.glue.setBool(id: id, value) }
        control.onWriteInt = { [weak self] id, value in self?.glue.setInt(id: id, value) }
        control.onRequestTree = { [weak self] in self?.glue.requestTree() }
        control.onSeedTree = { [weak self] in self?.lastTree }
        control.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        // Talkback chip in the monitor strip — same path as the hotkeys.
        control.onTalkback = { [weak self] on in self?.setTalkback(on) }
        control.talkbackState = { [weak self] in self?.talkbackOn ?? false }
        control.isGlueConnected = { [weak self] in
            guard let self else { return false }
            return self.glue.state == .connected && self.quartetPresence.isConnected
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
        engine.onFinished = { _, line, detail, gain, outcome in
            QuartetControlController.shared.showAutoGainResult(line, detail: detail,
                                                               gain: gain, outcome: outcome)
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
            self?.midiTrigger = nil
            UserDefaults.standard.removeObject(forKey: "midiTrigger")
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
