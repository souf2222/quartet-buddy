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
    let keyTap = MediaKeyTap()
    let talkbackHotKeys = HotKeyManager(signature: 0x51425442 /* 'QBTB' */, id: 1)
    let switchHotKeys = HotKeyManager(signature: 0x51515357 /* 'QBSW' */, id: 2)
    let midi = MidiWatcher()
    let deviceMonitor = DefaultDeviceMonitor()
    let quartetPresence = QuartetPresence()

    var statusItem: NSStatusItem!
    var menu = NSMenu()

    var selectedOutput: OutputTarget {
        didSet { UserDefaults.standard.set(selectedOutput.rawValue, forKey: "output"); refreshMenu() }
    }
    /// macOS-style volume: 0…1, each key press steps by 1/16
    /// (⌥ + key = fine step, ¼ block — like macOS).
    /// 100% ⇔ 0 dB, 0% ⇔ −64 dB, linear in dB (4 dB per block).
    var volumePercent: [OutputTarget: Double] = [.mainOut: 0.5, .headphones: 0.5]
    var gain: [OutputTarget: Double] = [.mainOut: 0, .headphones: 0]
    var muted: [OutputTarget: Bool] = [.mainOut: false, .headphones: false]

    static let volumeSteps = 16
    static let fineDivisor = 4     // ⌥ = quarter block
    static let minDB: Double = -64
    static let maxDB: Double = 0

    static func db(forPercent p: Double) -> Double {
        let c = min(1, max(0, p))
        return maxDB + (minDB - maxDB) * (1 - c)
    }

    static func percent(forDB db: Double) -> Double {
        let d = min(maxDB, max(minDB, db))
        return (d - minDB) / (maxDB - minDB)
    }

    private func syncPercent(for target: OutputTarget) {
        volumePercent[target] = Self.percent(forDB: gain[target] ?? 0)
    }
    var talkbackOn = false
    var talkbackMomentary = false
    var midiTrigger: MidiWatcher.Trigger? {
        didSet {
            if let midiTrigger, let data = try? JSONEncoder().encode(midiTrigger) {
                UserDefaults.standard.set(data, forKey: "midiTrigger")
            }
            refreshMenu()
        }
    }
    var learningMidi = false
    private var tccRetryTimer: Timer?

    override init() {
        self.selectedOutput = OutputTarget(rawValue: UserDefaults.standard.string(forKey: "output") ?? "") ?? .mainOut
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
        setupKeys()
        setupMIDI()
        deviceMonitor.start()
        quartetPresence.onChange = { [weak self] connected in
            QBLog.log("quartet presence: \(connected ? "connected" : "disconnected")")
            if !connected, self?.talkbackOn == true {
                // the TalkbackHelper resets talkback when the device goes away
                QBLog.log("talkback: assumed off (device disconnected)")
                self?.talkbackOn = false
            }
            self?.refreshMenu()
        }
        quartetPresence.start()
        syncLoginItem()
        // keep retrying the event tap until Input Monitoring gets granted
        tccRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.keyTap.isActive {
                self.tccRetryTimer?.invalidate()
                self.tccRetryTimer = nil
                return
            }
            self.ensureMediaKeyTap()
        }
    }

    /// Create the event tap if (and only if) Input Monitoring is granted.
    /// Pass request=true to trigger the system permission dialog if needed.
    @discardableResult
    private func ensureMediaKeyTap(request: Bool = false) -> Bool {
        if request && InputMonitoring.check() != .granted {
            QBLog.log("input monitoring: requesting…")
            InputMonitoring.request()
        }
        let granted = InputMonitoring.check() == .granted
        if !granted {
            QBLog.log("media keys: input monitoring not granted (tap not created)")
            return false
        }
        let ok = keyTap.start()
        QBLog.log("media keys: tap start -> \(ok ? "OK" : "FAILED")")
        refreshMenu()
        return ok
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
                self.syncPercent(for: .mainOut)
                self.syncPercent(for: .headphones)
                self.muted[.mainOut] = (GlueClient.intProp(hw0, "mute") ?? 0) == 1
                self.muted[.headphones] = (GlueClient.intProp(hw1, "mute") ?? 0) == 1
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
                self.syncPercent(for: .mainOut)
            case PathIds.hwout1Gain where event.tag == 4:
                self.gain[.headphones] = event.value.readDouble()
                self.syncPercent(for: .headphones)
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

    // MARK: - Media keys

    private func setupKeys() {
        keyTap.onKey = { [weak self] key, keyIsDown, optionHeld in
            guard let self, keyIsDown else { return false }
            let quartetActive = DefaultDeviceMonitor.quartetIsDefaultOutput()
            QBLog.log("media keys: handling key=\(key) opt=\(optionHeld) quartetIsDefault=\(quartetActive) glue=\(self.glue.state)")
            guard quartetActive else { return false }
            guard case .connected = self.glue.state else { return false }
            let delta = 1.0 / Double(Self.volumeSteps * (optionHeld ? Self.fineDivisor : 1))
            switch key {
            case .soundUp:
                self.adjustPercent(by: delta)
                return true
            case .soundDown:
                self.adjustPercent(by: -delta)
                return true
            case .mute:
                self.toggleMute()
                return true
            }
        }
        ensureMediaKeyTap()
    }

    /// Step the macOS-style volume percent and apply the mapped dB to hardware.
    private func adjustPercent(by delta: Double) {
        let target = selectedOutput
        let p = min(1, max(0, (volumePercent[target] ?? 0) + delta))
        volumePercent[target] = p
        let db = Self.db(forPercent: p)
        glue.setDouble(id: target.gainId, db)
        gain[target] = db
        refreshMenu()
    }

    /// ± dB adjustments (Test menu items) — keeps percent in sync afterwards.
    private func adjustGain(by delta: Double) {
        let target = selectedOutput
        let new = min(0, max(Self.minDB, (gain[target] ?? 0) + delta))
        glue.setDouble(id: target.gainId, new)
        gain[target] = new
        syncPercent(for: target)
        refreshMenu()
    }

    private func toggleMute() {
        let target = selectedOutput
        let newState = !(muted[target] ?? false)
        glue.setBool(id: target.muteId, newState)
        muted[target] = newState
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

    /// Hotkey action: toggle the volume-key target Main Out ↔ Headphones.
    func switchVolumeTarget() {
        selectedOutput = selectedOutput == .mainOut ? .headphones : .mainOut
        QBLog.log("hotkey: volume keys now control \(selectedOutput.rawValue)")
        refreshMenu()
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

    // MARK: - Menu

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.delegate = self
        refreshMenu()
    }

    private func refreshMenu() {
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
        let outItem = menu.addItem(withTitle: "Volume Keys Target", action: nil, keyEquivalent: "")
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

        // warnings (only when something needs attention)
        if !keyTap.isActive {
            let access = InputMonitoring.check()
            let title = access == .granted
                ? "⚠️ Media Key Tap Failed — Open Debug Log"
                : "⚠️ Volume Keys Need Input Monitoring…"
            menu.addItem(withTitle: title,
                         action: access == .granted ? #selector(openLog(_:))
                                                     : #selector(grantInputMonitoring(_:)),
                         keyEquivalent: "")
        }
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
        adv.submenu!.addItem(withTitle: "Open Input Monitoring Settings…",
                             action: #selector(openPrivacy(_:)), keyEquivalent: "")
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
            let size: CGFloat = 7
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
            // icon frame inside the button (query the cell; fallback: centered 20×16)
            let iconFrame: NSRect
            if let cell = button.cell as? NSButtonCell, !cell.imageRect(forBounds: b).isEmpty {
                iconFrame = cell.imageRect(forBounds: b)
            } else {
                iconFrame = NSRect(x: (b.width - 20) / 2, y: (b.height - 16) / 2,
                                   width: 20, height: 16)
            }
            talkbackDot?.frame = NSRect(x: iconFrame.maxX - size + 2,
                                        y: iconFrame.maxY - size + 1.5,
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

    @objc private func openPrivacy(_ sender: NSMenuItem) {
        openPrivacyPane()
    }

    @objc private func grantInputMonitoring(_ sender: NSMenuItem) {
        ensureMediaKeyTap()
        if InputMonitoring.check() != .granted {
            showStatus("Enable Input Monitoring",
                       "In System Settings → Privacy & Security → Input Monitoring, turn on Quartet Buddy.",
                       action: openPrivacyPane)
        }
        refreshMenu()
    }

    @objc private func testUp(_ sender: NSMenuItem) {
        QBLog.log("test: volume +1 dB")
        adjustGain(by: 1.0)
    }

    @objc private func testDown(_ sender: NSMenuItem) {
        QBLog.log("test: volume -1 dB")
        adjustGain(by: -1.0)
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(QBLog.url)
    }

    private func openPrivacyPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showStatus(_ title: String, _ subtitle: String, action: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = subtitle
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            action?()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // re-check permission every time the menu opens (grant may have just happened)
        if !keyTap.isActive {
            ensureMediaKeyTap()
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
