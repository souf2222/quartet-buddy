import AppKit
import CoreMIDI

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
    let hotKeys = HotKeyManager()
    let midi = MidiWatcher()
    let deviceMonitor = DefaultDeviceMonitor()

    var statusItem: NSStatusItem!
    var menu = NSMenu()

    var selectedOutput: OutputTarget {
        didSet { UserDefaults.standard.set(selectedOutput.rawValue, forKey: "output"); refreshMenu() }
    }
    var stepDB: Double {
        didSet { UserDefaults.standard.set(stepDB, forKey: "step"); refreshMenu() }
    }
    var gain: [OutputTarget: Double] = [.mainOut: 0, .headphones: 0]
    var muted: [OutputTarget: Bool] = [.mainOut: false, .headphones: false]
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

    override init() {
        self.selectedOutput = OutputTarget(rawValue: UserDefaults.standard.string(forKey: "output") ?? "") ?? .mainOut
        self.stepDB = UserDefaults.standard.object(forKey: "step") as? Double ?? 1.0
        self.talkbackMomentary = UserDefaults.standard.bool(forKey: "momentary")
        if let data = UserDefaults.standard.data(forKey: "midiTrigger") {
            self.midiTrigger = try? JSONDecoder().decode(MidiWatcher.Trigger.self, from: data)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupGlue()
        setupKeys()
        setupMIDI()
        deviceMonitor.start()
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
            case PathIds.hwout1Gain where event.tag == 4:
                self.gain[.headphones] = event.value.readDouble()
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
        keyTap.onKey = { [weak self] key, keyIsDown in
            guard let self, keyIsDown else { return false }
            guard DefaultDeviceMonitor.quartetIsDefaultOutput() else { return false }
            guard case .connected = self.glue.state else { return false }
            switch key {
            case .soundUp:
                self.adjustGain(by: self.stepDB)
                return true
            case .soundDown:
                self.adjustGain(by: -self.stepDB)
                return true
            case .mute:
                self.toggleMute()
                return true
            }
        }
        if !keyTap.start() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showStatus("⚠️ Enable Input Monitoring for Quartet Buddy",
                                 "System Settings → Privacy & Security → Input Monitoring",
                                 action: self?.openPrivacyPane)
            }
        }
    }

    private func adjustGain(by delta: Double) {
        let target = selectedOutput
        let current = gain[target] ?? 0
        let new = min(0, max(-90, current + delta))
        glue.setDouble(id: target.gainId, new)
        gain[target] = new
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
        hotKeys.onHotKey = { [weak self] in self?.toggleTalkback() }
        if let comboData = UserDefaults.standard.data(forKey: "hotkeyCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: comboData) {
            hotKeys.register(combo)
        }
    }

    // MARK: - MIDI

    private func setupMIDI() {
        setupHotKey()
        midi.onAnyEvent = { [weak self] event in
            guard let self else { return }
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

        let conn = glue.state == .connected ? "🟢 ApogeeGlue" : "🔴 ApogeeGlue (offline)"
        let title = statusTitle()
        statusItem?.button?.title = title

        menu.addItem(withTitle: "Quartet Buddy", action: nil, keyEquivalent: "")
            .isEnabled = false

        let outItem = menu.addItem(withTitle: "Output for volume keys", action: nil, keyEquivalent: "")
        outItem.submenu = NSMenu()
        for target in OutputTarget.allCases {
            let item = outItem.submenu!.addItem(withTitle: target.rawValue,
                                                action: #selector(pickOutput(_:)),
                                                keyEquivalent: "")
            item.representedObject = target.rawValue
            item.state = target == selectedOutput ? .on : .off
        }

        let stepItem = menu.addItem(withTitle: "Volume step", action: nil, keyEquivalent: "")
        stepItem.submenu = NSMenu()
        for s in [0.5, 1.0, 2.0] {
            let label = s == 0.5 ? "½ dB" : (s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s)) dB" : "\(s) dB")
            let item = stepItem.submenu!.addItem(withTitle: label,
                                                 action: #selector(pickStep(_:)),
                                                 keyEquivalent: "")
            item.representedObject = s
            item.state = s == stepDB ? .on : .off
        }

        menu.addItem(.separator())

        let mainGain = gain[.mainOut] ?? 0
        let hpGain = gain[.headphones] ?? 0
        menu.addItem(withTitle: String(format: "Main Out: %.1f dB%@", mainGain,
                                        (muted[.mainOut] ?? false) ? " 🔇" : ""),
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: String(format: "Headphones: %.1f dB%@", hpGain,
                                        (muted[.headphones] ?? false) ? " 🔇" : ""),
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: talkbackOn ? "🎙 Talkback: ON" : "🎙 Talkback: off",
                     action: #selector(talkbackNow(_:)), keyEquivalent: "")

        menu.addItem(.separator())

        let hk = hotKeys.current
        menu.addItem(withTitle: "Talkback hotkey: \(hk?.displayString ?? "none — click to set")",
                     action: #selector(recordHotKey(_:)), keyEquivalent: "")
        let midiLabel: String
        if learningMidi {
            midiLabel = "learning… press a button on your keyboard"
        } else if let t = midiTrigger {
            midiLabel = "MIDI: \(t.kind == .note ? "Note" : "CC") \(t.number) ch \(t.channel + 1)"
        } else {
            midiLabel = "MIDI: none — click to learn"
        }
        menu.addItem(withTitle: "Talkback \(midiLabel)",
                     action: #selector(learnMIDI(_:)), keyEquivalent: "")
        let modeItem = menu.addItem(withTitle: "MIDI mode: \(talkbackMomentary ? "momentary" : "toggle")",
                                    action: #selector(toggleMidiMode(_:)), keyEquivalent: "")
        if midiTrigger == nil { modeItem.isEnabled = false }

        menu.addItem(.separator())
        menu.addItem(withTitle: conn, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Open Input Monitoring settings…", action: #selector(openPrivacy(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func statusTitle() -> String {
        guard case .connected = glue.state else { return "🎛︎" }
        let g = gain[selectedOutput] ?? 0
        let v = Int(round((g + 90) / 90 * 16))
        let bars = String(repeating: "▮", count: max(0, min(16, v)))
            + String(repeating: "▯", count: max(0, 16 - v))
        let mark = selectedOutput == .mainOut ? "" : "🎧"
        let mute = (muted[selectedOutput] ?? false) ? "🔇" : ""
        return "\(mark)\(mute)\(bars)"
    }

    // MARK: - Actions

    @objc private func pickOutput(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let t = OutputTarget(rawValue: raw) {
            selectedOutput = t
        }
    }

    @objc private func pickStep(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double {
            stepDB = s
        }
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
        HotKeyRecorder.record { [weak self] combo in
            guard let self, let combo else { return }
            self.hotKeys.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: "hotkeyCombo")
            }
            self.refreshMenu()
        }
    }

    @objc private func openPrivacy(_ sender: NSMenuItem) {
        openPrivacyPane()
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
