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

    // per-pair controls (index = pair)
    private var nameFields: [NSTextField] = []
    private var sourcePopups: [NSPopUpButton] = []
    private var mirrorPopups: [NSPopUpButton] = []
    private var pluginPopups: [NSPopUpButton] = []
    private var enabledChecks: [NSButton] = []
    private var editorButtons: [NSButton] = []

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
        defer { suppressActions = false }
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

            // MIRROR TAP — only meaningful when the source is a mirror
            let mirrored = server.source(i).copyIndex != nil && server.source(i) != .off
            let mirrorPopup = mirrorPopups[i]
            mirrorPopup.removeAllItems()
            if mirrored {
                mirrorPopup.addItem(withTitle: "Before Plug-in")
                mirrorPopup.addItem(withTitle: "After Plug-in")
                mirrorPopup.selectItem(at: server.mirrorPre(i) ? 0 : 1)
                mirrorPopup.isEnabled = live
            } else {
                mirrorPopup.addItem(withTitle: "—")
                mirrorPopup.selectItem(at: 0)
                mirrorPopup.isEnabled = false
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
        }
    }

    // MARK: - build

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 600))
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 20
        grid.rowSpacing = 8
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

        // 4) MIRROR TAP
        grid.addRow(with: (0..<4).map { _ in sectionField("MIRROR TAP") })
        grid.addRow(with: (0..<4).map { i in
            let p = NSPopUpButton()
            p.target = self
            p.action = #selector(mirrorChanged(_:))
            p.tag = 200 + i
            mirrorPopups.append(p)
            return p
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
            let b = NSButton(title: "Open Editor…", target: self,
                             action: #selector(rowEditorOpened(_:)))
            b.tag = 450 + i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            editorButtons.append(b)
            return b
        })

        // column widths (NSGridView sizes to content; pin the popups)
        for i in 0..<4 {
            for rowIdx in [3, 5, 7] {   // source, mirror, plug-in popup rows
                if let cellView = grid.cell(atColumnIndex: i, rowIndex: rowIdx).contentView {
                    cellView.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
                }
            }
            if let nameCell = grid.cell(atColumnIndex: i, rowIndex: 1).contentView {
                nameCell.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: 840),
        ])

        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Outputs & Plug-ins"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.delegate = self
        w.center()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        // kept alive; nothing to do
    }

    // MARK: - name editing

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field.tag >= 500, field.tag < 504, !suppressActions else { return }
        let i = field.tag - 500
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.nameKey(i))
        } else {
            UserDefaults.standard.set(name, forKey: Self.nameKey(i))
        }
        QBLog.log("insert: pair \(i) named '\(name)'")
        refresh()
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

    @objc private func mirrorChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 200
        guard !suppressActions, sender.indexOfSelectedItem >= 0 else { return }
        InsertServer.shared.setMirrorPre(i, sender.indexOfSelectedItem == 0)
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