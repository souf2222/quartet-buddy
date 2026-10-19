import AppKit

/// The "Outputs & Plug-ins" window: one column per stereo output pair —
/// name, source, mirror point, plug-in, enabled, editor, and a vertical
/// signal flow. Rows align across columns via NSGridView.
///
/// Deliberately plain AppKit: native pop-up buttons, checkboxes,
/// secondary text. State lives in InsertServer; this window only reads
/// it and calls its setters.
final class OutputsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    private var window: NSWindow?
    private var suppressActions = false
    private var grid: NSGridView!

    // per-pair controls (index = pair)
    private var nameFields: [NSTextField] = []
    private var sourcePopups: [NSPopUpButton] = []
    private var includeChecks: [NSButton] = []
    private var pluginPopups: [NSPopUpButton] = []
    private var enabledChecks: [NSButton] = []
    private var editorButtons: [NSButton] = []
    private var levelSliders: [NSSlider] = []
    private var levelFields: [NSTextField] = []

    private static let nameKey: (Int) -> String = { "insertPair.\($0).name" }

    func show() {
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Current custom name for a pair ("" when unset).
    static func savedName(_ i: Int) -> String {
        UserDefaults.standard.string(forKey: nameKey(i)) ?? ""
    }

    func refresh() {
        guard window != nil else { return }
        suppressActions = true
        defer {
            suppressActions = false
            refit()
        }
        let server = InsertServer.shared
        let live = server.running

        for i in 0..<4 {
            if nameFields[i].stringValue != Self.savedName(i) {
                nameFields[i].stringValue = Self.savedName(i)
            }

            // SOURCE
            let srcPopup = sourcePopups[i]
            srcPopup.removeAllItems()
            for src in InsertServer.sourceOptions(i) {
                srcPopup.addItem(withTitle: InsertServer.sourceLabel(src, for: i))
                srcPopup.lastItem?.representedObject = src.rawValue
            }
            srcPopup.selectItem(at: srcPopup.indexOfItem(withObjectValue: server.source(i).rawValue)
                .getOrElse { 0 })
            srcPopup.isEnabled = live

            // Include source plug-in — only offered when the source is
            // a mirror. Checked = mirror AFTER the source's plug-in
            // (destination inherits its processing); unchecked = before.
            let mirrored = server.source(i).copyIndex != nil && server.source(i) != .off
            let include = includeChecks[i]
            include.isHidden = !mirrored
            if mirrored {
                include.state = server.mirrorPre(i) ? .off : .on
                include.isEnabled = live
            }

            // PLUG-IN
            let plugPopup = pluginPopups[i]
            plugPopup.removeAllItems()
            plugPopup.addItem(withTitle: "None")
            plugPopup.lastItem?.representedObject = ""
            for (name, desc) in InsertServer.listPlugins() {
                plugPopup.addItem(withTitle: name)
                plugPopup.lastItem?.representedObject = InsertServer.descKey(desc)
            }
            let key = UserDefaults.standard.string(forKey: "insertPair.\(i).plugin") ?? ""
            plugPopup.selectItem(at: plugPopup.indexOfItem(withObjectValue: key).getOrElse { 0 })
            plugPopup.isEnabled = live

            enabledChecks[i].state = (server.enabled(i) && !server.bypassAll) ? .on : .off
            enabledChecks[i].isEnabled = live && server.pluginName(i) != nil

            editorButtons[i].isEnabled = server.pluginName(i) != nil

            // LEVEL — slider + editable dB field, live state from server
            let trim = server.trim(i)
            if levelSliders[i].doubleValue != trim {
                levelSliders[i].doubleValue = trim
            }
            let text = String(format: "%+.1f dB", trim)
            if levelFields[i].stringValue != text {
                levelFields[i].stringValue = text
            }
            levelFields[i].textColor = trim > 0.01 ? .systemRed : .secondaryLabelColor
        }
    }

    // MARK: - build

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        self.grid = NSGridView()
        let grid = self.grid!
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 20
        grid.rowSpacing = 8

        // dark, translucent (blurred behind-window) background
        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        content.addSubview(blur, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: content.topAnchor),
            blur.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        content.addSubview(grid)

        // 1) column headers: Out 1‑2 … Out 7‑8
        grid.addRow(with: (0..<4).map { headerField(InsertServer.pairNames[$0]) })

        // 2) custom names (editable)
        grid.addRow(with: (0..<4).map { i in
            let f = NSTextField()
            f.placeholderString = "Name…"
            f.font = .systemFont(ofSize: 11)
            f.tag = 500 + i
            f.delegate = self
            nameFields.append(f)
            return f
        })

        // 3) SOURCE
        grid.addRow(with: (0..<4).map { _ in sectionField("SOURCE") })
        grid.addRow(with: (0..<4).map { i in
            let p = NSPopUpButton()
            p.target = self
            p.action = #selector(sourceChanged(_:))
            p.tag = 100 + i
            sourcePopups.append(p)
            return p
        })

        // 4) Include source plug-in (mirrored sources only; hidden
        //    otherwise — the grid keeps the row so columns stay aligned)
        grid.addRow(with: (0..<4).map { i in
            let c = NSButton(checkboxWithTitle: "Include source plug-in", target: self,
                             action: #selector(includeChanged(_:)))
            c.tag = 200 + i
            c.font = .systemFont(ofSize: 11)
            includeChecks.append(c)
            return c
        })

        // 5) PLUG-IN
        grid.addRow(with: (0..<4).map { _ in sectionField("PLUG-IN") })
        grid.addRow(with: (0..<4).map { i in
            let p = NSPopUpButton()
            p.target = self
            p.action = #selector(pluginChanged(_:))
            p.tag = 300 + i
            pluginPopups.append(p)
            return p
        })

        // 6) ENABLED
        grid.addRow(with: (0..<4).map { i in
            let c = NSButton(checkboxWithTitle: "Enabled", target: self,
                             action: #selector(enabledChanged(_:)))
            c.tag = 400 + i
            enabledChecks.append(c)
            return c
        })

        // 7) editors
        grid.addRow(with: (0..<4).map { i in
            let b = NSButton(title: "Show Plug-in", target: self,
                             action: #selector(rowEditorOpened(_:)))
            b.tag = 450 + i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            editorButtons.append(b)
            return b
        })

        // 8) LEVEL — input trim (slider + editable dB field)
        grid.addRow(with: (0..<4).map { _ in sectionField("Level") })
        grid.addRow(with: (0..<4).map { i in
            let sl = NSSlider(value: 0, minValue: -64, maxValue: 6, target: self,
                              action: #selector(levelSlid(_:)))
            sl.tag = 700 + i
            sl.isContinuous = true
            // double-click the knob → reset to 0 dB
            let dbl = NSClickGestureRecognizer(target: self, action: #selector(levelReset(_:)))
            dbl.numberOfClicksRequired = 2
            sl.addGestureRecognizer(dbl)
            levelSliders.append(sl)
            return sl
        })
        grid.addRow(with: (0..<4).map { i in
            let f = NSTextField()
            f.placeholderString = "0.0 dB"
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.tag = 750 + i
            f.delegate = self
            levelFields.append(f)
            return f
        })

        // fixed column widths so the window fits its content exactly
        for i in 0..<4 {
            for rowIdx in [1, 3, 6, 10, 11] {   // name, source, plug-in, slider, dB rows
                if let cellView = grid.cell(atColumnIndex: i, rowIndex: rowIdx).contentView {
                    cellView.widthAnchor.constraint(equalToConstant: 170).isActive = true
                }
            }
        }

        NSLayoutConstraint.activate([
            // 52pt top inset: the window has no visible title bar — the
            // close/minimize buttons float over the blurred background,
            // so the grid must clear the traffic-light zone
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 52),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Outputs & Plug-ins"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.styleMask.insert(.fullSizeContentView)   // content under the buttons
        w.titlebarAppearsTransparent = true        // one uniform surface
        w.titleVisibility = .hidden                // no title text
        w.isMovableByWindowBackground = true       // drag anywhere (blur = background)
        w.contentView = content
        w.delegate = self
        window = w
        refit()
    }

    /// Size the window to exactly fit the grid (+ edges), keep centered.
    private func refit() {
        guard let w = window, grid != nil else { return }
        contentLayout()
        let fit = grid.fittingSize
        let size = NSSize(width: fit.width + 48, height: fit.height + 72)
        if abs(w.contentView?.frame.size.width ?? 0 - size.width) > 1 ||
           abs(w.contentView?.frame.size.height ?? 0 - size.height) > 1 {
            w.setContentSize(size)
            w.center()
        }
    }

    private func contentLayout() {
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        // kept alive; nothing to do
    }

    // MARK: - name editing

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, !suppressActions else { return }
        if field.tag >= 500, field.tag < 504 {
            // custom output name
            let i = field.tag - 500
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.nameKey(i))
            } else {
                UserDefaults.standard.set(name, forKey: Self.nameKey(i))
            }
            QBLog.log("insert: pair \(i) named '\(name)'")
            refresh()
        } else if field.tag >= 750, field.tag < 754 {
            // Level dB field — parse ("−6", "-6 dB", "+3.5 dB", …)
            let i = field.tag - 750
            var t = field.stringValue
                .replacingOccurrences(of: "dB", with: "")
                .replacingOccurrences(of: "\u{2212}", with: "-")
                .trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("+") { t.removeFirst() }
            if let db = Double(t) {
                InsertServer.shared.setTrim(i, db)
            }
            refresh()
        }
    }

    // MARK: - helpers

    private func headerField(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }
    private func sectionField(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 10, weight: .semibold)
        f.textColor = .secondaryLabelColor
        return f
    }

    // MARK: - actions

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 100
        guard !suppressActions, let raw = sender.selectedItem?.representedObject as? String,
              let src = InsertServer.PairSource(rawValue: raw) else { return refresh() }
        InsertServer.shared.setSource(i, src)
        refresh()
    }

    /// "Include source plug-in" — checked = mirror AFTER the source's
    /// plug-in; unchecked = before (raw playback channels).
    @objc private func includeChanged(_ sender: NSButton) {
        let i = sender.tag - 200
        guard !suppressActions else { return refresh() }
        InsertServer.shared.setMirrorPre(i, sender.state == .off)
        refresh()
    }

    @objc private func pluginChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 300
        guard !suppressActions, let key = sender.selectedItem?.representedObject as? String else { return refresh() }
        let desc = key.isEmpty ? nil
            : InsertServer.listPlugins().first { InsertServer.descKey($0.desc) == key }?.desc
        InsertServer.shared.setPlugin(i, desc)
        refresh()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        let i = sender.tag - 400
        guard !suppressActions else { return refresh() }
        InsertServer.shared.setEnabled(i, sender.state == .on)
        refresh()
    }

    @objc private func rowEditorOpened(_ sender: NSButton) {
        InsertServer.shared.showPluginUI(sender.tag - 450)
    }

    /// Level slider (tag = 700 + pair). Soft-snaps to unity.
    @objc private func levelSlid(_ sender: NSSlider) {
        let i = sender.tag - 700
        var v = sender.doubleValue
        if abs(v) < 0.5 { v = 0 }   // snap near unity
        // quiet: the audio path updates live; a full window refresh on
        // every drag tick would rebuild all plug-in popups (slow)
        InsertServer.shared.setTrim(i, v, notify: false)
        suppressActions = true
        let text = String(format: "%+.1f dB", min(6.0, max(-64.0, v)))
        levelFields[i].stringValue = text
        levelFields[i].textColor = v > 0.01 ? .systemRed : .secondaryLabelColor
        suppressActions = false
    }

    /// Double-click the slider knob → reset to 0 dB.
    @objc private func levelReset(_ g: NSClickGestureRecognizer) {
        guard let sl = g.view as? NSSlider else { return }
        let i = sl.tag - 700
        InsertServer.shared.setTrim(i, 0)
        refresh()
    }
}

private extension NSPopUpButton {
    /// Index of the item whose representedObject == value, or nil.
    func indexOfItem(withObjectValue value: String) -> Int? {
        for (i, item) in itemArray.enumerated() where item.representedObject as? String == value {
            return i
        }
        return nil
    }
}

private extension Optional where Wrapped == Int {
    func getOrElse(_ f: () -> Int) -> Int { self ?? f() }
}