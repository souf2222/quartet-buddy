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
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    /// Wired by AppDelegate.
    var onMidiLearn: (() -> Void)?
    var onMidiClear: (() -> Void)?
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

    // MARK: Names pane (Settings ▸ Names)

    /// Renames live here instead of the control window's inline
    /// double-click (which never stuck reliably). Three groups:
    /// the Quartet's hardware input names, its hardware output names
    /// (both written THROUGH ApogeeGlue — the touchscreen follows), and
    /// the app-side stereo-pair display names.
    ///
    /// `readNames` → current values in ROW ORDER (nil = not connected),
    /// `writeName` is routed by the row's kind + index.
    struct NameRow {
        enum Kind { case hwInput, hwOutput, pair }
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
    /// Static row labels — fixed defaults, so a renamed input doesn't
    /// shift the row the user is looking for.
    private static let hwInLabels = ["Input 1 (Mic/line)", "Input 2 (Mic/line)",
                                     "Input 3 (Mic/line)", "Input 4 (Mic/line)"]
    private static let hwOutLabels = ["Main Out", "Headphones", "Analog Out 1", "Analog Out 2",
                                      "Analog Out 3", "Analog Out 4", "Analog Out 5", "Analog Out 6"]
    private static let pairLabels = ["Pair 1", "Pair 2", "Pair 3", "Pair 4"]

    private var nameFields: [NSTextField] = []
    private var nameSuppress = false

    enum Pane: Int, CaseIterable {
        case general, shortcuts, autoGain, audio, names, talkback, plugins, about

        var icon: String {
            switch self {
            case .general: return "⚙"
            case .shortcuts: return "⌘"
            case .autoGain: return "◤"
            case .audio: return "♫"
            case .names: return "✎"
            case .talkback: return "◉"
            case .plugins: return "◇"
            case .about: return "ⓘ"
            }
        }
        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .autoGain: return "Auto Gain"
            case .audio: return "Audio"
            case .names: return "Names"
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
        // open at the TOP of the shortcuts table (doc is unflipped — its
        // origin is the bottom edge, so top == bounds.maxY).
        window?.contentView?.layoutSubtreeIfNeeded()
        if let d = shortcutDoc {
            d.scroll(NSPoint(x: 0, y: d.bounds.maxY))
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
        rebuildAudio()
        rebuildAutoGain()
        rebuildPlugins()
        rebuildShortcuts()
        refreshTouchscreen()
        refreshTalkbackSource()
        refreshPads()
        rebuildNames()
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

        let w = QuartetWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Quartet Buddy Settings"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.delegate = self
        w.center()
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

    /// A pane = title + body, pinned directly under the title. The
    /// Shortcuts / Audio / Names panes may exceed the window (they
    /// scroll); everything else fits and must hug its content (a scroll
    /// view around a plain NSView stretches it, which pushed the
    /// controls down and showed a phantom scrollbar).
    private func makePane(_ pane: Pane) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: pane.title)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = GGTheme.primary
        title.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
        ])
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyViews[pane] = body
        body.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        if pane == .shortcuts || pane == .audio || pane == .names {
            // These panes can outgrow the window — they scroll. The
            // document view is FULLY chained to the body (top, leading,
            // trailing AND bottom) and width-locked to the clip view, so its
            // height derives from the table — without the bottom link Auto
            // Layout cannot size a plain NSView document and the scroll view
            // renders it zero-height (empty pane) with its own background as
            // a stray darker rectangle.
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
            shortcutDoc = doc
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
                scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
                scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
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
                body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
                body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
                body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            ])
        }
        switch pane {
        case .general: buildGeneral(into: body)
        case .shortcuts: buildShortcuts(into: body)
        case .autoGain: buildAutoGain(into: body)
        case .audio: buildAudio(into: body)
        case .names: buildNames(into: body)
        case .talkback: buildTalkback(into: body)
        case .plugins: buildPlugins(into: body)
        case .about: buildAbout(into: body)
        }
        return v
    }

    private var bodyViews: [Pane: NSStackView] = [:]
    /// The Shortcuts table's document view (top-scroll on show).
    private var shortcutDoc: NSView?

    /// Full-width divider (NSBox separators hug intrinsic width inside a
    /// .leading stack — pin them to the body's width explicitly).
    private func addDivider(to body: NSStackView) {
        let sep = separator()
        body.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
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

    // MARK: - General

    private var loginCheck: NSButton!
    private var invertScrollCheck: NSButton!

    /// UserDefaults key: when true, scrolling DOWN on a knob increases
    /// the value (classic mouse-wheel convention — "wheel down = more"),
    /// the reverse of the natural trackpad direction. Read live by
    /// GainKnob.scrollWheel.
    static let invertScrollKey = "invertKnobScroll"

    private func buildGeneral(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("Startup"))
        loginCheck = NSButton(checkboxWithTitle: "Launch Quartet Buddy at login", target: self,
                              action: #selector(loginChanged(_:)))
        body.addArrangedSubview(loginCheck)
        addDivider(to: body)
        // Knob behavior — the scroll-direction preference, live-read by
        // the control window's knobs (no restart needed).
        body.addArrangedSubview(sectionLabel("Knobs"))
        invertScrollCheck = NSButton(
            checkboxWithTitle: "Invert scroll direction (wheel down = more)",
            target: self, action: #selector(invertScrollChanged(_:)))
        invertScrollCheck.state = UserDefaults.standard.bool(forKey: Self.invertScrollKey) ? .on : .off
        invertScrollCheck.toolTip = "Reverses scrolling on the gain/trim/level knobs.\n\nOff (natural): scroll up = more.\nOn (classic wheel): scroll down = more."
        body.addArrangedSubview(invertScrollCheck)
        let invertSub = NSTextField(labelWithString:
            "Applies to the scroll wheel on every knob in Quartet Control (gain, trim, monitor level).")
        invertSub.textColor = .secondaryLabelColor
        invertSub.font = .systemFont(ofSize: 10)
        body.addArrangedSubview(invertSub)
        addDivider(to: body)
        // Touchscreen preferences — the same bits the Quartet's own
        // touchscreen settings page flips, written straight through
        // ApogeeGlue (dev/<serial>/{peakHold, overHold, lockHomeScreen}).
        body.addArrangedSubview(sectionLabel("Touchscreen"))
        for (key, title, tip) in [
            ("peakHold", "Meter peak hold",
             "Level meters hold a peak marker on the touchscreen."),
            ("overHold", "Overload hold",
             "Hold the red clip indicator until acknowledged."),
            ("lockHomeScreen", "Lock home screen",
             "Locks the touchscreen to its home screen (needs the touchscreen to unlock again)."),
        ] {
            let check = NSButton(checkboxWithTitle: title, target: self,
                                 action: #selector(deviceFlagChanged(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(key)
            check.toolTip = tip
            body.addArrangedSubview(check)
            touchscreenChecks[key] = check
        }
        let tsSub = NSTextField(labelWithString:
            "The unit's touchscreen settings, mirrored here. Requires the Quartet to be connected.")
        tsSub.textColor = .secondaryLabelColor
        tsSub.font = .systemFont(ofSize: 10)
        body.addArrangedSubview(tsSub)
        addDivider(to: body)
        // FRONT-PANEL PADS — the three A/B/C touchpads + the encoder push,
        // assignable like any output action (verified live: writing
        // Touchpad_A.actionButton remaps the pad; the enum was captured by
        // driving Apogee Control 2 — see docs/protocol-notes.md).
        body.addArrangedSubview(sectionLabel("Front Panel Pads"))
        for (i, title) in ["Pad A", "Pad B", "Pad C", "Encoder Push"].enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(label)
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
            row.addArrangedSubview(p)
            body.addArrangedSubview(row)
            padPopups.append(p)
            NSLayoutConstraint.activate([
                p.widthAnchor.constraint(equalToConstant: 210),
                label.widthAnchor.constraint(equalToConstant: 100),
            ])
        }
        let padSub = NSTextField(labelWithString:
            "What each pad does at a touch — the same assignments Apogee Control 2 edits. Requires the Quartet to be connected.")
        padSub.textColor = .secondaryLabelColor
        padSub.font = .systemFont(ofSize: 10)
        body.addArrangedSubview(padSub)
        addDivider(to: body)
        // Debug log lives in its own Troubleshooting group.
        body.addArrangedSubview(sectionLabel("Troubleshooting"))
        let logButton = NSButton(title: "Open Debug Log…", target: self,
                                  action: #selector(openLog(_:)))
        body.addArrangedSubview(logButton)
    }

    /// The Touchscreen checkboxes (keyed by dev-node property name).
    private var touchscreenChecks: [String: NSButton] = [:]
    /// True while refresh is copying tree state into the checkboxes.
    private var touchscreenSyncing = false

    /// Front-panel pad assignment popups (Pad A/B/C, Encoder Push),
    /// plus the action enum captured from Apogee Control 2 (Oct 25–26
    /// 2026) — `padGroups` mirrors AC2's dropdown structure (grouped
    /// submenus); `padActions` is the flat reverse lookup used by refresh.
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
    /// Encoder Push restricted set — Apogee Control 2 gives the encoder a
    /// SHORTER menu than the pads (Mute ▸… + Toggle ▸ Mute Speaker/HP).
    /// An out-of-menu value written to the encoder left its action at 0x0
    /// (inert — verified), so Pads A/B/C and the encoder get different
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
        addDivider(to: body)
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
        guard let shortcuts, let shortcutStack else { return }
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

    // MARK: - Names

    /// One rename row: fixed label + editable field with a commit hint.
    private func nameRow(_ title: String, tag: Int) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
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
            label.widthAnchor.constraint(equalToConstant: 118),
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
        return row
    }

    private func nameBlock(into body: NSStackView, _ title: String, _ subtitle: String,
                           _ labels: [String], _ baseTag: Int) {
        body.addArrangedSubview(sectionLabel(title))
        let sub = secondary(subtitle)
        sub.font = .systemFont(ofSize: 10)
        body.addArrangedSubview(sub)
        for (i, label) in labels.enumerated() {
            body.addArrangedSubview(nameRow(label, tag: baseTag + i))
        }
        addDivider(to: body)
    }

    private func buildNames(into body: NSStackView) {
        nameBlock(into: body, "Quartet Inputs", "Written to the hardware — the touchscreen and Apogee Control 2 show these names.",
                  Self.hwInLabels, 5000)
        nameBlock(into: body, "Quartet Outputs", "Written to the hardware — Main Out, Headphones and the six ¼\" outputs.",
                  Self.hwOutLabels, 5010)
        nameBlock(into: body, "Stereo Pair Names", "Shown only in Quartet Buddy's window (defaults like \"Out 1–2\"); leave empty to fall back to the physical pair name.",
                  Self.pairLabels, 5020)
        rebuildNames()
    }

    /// Tree → the eleven fields (nil read = everything blank + disabled).
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

    /// A rename commit. Hardware names skip empty strings (the hardware
    /// can hold an empty name but that looks like a bug on the screen);
    /// pair names empty = revert to the physical pair name.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !nameSuppress, let field = obj.object as? NSTextField,
              field.tag >= 5000, field.tag < nameFields.count + 5000,
              let i = nameFields.firstIndex(of: field) else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let row = nameRows[i]
        if row.kind == .pair {
            writeName?(i, name)          // empty = revert (handled app-side)
        } else if !name.isEmpty {
            writeName?(i, name)
        }
        rebuildNames()
    }

    // MARK: - Talkback

    private var momentaryCheck: NSButton!
    private var midiLearnButton: NSButton!
    private var midiStateField: NSTextField!
    private var midiSuppress = false

    private func buildTalkback(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("Source"))
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(secondary("Device"))
        sourcePopup = NSPopUpButton()
        sourcePopup.translatesAutoresizingMaskIntoConstraints = false
        sourcePopup.target = self
        sourcePopup.action = #selector(talkbackSourceChanged(_:))
        row.addArrangedSubview(sourcePopup)
        body.addArrangedSubview(row)
        let channelRow = NSStackView()
        channelRow.orientation = .horizontal
        channelRow.spacing = 8
        channelRow.translatesAutoresizingMaskIntoConstraints = false
        channelRow.addArrangedSubview(secondary("Channel"))
        channelPopup = NSPopUpButton()
        channelPopup.translatesAutoresizingMaskIntoConstraints = false
        channelPopup.target = self
        channelPopup.action = #selector(talkbackChannelChanged(_:))
        channelRow.addArrangedSubview(channelPopup)
        body.addArrangedSubview(channelRow)
        let srcSub = NSTextField(labelWithString:
            "Who the talkback listens to — the same setting Apogee Control 2's\nTalkback pane writes. Channel 1 is the device's first input.")
        srcSub.textColor = .secondaryLabelColor
        srcSub.font = .systemFont(ofSize: 10)
        body.addArrangedSubview(srcSub)
        addDivider(to: body)
        body.addArrangedSubview(sectionLabel("Mode"))
        momentaryCheck = NSButton(checkboxWithTitle: "Momentary mode (hold to talk)",
                                  target: self, action: #selector(momentaryChanged(_:)))
        body.addArrangedSubview(momentaryCheck)
        addDivider(to: body)
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

    private var sourcePopup: NSPopUpButton!
    private var channelPopup: NSPopUpButton!
    private var sourceSuppress = false

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
        addDivider(to: body)
        // DEVICE BUFFER — the Quartet's own IO buffer size. The glue
        // tree's `preferredBufferSize` is a dead preference (verified:
        // never reaches the HAL even across a replug), so this writes the
        // CoreAudio property directly — the same knob the DAW buffer
        // panels work through. The insert restarts after a change.
        let devBufRow = NSStackView()
        devBufRow.orientation = .horizontal
        devBufRow.spacing = 8
        devBufRow.translatesAutoresizingMaskIntoConstraints = false
        devBufRow.addArrangedSubview(secondary("Device buffer"))
        devBufPopup = NSPopUpButton()
        devBufPopup.translatesAutoresizingMaskIntoConstraints = false
        for frames in deviceBufferChoices {
            devBufPopup.addItem(withTitle: "\(frames) frames")
            devBufPopup.lastItem?.representedObject = frames
        }
        devBufPopup.action = #selector(deviceBufferChanged(_:))
        devBufPopup.target = self
        devBufRow.addArrangedSubview(devBufPopup)
        body.addArrangedSubview(devBufRow)
        devBufField = secondary("")
        body.addArrangedSubview(devBufField)
        NSLayoutConstraint.activate([
            devBufPopup.widthAnchor.constraint(equalToConstant: 160),
        ])
        addDivider(to: body)
        // HARDWARE LINE OUT LEVELS (Analog Out 1–6 = hwout2..7) — each
        // ¼" output's own reference level (+4 dBu / −10 dBV), the same
        // knob the touchscreen's output settings drive.
        lineLevelRows(into: body)
    }

    private var devBufPopup: NSPopUpButton!
    private var devBufField: NSTextField!
    /// Classic HAL buffer sizes, snapped from the driver's 15…4096 range.
    private let deviceBufferChoices: [UInt32] = [32, 64, 128, 256, 512, 1024, 2048, 4096]

    /// Line-out hardware levels (Analog Out 1–6 — hwout2..7), read from
    /// the tree and written as int32 (+4 dBu = 2, −10 dBV = 3).
    var readLineOutLevels: (() -> [(name: String, refLevel: Int?)])?
    var writeLineOutLevel: ((Int, Int) -> Void)?

    private var lineOutPopups: [NSPopUpButton] = []
    private var lineOutLabels: [NSTextField] = []
    private var lineOutSuppress = false
    private var lineOutNames: [String] = []

    /// The reference-level popup for one hardware line output (the same
    /// analogRefLevel enum as the inputs: 2 = +4 dBu, 3 = −10 dBV).
    private func lineLevelRows(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("Line Out Levels"))
        for i in 0..<6 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(labelWithString: "Analog Out \(i + 1)")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(label)
            lineOutLabels.append(label)
            let p = NSPopUpButton()
            p.translatesAutoresizingMaskIntoConstraints = false
            p.addItem(withTitle: "+4 dBu")
            p.addItem(withTitle: "−10 dBV")
            p.lastItem?.representedObject = 3
            p.item(at: 0)?.representedObject = 2
            p.action = #selector(lineOutLevelChanged(_:))
            p.target = self
            p.tag = 3600 + i
            row.addArrangedSubview(p)
            body.addArrangedSubview(row)
            lineOutPopups.append(p)
            NSLayoutConstraint.activate([
                p.widthAnchor.constraint(equalToConstant: 110),
                label.widthAnchor.constraint(equalToConstant: 90),
            ])
        }
        lineOutNames = (0..<6).map { "Analog Out \($0 + 1)" }
    }

    private func rebuildLineOuts() {
        guard !lineOutPopups.isEmpty else { return }
        lineOutSuppress = true
        defer { lineOutSuppress = false }
        let read = readLineOutLevels?() ?? []
        let ok = read.count == 6 && read[0].refLevel != nil
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

    private func rebuildAudio() {
        guard latencyPopup != nil else { return }
        audioSuppress = true
        defer { audioSuppress = false }
        let current = InsertServer.savedBufferFrames()
        latencyPopup.selectItem(at: InsertServer.bufferChoices.firstIndex { $0.frames == current } ?? 0)
        let liveRate = InsertServer.shared.currentRate()
        let khz = liveRate / 1000
        rateField.stringValue = "Quartet · \(khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)) kHz"
        // Device buffer — live value from Core Audio; the field carries
        // the ms figure at the live rate (e.g. "≈2.7 ms").
        if let frames = InsertServer.deviceBufferFrames() {
            let idx = deviceBufferChoices.enumerated().min {
                abs(Int($0.element) - Int(frames)) < abs(Int($1.element) - Int(frames))
            }
            devBufPopup.selectItem(at: idx?.offset ?? 0)
            let rate = InsertServer.deviceSampleRate() ?? 48000
            let ms = Double(frames) / rate * 1000
            devBufField.stringValue = String(format: "Quartet · %d frames ≈ %.1f ms", frames, ms)
            devBufPopup.isEnabled = true
        } else {
            devBufPopup.isEnabled = false
            devBufField.stringValue = "Quartet not connected"
        }
        rebuildLineOuts()
    }

    /// A device-buffer pick: write straight into Core Audio, then restart
    /// the insert (its aggregate was built against the old buffer).
    /// Persist the last REQUESTED size for a friendly restore read.
    @objc private func deviceBufferChanged(_ sender: NSPopUpButton) {
        guard !audioSuppress,
              let frames = sender.selectedItem?.representedObject as? UInt32 else { return }
        let live = InsertServer.deviceBufferFrames()
        QBLog.log("settings: device buffer \(live.map(String.init) ?? "?") → \(frames)")
        guard InsertServer.setDeviceBufferFrames(frames) else {
            QBLog.log("settings: device buffer write rejected by Core Audio")
            return rebuildAudio()
        }
        let wasRunning = InsertServer.shared.running
        if wasRunning {
            // re-close the tap/aggregate against the reconfigured stream
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                InsertServer.shared.setBufferFrames(InsertServer.savedBufferFrames())
            }
        }
    }

    // MARK: - Auto Gain

    private var gainTargetPopup: NSPopUpButton!
    private var gainDurationPopup: NSPopUpButton!
    private var gainSuppress = false

    /// Settings ▸ Auto Gain — the two labeled rows that used to live in
    /// the main window's Inputs header:
    ///
    ///     Target peak level      [ −18 dBFS peak ▾ ]
    ///     Measurement duration   [ 5 s           ▾ ]
    ///
    /// One persisted configuration for BOTH the per-input Auto Gain and
    /// Auto Gain All. A change applies to the NEXT operation — a run in
    /// flight keeps its own target/duration.
    private func buildAutoGain(into body: NSStackView) {
        body.addArrangedSubview(sectionLabel("Calibration"))

        // Target peak level
        let targetRow = NSStackView()
        targetRow.orientation = .horizontal
        targetRow.spacing = 8
        targetRow.alignment = .centerY
        targetRow.translatesAutoresizingMaskIntoConstraints = false
        targetRow.addArrangedSubview(secondary("Target peak level"))
        gainTargetPopup = NSPopUpButton()
        gainTargetPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AutoGainEngine.targetOptions {
            gainTargetPopup.addItem(withTitle: String(format: "%.0f dBFS peak", v))
            gainTargetPopup.lastItem?.representedObject = NSNumber(value: v)
        }
        gainTargetPopup.action = #selector(gainTargetChanged(_:))
        gainTargetPopup.target = self
        targetRow.addArrangedSubview(gainTargetPopup)
        body.addArrangedSubview(targetRow)

        // Measurement duration
        let durationRow = NSStackView()
        durationRow.orientation = .horizontal
        durationRow.spacing = 8
        durationRow.alignment = .centerY
        durationRow.translatesAutoresizingMaskIntoConstraints = false
        durationRow.addArrangedSubview(secondary("Measurement duration"))
        gainDurationPopup = NSPopUpButton()
        gainDurationPopup.translatesAutoresizingMaskIntoConstraints = false
        for v in AutoGainEngine.listenOptions {
            gainDurationPopup.addItem(withTitle: String(format: "%.0f s", v))
            gainDurationPopup.lastItem?.representedObject = NSNumber(value: v)
        }
        gainDurationPopup.action = #selector(gainDurationChanged(_:))
        gainDurationPopup.target = self
        durationRow.addArrangedSubview(gainDurationPopup)
        body.addArrangedSubview(durationRow)

        NSLayoutConstraint.activate([
            gainTargetPopup.widthAnchor.constraint(equalToConstant: 160),
            gainDurationPopup.widthAnchor.constraint(equalToConstant: 160),
        ])

        body.addArrangedSubview(secondary(
            "Applies to the next Auto Gain operation — both per-input and Auto Gain All."))
    }

    private func rebuildAutoGain() {
        guard gainTargetPopup != nil, gainDurationPopup != nil else { return }
        gainSuppress = true
        defer { gainSuppress = false }
        for item in gainTargetPopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AutoGainEngine.targetDBFS {
            gainTargetPopup.select(item); break
        }
        for item in gainDurationPopup.itemArray
        where (item.representedObject as? NSNumber)?.doubleValue == AutoGainEngine.listenSeconds {
            gainDurationPopup.select(item); break
        }
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
        addDivider(to: body)
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

    /// Knob scroll-direction preference — GainKnob reads the default
    /// live, so no restart/rebuild is needed.
    @objc private func invertScrollChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.invertScrollKey)
        QBLog.log("settings: knob scroll inverted = \(sender.state == .on)")
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