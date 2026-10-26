import AppKit
import ServiceManagement

/// "Quartet Buddy Settings" — a sidebar shell with one pane per area,
/// organized by ownership (app vs. hardware vs. audio feature):
///
///     ⚙ General · ⌘ Shortcuts · ▣ Quartet · ≈ Processing · ◉ Talkback · ⓘ About
///
/// General holds the application's own preferences (launch at login, knob
/// interaction). Quartet holds everything that is written to the hardware
/// (touchscreen flags, front-panel pads, channel names, line-output
/// levels) with Controls / Channel Names / Output Levels sub-sections.
/// Processing combines the audio-engine config with Auto Gain and plug-in
/// configuration. Hotkey registration and MIDI learning stay owned by
/// AppDelegate — this window calls back through the closures it wires up.
/// Shortcut bindings live in ShortcutManager (wired in as `shortcuts`).
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    /// Wired by AppDelegate.
    var onMidiLearn: (() -> Void)?
    var onMidiClear: (() -> Void)?
    /// The MIDI-learn state lives with the MIDI watcher (AppDelegate);
    /// `onMidiCancel` abandons a learn in progress.
    var isMidiLearning: (() -> Bool)?
    var onMidiCancel: (() -> Void)?
    /// The shortcut engine (bindings, conflicts, defaults).
    var shortcuts: ShortcutManager?

    /// Device-node plumbing (wired by AppDelegate):
    /// - `readDeviceProps` → the connected Quartet's dev-node props dict
    ///   (nil = no tree/Quartet away).
    /// - `writeDeviceFlag` → a 0/1 hardware preference write (identified
    ///   by its property name).
    var readDeviceProps: (() -> [String: Any]?)?
    var writeDeviceFlag: ((String, Bool) -> Void)?

    /// Talkback source picker: `readTalkback` → the helper app's subtree
    /// description (sources + selection), `writeTalkbackSource` → the
    /// source-device + channel writes.
    var readTalkback: (() -> AppDelegate.TalkbackSourceDescription?)?
    var writeTalkbackSource: ((String, Int) -> Void)?

    /// Front-panel pad assignments: `readPadAssignments` → the tree's
    /// four `actionButton` values (Touchpad_A/B/C, Encoder_Push, nil when
    /// absent), `writePadAssignment(slot, actionValue)` → one int32
    /// setProperty (live-verified remap path).
    var readPadAssignments: (() -> [Int?])?
    var writePadAssignment: ((Int, Int) -> Void)?

    private var window: NSWindow?
    private var sidebarButtons: [Pane: NSButton] = [:]
    private var paneViews: [Pane: NSView] = [:]
    private var currentPane: Pane = .general

    // MARK: Names (Quartet ▸ Channel Names)

    /// Renames live here instead of the control window's inline
    /// double-click (which never stuck reliably). Three groups:
    /// the Quartet's hardware input names, its hardware output names
    /// (both written THROUGH ApogeeGlue — the touchscreen follows), and
    /// the app-side stereo-pair display names.
    ///
    /// `readNames` → current values in ROW ORDER (nil = not connected),
    /// `writeName` is routed by the row's kind + index.
    struct NameRow {
        enum Kind { case hwInput, hwOutput, pair, adat }
        let kind: Kind
        /// hardware/pair index for the write routing
        let index: Int
    }
    var readNames: (() -> [String]?)?
    var writeName: ((Int, String) -> Void)?

    /// The FIXED row list (order = the read/write callback order).
    private let nameRows: [NameRow] = (0..<4).map { NameRow(kind: .hwInput, index: $0) }
        + (0..<8).map { NameRow(kind: .hwOutput, index: $0) }
        + (0..<4).map { NameRow(kind: .pair, index: $0) }
        + (0..<8).map { NameRow(kind: .adat, index: $0) }
    /// Static row labels — fixed physical channel identifiers, so a
    /// renamed input doesn't shift the row the user is looking for. The
    /// editable field beside each shows the current (hardware) name.
    private static let hwInLabels = ["Input 1 (Mic/line)", "Input 2 (Mic/line)",
                                     "Input 3 (Mic/line)", "Input 4 (Mic/line)"]
    private static let hwOutLabels = ["Main output", "Headphones", "Analog output 1", "Analog output 2",
                                      "Analog output 3", "Analog output 4", "Analog output 5",
                                      "Analog output 6"]
    private static let pairLabels = ["Pair 1", "Pair 2", "Pair 3", "Pair 4"]
    private static let adatLabels = (0..<8).map { "Digital \($0 + 1)" }

    private var nameFields: [NSTextField] = []
    private var nameSuppress = false
    /// Value captured when a name field gains its editor — Escape
    /// restores it and skips the write.
    private var nameEditOriginals: [ObjectIdentifier: String] = [:]

    enum Pane: Int, CaseIterable {
        case general, shortcuts, quartet, processing, talkback, about

        var icon: String {
            switch self {
            case .general: return "⚙"
            case .shortcuts: return "⌘"
            case .quartet: return "▣"
            case .processing: return "≈"
            case .talkback: return "◉"
            case .about: return "ⓘ"
            }
        }
        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .quartet: return "Quartet"
            case .processing: return "Processing"
            case .talkback: return "Talkback"
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
        // open at the TOP of every scrolling pane (docs are unflipped —
        // their origin is the bottom edge, so top == bounds.maxY).
        window?.contentView?.layoutSubtreeIfNeeded()
        for (_, doc) in docViews {
            doc.scroll(NSPoint(x: 0, y: doc.bounds.maxY))
        }
    }

    /// Open straight to the Shortcuts pane.
    func showShortcuts() {
        show()
        selectPane(.shortcuts)
    }

    func refresh() {
        guard window != nil else { return }
        rebuildTalkback()
        refreshTalkbackSource()
        rebuildProcessing()
        rebuildShortcuts()
        refreshQuartet()
    }

    // MARK: - build (the shared page shell)

    private func build() {
        let content = NSView(frame: NSRect(origin: .zero,
                                           size: SettingsLayout.pageSize))
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
            sidebar.widthAnchor.constraint(equalToConstant: SettingsLayout.sidebarWidth),
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

        let w = QuartetWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Quartet Buddy Settings"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.delegate = self
        w.center()
        w.minSize = SettingsLayout.minPageSize
        w.maxSize = NSSize(width: 1600, height: 1200)
        // Native dark surface — the standard window background, matching
        // Quartet Control's system-material look in every appearance.
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor.windowBackgroundColor
        window = w
    }

    /// Sidebar: the standard sidebar MATERIAL (the system's own surface,
    /// like System Settings — a NSVisualEffectView with the .sidebar
    /// material, correct in every appearance), light text, and a clear
    /// selected-row pill.
    ///
    /// NB never assign a dynamic color's `.cgColor` to a layer here: it
    /// resolves against whatever appearance is CURRENT at that moment
    /// (before the window's darkAqua is guaranteed), yielding the LIGHT
    /// variant — a white sidebar with white text.
    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
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
            // Full-width row: the row carries the selected highlight, the
            // button stays transparent — a recessed bezel would fight it.
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            let b = NSButton(title: "\(pane.icon)  \(pane.title)", target: self,
                             action: #selector(sidebarClicked(_:)))
            b.isBordered = false
            b.alignment = .left
            b.tag = pane.rawValue
            b.font = .systemFont(ofSize: 13, weight: .medium)
            b.contentTintColor = GGTheme.primary
            b.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(b)
            NSLayoutConstraint.activate([
                b.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                b.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 30),
            ])
            stack.addArrangedSubview(row)
            // equal widths — every pill spans the sidebar's content width
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            paneRows[pane] = row
            sidebarButtons[pane] = b
        }
        return sidebar
    }

    /// Sidebar rows (the highlight carriers).
    private var paneRows: [Pane: NSView] = [:]

    /// A pane = title + body. The Shortcuts / Quartet / Processing panes
    /// may exceed the window — they scroll. Everything else hugs its
    /// content (a scroll view around a plain NSView stretches it, which
    /// pushed the controls down and showed a phantom scrollbar).
    private func makePane(_ pane: Pane) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: pane.title)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = GGTheme.primary
        title.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: SettingsLayout.titleTopInset),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor,
                                           constant: SettingsLayout.contentPadding),
        ])
        let body = formStack()
        bodyViews[pane] = body

        if pane == .shortcuts || pane == .quartet || pane == .processing {
            // These panes can outgrow the window — they scroll. The
            // document view is FULLY chained to the body (top, leading,
            // trailing AND bottom) and width-locked to the clip view, so
            // its height derives from the table — without the bottom link
            // Auto Layout cannot size a plain NSView document and the
            // scroll view renders it zero-height (empty pane) with its
            // own background as a stray darker rectangle.
            let doc = NSView()
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(body)
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.documentView = doc
            v.addSubview(scroll)
            docViews[pane] = doc
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: title.bottomAnchor,
                                            constant: SettingsLayout.titleBodyGap),
                scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor,
                                                constant: SettingsLayout.contentPadding),
                scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor,
                                                 constant: -SettingsLayout.contentPadding),
                scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
                body.topAnchor.constraint(equalTo: doc.topAnchor),
                body.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                // <= (NOT ==): the doc may stretch taller than the table
                // (doc.height >= clip.height); an equality pin would drag
                // the body to the doc's BOTTOM edge, opening the pane
                // scrolled to the end. The stack hugs the TOP — same
                // pattern as the control window's scroll area.
                body.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                // content fills at least the visible area, never a stub.
                doc.heightAnchor.constraint(
                    greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            ])
        } else {
            // Top-pinned, hugs its content — no expanding gap, no scrollbar.
            v.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: title.bottomAnchor,
                                          constant: SettingsLayout.titleBodyGap),
                body.leadingAnchor.constraint(equalTo: v.leadingAnchor,
                                              constant: SettingsLayout.contentPadding),
                body.trailingAnchor.constraint(equalTo: v.trailingAnchor,
                                               constant: -SettingsLayout.contentPadding),
            ])
        }
        switch pane {
        case .general: buildGeneral(into: body)
        case .shortcuts: buildShortcuts(into: body)
        case .quartet: buildQuartet(into: body)
        case .processing: buildProcessing(into: body)
        case .talkback: buildTalkback(into: body)
        case .about: buildAbout(into: body)
        }
        body.addArrangedSubview(gap(SettingsLayout.bottomPadding))
        return v
    }

    private var bodyViews: [Pane: NSStackView] = [:]
    /// Document views of the scrolling panes (top-scroll on show).
    private var docViews: [Pane: NSView] = [:]

    /// The standard vertical form stack every pane (and every Quartet
    /// sub-section) builds into — one row/section spacing everywhere.
    private func formStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = SettingsLayout.rowSpacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    @objc private func sidebarClicked(_ sender: NSButton) {
        guard let pane = Pane(rawValue: sender.tag) else { return }
        selectPane(pane)
    }

    private func selectPane(_ pane: Pane) {
        currentPane = pane
        for (p, view) in paneViews { view.isHidden = p != pane }
        for (p, row) in paneRows {
            row.layer?.backgroundColor = (p == pane)
                ? NSColor(white: 1, alpha: 0.10).cgColor   // clear selected pill
                : NSColor.clear.cgColor
        }
        for (p, button) in sidebarButtons {
            button.font = .systemFont(ofSize: 13, weight: p == pane ? .semibold : .medium)
        }
    }

    private func gap(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: - General (application preferences)

    private var loginCheck: NSButton!
    private var scrollDirPopup: NSPopUpButton!

    /// UserDefaults key: when true, scrolling DOWN on a knob increases
    /// the value (classic mouse-wheel convention — "wheel down = more"),
    /// the reverse of the natural trackpad direction. Read live by
    /// GainKnob.scrollWheel.
    static let invertScrollKey = "invertKnobScroll"

    private func buildGeneral(into body: NSStackView) {
        // STARTUP — app-local concern.
        SettingsSection.add(to: body, "Startup")
        loginCheck = NSButton(checkboxWithTitle: "Launch Quartet Buddy at login",
                              target: self, action: #selector(loginChanged(_:)))
        // The checkbox mirrors the actual registration (SMAppService) —
        // previously it never read state back and desynced from the
        // menubar toggle and the `launchAtLogin` key.
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        body.addArrangedSubview(loginCheck)

        // KNOB INTERACTION — scroll-direction preference, live-read by
        // the control window's knobs (no restart needed).
        SettingsSection.add(to: body, "Knob interaction")
        scrollDirPopup = NSPopUpButton()
        scrollDirPopup.addItems(withTitles: ["Standard", "Inverted"])
        scrollDirPopup.selectItem(
            at: UserDefaults.standard.bool(forKey: Self.invertScrollKey) ? 1 : 0)
        scrollDirPopup.action = #selector(scrollDirectionChanged(_:))
        scrollDirPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Scroll direction",
                                                  control: scrollDirPopup,
                                                  controlWidth: 160))
        body.addArrangedSubview(SettingsHelpText.label(
            "Standard: scroll up increases the value; Inverted goes the other way\n" +
            "(classic wheel — down = more). Applies only to the knobs in Quartet\n" +
            "Buddy (gain, trim, monitor level) — never to system scrolling."))

        // TROUBLESHOOTING
        SettingsSection.add(to: body, "Troubleshooting")
        body.addArrangedSubview(NSButton(title: "Open Debug Log…", target: self,
                                         action: #selector(openLog(_:))))
    }

    // MARK: - Shortcuts (the Keyboard Shortcuts table)

    private var globalCheck: NSButton!
    private var searchField: NSSearchField!
    private var filterPopup: NSPopUpButton!
    private var shortcutStack: NSStackView!
    /// The pane's form stack (the page's fixed-width content area) — every
    /// table row and the column header pin to ITS width, so all rows share
    /// one grid regardless of how long each action name is.
    private var shortcutBody: NSStackView?
    private var volStepLabel: NSTextField!
    private var fineStepLabel: NSTextField!
    private var expandedSections: Set<String> = [
        "Window & Navigation", "Speakers", "Headphones",
        "Volume-Control Target", "Talkback", "Plug-ins", "Safety"]
    private var pendingScope: [ShortcutAction: Bool] = [:]
    /// The Global checkbox of each visible row (rebuilt with the table).
    private var scopeChecks: [ShortcutAction: NSButton] = [:]

    /// THE SHARED COLUMN GRID — one definition for the header and every
    /// row, in order: stretchable Action | Shortcut | clear | Global.
    /// Column positions never depend on label or shortcut-text lengths.
    private enum ShortcutColumns {
        static let recordWidth: CGFloat = 140
        static let clearWidth: CGFloat = 26
        static let globalWidth: CGFloat = 40
        static let spacing: CGFloat = 8
    }

    private func buildShortcuts(into body: NSStackView) {
        shortcutBody = body
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

        // the table: column header + groups + rows, rebuilt on each change
        shortcutStack = NSStackView()
        shortcutStack.orientation = .vertical
        shortcutStack.alignment = .leading
        shortcutStack.spacing = 3
        shortcutStack.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(shortcutStack)
        let header = shortcutHeaderRow()
        shortcutStack.addArrangedSubview(header)
        pinRowWidth(header)

        // footer
        SettingsSection.add(to: body, "Options")
        globalCheck = NSButton(checkboxWithTitle: "Enable global shortcuts",
                               target: self, action: #selector(globalToggled(_:)))
        body.addArrangedSubview(globalCheck)
        body.addArrangedSubview(SettingsHelpText.label(
            "Global shortcuts work while another app is active."))

        body.addArrangedSubview(LabeledSettingRow(
            "Volume step", control: stepperRow(tag: 1), controlWidth: 110))
        body.addArrangedSubview(LabeledSettingRow(
            "Fine step", control: stepperRow(tag: 2), controlWidth: 110))
        body.addArrangedSubview(SettingsHelpText.label(
            ""))  // placeholder keeps a consistent row; text set in rebuild
        fineStepHelp = body.arrangedSubviews.last as? NSTextField

        let restore = NSButton(title: "Restore Defaults…", target: self,
                               action: #selector(restoreDefaults(_:)))
        body.addArrangedSubview(restore)

        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(equalToConstant: 200),
            filterPopup.widthAnchor.constraint(equalToConstant: 170),
        ])
    }

    private var fineStepHelp: NSTextField?

    /// The column header row — the same shared grid as the action rows:
    /// stretchable Action | Shortcut (right-aligned in its column) |
    /// clear-cell spacer | Global (centered in its column). Its cells
    /// therefore sit exactly above the rows' controls. Pinned to the page
    /// width together with the rows, so the columns can't drift.
    private func shortcutHeaderRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ShortcutColumns.spacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let action = NSTextField(labelWithString: "Action")
        action.font = .systemFont(ofSize: 11)
        action.textColor = .secondaryLabelColor
        action.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)   // stretches
        row.addArrangedSubview(action)

        let shortcut = NSTextField(labelWithString: "Shortcut")
        shortcut.font = .systemFont(ofSize: 11)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        row.addArrangedSubview(shortcut)

        // empty cell over the clear column keeps the column pitch
        row.addArrangedSubview(centeredCell(NSView(), width: ShortcutColumns.clearWidth))

        let global = NSTextField(labelWithString: "Global")
        global.font = .systemFont(ofSize: 11)
        global.textColor = .secondaryLabelColor
        global.alignment = .center
        row.addArrangedSubview(centeredCell(global, width: ShortcutColumns.globalWidth))
        return row
    }

    /// A fixed-width column CELL with its control centered horizontally
    /// and vertically — used for the clear buttons and the Global
    /// checkboxes (and their header captions), so a checkbox sits in the
    /// exact center of its column whatever its own bounds.
    private func centeredCell(_ control: NSView, width: CGFloat) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: width),
            cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            control.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// One fixed-column shortcut row built from the SAME grid as the
    /// header: the stretchable Action cell takes the remaining width, and
    /// the Shortcut / clear / Global cells have identical widths on every
    /// row — nothing depends on the length of a name or a combo.
    private func makeShortcutRow(_ action: ShortcutAction, shortcuts: ShortcutManager) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ShortcutColumns.spacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = false
        // stretches to fill the Action column, truncates only if needed
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        row.addArrangedSubview(label)

        let record = NSButton(title: "", target: self, action: #selector(recordShortcut(_:)))
        record.bezelStyle = .rounded
        record.controlSize = .regular
        record.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        setShortcutTitle(record, action, shortcuts)
        row.addArrangedSubview(record)

        let clear = NSButton(title: "×", target: self, action: #selector(clearShortcut(_:)))
        clear.bezelStyle = .recessed
        clear.toolTip = "Clear shortcut"
        clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        clear.font = .systemFont(ofSize: 12)
        clear.isEnabled = shortcuts.bindings[action] != nil
        row.addArrangedSubview(centeredCell(clear, width: ShortcutColumns.clearWidth))

        let global = NSButton(checkboxWithTitle: "", target: self,
                              action: #selector(scopeToggled(_:)))
        global.toolTip = "Global — works while another app is active"
        global.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        global.state = (shortcuts.bindings[action]?.isGlobal ?? action.defaultGlobal) ? .on : .off
        scopeChecks[action] = global
        row.addArrangedSubview(centeredCell(global, width: ShortcutColumns.globalWidth))

        NSLayoutConstraint.activate([
            record.widthAnchor.constraint(equalToConstant: ShortcutColumns.recordWidth),
        ])
        return row
    }

    /// Rows must span the page content width — pinned AFTER the row enters
    /// the hierarchy (a cross-hierarchy constraint may only be activated
    /// once the anchors share a common ancestor), and to the PAGE's fixed
    /// content width, not the stack's own width.
    private func pinRowWidth(_ v: NSView) {
        guard let body = shortcutBody else { return }
        v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    /// Recorder title = the binding (or "Not set"), tinted orange with an
    /// explanatory tooltip when another action holds the same combo in
    /// the same scope. Reassignment still asks first (see recordShortcut).
    private func setShortcutTitle(_ button: NSButton, _ action: ShortcutAction,
                                  _ shortcuts: ShortcutManager) {
        guard let binding = shortcuts.bindings[action] else {
            button.title = "Not set"
            button.toolTip = "Record a key combination"
            return
        }
        if let other = sameScopeConflict(of: action, in: shortcuts) {
            button.attributedTitle = NSAttributedString(
                string: binding.combo.displayString,
                attributes: [.foregroundColor: NSColor.systemOrange,
                             .font: NSFont.systemFont(ofSize: 13)])
            button.toolTip = "\"\(binding.combo.displayString)\" is also assigned to " +
                "\"\(other.title)\" in the same scope."
            QBLog.log("shortcuts: conflict — \(action.rawValue) shares \(binding.combo.displayString) " +
                      "with \(other.rawValue) (same scope)")
        } else {
            button.title = binding.combo.displayString
            button.toolTip = nil
        }
    }

    /// Another action with the SAME key combination AND scope (global vs
    /// app-only) — visible conflicts, never silently replaced.
    private func sameScopeConflict(of action: ShortcutAction,
                                   in shortcuts: ShortcutManager) -> ShortcutAction? {
        guard let b = shortcuts.bindings[action] else { return nil }
        for other in ShortcutAction.allCases where other != action {
            if let ob = shortcuts.bindings[other],
               ob.combo.keyCode == b.combo.keyCode,
               ob.combo.modifiers == b.combo.modifiers,
               ob.isGlobal == b.isGlobal {
                return other
            }
        }
        return nil
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

    private func stepperRow(tag: Int) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let s = makeStepStepper(tag)
        s.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(s)
        let l = tag == 2 ? {
            fineStepLabel = stepLabel(); return fineStepLabel!
        }() : {
            volStepLabel = stepLabel(); return volStepLabel!
        }()
        l.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(l)
        return stack
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

    /// Rebuild the shortcut table: groups in catalog order, plain
    /// disclosure headers, fixed-column rows. A search reveals matches
    /// inside collapsed groups (groups force-expand while searching).
    private func rebuildShortcuts() {
        guard let shortcuts, let shortcutStack else { return }
        globalCheck.state = shortcuts.globalEnabled ? .on : .off
        volStepLabel.stringValue = String(format: "%.1f dB", shortcuts.volumeStep)
        fineStepLabel.stringValue = String(format: "%.1f dB", shortcuts.fineStep)
        fineStepHelp?.stringValue =
            "Steps for the volume/monitor keyboard shortcuts — apply only when a shortcut is used."

        let q = (searchField.stringValue).trimmingCharacters(in: .whitespaces).lowercased()
        let filter = filterPopup.indexOfSelectedItem

        // keep the column header at the top while the groups rebuild
        let header = shortcutStack.arrangedSubviews.first
        shortcutStack.views.forEach { shortcutStack.removeView($0) }
        scopeChecks.removeAll()
        if let header {
            shortcutStack.addArrangedSubview(header)
            pinRowWidth(header)
        }

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
            shortcutStack.addArrangedSubview(sectionHeader(section, expanded: expanded))
            guard expanded else { continue }
            for action in actions {
                let row = makeShortcutRow(action, shortcuts: shortcuts)
                shortcutStack.addArrangedSubview(row)
                pinRowWidth(row)
            }
        }
        let spacer = gap(4)
        shortcutStack.addArrangedSubview(spacer)
    }

    /// A plain disclosure heading (no recessed pill) that toggles its
    /// group — triangle + section name in the standard heading style.
    private func sectionHeader(_ section: String, expanded: Bool) -> NSView {
        let b = NSButton(title: "\(expanded ? "▾" : "▸")  \(section)", target: self,
                         action: #selector(sectionToggled(_:)))
        b.isBordered = false
        b.alignment = .left
        b.font = .systemFont(ofSize: 12, weight: .semibold)
        b.contentTintColor = .labelColor
        b.identifier = NSUserInterfaceItemIdentifier(section)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func orderedSections() -> [String] {
        var seen: [String] = []
        for a in ShortcutAction.allCases where !seen.contains(a.section) { seen.append(a.section) }
        return seen
    }

    @objc private func sectionToggled(_ sender: NSButton) {
        guard let section = sender.identifier?.rawValue else { return }
        if expandedSections.contains(section) { expandedSections.remove(section) }
        else { expandedSections.insert(section) }
        rebuildShortcuts()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let action = ShortcutAction(rawValue: sender.identifier?.rawValue ?? "") else { return }
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

    // MARK: - Quartet (hardware configuration)

    private var quartetStatusField: NSTextField!
    private var hardwareNotice: HardwareAvailabilityNotice!
    private var quartetSegment: NSSegmentedControl!
    /// The three sub-sections of the Quartet page (Controls / Channel
    /// Names / Output Levels) — one visible at a time.
    private var quartetSectionStacks: [NSStackView] = []

    private func buildQuartet(into body: NSStackView) {
        // status + one clear availability message for the whole page
        quartetStatusField = NSTextField(labelWithString: "Apogee Quartet")
        quartetStatusField.font = .systemFont(ofSize: 11)
        quartetStatusField.textColor = .secondaryLabelColor
        body.addArrangedSubview(quartetStatusField)
        hardwareNotice = HardwareAvailabilityNotice(
            text: "Quartet is disconnected. Hardware settings are unavailable; shown values are the last known state.")
        hardwareNotice.isHidden = true
        body.addArrangedSubview(hardwareNotice)

        quartetSegment = NSSegmentedControl(
            labels: ["Controls", "Channel Names", "Output Levels"],
            trackingMode: .selectOne, target: self,
            action: #selector(quartetSectionChanged(_:)))
        quartetSegment.selectedSegment = 0
        body.addArrangedSubview(quartetSegment)

        let controls = formStack()
        buildQuartetControls(controls)
        let names = formStack()
        buildQuartetNames(names)
        let levels = formStack()
        buildQuartetLevels(levels)
        quartetSectionStacks = [controls, names, levels]
        body.addArrangedSubview(controls)
        body.addArrangedSubview(names)
        body.addArrangedSubview(levels)
        names.isHidden = true
        levels.isHidden = true
    }

    @objc private func quartetSectionChanged(_ sender: NSSegmentedControl) {
        for (i, stack) in quartetSectionStacks.enumerated() {
            stack.isHidden = i != sender.selectedSegment
        }
    }

    // --- Controls: touchscreen flags + front-panel pads, hardware-backed

    /// The Touchscreen checkboxes (keyed by dev-node property name).
    private var touchscreenChecks: [String: NSButton] = [:]
    /// True while refresh is copying tree state into the checkboxes.
    private var touchscreenSyncing = false

    /// Front-panel pad assignment popups (Pad A/B/C, Encoder press),
    /// plus the action enum captured from Apogee Control 2 (Oct 25–26
    /// 2026) — `padGroups` mirrors AC2's dropdown structure; `padActions`
    /// is the flat reverse lookup used by refresh.
    private var padPopups: [NSPopUpButton] = []
    private var padSyncing = false
    static let padGroups: [(group: String, items: [(name: String, value: Int)])] = [
        ("Mute", [("Speaker", 0x20002), ("Headphone", 0x20003), ("All Outputs", 0x20004)]),
        ("Dim", [("Speaker", 0x30002), ("Headphone", 0x30003), ("All Outputs", 0x30004)]),
        ("Sum to Mono", [("Speaker", 0x40002), ("Headphone", 0x40003), ("All Outputs", 0x40004)]),
        ("Toggle", [("Mute Speaker/HP", 0x5000B), ("Speaker Set 1/2", 0x5000C)]),
        ("Clear Meters", [("", 0x60001)]),
        ("Engage Speaker Set", [("Set 1", 0x70005), ("Set 2", 0x70006), ("Set 3", 0x70007)]),
    ]
    /// Encoder press restricted set — Apogee Control 2 gives the encoder
    /// a SHORTER menu than the pads (Mute ▸… + Toggle ▸ Mute Speaker/HP).
    /// An out-of-menu value written to the encoder left its action at 0x0
    /// (inert — verified), so the pads and the encoder keep separate
    /// option sets.
    static let encoderGroups: [(group: String, items: [(name: String, value: Int)])] = [
        ("Mute", [("Speaker", 0x20002), ("Headphone", 0x20003), ("All Outputs", 0x20004)]),
        ("Toggle", [("Mute Speaker/HP", 0x5000B)]),
    ]
    /// Flat list in AC2's dropdown order — labels exactly mirrored from
    /// the group structure. Used by refresh + app-side mapping.
    static var padActions: [(name: String, value: Int)] {
        padGroups.flatMap { g in
            g.items.map { item in
                (g.items.count == 1 ? g.group : "\(g.group) — \(item.name)", item.value)
            }
        }
    }

    private func buildQuartetControls(_ stack: NSStackView) {
        // Touchscreen preferences — the same bits the Quartet's own
        // touchscreen settings page flips, written straight through
        // ApogeeGlue (dev/<serial>/{peakHold, overHold, lockHomeScreen}).
        SettingsSection.add(to: stack, "Touchscreen")
        for (key, title, tip) in [
            ("peakHold", "Hold meter peaks",
             "Level meters hold a peak marker on the touchscreen."),
            ("overHold", "Hold overload indicators",
             "Hold the red clip indicator until acknowledged."),
            ("lockHomeScreen", "Lock home screen",
             "Locks the touchscreen to its home screen (needs the touchscreen to unlock again)."),
        ] {
            let check = NSButton(checkboxWithTitle: title, target: self,
                                 action: #selector(deviceFlagChanged(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(key)
            check.toolTip = tip
            stack.addArrangedSubview(check)
            touchscreenChecks[key] = check
        }

        // FRONT-PANEL ASSIGNMENTS — the three A/B/C touchpads + the
        // encoder push, assignable like any output action (verified live:
        // writing Touchpad_A.actionButton remaps the pad; the enum was
        // captured by driving Apogee Control 2 — see docs/protocol-notes.md).
        SettingsSection.add(to: stack, "Front-panel assignments")
        for (i, title) in ["Pad A", "Pad B", "Pad C", "Encoder press"].enumerated() {
            let p = NSPopUpButton()
            p.translatesAutoresizingMaskIntoConstraints = false
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (group, items) in (i == 3 ? Self.encoderGroups : Self.padGroups) {
                if items.count == 1 {
                    let item = menu.addItem(withTitle: group, action: nil, keyEquivalent: "")
                    item.representedObject = items[0].value
                    continue
                }
                // GROUP HEADER — non-selectable, like AC2's dropdown
                menu.addItem(.sectionHeader(title: group))
                for (leaf, value) in items {
                    let item = menu.addItem(withTitle: "\(group) — \(leaf)",
                                            action: nil, keyEquivalent: "")
                    item.representedObject = value
                    item.indentationLevel = 1
                }
            }
            p.menu = menu
            p.action = #selector(padAssignmentChanged(_:))
            p.target = self
            p.tag = 3700 + i
            stack.addArrangedSubview(LabeledSettingRow(title, control: p, controlWidth: 260))
            padPopups.append(p)
        }
        stack.addArrangedSubview(SettingsHelpText.label(
            "What each pad does at a touch — the same assignments Apogee Control 2\nedits."))
        // One section-level note instead of repeated explanations.
        stack.addArrangedSubview(SettingsHelpText.label(
            "Changes are written to the connected Quartet."))
    }

    /// Copy the tree's pad assignments into the popups (bound to the
    /// actionButtons children's `actionButton` values, latest tree state
    /// is picked up by our tree polling).
    private func refreshPads() {
        guard !padPopups.isEmpty else { return }
        padSyncing = true
        defer { padSyncing = false }
        let values = readPadAssignments?() ?? []
        let connected = values.count == padPopups.count && values[0] != nil
        for (i, popup) in padPopups.enumerated() {
            popup.isEnabled = connected
            if connected, let v = values[i],
               let item = deepItem(in: popup.menu, value: v) {
                popup.select(item)
            }
        }
    }

    /// Hierarchical menu lookup — the pad popups are NSMenus with
    /// submenus, so selectItem(at:) alone can't reach the leaves.
    private func deepItem(in menu: NSMenu?, value: Int) -> NSMenuItem? {
        guard let menu else { return nil }
        for it in menu.items {
            if let r = it.representedObject as? Int, r == value { return it }
            if let sub = it.submenu, let found = deepItem(in: sub, value: value) { return found }
        }
        return nil
    }

    /// A pad action was picked — one setProperty (int32) to
    /// `dev/appState/actionButtons/<pad>/actionButton`. Verified live:
    /// the pad performs the new action right away.
    @objc private func padAssignmentChanged(_ sender: NSPopUpButton) {
        guard !padSyncing, let v = sender.selectedItem?.representedObject as? Int else { return }
        let slot = sender.tag - 3700
        writePadAssignment?(slot, v)
        QBLog.log("settings: pad \(slot) → \(String(v, radix: 16))")
    }

    /// Copy the tree's current flag values into the checkboxes (disabled
    /// while the Quartet is away / no tree yet).
    private func refreshTouchscreen() {
        guard !touchscreenChecks.isEmpty else { return }
        let props = readDeviceProps?()
        touchscreenSyncing = true
        defer { touchscreenSyncing = false }
        for (key, check) in touchscreenChecks {
            if let props, let v = GlueClient.intIn(props, key) {
                check.state = v == 1 ? .on : .off
                check.isEnabled = true
            } else {
                check.isEnabled = false
            }
        }
    }

    /// A Touchscreen checkbox flipped — one setProperty (bool) through the
    /// glue; the hardware echoes it back and the tree refreshes the row.
    @objc private func deviceFlagChanged(_ sender: NSButton) {
        guard !touchscreenSyncing,
              let key = sender.identifier?.rawValue else { return }
        writeDeviceFlag?(key, sender.state == .on)
    }

    // --- Channel Names

    /// One rename row: fixed physical-channel label + editable field
    /// with the current name. Commits on Return / lost focus; Escape
    /// cancels (see the field-editor delegate below).
    private func nameRow(_ title: String, tag: Int) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = SettingsLayout.labelControlGap
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(label)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.tag = tag
        row.addArrangedSubview(field)
        nameFields.append(field)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: SettingsLayout.labelColumn),
            field.widthAnchor.constraint(equalToConstant: SettingsLayout.controlWidth),
        ])
        return row
    }

    private func nameBlock(into stack: NSStackView, _ title: String, _ subtitle: String,
                           _ labels: [String], _ baseTag: Int) {
        SettingsSection.add(to: stack, title)
        stack.addArrangedSubview(SettingsHelpText.label(subtitle))
        for (i, label) in labels.enumerated() {
            stack.addArrangedSubview(nameRow(label, tag: baseTag + i))
        }
    }

    private func buildQuartetNames(_ stack: NSStackView) {
        nameBlock(into: stack, "Inputs",
                  "Renames are written to the connected Quartet — the touchscreen and\nApogee Control 2 show these names.",
                  Self.hwInLabels, 5000)
        nameBlock(into: stack, "Outputs",
                  "Main Out, Headphones and the six ¼\" outputs — also written to\nthe hardware.",
                  Self.hwOutLabels, 5010)
        nameBlock(into: stack, "Stereo Pair Names",
                  "Shown only in Quartet Buddy's window (defaults like \"Out 1–2\");\nleave empty to fall back to the physical pair name.",
                  Self.pairLabels, 5020)
        nameBlock(into: stack, "Digital Inputs",
                  "App-side names for the eight digital inputs via ADAT (shown\nin the Digital bank and Gain Assistant); leave empty to show\njust \"Digital n\".",
                  Self.adatLabels, 5030)
        stack.addArrangedSubview(SettingsHelpText.label(
            "Press Return (or click away) to commit a rename; Esc cancels the edit."))
    }

    /// Tree → the fields. Skips a field while it has an editor, so a
    /// hardware refresh never clobbers an in-progress edit.
    private func rebuildNames() {
        guard !nameFields.isEmpty else { return }
        nameSuppress = true
        defer { nameSuppress = false }
        let values = readNames?() ?? []
        let connected = values.count == nameRows.count
        for (i, field) in nameFields.enumerated() {
            let v = i < values.count ? values[i] : ""
            if field.stringValue != v, field.currentEditor() == nil {
                field.stringValue = v
            }
            field.isEnabled = connected
        }
    }

    /// A rename commit — on Return or when the field loses focus
    /// (never per keystroke). Hardware names skip empty strings (the
    /// hardware can hold an empty name but that looks like a bug on the
    /// screen); pair names empty = revert to the physical pair name.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !nameSuppress, let field = obj.object as? NSTextField,
              field.tag >= 5000, field.tag < nameFields.count + 5000,
              let i = nameFields.firstIndex(of: field) else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        let original = nameEditOriginals[ObjectIdentifier(field)]
        nameEditOriginals[ObjectIdentifier(field)] = nil
        // restore without a write: Escape restores first, then ends the
        // edit; a lost focus with a value equal to the captured one is
        // also a no-op.
        if let original, value == original { return }
        let row = nameRows[i]
        if row.kind == .pair || row.kind == .adat {
            writeName?(i, value)          // empty = revert (handled app-side)
        } else if !value.isEmpty {
            writeName?(i, value)
        }
        rebuildNames()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              nameFields.firstIndex(of: field) != nil else { return }
        nameEditOriginals[ObjectIdentifier(field)] = field.stringValue
    }

    /// Escape in a name field cancels the edit: restore the captured
    /// value and end editing without a hardware write (the end-edit pass
    /// runs while suppressed so no commit handler fires).
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField,
              nameFields.firstIndex(of: field) != nil else { return false }
        field.stringValue = nameEditOriginals[ObjectIdentifier(field)] ?? field.stringValue
        nameEditOriginals[ObjectIdentifier(field)] = nil
        nameSuppress = true
        field.window?.makeFirstResponder(nil)
        nameSuppress = false
        return true
    }

    // --- Output Levels (moved from the old Audio page)

    var readLineOutLevels: (() -> [(name: String, refLevel: Int?)])?
    var writeLineOutLevel: ((Int, Int) -> Void)?

    /// Line-output firmware trim (pairs 1…3 = Analog Out 1/2…5/6). Expects
    /// `(name, trim?)` triples — name is the left strip's hardware name
    /// joined with the right, trim nil = unknown/disconnected.
    var readHwoutTrims: (() -> [(name: String, trim: Double?)])?
    var writeHwoutTrim: ((Int, Double) -> Void)?

    private var lineOutPopups: [NSPopUpButton] = []
    private var lineOutLabels: [NSTextField] = []
    private var lineOutSuppress = false

    /// The reference-level popup for one hardware line output (the same
    /// analogRefLevel enum as the inputs: 2 = +4 dBu, 3 = −10 dBV).
    private func buildQuartetLevels(_ stack: NSStackView) {
        SettingsSection.add(to: stack, "Line-output reference levels")
        for i in 0..<6 {
            let label = NSTextField(labelWithString: "Analog output \(i + 1)")
            label.font = .systemFont(ofSize: 13)
            label.setContentCompressionResistancePriority(
                NSLayoutConstraint.Priority(751), for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            let wrap = NSStackView()
            wrap.orientation = .horizontal
            wrap.spacing = 8
            wrap.addArrangedSubview(label)
            let p = NSPopUpButton()
            p.translatesAutoresizingMaskIntoConstraints = false
            p.addItem(withTitle: "+4 dBu")
            p.addItem(withTitle: "−10 dBV")
            p.lastItem?.representedObject = 3
            p.item(at: 0)?.representedObject = 2
            p.action = #selector(lineOutLevelChanged(_:))
            p.target = self
            p.tag = 3600 + i
            wrap.addArrangedSubview(p)
            lineOutLabels.append(label)
            lineOutPopups.append(p)
            stack.addArrangedSubview(wrap)
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: SettingsLayout.labelColumn),
                p.widthAnchor.constraint(equalToConstant: 110),
            ])
        }
        stack.addArrangedSubview(SettingsHelpText.label(
            "Each ¼\" line output's reference level — the same setting the\ntouchscreen's output page drives. Channels stay independent; pairs\nare not linked."))

        // --- Line-output trim (firmware) — settings-side hardware trim

        buildHwoutTrims(stack)
    }

    /// Line-output TRIM (firmware): the hardware strips' `trim` property,
    /// applied by the Quartet at the DAC — downstream of everything macOS
    /// sends, so it listens to ALL apps, not just this one's insert chain.
    /// Rows are PAIRS of the mono strips, labeled with the strips' own
    /// hardware names. Range −64…+6 dB; values survive power cycles and
    /// re-push from these saved keys on every reconnect.
    private var hwoutTrimSliders: [NSSlider] = []
    private var hwoutTrimNameLabels: [NSTextField] = []
    private var hwoutTrimReadouts: [NSTextField] = []
    private var hwoutTrimSuppress = false

    private func buildHwoutTrims(_ stack: NSStackView) {
        SettingsSection.add(to: stack, "Line-output trim (hardware)")
        for pair in 1...3 {
            let label = NSTextField(labelWithString: "Analog Out \(2 * pair - 1) / \(2 * pair)")
            label.font = .systemFont(ofSize: 13)
            label.setContentCompressionResistancePriority(
                NSLayoutConstraint.Priority(751), for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            let slider = HwoutTrimSlider(value: 0, minValue: -24, maxValue: 0,
                                         target: self, action: #selector(hwoutTrimChanged(_:)))
            slider.tag = 3700 + pair
            slider.translatesAutoresizingMaskIntoConstraints = false
            let readout = NSTextField(labelWithString: "0.0 dB")
            readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            readout.translatesAutoresizingMaskIntoConstraints = false
            readout.alignment = .right
            let wrap = NSStackView()
            wrap.orientation = .horizontal
            wrap.spacing = 8
            wrap.addArrangedSubview(label)
            wrap.addArrangedSubview(slider)
            wrap.addArrangedSubview(readout)
            hwoutTrimNameLabels.append(label)
            hwoutTrimSliders.append(slider)
            hwoutTrimReadouts.append(readout)
            stack.addArrangedSubview(wrap)
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: SettingsLayout.labelColumn),
                slider.widthAnchor.constraint(equalToConstant: 180),
                readout.widthAnchor.constraint(equalToConstant: 64),
            ])
        }
        stack.addArrangedSubview(SettingsHelpText.label(
            "The Quartet's own output trim, applied by the firmware at the\nDAC — downstream of everything macOS sends, so it affects every\napp. Rows carry the strips' hardware names; the routing window's\ncards are one pair number up (Out 3‑4 card ⟶ Analog Out 1/2 …\nOut 7‑8 card ⟶ Analog Out 5/6). Range −24…0 dB (attenuation\nonly); ⌘+click a slider to reset it to 0 dB. Saved values re-push\nto the unit after every reconnect or power cycle."))
    }

    /// Slider that ⌘+click snaps to 0 dB (unity) instead of jumping to the
    /// click position — the reset gesture for the hardware trims.
    final class HwoutTrimSlider: NSSlider {
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                doubleValue = 0
                if let target, let action {
                    NSApp.sendAction(action, to: target, from: self)
                }
                return
            }
            super.mouseDown(with: event)
        }
    }

    @objc private func hwoutTrimChanged(_ sender: NSSlider) {
        let pair = sender.tag - 3700
        guard !hwoutTrimSuppress, (1...3).contains(pair) else { return }
        let db = min(AppDelegate.hwoutTrimMax, max(AppDelegate.hwoutTrimMin,
            (sender.doubleValue * 2).rounded() / 2))   // 0.5 dB steps, clamped
        sender.doubleValue = db
        hwoutTrimReadouts[pair - 1].stringValue = String(format: "%.1f dB", db)
        writeHwoutTrim?(pair, db)
        QBLog.log(String(format: "settings: hardware trim pair %d → %.1f dB", pair, db))
    }

    private func refreshHwoutTrims() {
        guard !hwoutTrimSliders.isEmpty else { return }
        hwoutTrimSuppress = true
        defer { hwoutTrimSuppress = false }
        let read = readHwoutTrims?() ?? []
        for pair in 1...3 {
            let row = pair - 1
            guard pair <= read.count else {
                hwoutTrimSliders[row].isEnabled = false
                continue
            }
            let entry = read[row]
            hwoutTrimNameLabels[row].stringValue = entry.name
            if let db = entry.trim {
                // tree values outside the hard range can't be shown — the
                // slider clamps them (the next change writes the clamp back)
                let shown = min(AppDelegate.hwoutTrimMax, max(AppDelegate.hwoutTrimMin, db))
                hwoutTrimSliders[row].isEnabled = true
                hwoutTrimSliders[row].doubleValue = shown
                hwoutTrimReadouts[row].stringValue = String(format: "%.1f dB", shown)
            } else {
                hwoutTrimSliders[row].isEnabled = false
                hwoutTrimReadouts[row].stringValue = "—"
            }
        }
    }

    private func refreshLineOuts() {
        guard !lineOutPopups.isEmpty else { return }
        lineOutSuppress = true
        defer { lineOutSuppress = false }
        let read = readLineOutLevels?() ?? []
        for i in 0..<6 {
            let popup = lineOutPopups[i]
            if i < read.count {
                lineOutLabels[i].stringValue = read[i].name
                if let v = read[i].refLevel {
                    popup.isEnabled = true
                    popup.selectItem(at: v == 3 ? 1 : 0)
                } else {
                    popup.isEnabled = false
                }
            } else {
                popup.isEnabled = false
            }
        }
    }

    @objc private func lineOutLevelChanged(_ sender: NSPopUpButton) {
        guard !lineOutSuppress,
              let i = lineOutPopups.firstIndex(of: sender),
              let v = sender.selectedItem?.representedObject as? Int else { return }
        writeLineOutLevel?(i, v)
        QBLog.log("settings: line out \(i + 1) level → \(v == 3 ? "−10 dBV" : "+4 dBu")")
    }

    /// Page-level hardware refresh: status line, availability notice and
    /// the four hardware-backed sections (each disables its own controls
    /// when the tree is gone, keeping the last read values as labels).
    private func refreshQuartet() {
        guard hardwareNotice != nil else { return }
        let connected = readDeviceProps?() != nil
        quartetStatusField.stringValue = connected
            ? "Apogee Quartet · Connected" : "Apogee Quartet · Not connected"
        hardwareNotice.isHidden = connected
        refreshTouchscreen()
        refreshPads()
        rebuildNames()
        refreshLineOuts()
        refreshHwoutTrims()
    }

    // MARK: - Processing (audio engine + Auto Gain + plug-ins)

    private var blockPopup: NSPopUpButton!
    private var blockActiveField: NSTextField!
    private var devBufPopup: NSPopUpButton!
    private var devBufField: NSTextField!
    private var rateField: NSTextField!
    private var gainTargetPopup: NSPopUpButton!
    private var gainDurationPopup: NSPopUpButton!
    private var assistTargetPopup: NSPopUpButton!
    private var assistDurationPopup: NSPopUpButton!
    private var assistTolerancePopup: NSPopUpButton!
    private var insertCheck: NSButton!
    private var bypassCheck: NSButton!
    private var audioSuppress = false
    private var gainSuppress = false
    private var pluginSuppress = false

    /// Classic HAL buffer sizes, snapped from the driver's 15…4096 range.
    private let deviceBufferChoices: [UInt32] = [32, 64, 128, 256, 512, 1024, 2048, 4096]

    private func buildProcessing(into body: NSStackView) {
        // AUDIO ENGINE — two genuinely different buffers (verified in
        // InsertServer): the plug-in engine's own IO slice vs. the
        // Quartet's CoreAudio device buffer.
        SettingsSection.add(to: body, "Audio engine")
        blockPopup = NSPopUpButton()
        blockPopup.translatesAutoresizingMaskIntoConstraints = false
        for choice in InsertServer.bufferChoices {
            blockPopup.addItem(withTitle: "\(choice.frames) frames")
            blockPopup.lastItem?.representedObject = choice.frames
        }
        blockPopup.action = #selector(blockSizeChanged(_:))
        blockPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Processing block size",
                                                  control: blockPopup))
        body.addArrangedSubview(SettingsHelpText.label(
            "The block size Quartet Buddy's plug-in engine renders in — larger\n" +
            "blocks add buffer duration (16 frames ≈ 0.3 ms at 48 kHz); this is a\n" +
            "buffer size, not measured round-trip latency. Changing it restarts\nthe engine."))
        blockActiveField = SettingsHelpText.label("")
        body.addArrangedSubview(blockActiveField)

        // DEVICE BUFFER — the Quartet's own IO buffer size. The glue
        // tree's `preferredBufferSize` is a dead preference (verified:
        // never reaches the HAL even across a replug), so this writes the
        // CoreAudio property directly — the same knob the DAW buffer
        // panels work through. The insert restarts after a change.
        devBufPopup = NSPopUpButton()
        devBufPopup.translatesAutoresizingMaskIntoConstraints = false
        for frames in deviceBufferChoices {
            devBufPopup.addItem(withTitle: "\(frames) frames")
            devBufPopup.lastItem?.representedObject = frames
        }
        devBufPopup.action = #selector(deviceBufferChanged(_:))
        devBufPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Device buffer size",
                                                  control: devBufPopup))
        body.addArrangedSubview(SettingsHelpText.label(
            "Buffer size requested from the Quartet's audio driver — the device's\n" +
            "own IO buffer, independent of the processing block. Core Audio\n" +
            "reconfigures the device after a change (a brief audio hiccup)."))
        devBufField = SettingsHelpText.label("")
        body.addArrangedSubview(devBufField)

        rateField = NSTextField(labelWithString: "")
        rateField.font = .systemFont(ofSize: 13)
        rateField.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(LabeledSettingRow("Sample rate", control: rateField,
                                                  controlWidth: 110))

        // AUTO GAIN — one configuration for both per-input and Auto Gain
        // All; applies to the NEXT operation.
        SettingsSection.add(to: body, "Auto Gain")
        gainTargetPopup = NSPopUpButton()
        gainTargetPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AutoGainEngine.targetOptions {
            gainTargetPopup.addItem(withTitle: String(format: "%.0f dBFS", v))
            gainTargetPopup.lastItem?.representedObject = NSNumber(value: v)
        }
        gainTargetPopup.action = #selector(gainTargetChanged(_:))
        gainTargetPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Target peak", control: gainTargetPopup))

        gainDurationPopup = NSPopUpButton()
        gainDurationPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AutoGainEngine.listenOptions {
            gainDurationPopup.addItem(withTitle: String(format: "%.0f s", v))
            gainDurationPopup.lastItem?.representedObject = NSNumber(value: v)
        }
        gainDurationPopup.action = #selector(gainDurationChanged(_:))
        gainDurationPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Measurement duration",
                                                  control: gainDurationPopup))
        body.addArrangedSubview(SettingsHelpText.label(
            "Used for individual inputs and Auto Gain All. Changes apply to\nthe next measurement — a run in flight keeps its own settings."))

        // GAIN ASSISTANCE (DIGITAL 1–8) — measurement-and-guidance for the
        // external preamps. The assistant compares a captured peak with
        // these numbers; these are proposed defaults, not standards.
        assistTargetPopup = NSPopUpButton()
        assistTargetPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AdatGainEngine.targetOptions {
            assistTargetPopup.addItem(withTitle: String(format: "%.0f dBFS", v))
            assistTargetPopup.lastItem?.representedObject = NSNumber(value: v)
        }
        assistTargetPopup.action = #selector(assistTargetChanged(_:))
        assistTargetPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Target peak", control: assistTargetPopup))

        assistDurationPopup = NSPopUpButton()
        assistDurationPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AdatGainEngine.durationOptions {
            assistDurationPopup.addItem(withTitle: String(format: "%.0f s", v))
            assistDurationPopup.lastItem?.representedObject = NSNumber(value: v)
        }
        assistDurationPopup.action = #selector(assistDurationChanged(_:))
        assistDurationPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Measurement duration",
                                                  control: assistDurationPopup))

        assistTolerancePopup = NSPopUpButton()
        assistTolerancePopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AdatGainEngine.toleranceOptions {
            assistTolerancePopup.addItem(withTitle: String(format: "±%.0f dB", v))
            assistTolerancePopup.lastItem?.representedObject = NSNumber(value: v)
        }
        assistTolerancePopup.action = #selector(assistToleranceChanged(_:))
        assistTolerancePopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Acceptable range",
                                                  control: assistTolerancePopup))
        body.addArrangedSubview(SettingsHelpText.label(
            "Used by the Gain Assistant (Inputs ▸ Digital 1–8). Changes\napply to the next measurement — a running measurement keeps\nits own settings."))

        // PLUG-INS
        SettingsSection.add(to: body, "Plug-ins")
        insertCheck = NSButton(checkboxWithTitle: "Enable plug-in processing",
                               target: self, action: #selector(insertToggled(_:)))
        body.addArrangedSubview(insertCheck)
        body.addArrangedSubview(SettingsHelpText.label(
            "Runs Quartet Buddy's plug-in engine: it taps routed audio and hosts\nyour AU plug-ins. Turning it off stops the engine and unloads the\nplug-ins — routing and per-pair settings are preserved."))
        bypassCheck = NSButton(checkboxWithTitle: "Bypass all plug-ins",
                               target: self, action: #selector(bypassToggled(_:)))
        body.addArrangedSubview(bypassCheck)
        body.addArrangedSubview(SettingsHelpText.label(
            "Temporarily bypasses the effect of every plug-in without stopping\nthe engine. The control window has the same toggle."))
    }

    private func rebuildProcessing() {
        guard blockPopup != nil else { return }
        audioSuppress = true
        gainSuppress = true
        pluginSuppress = true
        defer { audioSuppress = false; gainSuppress = false; pluginSuppress = false }

        // Processing block size — what the engine is configured for.
        let current = InsertServer.savedBufferFrames()
        blockPopup.selectItem(
            at: InsertServer.bufferChoices.firstIndex { $0.frames == current } ?? 0)
        if InsertServer.shared.running {
            blockActiveField.stringValue =
                "Active: \(current) frames while the plug-in engine runs."
        } else {
            blockActiveField.stringValue =
                "Engine stopped — \(current) frames will be used when it starts."
        }

        // Device buffer — live value from Core Audio (the CONFIRMED active
        // value, not just what was requested); the readout carries the
        // buffer duration at the live rate.
        if let frames = InsertServer.deviceBufferFrames() {
            let idx = deviceBufferChoices.enumerated().min {
                abs(Int($0.element) - Int(frames)) < abs(Int($1.element) - Int(frames))
            }
            devBufPopup.selectItem(at: idx?.offset ?? 0)
            let rate = InsertServer.deviceSampleRate() ?? 48000
            let ms = Double(frames) / rate * 1000
            devBufField.stringValue = String(format: "Active: %d frames ≈ %.1f ms buffer duration",
                                             frames, ms)
            devBufPopup.isEnabled = true
        } else {
            devBufPopup.isEnabled = false
            devBufField.stringValue = "Quartet not connected"
        }

        let liveRate = InsertServer.shared.currentRate()
        let khz = liveRate / 1000
        rateField.stringValue =
            "\(khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)) kHz"

        for item in gainTargetPopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AutoGainEngine.targetDBFS {
            gainTargetPopup.select(item); break
        }
        for item in gainDurationPopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AutoGainEngine.listenSeconds {
            gainDurationPopup.select(item); break
        }

        // Gain Assistance (ADAT) — the persisted departure
        for item in assistTargetPopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AdatGainEngine.targetDBFS {
            assistTargetPopup.select(item); break
        }
        for item in assistDurationPopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AdatGainEngine.durationSeconds {
            assistDurationPopup.select(item); break
        }
        for item in assistTolerancePopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AdatGainEngine.toleranceDB {
            assistTolerancePopup.select(item); break
        }

        insertCheck.state = InsertServer.shared.running ? .on : .off
        bypassCheck.isEnabled = InsertServer.shared.running
        bypassCheck.state = InsertServer.shared.bypassAll ? .on : .off
    }

    /// A processing block pick: persists and restarts the insert with the
    /// new IO slice (InsertServer.setBufferFrames is the only writer of
    /// `insertBufferFrames`).
    @objc private func blockSizeChanged(_ sender: NSPopUpButton) {
        guard !audioSuppress, let frames = sender.selectedItem?.representedObject as? Int else { return }
        InsertServer.shared.setBufferFrames(frames)
        rebuildProcessing()
    }

    /// A device-buffer pick: write straight into Core Audio, then restart
    /// the insert (its aggregate was built against the old buffer).
    /// Persist the last REQUESTED size for a friendly restore read; the
    /// readout switches to the CONFIRMED value once the HAL settles.
    @objc private func deviceBufferChanged(_ sender: NSPopUpButton) {
        guard !audioSuppress,
              let frames = sender.selectedItem?.representedObject as? UInt32 else { return }
        let live = InsertServer.deviceBufferFrames()
        QBLog.log("settings: device buffer \(live.map(String.init) ?? "?") → \(frames)")
        guard InsertServer.setDeviceBufferFrames(frames) else {
            QBLog.log("settings: device buffer write rejected by Core Audio")
            return rebuildProcessing()
        }
        if InsertServer.shared.running {
            // re-close the tap/aggregate against the reconfigured stream;
            // the refresh after it re-reads the live device buffer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                InsertServer.shared.setBufferFrames(InsertServer.savedBufferFrames())
                self?.rebuildProcessing()
            }
        }
        rebuildProcessing()
    }

    /// A change persists immediately and applies to the NEXT operation.
    @objc private func gainTargetChanged(_ sender: NSPopUpButton) {
        guard !gainSuppress,
              let v = sender.selectedItem?.representedObject as? NSNumber else { return }
        AutoGainEngine.targetDBFS = v.doubleValue
        QuartetControlController.shared.refresh()
    }

    @objc private func gainDurationChanged(_ sender: NSPopUpButton) {
        guard !gainSuppress,
              let v = sender.selectedItem?.representedObject as? NSNumber else { return }
        AutoGainEngine.listenSeconds = v.doubleValue
        QuartetControlController.shared.refresh()
    }

    // Gain Assistance (ADAT) — persist and apply to the NEXT measurement.
    @objc private func assistTargetChanged(_ sender: NSPopUpButton) {
        guard !gainSuppress,
              let v = sender.selectedItem?.representedObject as? NSNumber else { return }
        AdatGainEngine.targetDBFS = v.doubleValue
        QuartetControlController.shared.refresh()
    }
    @objc private func assistDurationChanged(_ sender: NSPopUpButton) {
        guard !gainSuppress,
              let v = sender.selectedItem?.representedObject as? NSNumber else { return }
        AdatGainEngine.durationSeconds = v.doubleValue
        QuartetControlController.shared.refresh()
    }
    @objc private func assistToleranceChanged(_ sender: NSPopUpButton) {
        guard !gainSuppress,
              let v = sender.selectedItem?.representedObject as? NSNumber else { return }
        AdatGainEngine.toleranceDB = v.doubleValue
        QuartetControlController.shared.refresh()
    }

    @objc private func insertToggled(_ sender: NSButton) {
        guard !pluginSuppress else { return }
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "insertEnabled")
        InsertServer.shared.setRunning(on)
        rebuildProcessing()
    }

    @objc private func bypassToggled(_ sender: NSButton) {
        guard !pluginSuppress else { return }
        InsertServer.shared.setBypassAll(sender.state == .on)
    }

    // MARK: - Talkback

    private var sourcePopup: NSPopUpButton!
    private var channelPopup: NSPopUpButton!
    private var behaviorPopup: NSPopUpButton!
    private var midiStatusField: NSTextField!
    private var midiLearnButton: NSButton!
    private var midiClearButton: NSButton!
    private var midiCancelButton: NSButton!
    private var sourceSuppress = false
    private var midiSuppress = false

    private func buildTalkback(into body: NSStackView) {
        // SOURCE
        SettingsSection.add(to: body, "Source")
        sourcePopup = NSPopUpButton()
        sourcePopup.translatesAutoresizingMaskIntoConstraints = false
        sourcePopup.target = self
        sourcePopup.action = #selector(talkbackSourceChanged(_:))
        body.addArrangedSubview(LabeledSettingRow("Input device", control: sourcePopup))
        channelPopup = NSPopUpButton()
        channelPopup.translatesAutoresizingMaskIntoConstraints = false
        channelPopup.target = self
        channelPopup.action = #selector(talkbackChannelChanged(_:))
        body.addArrangedSubview(LabeledSettingRow("Input channel", control: channelPopup))
        body.addArrangedSubview(SettingsHelpText.label(
            "Who the talkback listens to. Channel 1 is the device's first input\n" +
            "— this is the same source Apogee Control 2's Talkback pane writes."))

        // ACTIVATION
        SettingsSection.add(to: body, "Activation")
        behaviorPopup = NSPopUpButton()
        behaviorPopup.addItems(withTitles: ["Toggle", "Hold to talk"])
        behaviorPopup.action = #selector(behaviorChanged(_:))
        behaviorPopup.target = self
        body.addArrangedSubview(LabeledSettingRow("Behavior", control: behaviorPopup,
                                                  controlWidth: 140))
        body.addArrangedSubview(SettingsHelpText.label(
            "How the talkback trigger switches talkback: press toggles it on/off,\n" +
            "or hold to keep it open while pressed. Applies to the MIDI trigger and\n" +
            "the Talkback button/shortcut in the control panel and menu."))
        body.addArrangedSubview(SettingsHelpText.label(
            "The keyboard shortcuts “Hold to talk” / “Toggle talkback” act\n" +
            "momentary or toggling individually and ignore this setting."))

        // MIDI
        SettingsSection.add(to: body, "MIDI")
        let midiRow = NSStackView()
        midiRow.orientation = .horizontal
        midiRow.spacing = 10
        midiRow.alignment = .centerY
        midiRow.translatesAutoresizingMaskIntoConstraints = false
        midiStatusField = NSTextField(labelWithString: "Not assigned")
        midiStatusField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        midiStatusField.textColor = .secondaryLabelColor
        midiStatusField.translatesAutoresizingMaskIntoConstraints = false
        midiRow.addArrangedSubview(midiStatusField)
        midiLearnButton = NSButton(title: "Learn…", target: self, action: #selector(midiLearn(_:)))
        midiLearnButton.translatesAutoresizingMaskIntoConstraints = false
        midiRow.addArrangedSubview(midiLearnButton)
        midiClearButton = NSButton(title: "Clear", target: self, action: #selector(midiClear(_:)))
        midiClearButton.translatesAutoresizingMaskIntoConstraints = false
        midiRow.addArrangedSubview(midiClearButton)
        midiCancelButton = NSButton(title: "Cancel", target: self,
                                    action: #selector(midiCancel(_:)))
        midiCancelButton.translatesAutoresizingMaskIntoConstraints = false
        midiCancelButton.isHidden = true
        midiRow.addArrangedSubview(midiCancelButton)
        body.addArrangedSubview(LabeledSettingRow("Trigger", control: midiRow))
        body.addArrangedSubview(SettingsHelpText.label(
            "A MIDI note or control change on the Quartet's MIDI port that\noperates talkback."))
    }

    /// Copy the tree's talkback subtree into the source/channel popups.
    private func refreshTalkbackSource() {
        guard sourcePopup != nil else { return }
        sourceSuppress = true
        defer { sourceSuppress = false }
        guard let desc = readTalkback?(), !desc.sources.isEmpty else {
            sourcePopup.removeAllItems()
            sourcePopup.addItem(withTitle: "No sources")
            sourcePopup.isEnabled = false
            channelPopup.removeAllItems()
            channelPopup.addItem(withTitle: "—")
            channelPopup.isEnabled = false
            return
        }
        sourcePopup.isEnabled = true
        sourcePopup.removeAllItems()
        for (device, _) in desc.sources { sourcePopup.addItem(withTitle: device) }
        let target = desc.sources.first(where: { $0.device == desc.selectedDevice })
        if let target { sourcePopup.selectItem(withTitle: target.device) }
        rebuildChannelPopup(for: desc.selectedDevice, channels: target?.channels ?? 1,
                            selectedChannel: desc.selectedChannel)
    }

    private func rebuildChannelPopup(for device: String, channels: Int, selectedChannel: Int) {
        channelPopup.isEnabled = channels > 1
        channelPopup.removeAllItems()
        for c in 0..<max(1, channels) { channelPopup.addItem(withTitle: "Ch \(c + 1)") }
        channelPopup.lastItem?.representedObject = max(0, channels - 1)
        if selectedChannel < max(1, channels) {
            channelPopup.selectItem(at: selectedChannel)
        }
    }

    @objc private func talkbackSourceChanged(_ sender: NSPopUpButton) {
        guard !sourceSuppress,
              let device = sender.titleOfSelectedItem else { return }
        // A new device resets to its first input channel; the selected
        // device's channel count comes from the last description.
        let channels = readTalkback?()?
            .sources.first(where: { $0.device == device })?.channels ?? 1
        rebuildChannelPopup(for: device, channels: channels, selectedChannel: 0)
        writeTalkbackSource?(device, 0)
    }

    @objc private func talkbackChannelChanged(_ sender: NSPopUpButton) {
        guard !sourceSuppress,
              let device = sourcePopup.titleOfSelectedItem else { return }
        writeTalkbackSource?(device, sender.indexOfSelectedItem)
    }

    /// The MIDI row + behavior popup reflect current state: learning →
    /// "Press a MIDI control…" with Cancel; no trigger → Clear disabled.
    private func rebuildTalkback() {
        guard midiStatusField != nil, behaviorPopup != nil else { return }
        midiSuppress = true
        defer { midiSuppress = false }
        behaviorPopup.selectItem(
            at: UserDefaults.standard.bool(forKey: "momentary") ? 1 : 0)
        if isMidiLearning?() == true {
            midiStatusField.stringValue = "Press a MIDI control…"
            midiLearnButton.isHidden = true
            midiClearButton.isHidden = true
            midiCancelButton.isHidden = false
            return
        }
        midiLearnButton.isHidden = false
        midiClearButton.isHidden = false
        midiCancelButton.isHidden = true
        if let data = UserDefaults.standard.data(forKey: "midiTrigger"),
           let t = try? JSONDecoder().decode(MidiWatcher.Trigger.self, from: data) {
            midiStatusField.stringValue =
                "\(t.kind == .note ? "Note" : "CC") \(t.number) · Ch \(t.channel + 1)"
            midiClearButton.isEnabled = true
        } else {
            midiStatusField.stringValue = "Not assigned"
            midiClearButton.isEnabled = false   // nothing to clear
        }
    }

    @objc private func behaviorChanged(_ sender: NSPopUpButton) {
        guard !midiSuppress else { return }
        let momentary = sender.indexOfSelectedItem == 1
        UserDefaults.standard.set(momentary, forKey: "momentary")
        NotificationCenter.default.post(name: .init("qb.momentaryChanged"), object: nil)
        QBLog.log("settings: talkback behavior = \(momentary ? "hold to talk" : "toggle")")
    }

    @objc private func midiLearn(_ sender: NSButton) {
        onMidiLearn?()
        rebuildTalkback()
    }

    @objc private func midiClear(_ sender: NSButton) {
        onMidiClear?()
        rebuildTalkback()
    }

    @objc private func midiCancel(_ sender: NSButton) {
        onMidiCancel?()
        rebuildTalkback()
    }

    // MARK: - About

    private func buildAbout(into body: NSStackView) {
        let name = NSTextField(labelWithString: "Quartet Buddy")
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        body.addArrangedSubview(name)
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "0.2"
        let build = info?["CFBundleVersion"] as? String ?? "2"
        body.addArrangedSubview(SettingsHelpText.label("Version \(ver) (\(build))"))
        body.addArrangedSubview(SettingsHelpText.label(
            "Menubar companion for the Apogee Quartet — monitoring, talkback,\n" +
            "routing, AU plug-ins and Auto Gain, driven through ApogeeGlue.\n"))
        body.addArrangedSubview(SettingsHelpText.label("MIT License — see LICENSE"))
    }

    // MARK: - actions & helpers

    /// Login item — mirrored with the menubar toggle: the `launchAtLogin`
    /// key is written on success so both entrances own the same state,
    /// and a failure reverts the checkbox to the real registration state.
    @objc private func loginChanged(_ sender: NSButton) {
        let want = sender.state == .on
        let service = SMAppService.mainApp
        do {
            if want {
                try service.register()
            } else {
                try service.unregister()
            }
            UserDefaults.standard.set(want, forKey: "launchAtLogin")
            QBLog.log("settings: login item \(want ? "registered" : "unregistered")")
        } catch {
            QBLog.log("settings: login item error — \(error.localizedDescription)")
            sender.state = service.status == .enabled ? .on : .off
        }
    }

    /// Knob scroll-direction preference — GainKnob reads the default
    /// live, so no restart/rebuild is needed.
    @objc private func scrollDirectionChanged(_ sender: NSPopUpButton) {
        let inverted = sender.indexOfSelectedItem == 1
        UserDefaults.standard.set(inverted, forKey: Self.invertScrollKey)
        QBLog.log("settings: knob scroll \(inverted ? "inverted" : "standard")")
    }

    @objc private func openLog(_ sender: NSButton) {
        NSWorkspace.shared.open(QBLog.url)
    }

    func windowWillClose(_ notification: Notification) {
        // nothing persisted here — everything saves immediately on change
    }
}
