import AppKit
import ServiceManagement

/// The Settings window: app-level configuration only (per Apple's
/// HIG — operational routing lives in Outputs & Plug-ins).
/// Sections: General · Talkback · Shortcuts & MIDI · Audio.
///
/// Hotkey registration and MIDI learning stay owned by AppDelegate —
/// this window calls back through the closures it wires up.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    /// Wired by AppDelegate.
    var onTalkbackHotkey: ((HotKeyManager.Combo?) -> Void)?
    var onSwitchHotkey: ((HotKeyManager.Combo?) -> Void)?
    var onMidiLearn: (() -> Void)?
    var onMidiClear: (() -> Void)?

    private var window: NSWindow?

    // General
    private var loginCheck: NSButton!
    // Talkback
    private var momentaryCheck: NSButton!
    // Shortcuts & MIDI
    private var talkbackHotkeyButton: NSButton!
    private var switchHotkeyButton: NSButton!
    private var midiLearnButton: NSButton!
    private var midiStateField: NSTextField!
    // Audio
    private var latencyPopup: NSPopUpButton!
    private var rateField: NSTextField!
    private var suppress = false

    func show() {
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard window != nil else { return }
        suppress = true
        defer { suppress = false }
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        momentaryCheck.state = UserDefaults.standard.bool(forKey: "momentary") ? .on : .off
        if let data = UserDefaults.standard.data(forKey: "hotkeyCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: data) {
            talkbackHotkeyButton.title = "Talkback: \(combo.displayString)…"
        } else {
            talkbackHotkeyButton.title = "Set Talkback Shortcut…"
        }
        if let data = UserDefaults.standard.data(forKey: "hotkeySwitchCombo"),
           let combo = try? JSONDecoder().decode(HotKeyManager.Combo.self, from: data) {
            switchHotkeyButton.title = "Switch Output: \(combo.displayString)…"
        } else {
            switchHotkeyButton.title = "Set Switch Output Shortcut…"
        }
        if let data = UserDefaults.standard.data(forKey: "midiTrigger"),
           let t = try? JSONDecoder().decode(MidiWatcher.Trigger.self, from: data) {
            midiStateField.stringValue = "Trigger: \(t.kind == .note ? "Note" : "CC") \(t.number) · Ch \(t.channel + 1)"
            midiLearnButton.title = "Learn MIDI Button…"
        } else {
            midiStateField.stringValue = "No MIDI trigger"
            midiLearnButton.title = "Learn MIDI Button…"
        }
        // latency
        let current = InsertServer.savedBufferFrames()
        latencyPopup.selectItem(at: InsertServer.bufferChoices.firstIndex { $0.frames == current } ?? 0)
        rateField.stringValue = "Quartet · \(Int(InsertServer.shared.currentRate())) Hz"
    }

    // MARK: - build

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 470))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.addSubview(stack)

        // General
        stack.addArrangedSubview(sectionTitle("General"))
        loginCheck = NSButton(checkboxWithTitle: "Launch at Login", target: self,
                              action: #selector(loginChanged(_:)))
        stack.addArrangedSubview(loginCheck)
        let logButton = NSButton(title: "Open Debug Log…", target: self,
                                 action: #selector(openLog(_:)))
        stack.addArrangedSubview(logButton)
        stack.addArrangedSubview(separator())

        // Talkback
        stack.addArrangedSubview(sectionTitle("Talkback"))
        momentaryCheck = NSButton(checkboxWithTitle: "Momentary mode (hold to talk)", target: self,
                                  action: #selector(momentaryChanged(_:)))
        stack.addArrangedSubview(momentaryCheck)
        stack.addArrangedSubview(separator())

        // Shortcuts & MIDI
        stack.addArrangedSubview(sectionTitle("Shortcuts & MIDI"))
        talkbackHotkeyButton = NSButton(title: "Set Talkback Shortcut…", target: self,
                                        action: #selector(recordTalkback(_:)))
        stack.addArrangedSubview(talkbackHotkeyButton)
        switchHotkeyButton = NSButton(title: "Set Switch Output Shortcut…", target: self,
                                      action: #selector(recordSwitch(_:)))
        stack.addArrangedSubview(switchHotkeyButton)
        midiLearnButton = NSButton(title: "Learn MIDI Button…", target: self,
                                   action: #selector(midiLearn(_:)))
        stack.addArrangedSubview(midiLearnButton)
        midiStateField = secondary("")
        midiStateField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(midiStateField)
        let clearMidi = NSButton(title: "Clear MIDI Trigger", target: self,
                                 action: #selector(midiClear(_:)))
        stack.addArrangedSubview(clearMidi)
        stack.addArrangedSubview(separator())

        // Audio
        stack.addArrangedSubview(sectionTitle("Audio"))
        let latencyRow = NSStackView(views: [])
        latencyRow.orientation = .horizontal
        latencyRow.spacing = 8
        latencyRow.addArrangedSubview(secondary("Latency"))
        latencyPopup = NSPopUpButton()
        latencyPopup.translatesAutoresizingMaskIntoConstraints = false
        for choice in InsertServer.bufferChoices {
            latencyPopup.addItem(withTitle: choice.label)
            latencyPopup.lastItem?.representedObject = choice.frames
        }
        latencyPopup.action = #selector(latencyChanged(_:))
        latencyPopup.target = self
        latencyRow.addArrangedSubview(latencyPopup)
        stack.addArrangedSubview(latencyRow)
        rateField = secondary("")
        stack.addArrangedSubview(rateField)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            latencyPopup.widthAnchor.constraint(equalToConstant: 160),
        ])

        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.delegate = self
        w.center()
        window = w
    }

    // MARK: - helpers

    private func sectionTitle(_ s: String) -> NSView {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        return f
    }
    private func secondary(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.textColor = .secondaryLabelColor
        f.font = .systemFont(ofSize: 11)
        return f
    }
    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    // MARK: - actions

    @objc private func loginChanged(_ sender: NSButton) {
        guard !suppress else { return }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            QBLog.log("settings: login item error — \(error.localizedDescription)")
        }
        refresh()
    }

    @objc private func momentaryChanged(_ sender: NSButton) {
        guard !suppress else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: "momentary")
        // AppDelegate reads this on MIDI events; also update directly
        NotificationCenter.default.post(name: .init("qb.momentaryChanged"), object: nil)
    }

    @objc private func recordTalkback(_ sender: NSButton) {
        HotKeyRecorder.record(title: "Talkback Shortcut") { [weak self] combo in
            guard let self else { return }
            self.onTalkbackHotkey?(combo)
            self.refresh()
        }
    }

    @objc private func recordSwitch(_ sender: NSButton) {
        HotKeyRecorder.record(title: "Switch Output Shortcut") { [weak self] combo in
            guard let self else { return }
            self.onSwitchHotkey?(combo)
            self.refresh()
        }
    }

    @objc private func midiLearn(_ sender: NSButton) {
        onMidiLearn?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    @objc private func midiClear(_ sender: NSButton) {
        onMidiClear?()
        refresh()
    }

    @objc private func latencyChanged(_ sender: NSPopUpButton) {
        guard !suppress, let frames = sender.selectedItem?.representedObject as? Int else { return }
        InsertServer.shared.setBufferFrames(frames)
    }

    @objc private func openLog(_ sender: NSButton) {
        NSWorkspace.shared.open(QBLog.url)
    }
}