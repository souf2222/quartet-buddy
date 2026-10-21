import AppKit

// QUICK-CONTROL PANEL — an optional, TITLEBAR-FREE floating strip.
//
// A compact, borderless panel with the essentials: both monitor outputs
// (Speakers · Headphones) as knobs with their M/D/∑ chips, the OS
// volume-target marker, and the global tiles (Talkback · Mute-All ·
// Settings). Shown/hidden with a configurable global hotkey (default
// ⌥C — Settings ▸ Shortcuts ▸ "Show / hide quick-control panel").
//
// Everything re-uses the main window's controls and plumbing: the knobs,
// chips and icon tiles are the same classes, the state is read back from
// QuartetControlController (it fires `onRefreshed` after every refresh),
// and the writes go through the same path-id plumbing. No new state.

/// Owns the one shared panel.
final class QuickPanelController: NSObject, NSWindowDelegate {

    static let shared = QuickPanelController()

    // MARK: controls (mirrors of the monitor bar's)

    private var panel: NSPanel?
    private var monKnobs: [GainKnob] = []
    private var markers: [NSView] = []
    private var muteToggles: [NSButton] = []
    private var dimToggles: [NSButton] = []
    private var sumToggles: [NSButton] = []
    private var talkbackButton: TalkbackIconButton?
    private var muteAllButton: MuteAllIconButton?

    /// Panel size — one row per output + the global row.
    private static let size = NSSize(width: 380, height: 158)

    // MARK: show / hide

    /// Hotkey / logo-click entry point — toggle the panel.
    func toggleShown() { isShown ? hide() : show() }

    var isShown: Bool { panel?.isVisible ?? false }

    func show() {
        buildIfNeeded()
        position()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        sync()
    }

    func hide() { panel?.orderOut(nil) }

    /// Re-sync every control from the controller's live state — the
    /// controller fires `onRefreshed` after each of its refreshes.
    func sync() {
        guard panel != nil else { return }
        let control = QuartetControlController.shared
        let states = control.monitorStates()
        let connected = control.isGlueConnected?() ?? false
        let learning = control.isLearning
        let target = control.volumeTarget?()

        for o in 0..<2 {
            let st = o < states.count ? states[o] : .init()
            let knob = monKnobs[o]
            knob.isEnabled = connected && !learning
            if let g = st.gain, knob.doubleValue != g { knob.doubleValue = g }
            knob.valueKind = (connected && st.gain != nil) ? .live : .unknown
            muteToggles[o].isEnabled = connected && !learning
            muteToggles[o].state = (st.mute ?? false) ? .on : .off
            dimToggles[o].isEnabled = connected && !learning
            dimToggles[o].state = (st.dim ?? false) ? .on : .off
            sumToggles[o].isEnabled = connected && !learning
            sumToggles[o].state = (st.sum ?? false) ? .on : .off
            markers[o].layer?.backgroundColor = (o == target
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor)
        }
        let tb = control.talkbackState?() ?? false
        talkbackButton?.state = tb ? .on : .off
        talkbackButton?.isEnabled = connected && !learning
        let bothMuted = (states.first?.mute ?? false) && (states.last?.mute ?? false)
        muteAllButton?.state = bothMuted ? .on : .off
        muteAllButton?.isEnabled = connected && !learning
        muteAllButton?.idleTint = connected && !bothMuted ? GGTheme.muteIdle : nil
    }

    /// Pin the panel under the menubar's right edge (near the Apogee logo).
    private func position() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let x = v.maxX - Self.size.width - 16
        let y = v.maxY - Self.size.height - 10
        panel?.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: Self.size), display: false)
    }

    // MARK: build

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12

        // quiet dark surface, like the main window's
        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .windowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        content.addSubview(blur, positioned: .below, relativeTo: nil)

        let title = NSTextField(labelWithString: "Quartet · Quick Control")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = GGTheme.muted
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // one row per monitor output
        for o in 0..<2 {
            stack.addArrangedSubview(makeMonitorRow(o))
        }

        // the global row — the same tiles the monitor bar uses
        let globals = NSStackView()
        globals.orientation = .horizontal
        globals.spacing = 6
        globals.translatesAutoresizingMaskIntoConstraints = false

        let mic = TalkbackIconButton(tag: 0, accent: GGTheme.talkbackActive,
                                      target: self, action: #selector(quickTalkback(_:)))
        mic.toolTip = "Talkback"
        mic.setAccessibilityLabel("Talkback")
        talkbackButton = mic
        globals.addArrangedSubview(mic)

        let mute = MuteAllIconButton(tag: 0, accent: GGTheme.muteEngaged,
                                      target: self, action: #selector(quickMuteAll(_:)))
        mute.toolTip = "Mute all outputs"
        mute.setAccessibilityLabel("Mute all outputs")
        muteAllButton = mute
        globals.addArrangedSubview(mute)

        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        globals.addArrangedSubview(gap)

        let settings = SettingsIconButton(tag: 0, accent: GGTheme.accent,
                                          target: self, action: #selector(quickSettings(_:)))
        settings.toolTip = "Settings…"
        settings.setAccessibilityLabel("Settings")
        globals.addArrangedSubview(settings)

        stack.addArrangedSubview(globals)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: content.topAnchor),
            blur.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -10),
            content.heightAnchor.constraint(equalToConstant: Self.size.height),
            content.widthAnchor.constraint(equalToConstant: Self.size.width),
        ])

        let p = QuartetPanel(contentRect: content.bounds,
                        styleMask: [.nonactivatingPanel, .borderless, .resizable],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = content
        p.delegate = self
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p

        // live sync — the controller refreshes on every echo/state change
        QuartetControlController.shared.onRefreshed = { [weak self] in self?.sync() }
    }

    /// [marker] Label  (knob)  [M] [D] [∑] — mirrors the monitor bar.
    private func makeMonitorRow(_ o: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = GGSpace.related
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        // the OS volume-target marker (space reserved in both rows)
        let marker = NSView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.clear.cgColor
        marker.layer?.cornerRadius = 1
        marker.widthAnchor.constraint(equalToConstant: 2).isActive = true
        marker.heightAnchor.constraint(equalToConstant: 14).isActive = true
        markers.append(marker)

        let name = NSTextField(labelWithString: o == 0 ? "Speakers" : "Headphones")
        name.font = GGTheme.nameFont
        name.textColor = GGTheme.primary
        let nameBlock = NSView()
        nameBlock.translatesAutoresizingMaskIntoConstraints = false
        nameBlock.addSubview(name)
        NSLayoutConstraint.activate([
            nameBlock.widthAnchor.constraint(equalToConstant: 84),
            name.leadingAnchor.constraint(equalTo: nameBlock.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: nameBlock.centerYAnchor),
        ])

        let knob = GainKnob()
        knob.minValue = AppDelegate.minDB
        knob.maxValue = AppDelegate.maxDB
        knob.controlName = o == 0 ? "Speakers level" : "Headphones level"
        knob.target = self
        knob.action = #selector(quickMonSlid(_:))
        knob.tag = 700 + o
        knob.sendsContinuously = true
        knob.widthAnchor.constraint(equalToConstant: 44).isActive = true
        knob.heightAnchor.constraint(equalToConstant: 44).isActive = true
        monKnobs.append(knob)

        func chip(_ title: String, accent: NSColor, tag: Int,
                  which: QuartetControlController.QuickMonitorToggle) -> FunctionToggle {
        let t = FunctionToggle(title: title, tag: tag, accent: accent,
                               target: self, action: #selector(quickChip(_:)))
        t.toolTip = title
        t.setAccessibilityRole(.button)
        t.setAccessibilityLabel(title)
            switch which {
            case .mute: muteToggles.append(t)
            case .dim: dimToggles.append(t)
            case .sum: sumToggles.append(t)
            }
            return t
        }

        let mute = chip("M", accent: GGTheme.red, tag: 800 + o, which: .mute)
        let dim = chip("D", accent: GGTheme.amber, tag: 900 + o, which: .dim)
        let sum = chip("∑", accent: GGTheme.accent, tag: 1000 + o, which: .sum)

        row.addArrangedSubview(marker)
        row.addArrangedSubview(nameBlock)
        row.addArrangedSubview(knob)
        row.addArrangedSubview(mute)
        row.addArrangedSubview(dim)
        row.addArrangedSubview(sum)
        return row
    }

    // MARK: actions — routed through the controller's own plumbing

    @objc private func quickMonSlid(_ sender: NSControl) {
        let o = sender.tag - 700
        let control = QuartetControlController.shared
        let id = o == 0 ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain
        guard !control.isLearning, !id.isEmpty else { return sync() }
        let v = min(max(sender.doubleValue, AppDelegate.minDB), AppDelegate.maxDB)
        control.onWriteDouble?(id, v)
    }

    @objc private func quickChip(_ sender: NSButton) {
        let control = QuartetControlController.shared
        let on = sender.state == .on
        switch sender.tag {
        case 800..<802: control.quickSetMonitor(sender.tag - 800, .mute, on)
        case 900..<902: control.quickSetMonitor(sender.tag - 900, .dim, on)
        case 1000..<1002: control.quickSetMonitor(sender.tag - 1000, .sum, on)
        default: break
        }
    }

    /// Talkback tile (latch-toggle form; hold is handled by `hold`).
    @objc private func quickTalkback(_ sender: NSButton) {
        QuartetControlController.shared.onTalkback?(sender.state == .on)
    }

    @objc private func quickMuteAll(_ sender: NSButton) {
        QuartetControlController.shared.quickToggleMuteAll()
    }

    @objc private func quickSettings(_ sender: NSButton) {
        QuartetControlController.shared.onOpenSettings?()
    }

    // MARK: NSWindowDelegate — vanish when the focus leaves

    func windowDidResignKey(_ notification: Notification) {
        // a click outside quietly dismisses the quick strip
        hide()
    }
}