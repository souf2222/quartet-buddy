import AppKit
import CoreAudio

/// The "Outputs & Plug-ins" window: one row per stereo output pair
/// (source / plug-in / enabled), with a details pane for the selected
/// pair (route, mirror point, editor, signal flow).
///
/// Deliberately plain AppKit: native pop-up buttons, checkboxes,
/// secondary text. State lives in InsertServer; this window only
/// reads it and calls its setters.
final class OutputsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var selectedPair = 0
    private var suppressActions = false

    // row controls per pair
    private var sourcePopups: [NSPopUpButton] = []
    private var pluginPopups: [NSPopUpButton] = []
    private var enabledChecks: [NSButton] = []

    // detail controls
    private var detailTitle: NSTextField!
    private var detailRoute: NSTextField!
    private var mirrorLabel: NSTextField!
    private var mirrorPopup: NSPopUpButton!
    private var flowField: NSTextField!
    private var editorButton: NSButton!
    private var statusField: NSTextField!

    func show() {
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard window != nil else { return }
        suppressActions = true
        defer { suppressActions = false }
        let server = InsertServer.shared

        // header sensitivity: nothing to route without the Quartet
        let live = server.running

        for i in 0..<4 {
            // sources
            let srcPopup = sourcePopups[i]
            srcPopup.removeAllItems()
            for src in InsertServer.sourceOptions(i) {
                srcPopup.addItem(withTitle: InsertServer.sourceLabel(src, for: i))
                srcPopup.lastItem?.representedObject = src.rawValue
            }
            srcPopup.selectItem(at: srcPopup.indexOfItem(withObjectValue: server.source(i).rawValue)
                .getOrElse { srcPopup.indexOfItem(withTitle: InsertServer.sourceLabel(.systemMix, for: i)) })
            srcPopup.isEnabled = live && i > 0

            // plug-ins
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

            enabledChecks[i].state = server.enabled(i) && !server.bypassAll ? .on : .off
            enabledChecks[i].isEnabled = live && server.pluginName(i) != nil
        }

        // details
        let i = selectedPair
        detailTitle.stringValue = InsertServer.pairNames[i]
        detailRoute.stringValue = server.routeSummary(i)
        flowField.stringValue = server.flowLine(i)

        let mirrored = server.source(i).copyIndex != nil && server.source(i) != .off && i != server.source(i).copyIndex
        mirrorLabel.isHidden = !mirrored
        mirrorPopup.isHidden = !mirrored
        if mirrored {
            mirrorPopup.selectItem(at: server.mirrorPre(i) ? 0 : 1)
        }
        mirrorPopup.isEnabled = live

        let hasPlugin = server.pluginName(i) != nil
        editorButton.isEnabled = hasPlugin && !server.running || hasPlugin && server.running
        editorButton.isHidden = !hasPlugin
        statusField.stringValue = live ? "" : "Quartet not connected — routing is inactive."
        if server.running && server.tapSilent {
            statusField.stringValue = "⚠️ Tap silent — allow Quartet Buddy in System Settings → Privacy → System Audio Recording."
        }
    }

    // MARK: - build

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.addSubview(stack)

        // table header
        let header = makeGridRow(output: "Output", source: "Audio Source",
                                 plugin: "Plug-in", enabled: "Enabled", bold: true)
        stack.addArrangedSubview(header)

        // rows
        for i in 0..<4 {
            let outLabel = secondaryTextField(InsertServer.pairNames[i], bold: true)
            let srcPopup = NSPopUpButton()
            srcPopup.translatesAutoresizingMaskIntoConstraints = false
            srcPopup.action = #selector(sourceChanged(_:))
            srcPopup.target = self
            srcPopup.tag = 100 + i
            sourcePopups.append(srcPopup)

            let plugPopup = NSPopUpButton()
            plugPopup.translatesAutoresizingMaskIntoConstraints = false
            plugPopup.action = #selector(pluginChanged(_:))
            plugPopup.target = self
            plugPopup.tag = 200 + i
            pluginPopups.append(plugPopup)

            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledChanged(_:)))
            check.tag = 300 + i
            enabledChecks.append(check)

            let row = NSStackView(views: [outLabel, srcPopup, plugPopup, check])
            row.orientation = .horizontal
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            // fixed column widths so the rows align
            NSLayoutConstraint.activate([
                outLabel.widthAnchor.constraint(equalToConstant: 70),
                srcPopup.widthAnchor.constraint(equalToConstant: 170),
                plugPopup.widthAnchor.constraint(equalToConstant: 190),
                check.widthAnchor.constraint(equalToConstant: 64),
            ])
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(makeSeparator())

        // details pane
        let detailBox = NSBox()
        detailBox.boxType = .custom
        detailBox.borderType = .noBorder
        detailBox.title = ""
        detailBox.translatesAutoresizingMaskIntoConstraints = false
        let dstack = NSStackView()
        dstack.orientation = .vertical
        dstack.alignment = .leading
        dstack.spacing = 8
        dstack.translatesAutoresizingMaskIntoConstraints = false
        detailBox.contentView = dstack

        detailTitle = NSTextField(labelWithString: "Out 1‑2")
        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        dstack.addArrangedSubview(detailTitle)

        detailRoute = secondaryTextField("")
        dstack.addArrangedSubview(detailRoute)

        // mirror point row
        let mirrorRow = NSStackView(views: [])
        mirrorRow.orientation = .horizontal
        mirrorRow.spacing = 8
        mirrorLabel = secondaryTextField("Mirror Signal")
        mirrorPopup = NSPopUpButton()
        mirrorPopup.translatesAutoresizingMaskIntoConstraints = false
        mirrorPopup.addItem(withTitle: "Before Source Plug-in")
        mirrorPopup.addItem(withTitle: "After Source Plug-in")
        mirrorPopup.action = #selector(mirrorChanged(_:))
        mirrorPopup.target = self
        mirrorRow.addArrangedSubview(mirrorLabel)
        mirrorRow.addArrangedSubview(mirrorPopup)
        dstack.addArrangedSubview(mirrorRow)

        // editor + status row
        let actionRow = NSStackView(views: [])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        editorButton = NSButton(title: "Open Editor…", target: self, action: #selector(openEditor(_:)))
        actionRow.addArrangedSubview(editorButton)
        statusField = secondaryTextField("")
        statusField.lineBreakMode = .byWordWrapping
        statusField.maximumNumberOfLines = 2
        actionRow.addArrangedSubview(statusField)
        dstack.addArrangedSubview(actionRow)

        // signal flow
        dstack.addArrangedSubview(secondaryTextField("Signal Flow", bold: true))
        flowField = secondaryTextField("")
        flowField.lineBreakMode = .byWordWrapping
        flowField.maximumNumberOfLines = 2
        dstack.addArrangedSubview(flowField)

        stack.addArrangedSubview(detailBox)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            statusField.widthAnchor.constraint(equalToConstant: 240),
            flowField.widthAnchor.constraint(equalTo: detailBox.widthAnchor),
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
        // kept alive; nothing to do (views are ours, plugins' views stay
        // owned by InsertServer's editor windows)
    }

    // MARK: - helpers

    private func makeGridRow(output: String, source: String, plugin: String,
                              enabled: String, bold: Bool) -> NSStackView {
        let views = [secondaryTextField(output, bold: bold),
                    secondaryTextField(source, bold: bold),
                    secondaryTextField(plugin, bold: bold),
                    secondaryTextField(enabled, bold: bold)]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 12
        NSLayoutConstraint.activate([
            views[0].widthAnchor.constraint(equalToConstant: 70),
            views[1].widthAnchor.constraint(equalToConstant: 170),
            views[2].widthAnchor.constraint(equalToConstant: 190),
            views[3].widthAnchor.constraint(equalToConstant: 64),
        ])
        return row
    }

    private func secondaryTextField(_ s: String, bold: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: f.font == nil ? 12 : 12, weight: bold ? .semibold : .regular)
        f.textColor = bold ? nil : .secondaryLabelColor
        return f
    }

    private func makeSeparator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    // MARK: - actions

    // Row selection: each control sets selectedPair from its tag.

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        selectedPair = sender.tag - 100
        guard !suppressActions, let raw = sender.selectedItem?.representedObject as? String,
              let src = InsertServer.PairSource(rawValue: raw) else { return refresh() }
        InsertServer.shared.setSource(selectedPair, src)
        refresh()
    }

    @objc private func pluginChanged(_ sender: NSPopUpButton) {
        selectedPair = sender.tag - 200
        guard !suppressActions, let key = sender.selectedItem?.representedObject as? String else { return refresh() }
        let desc = key.isEmpty ? nil
            : InsertServer.listPlugins().first { InsertServer.descKey($0.desc) == key }?.desc
        InsertServer.shared.setPlugin(selectedPair, desc)
        refresh()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        selectedPair = sender.tag - 300
        guard !suppressActions else { return refresh() }
        InsertServer.shared.setEnabled(selectedPair, sender.state == .on)
        refresh()
    }

    @objc private func mirrorChanged(_ sender: NSPopUpButton) {
        guard !suppressActions else { return }
        InsertServer.shared.setMirrorPre(selectedPair, sender.indexOfSelectedItem == 0)
        refresh()
    }

    @objc private func openEditor(_ sender: NSButton) {
        InsertServer.shared.showPluginUI(selectedPair)
    }
}

private extension NSPopUpButton {
    /// Index of the item whose representedObject == value, or fallback.
    func indexOfItem(withObjectValue value: String) -> Int? {
        for (i, item) in enumerateItems() where item.representedObject as? String == value {
            return i
        }
        return nil
    }
    func enumerateItems() -> [(Int, NSMenuItem)] {
        itemArray.enumerated().map { ($0.offset, $0.element) }
    }
}

extension Optional where Wrapped == Int {
    func getOrElse(_ f: () -> Int) -> Int { self ?? f() }
}