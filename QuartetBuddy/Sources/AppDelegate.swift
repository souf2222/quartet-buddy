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
// AppDelegate.setupGlue). For a NEW Quartet: connect it, run
// tools/watch_ids.py, wiggle the controls, and add the captured ids here.
enum PathIds {
    struct DeviceTable {
        let hwout0Gain: [UInt8]   // Main Out fader (double)
        let hwout1Gain: [UInt8]   // Headphones fader (double)
        let hwout0Mute: [UInt8]   // Main Out mute (bool)
        let hwout1Mute: [UInt8]   // Headphones mute (bool)
        let hwout0Dim: [UInt8]    // Main Out dim (bool)
    }

    /// App-scoped — identical on every device.
    static let talkbackOn: [UInt8] = [0x8f, 0x0a, 0x6a, 0x00]

    /// The original captured unit (the table this project was built on).
    private static let defaultTable = DeviceTable(
        hwout0Gain: [0xc5, 0xa2, 0xbd, 0xb5],
        hwout1Gain: [0x64, 0x7b, 0x72, 0xb7],
        hwout0Mute: [0x5f, 0xa9, 0xc0, 0xb5],
        hwout1Mute: [0xfe, 0x81, 0x75, 0xb7],
        hwout0Dim:  [0x82, 0x2c, 0x69, 0x37])

    /// Per-serial tables — every known Quartet.
    private static let bySerial: [String: DeviceTable] = [
        "quartet1528B15CEE547FA": defaultTable,
        "quartet15819153CE0E077": DeviceTable(
            hwout0Gain: [0x1f, 0x1d, 0x4c, 0x1d],
            hwout1Gain: [0xbe, 0xf5, 0x00, 0x1f],
            hwout0Mute: [0xb9, 0x23, 0x4f, 0x1d],
            hwout1Mute: [0x58, 0xfc, 0x03, 0x1f],
            hwout0Dim:  [0xe8, 0xfe, 0x54, 0x8d]),
    ]

    /// The table for the connected Quartet. Serial-keyed; falls back to
    /// the default table for unknown units (reads still work — the tree
    /// layout is identical — but writes need the right table).
    private(set) static var active = defaultTable

    /// The connected device's serial (from the tree), for the log.
    private(set) static var activeSerial: String?

    /// Pick the id table for the connected Quartet's serial.
    /// Called from the tree handler on every tree (connect + reconnect).
    static func select(serial: String?) {
        guard serial != activeSerial else { return }
        activeSerial = serial
        if let serial, let table = bySerial[serial] {
            active = table
            QBLog.log("path-ids: known serial \(serial)")
        } else if let serial {
            active = defaultTable
            QBLog.log("path-ids: UNKNOWN serial \(serial) — using the default table; " +
                      "capture this unit's ids with tools/watch_ids.py and add them")
        } else {
            active = defaultTable
        }
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
    let talkbackHotKeys = HotKeyManager(signature: 0x51425442 /* 'QBTB' */, id: 1)
    let switchHotKeys = HotKeyManager(signature: 0x51515357 /* 'QBSW' */, id: 2)
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
            osSlider.noteTargetSwitch()   // stale OS mute must not leak to the new target
            syncMacSlider(force: true)    // slider follows whichever output is bound
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
    /// Quartet's hardware mute. One-way by design — see OSVolumeMirror's
    /// header for why the app never writes the OS mute.
    private func osMuteChanged(to m: Bool) {
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
        if ProcessInfo.processInfo.environment["QB_AUTO_UI"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QBLog.log("insert: AUTO-UI debug trigger")
                InsertServer.shared.showPluginUI(0)
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
            // The device node's type is its serial — path-ids are hashed
            // per-serial, so pick this unit's id table before anything else.
            PathIds.select(serial: GlueClient.quartetSerial(in: tree))
            if let hw0 = GlueClient.findNode(in: tree, type: "hwout0"),
               let hw1 = GlueClient.findNode(in: tree, type: "hwout1") {
                self.gain[.mainOut] = GlueClient.doubleProp(hw0, "gain") ?? 0
                self.gain[.headphones] = GlueClient.doubleProp(hw1, "gain") ?? 0
                self.muted[.mainOut] = (GlueClient.intProp(hw0, "mute") ?? 0) == 1
                self.speakerDim = (GlueClient.intProp(hw0, "dim") ?? 0) == 1
                self.muted[.headphones] = (GlueClient.intProp(hw1, "mute") ?? 0) == 1
                self.gainKnown = true
                self.syncMacSlider(force: true)
            }
            if let tb = GlueClient.findNode(in: tree, type: "Talkback"),
               let props = tb["props"] as? [String: Any],
               let on = props["talkbackOn"] as? Bool {
                self.talkbackOn = on
            }
            self.refreshMenu()
        }
        glue.onSetProperty = { [weak self] event in
            guard let self else { return }
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
        talkbackHotKeys.onHotKey = { [weak self] in self?.toggleTalkback() }
        if let comboData = UserDefaults.standard.data(forKey: "hotkeyCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: comboData) {
            talkbackHotKeys.register(combo)
        }
        switchHotKeys.onHotKey = { [weak self] in self?.switchVolumeTarget() }
        if let comboData = UserDefaults.standard.data(forKey: "hotkeySwitchCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: comboData) {
            switchHotKeys.register(combo)
        }
    }

    /// Hotkey action: toggle the volume target Main Out ↔ Headphones.
    func switchVolumeTarget() {
        selectedOutput = selectedOutput == .mainOut ? .headphones : .mainOut
        QBLog.log("hotkey: volume target now \(selectedOutput.rawValue)")
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
            self.outputsWindow.refresh()
            self.settingsWindow.refresh()
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
        let muteHP = menu.addItem(withTitle: "Mute Headphones", action: #selector(toggleMuteTarget(_:)), keyEquivalent: "")
        muteHP.representedObject = OutputTarget.headphones.rawValue
        muteHP.state = hpMuted ? .on : .off
        let dimItem = menu.addItem(withTitle: "Dim Speakers", action: #selector(toggleDim(_:)), keyEquivalent: "")
        dimItem.state = speakerDim ? .on : .off

        menu.addItem(.separator())

        // talkback + AU insert + global plug-in bypass
        let tbTitle = talkbackOn ? "Stop Talkback" : "Start Talkback"
        let tbItem = menu.addItem(withTitle: tbTitle, action: #selector(talkbackNow(_:)), keyEquivalent: "")
        applyKeyEquivalent(tbItem, combo: talkbackHotKeys.current)
        let insertTitle = server.running ? "Stop Plug-in Insert" : "Start Plug-in Insert"
        let insertItem = menu.addItem(withTitle: insertTitle,
                                      action: #selector(toggleInsert(_:)), keyEquivalent: "")
        insertItem.state = server.running ? .on : .off
        let bypassItem = menu.addItem(withTitle: "Bypass All Plug-ins",
                                       action: #selector(toggleBypassAll(_:)), keyEquivalent: "")
        bypassItem.state = server.bypassAll ? .on : .off

        menu.addItem(.separator())

        // windows
        menu.addItem(withTitle: "Outputs & Plug-ins…", action: #selector(openOutputs(_:)), keyEquivalent: "")
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

    @objc private func recordHotKey(_ sender: NSMenuItem) {
        HotKeyRecorder.record(title: "Talkback Hotkey") { [weak self] combo in
            guard let self, let combo else { return }
            self.talkbackHotKeys.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: "hotkeyCombo")
            }
            self.refreshMenu()
        }
    }

    @objc private func recordSwitchHotKey(_ sender: NSMenuItem) {
        HotKeyRecorder.record(title: "Switch Output Hotkey") { [weak self] combo in
            guard let self, let combo else { return }
            self.switchHotKeys.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: "hotkeySwitchCombo")
            }
            self.refreshMenu()
        }
    }

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

    private lazy var outputsWindow = OutputsWindowController()
    private lazy var settingsWindow = SettingsWindowController()

    @objc private func openOutputs(_ sender: NSMenuItem) {
        outputsWindow.show()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        settingsWindow.show()
    }

    /// Wire the Settings window's callbacks to this delegate's plumbing.
    private func setupSettingsWindow() {
        settingsWindow.onTalkbackHotkey = { [weak self] combo in
            guard let self, let combo else { return }
            self.talkbackHotKeys.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: "hotkeyCombo")
            }
        }
        settingsWindow.onSwitchHotkey = { [weak self] combo in
            guard let self, let combo else { return }
            self.switchHotKeys.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: "hotkeySwitchCombo")
            }
        }
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
