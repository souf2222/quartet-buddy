import AppKit
import CoreMIDI
import Carbon.HIToolbox
import ServiceManagement

// Path-ids captured from live traffic (see docs/protocol-notes.md).
// They are deterministic per device — same values Apogee's own apps use.
enum PathIds {
    static let hwout0Gain: [UInt8] = [0xc5, 0xa2, 0xbd, 0xb5]
    static let hwout1Gain: [UInt8] = [0x64, 0x7b, 0x72, 0xb7]
    static let hwout0Mute: [UInt8] = [0x5f, 0xa9, 0xc0, 0xb5]
    static let hwout1Mute: [UInt8] = [0xfe, 0x81, 0x75, 0xb7]
    static let hwout0Dim:  [UInt8] = [0x82, 0x2c, 0x69, 0x37]
    static let talkbackOn: [UInt8] = [0x8f, 0x0a, 0x6a, 0x00]
}

enum OutputTarget: String, CaseIterable, Codable {
    case mainOut = "Main Out"
    case headphones = "Headphones"

    var gainId: [UInt8] { self == .mainOut ? PathIds.hwout0Gain : PathIds.hwout1Gain }
    var muteId: [UInt8] { self == .mainOut ? PathIds.hwout0Mute : PathIds.hwout1Mute }
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
            syncMacSlider(force: true)   // slider follows whichever output is bound
            refreshMenu()
        }
    }
    var gain: [OutputTarget: Double] = [.mainOut: 0, .headphones: 0]
    var muted: [OutputTarget: Bool] = [.mainOut: false, .headphones: false]

    static let minDB: Double = -64
    static let maxDB: Double = 0

    var talkbackOn = false
    var talkbackMomentary = false
    /// True once a tree has given us real hardware gain values (never
    /// enforce the macOS slider from the pre-tree defaults).
    private var gainKnown = false
    private var lastSliderDB: Double?

    /// Copy the selected output's real level onto the macOS volume slider —
    /// the Quartet → macOS half of the binding (see OSVolumeMirror).
    private func syncMacSlider(force: Bool = false) {
        guard gainKnown else { return }
        let db = gain[selectedOutput] ?? 0
        guard force || lastSliderDB != db else { return }
        lastSliderDB = db
        osSlider.enforce(db)
    }

    /// The macOS slider moved (volume key press, dragged in Sound settings):
    /// apply its level to the Quartet's real fader — the macOS → Quartet
    /// half of the binding. Our own enforce writes land here too and are
    /// filtered out by the value check.
    private func osSliderMoved(to db: Double) {
        guard gainKnown else { return }
        guard case .connected = glue.state else { return }   // bridge down: let tree re-sync later
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
            if let hw0 = GlueClient.findNode(in: tree, type: "hwout0"),
               let hw1 = GlueClient.findNode(in: tree, type: "hwout1") {
                self.gain[.mainOut] = GlueClient.doubleProp(hw0, "gain") ?? 0
                self.gain[.headphones] = GlueClient.doubleProp(hw1, "gain") ?? 0
                self.muted[.mainOut] = (GlueClient.intProp(hw0, "mute") ?? 0) == 1
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
            case PathIds.hwout0Gain where event.tag == 4:
                self.gain[.mainOut] = event.value.readDouble()
                self.syncMacSlider()
            case PathIds.hwout1Gain where event.tag == 4:
                self.gain[.headphones] = event.value.readDouble()
                self.syncMacSlider()
            case PathIds.hwout0Mute where event.tag == 3:
                self.muted[.mainOut] = event.value.first == 1
            case PathIds.hwout1Mute where event.tag == 3:
                self.muted[.headphones] = event.value.first == 1
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

        // header
        var headerTitle = "Quartet Buddy"
        if !quartetPresence.isConnected {
            headerTitle += " — Quartet Not Connected"
        } else if glue.state != .connected {
            headerTitle += " — Glue Offline"
        }
        menu.addItem(sectionHeader(headerTitle))

        // output target (with live levels)
        let outItem = menu.addItem(withTitle: "Volume Target", action: nil, keyEquivalent: "")
        outItem.submenu = NSMenu()
        for target in OutputTarget.allCases {
            let g = gain[target] ?? 0
            let isMuted = muted[target] ?? false
            let title = String(format: "%@ — %.1f dB%@", target.rawValue, g, isMuted ? "  muted" : "")
            let item = outItem.submenu!.addItem(withTitle: title,
                                                action: #selector(pickOutput(_:)),
                                                keyEquivalent: "")
            item.representedObject = target.rawValue
            item.state = target == selectedOutput ? .on : .off
        }

        // compact level line
        if quartetPresence.isConnected {
            menu.addItem(withTitle: String(format: "Main %.1f dB  ·  HP %.1f dB", mainGain, hpGain),
                         action: nil, keyEquivalent: "").isEnabled = false
        }

        menu.addItem(.separator())

        // talkback section
        menu.addItem(sectionHeader("Talkback"))
        let tbAction = menu.addItem(withTitle: talkbackOn ? "Turn Talkback Off" : "Turn Talkback On",
                                    action: #selector(talkbackNow(_:)), keyEquivalent: "")
        applyKeyEquivalent(tbAction, combo: talkbackHotKeys.current)

        let hk = talkbackHotKeys.current
        menu.addItem(withTitle: hk.map({ "Talkback Hotkey: \($0.displayString)…" }) ?? "Set Talkback Hotkey…",
                     action: #selector(recordHotKey(_:)), keyEquivalent: "")

        let sw = switchHotKeys.current
        menu.addItem(withTitle: sw.map({ "Switch Output Hotkey: \($0.displayString)…" }) ?? "Set Switch Output Hotkey…",
                     action: #selector(recordSwitchHotKey(_:)), keyEquivalent: "")

        let midiMenu = menu.addItem(withTitle: "MIDI Button", action: nil, keyEquivalent: "")
        midiMenu.submenu = NSMenu()
        if learningMidi {
            midiMenu.submenu!.addItem(withTitle: "Learning… press a button on your keyboard",
                                      action: nil, keyEquivalent: "").isEnabled = false
        } else {
            midiMenu.submenu!.addItem(withTitle: "Learn…",
                                      action: #selector(learnMIDI(_:)), keyEquivalent: "")
        }
        if let t = midiTrigger {
            let trig = midiMenu.submenu!.addItem(
                withTitle: String(format: "Trigger: %@ %d · Ch %d", t.kind == .note ? "Note" : "CC", t.number, t.channel + 1),
                action: nil, keyEquivalent: "")
            trig.isEnabled = false
            midiMenu.submenu!.addItem(withTitle: "Clear Trigger",
                                      action: #selector(clearMidiTrigger(_:)), keyEquivalent: "")
            let mode = midiMenu.submenu!.addItem(
                withTitle: "Mode: \(talkbackMomentary ? "Momentary" : "Toggle")",
                action: #selector(toggleMidiMode(_:)), keyEquivalent: "")
            mode.state = .on
        }

        menu.addItem(.separator())

        // AU insert section
        let server = InsertServer.shared
        menu.addItem(sectionHeader("AU Insert"))

        // quick access: Out 1‑2's plugin editor, right under the header
        if let mainPlugin = server.pluginName(0) {
            let ui = menu.addItem(withTitle: "Open \(InsertServer.shortName(mainPlugin))…",
                                  action: #selector(openMainPluginUI(_:)), keyEquivalent: "")
            ui.tag = 0
        }

        // master toggle — title shows live state
        let insertItem = menu.addItem(
            withTitle: server.running ? "Insert On" : "Insert Off",
            action: #selector(toggleInsert(_:)), keyEquivalent: "")
        insertItem.state = server.running ? .on : .off

        if server.running, server.tapSilent {
            menu.addItem(withTitle: "⚠️ Tap silent — allow Quartet Buddy in",
                          action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "System Settings → Privacy → System Audio Recording",
                          action: #selector(openPrivacySettings(_:)), keyEquivalent: "")
        }

        // latency submenu
        let bufItem = menu.addItem(withTitle: "Latency", action: nil, keyEquivalent: "")
        bufItem.submenu = NSMenu()
        let currentBuf = InsertServer.savedBufferFrames()
        for choice in InsertServer.bufferChoices {
            let item = bufItem.submenu!.addItem(withTitle: choice.label,
                                                action: #selector(pickInsertBuffer(_:)), keyEquivalent: "")
            item.representedObject = choice.frames
            item.state = choice.frames == currentBuf ? .on : .off
        }

        menu.addItem(.separator())

        // one submenu per stereo pair: source routing + plugin + controls
        for i in 0..<4 {
            let pairTitle = "\(InsertServer.pairNames[i]) → \(server.statusLine(i))"
            let pairItem = menu.addItem(withTitle: pairTitle, action: nil, keyEquivalent: "")
            pairItem.submenu = NSMenu()

            // live status line
            pairItem.submenu!.addItem(withTitle: server.statusLine(i),
                                      action: nil, keyEquivalent: "").isEnabled = false

            // Source ▸ copies of other pairs' pre-plugin inputs, or Off.
            // Out 1‑2 is the dry system mix itself (fixed source), so
            // "Copy of Out 1‑2" == dry mix — no separate "system mix dry".
            if i > 0 {
                let srcItem = pairItem.submenu!.addItem(withTitle: "Source", action: nil, keyEquivalent: "")
                srcItem.submenu = NSMenu()
                let currentSrc = server.source(i)
                // No routing (= the dry mix directly) first, then the
                // other pairs, then Off
                let srcOptions: [InsertServer.PairSource] = [.systemMix]
                    + [0, 1, 2, 3].filter { $0 != i }.map { InsertServer.PairSource.copy($0) }
                    + [.off]
                for src in srcOptions {
                    let item = srcItem.submenu!.addItem(withTitle: src.label,
                                                        action: #selector(pickPairSource(_:)), keyEquivalent: "")
                    item.tag = i
                    item.representedObject = src.rawValue
                    item.state = src == currentSrc ? .on : .off
                }
            }

            // Plugin ▸ none + all installed effects
            let plugItem = pairItem.submenu!.addItem(withTitle: "Plugin", action: nil, keyEquivalent: "")
            plugItem.submenu = NSMenu()
            let noneItem = plugItem.submenu!.addItem(withTitle: "None",
                                                     action: #selector(pickPairPlugin(_:)), keyEquivalent: "")
            noneItem.tag = i
            noneItem.representedObject = ""
            noneItem.state = server.pluginName(i) == nil ? .on : .off
            let currentPlug = UserDefaults.standard.string(forKey: "insertPair.\(i).plugin")
            for (name, desc) in InsertServer.listPlugins() {
                let item = plugItem.submenu!.addItem(withTitle: name,
                                                     action: #selector(pickPairPlugin(_:)), keyEquivalent: "")
                item.tag = i
                item.representedObject = InsertServer.descKey(desc)
                item.state = server.pluginName(i) != nil && InsertServer.descKey(desc) == currentPlug ? .on : .off
            }

            // per-pair bypass + editor
            if server.pluginName(i) != nil {
                let bypass = pairItem.submenu!.addItem(
                    withTitle: "Bypass Plugin",
                    action: #selector(togglePairBypass(_:)), keyEquivalent: "")
                bypass.tag = i
                bypass.state = server.bypass(i) ? .on : .off
                let ui = pairItem.submenu!.addItem(
                    withTitle: "Open Plugin UI…",
                    action: #selector(openPairUI(_:)), keyEquivalent: "")
                ui.tag = i
            }
        }

        menu.addItem(.separator())
        if glue.state != .connected {
            menu.addItem(withTitle: "Reconnect to ApogeeGlue",
                         action: #selector(reconnect(_:)), keyEquivalent: "")
        }

        menu.addItem(.separator())

        // advanced
        let adv = menu.addItem(withTitle: "Advanced", action: nil, keyEquivalent: "")
        adv.submenu = NSMenu()
        adv.submenu!.addItem(withTitle: "Volume +1 dB (Test)",
                             action: #selector(testUp(_:)), keyEquivalent: "")
        adv.submenu!.addItem(withTitle: "Volume −1 dB (Test)",
                             action: #selector(testDown(_:)), keyEquivalent: "")
        adv.submenu!.addItem(withTitle: "Open Debug Log…",
                             action: #selector(openLog(_:)), keyEquivalent: "")

        menu.addItem(.separator())

        // launch at login
        let loginStatus = SMAppService.mainApp.status
        let loginTitle: String
        switch loginStatus {
        case .enabled:
            loginTitle = "Launch at Login"
        case .requiresApproval:
            loginTitle = "Launch at Login (approve in System Settings)"
        default:
            loginTitle = "Launch at Login"
        }
        let loginItem = menu.addItem(withTitle: loginTitle,
                                     action: #selector(toggleLaunchAtLogin(_:)),
                                     keyEquivalent: "")
        loginItem.state = loginStatus == .enabled ? .on : .off

        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    @objc private func testUp(_ sender: NSMenuItem) {
        QBLog.log("test: volume +1 dB")
        adjustGain(by: 1.0)
    }

    @objc private func testDown(_ sender: NSMenuItem) {
        QBLog.log("test: volume -1 dB")
        adjustGain(by: -1.0)
    }

    // MARK: AU insert

    @objc private func toggleInsert(_ sender: NSMenuItem) {
        let on = !InsertServer.shared.running
        UserDefaults.standard.set(on, forKey: "insertEnabled")
        InsertServer.shared.setRunning(on)
    }

    /// Pair submenu actions — `sender.tag` is the pair index.
    @objc private func pickPairSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let src = InsertServer.PairSource(rawValue: raw) else { return }
        InsertServer.shared.setSource(sender.tag, src)
    }

    @objc private func pickPairPlugin(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let desc = key.isEmpty ? nil
            : InsertServer.listPlugins().first { InsertServer.descKey($0.desc) == key }?.desc
        InsertServer.shared.setPlugin(sender.tag, desc)
    }

    @objc private func togglePairBypass(_ sender: NSMenuItem) {
        let i = sender.tag
        InsertServer.shared.setBypass(i, !InsertServer.shared.bypass(i))
    }

    @objc private func openPairUI(_ sender: NSMenuItem) {
        InsertServer.shared.showPluginUI(sender.tag)
    }

    /// Quick access: Out 1‑2 (Main) plugin editor.
    @objc private func openMainPluginUI(_ sender: NSMenuItem) {
        InsertServer.shared.showPluginUI(0)
    }

    @objc private func pickInsertBuffer(_ sender: NSMenuItem) {
        guard let frames = sender.representedObject as? Int else { return }
        InsertServer.shared.setBufferFrames(frames)
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
