import AppKit
import ServiceManagement

/// "Quartet Buddy Settings" — a sidebar shell with one pane per area
/// (matching the settings-window design):
///
///     ⚙ General · ⌨ Shortcuts · ♫ Audio · ◉ Talkback · ◇ Plug-ins · ⓘ About
///
/// Hotkey registration and MIDI learning stay owned by AppDelegate — this
/// window calls back through the closures it wires up. Shortcut bindings
/// live in ShortcutManager (wired in as `shortcuts`).
final class SettingsWindowController: NSObject, NSWindowDelegate {

    /// Wired by AppDelegate.
    var onMidiLearn: (() -> Void)?
    var onMidiClear: (() -> Void)?
    /// The shortcut engine (bindings, conflicts, defaults).
    var shortcuts: ShortcutManager?

    private var window: NSWindow?
    private var sidebarButtons: [Pane: NSButton] = [:]
    private var paneViews: [Pane: NSView] = [:]
    private var currentPane: Pane = .general

    enum Pane: Int, CaseIterable {
        case general, shortcuts, audio, talkback, plugins, about

        var icon: String {
            switch self {
            case .general: return "⚙"
            case .shortcuts: return "⌘"
            case .audio: return "♫"
            case .talkback: return "◉"
            case .plugins: return "◇"
            case .about: return "ⓘ"
            }
        }
        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .audio: return "Audio"
            case .talkback: return "Talkback"
            case .plugins: return "Plug-ins"
            case .about: return "About"
            }
        }
    }

    func show() {
        if window == nil { build() }
        selectPane(currentPane)
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open straight to the Shortcuts pane.
    func showShortcuts() {
        show()
        selectPane(.shortcuts)
    }

    func refresh() {
        guard window != nil else { return }
        rebuildTalkback()
        rebuildAudio()
        rebuildPlugins()
        rebuildShortcuts()
    }

    // MARK: - build

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 520))
        let sidebar = makeSidebar()
        content.addSubview(sidebar)

        for pane in Pane.allCases {
            let view = makePane(pane)
            paneViews[pane] = view
            content.addSubview(view)
            view.isHidden = true
        }

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 170),
        ])
        for view in paneViews.values {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Quartet Buddy Settings"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.delegate = self
        w.center()
        window = w
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 8, bottom: 14, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
        ])
        for pane in Pane.allCases {
            let b = NSButton(title: "\(pane.icon)  \(pane.title)", target: self,
                             action: #selector(sidebarClicked(_:)))
            b.bezelStyle = .recessed
            b.alignment = .left
            b.tag = pane.rawValue
            b.font = .systemFont(ofSize: 13, weight: .medium)
            stack.addArrangedSubview(b)
            sidebarButtons[pane] = b
        }
        return sidebar
    }

    /// A pane = title + scrollable stack body (pinned 20/24 insets).
    private func makePane(_ pane: Pane) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: pane.title)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(title)
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyViews[pane] = body
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(body)
        scroll.documentView = doc
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: doc.topAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            body.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        switch pane {
        case .general: buildGeneral(into: body)
        case .shortcuts: buildShortcuts(into: body)
        case .audio: buildAudio(into: body)
        case .talkback: buildTalkback(into: body)
        case .plugins: buildPlugins(into: body)
        case .about: buildAbout(into: body)
        }
        return v
    }

    private var bodyViews: [Pane: NSStackView] = [:]

    @objc private func sidebarClicked(_ sender: NSButton) {
        guard let pane = Pane(rawValue: sender.tag) else { return }
        selectPane(pane)
    }

    private func selectPane(_ pane: Pane) {
        currentPane = pane
        for (p, view) in paneViews { view.isHidden = p != pane }
        for (p, button) in sidebarButtons {
            button.font = .systemFont(ofSize: 13, weight: p == pane ? .bold : .medium)
        }
    }

    // MARK: - General

    private var loginCheck: NSButton!

    private func buildGeneral(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("Launch at Login"))
        loginCheck = NSButton(checkboxWithTitle: "Launch Quartet Buddy at login", target: self,
                              action: #selector(loginChanged(_:)))
        body.addArrangedSubview(loginCheck)
        body.addArrangedSubview(separator())
        let logButton = NSButton(title: "Open Debug Log…", target: self,
                                  action: #selector(openLog(_:)))
        body.addArrangedSubview(logButton)
    }

    // MARK: - Shortcuts (the design's Keyboard Shortcuts table)

    private var globalCheck: NSButton!
    private var searchField: NSSearchField!
    private var filterPopup: NSPopUpButton!
    private var shortcutStack: NSStackView!
    private var volStepLabel: NSTextField!
    private var fineStepLabel: NSTextField!
    private var expandedSections: Set<String> = [
        "Window & Navigation", "Speakers", "Headphones",
        "Volume-Control Target", "Talkback", "Plug-ins", "Safety"]
    private var pendingScope: [ShortcutAction: Bool] = [:]
    /// The Global checkbox of each visible row (rebuilt with the table).
    private var scopeChecks: [ShortcutAction: NSButton] = [:]

    private func buildShortcuts(into body: NSStackView) {
        let sub = NSTextField(labelWithString:
            "Control Quartet Buddy from any app — global shortcuts — or within Quartet Control.")
        sub.textColor = .secondaryLabelColor
        sub.font = .systemFont(ofSize: 11)
        body.addArrangedSubview(sub)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search actions…"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        controls.addArrangedSubview(searchField)
        filterPopup = NSPopUpButton()
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.addItems(withTitles: ["All shortcuts", "Global shortcuts", "App-only shortcuts"])
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged(_:))
        controls.addArrangedSubview(filterPopup)
        body.addArrangedSubview(controls)

        // the table: groups + rows, rebuilt on every change
        shortcutStack = NSStackView()
        shortcutStack.orientation = .vertical
        shortcutStack.alignment = .leading
        shortcutStack.spacing = 2
        shortcutStack.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(shortcutStack)

        // footer
        body.addArrangedSubview(separator())
        globalCheck = NSButton(checkboxWithTitle: "Enable global shortcuts", target: self,
                               action: #selector(globalToggled(_:)))
        body.addArrangedSubview(globalCheck)
        let globalSub = NSTextField(labelWithString: "Global shortcuts work while another app is active.")
        globalSub.textColor = .secondaryLabelColor
        globalSub.font = .systemFont(ofSize: 10)
        body.addArrangedSubview(globalSub)

        let stepRow = NSStackView()
        stepRow.orientation = .horizontal
        stepRow.spacing = 6
        stepRow.translatesAutoresizingMaskIntoConstraints = false
        stepRow.addArrangedSubview(NSTextField(labelWithString: "Volume step"))
        let vol = makeStepStepper(1)
        stepRow.addArrangedSubview(vol)
        volStepLabel = stepLabel()
        stepRow.addArrangedSubview(volStepLabel)
        stepRow.addArrangedSubview(NSTextField(labelWithString: "Fine step"))
        let fine = makeStepStepper(2)
        stepRow.addArrangedSubview(fine)
        fineStepLabel = stepLabel()
        stepRow.addArrangedSubview(fineStepLabel)
        body.addArrangedSubview(stepRow)

        let restore = NSButton(title: "Restore Defaults…", target: self,
                               action: #selector(restoreDefaults(_:)))
        body.addArrangedSubview(restore)

        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(equalToConstant: 200),
            shortcutStack.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
        ])
    }

    private func makeStepStepper(_ tag: Int) -> NSStepper {
        let key = tag == 2 ? "fineStep" : "volumeStep"
        let s = NSStepper()
        s.minValue = 0.5
        s.maxValue = 6
        s.increment = 0.5
        s.valueWraps = false
        s.doubleValue = (UserDefaults.standard.double(forKey: key) > 0
            ? UserDefaults.standard.double(forKey: key) : (tag == 2 ? 0.5 : 2))
        s.tag = tag
        s.target = self
        s.action = #selector(stepChanged(_:))
        return s
    }

    private func stepLabel() -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return f
    }

    @objc private func stepChanged(_ sender: NSStepper) {
        let key = sender.tag == 2 ? "fineStep" : "volumeStep"
        UserDefaults.standard.set(sender.doubleValue, forKey: key)
        (sender.tag == 2 ? fineStepLabel : volStepLabel)?
            .stringValue = String(format: "%.1f dB", sender.doubleValue)
    }

    @objc private func searchChanged(_ sender: NSSearchField) { rebuildShortcuts() }
    @objc private func filterChanged(_ sender: NSPopUpButton) { rebuildShortcuts() }

    @objc private func globalToggled(_ sender: NSButton) {
        shortcuts?.globalEnabled = sender.state == .on
        rebuildShortcuts()
    }

    @objc private func restoreDefaults(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Restore default shortcuts?"
        alert.informativeText = "Your current bindings will be replaced."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            shortcuts?.restoreDefaults()
            rebuildShortcuts()
        }
    }

    /// Rebuild the shortcut table: groups in catalog order, disclosure
    /// headers, action rows (record button + clear + global checkbox).
    private func rebuildShortcuts() {
        guard let shortcuts, let shortcutStack, window?.isVisible == true else { return }
        globalCheck.state = shortcuts.globalEnabled ? .on : .off
        volStepLabel.stringValue = String(format: "%.1f dB", shortcuts.volumeStep)
        fineStepLabel.stringValue = String(format: "%.1f dB", shortcuts.fineStep)

        let q = (searchField.stringValue).trimmingCharacters(in: .whitespaces).lowercased()
        let filter = filterPopup.indexOfSelectedItem

        shortcutStack.views.forEach { shortcutStack.removeView($0) }
        scopeChecks.removeAll()

        for section in orderedSections() {
            let actions = ShortcutAction.allCases.filter { $0.section == section }.filter { action in
                if filter == 1, !(shortcuts.bindings[action]?.isGlobal ?? action.defaultGlobal) { return false }
                if filter == 2, (shortcuts.bindings[action]?.isGlobal ?? action.defaultGlobal) { return false }
                if !q.isEmpty,
                   !action.title.lowercased().contains(q),
                   !action.section.lowercased().contains(q) { return false }
                return true
            }
            guard !actions.isEmpty else { continue }
            let expanded = !q.isEmpty || expandedSections.contains(section)
            let header = NSButton(title: "\(expanded ? "▾" : "▸")  \(section)", target: self,
                                  action: #selector(sectionToggled(_:)))
            header.bezelStyle = .recessed
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.alignment = .left
            header.identifier = NSUserInterfaceItemIdentifier(section)
            shortcutStack.addArrangedSubview(header)
            guard expanded else { continue }
            for action in actions {
                shortcutStack.addArrangedSubview(makeRow(action, shortcuts: shortcuts))
            }
            shortcutStack.addArrangedSubview(gap(6))
        }
    }

    private func orderedSections() -> [String] {
        var seen: [String] = []
        for a in ShortcutAction.allCases where !seen.contains(a.section) { seen.append(a.section) }
        return seen
    }

    private func gap(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func makeRow(_ action: ShortcutAction, shortcuts: ShortcutManager) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: 12)
        row.addArrangedSubview(label)

        let record = NSButton(title: "Record…", target: self,
                              action: #selector(recordShortcut(_:)))
        record.bezelStyle = .rounded
        record.controlSize = .regular
        record.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        setRecordTitle(record, action, shortcuts)
        record.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(record)

        let clear = NSButton(title: "×", target: self, action: #selector(clearShortcut(_:)))
        clear.bezelStyle = .recessed
        clear.toolTip = "Clear shortcut"
        clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        clear.font = .systemFont(ofSize: 12)
        clear.isEnabled = shortcuts.bindings[action] != nil
        row.addArrangedSubview(clear)

        let global = NSButton(checkboxWithTitle: "", target: self,
                              action: #selector(scopeToggled(_:)))
        global.toolTip = "Global — works while another app is active"
        global.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        global.state = (shortcuts.bindings[action]?.isGlobal ?? action.defaultGlobal) ? .on : .off
        scopeChecks[action] = global
        row.addArrangedSubview(global)
        let globalLabel = NSTextField(labelWithString: "Global")
        globalLabel.font = .systemFont(ofSize: 10)
        globalLabel.textColor = .secondaryLabelColor
        row.addArrangedSubview(globalLabel)
        return row
    }

    private func setRecordTitle(_ button: NSButton, _ action: ShortcutAction,
                                _ shortcuts: ShortcutManager) {
        button.title = shortcuts.bindings[action]?.combo.displayString ?? "Record…"
    }

    @objc private func sectionToggled(_ sender: NSButton) {
        guard let section = sender.identifier?.rawValue else { return }
        if expandedSections.contains(section) { expandedSections.remove(section) }
        else { expandedSections.insert(section) }
        rebuildShortcuts()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let shortcuts,
              let action = ShortcutAction(rawValue: sender.identifier?.rawValue ?? "") else { return }
        // capture the row's current scope before the async recorder runs
        pendingScope[action] = (scopeChecks[action]?.state ?? (action.defaultGlobal ? .on : .off)) == .on
        HotKeyRecorder.record(title: "\(action.title) Shortcut") { [weak self] combo in
            guard let self, let shortcuts = self.shortcuts else { return }
            guard let combo else { return }   // Esc = keep current binding
            if let other = shortcuts.conflict(for: combo, excluding: action) {
                let alert = NSAlert()
                alert.messageText = "\"\(combo.displayString)\" is already assigned"
                alert.informativeText =
                    "It is currently used by \"\(other.title)\" (\(other.section))."
                alert.addButton(withTitle: "Reassign")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
            shortcuts.assign(action, combo: combo,
                             isGlobal: self.pendingScope[action] ?? action.defaultGlobal)
            self.pendingScope[action] = nil
            self.rebuildShortcuts()
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let shortcuts,
              let action = ShortcutAction(rawValue: sender.identifier?.rawValue ?? "") else { return }
        shortcuts.assign(action, combo: nil, isGlobal: false)
        rebuildShortcuts()
    }

    @objc private func scopeToggled(_ sender: NSButton) {
        guard let shortcuts, let action = ShortcutAction(rawValue: sender.identifier?.rawValue ?? ""),
              var binding = shortcuts.bindings[action] else { return }
        binding.isGlobal = sender.state == .on
        shortcuts.assign(action, combo: binding.combo, isGlobal: binding.isGlobal)
        rebuildShortcuts()
    }

    // MARK: - Talkback

    private var momentaryCheck: NSButton!
    private var midiLearnButton: NSButton!
    private var midiStateField: NSTextField!
    private var midiSuppress = false

    private func buildTalkback(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("Mode"))
        momentaryCheck = NSButton(checkboxWithTitle: "Momentary mode (hold to talk)",
                                  target: self, action: #selector(momentaryChanged(_:)))
        body.addArrangedSubview(momentaryCheck)
        body.addArrangedSubview(separator())
        body.addArrangedSubview(sectionLabel("MIDI Trigger"))
        midiLearnButton = NSButton(title: "Learn MIDI Button…", target: self,
                                    action: #selector(midiLearn(_:)))
        body.addArrangedSubview(midiLearnButton)
        midiStateField = secondary("")
        midiStateField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        body.addArrangedSubview(midiStateField)
        let clearMidi = NSButton(title: "Clear MIDI Trigger", target: self,
                                 action: #selector(midiClear(_:)))
        body.addArrangedSubview(clearMidi)
    }

    private func rebuildTalkback() {
        guard momentaryCheck != nil else { return }
        midiSuppress = true
        defer { midiSuppress = false }
        momentaryCheck.state = UserDefaults.standard.bool(forKey: "momentary") ? .on : .off
        if let data = UserDefaults.standard.data(forKey: "midiTrigger"),
           let t = try? JSONDecoder().decode(MidiWatcher.Trigger.self, from: data) {
            midiStateField.stringValue =
                "Trigger: \(t.kind == .note ? "Note" : "CC") \(t.number) · Ch \(t.channel + 1)"
        } else {
            midiStateField.stringValue = "No MIDI trigger"
        }
    }

    // MARK: - Audio

    private var latencyPopup: NSPopUpButton!
    private var rateField: NSTextField!
    private var audioSuppress = false

    private func buildAudio(into body: NSStackView) {
        let latencyRow = NSStackView()
        latencyRow.orientation = .horizontal
        latencyRow.spacing = 8
        latencyRow.translatesAutoresizingMaskIntoConstraints = false
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
        body.addArrangedSubview(latencyRow)
        rateField = secondary("")
        body.addArrangedSubview(rateField)
        NSLayoutConstraint.activate([
            latencyPopup.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    private func rebuildAudio() {
        guard latencyPopup != nil else { return }
        audioSuppress = true
        defer { audioSuppress = false }
        let current = InsertServer.savedBufferFrames()
        latencyPopup.selectItem(at: InsertServer.bufferChoices.firstIndex { $0.frames == current } ?? 0)
        rateField.stringValue = "Quartet · \(Int(InsertServer.shared.currentRate())) Hz"
    }

    // MARK: - Plug-ins

    private var insertCheck: NSButton!
    private var bypassCheck: NSButton!
    private var pluginSuppress = false

    private func buildPlugins(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("AU Insert"))
        insertCheck = NSButton(checkboxWithTitle: "Plug-in insert active", target: self,
                               action: #selector(insertToggled(_:)))
        body.addArrangedSubview(insertCheck)
        bypassCheck = NSButton(checkboxWithTitle: "Bypass all plug-ins (toggle)", target: self,
                               action: #selector(bypassToggled(_:)))
        body.addArrangedSubview(bypassCheck)
    }

    private func rebuildPlugins() {
        guard insertCheck != nil else { return }
        pluginSuppress = true
        defer { pluginSuppress = false }
        insertCheck.state = InsertServer.shared.running ? .on : .off
        bypassCheck.isEnabled = InsertServer.shared.running
        bypassCheck.state = InsertServer.shared.bypassAll ? .on : .off
    }

    // MARK: - About

    private func buildAbout(into body: NSStackView) {
        let name = NSTextField(labelWithString: "Quartet Buddy")
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        body.addArrangedSubview(name)
        body.addArrangedSubview(secondary("Version 0.2 (2)"))
        body.addArrangedSubview(separator())
        body.addArrangedSubview(secondary(
            "Menubar companion for the Apogee Quartet — monitoring, talkback,\n" +
            "routing, AU plug-ins and Auto Gain, driven through ApogeeGlue.\n"))
        body.addArrangedSubview(secondary("MIT License — see LICENSE"))
    }

    // MARK: - actions & helpers

    @objc private func loginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            QBLog.log("settings: login item error — \(error.localizedDescription)")
        }
    }

    @objc private func momentaryChanged(_ sender: NSButton) {
        guard !midiSuppress else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: "momentary")
        NotificationCenter.default.post(name: .init("qb.momentaryChanged"), object: nil)
    }

    @objc private func midiLearn(_ sender: NSButton) {
        onMidiLearn?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuildTalkback()
        }
    }

    @objc private func midiClear(_ sender: NSButton) {
        onMidiClear?()
        rebuildTalkback()
    }

    @objc private func latencyChanged(_ sender: NSPopUpButton) {
        guard !audioSuppress, let frames = sender.selectedItem?.representedObject as? Int else { return }
        InsertServer.shared.setBufferFrames(frames)
    }

    @objc private func insertToggled(_ sender: NSButton) {
        guard !pluginSuppress else { return }
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "insertEnabled")
        InsertServer.shared.setRunning(on)
    }

    @objc private func bypassToggled(_ sender: NSButton) {
        guard !pluginSuppress else { return }
        InsertServer.shared.setBypassAll(sender.state == .on)
    }

    @objc private func openLog(_ sender: NSButton) {
        NSWorkspace.shared.open(QBLog.url)
    }

    private func sectionLabel(_ s: String) -> NSView {
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
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    func windowWillClose(_ notification: Notification) {
        // nothing persistented here — everything saves immediately on change
    }
}