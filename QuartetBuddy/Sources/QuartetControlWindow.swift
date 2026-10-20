import AppKit

/// "Quartet Control" — the single unified audio-control window.
///
/// Merges the old "Quartet Console" (inputs + monitoring) and "Outputs &
/// Plug-ins" (routing) windows into ONE resizable workspace with an
/// explicit signal flow, top to bottom:
///
///     input configuration → playback routing & processing → listening level
///
/// Three regions share one window (never tabs — everything stays visible):
///   • Inputs             — four identical analog-input cards
///   • Outputs & Routing  — four stereo-output cards (same 4-column grid)
///   • Monitor            — a fixed strip: Main Speakers + Headphones
///
/// The Inputs and Outputs sections live in a scroll view; the Monitor strip
/// is pinned to the bottom so everyday listening controls never scroll away.
///
/// macOS "Golden Gate" visual direction: warm charcoal, graphite cards
/// (1pt border, 14pt radius, mostly opaque), restrained translucency in the
/// title bar and monitor strip only, and a muted bridge-orange accent.
///
/// Plumbing is unchanged from the two windows it replaces: hardware reads
/// come from the glue tree (live 2 s poll while visible), writes go through
/// setProperty path-ids (all clamped — out-of-range writes crash the unit),
/// routing state lives in InsertServer, and Learn mode captures missing
/// ids by listening to the live event stream.

// MARK: - Theme (neutral graphite; color = state only)

enum GGTheme {
    /// Window base — neutral charcoal `#202022` (no warm tint).
    static let windowTint = NSColor(calibratedWhite: 0.1255, alpha: 0.92)
    /// Channel cards — a step lighter than the window (`#2B2B2E`), no purple.
    static let card = NSColor(calibratedWhite: 0.169, alpha: 1)
    /// Editable / recessed control surface (`#343437`).
    static let control = NSColor(calibratedWhite: 0.204, alpha: 1)
    /// One-point quiet card outline (white at 7%).
    static let cardBorder = NSColor(white: 1, alpha: 0.07)
    /// Monitor strip — close to the window color; a thin top divider does
    /// the separation, not a contrast panel.
    static let monitorStrip = NSColor(calibratedWhite: 0.135, alpha: 1)
    /// Primary text — names and important values (`#F0F0F2`).
    static let primary = NSColor(calibratedWhite: 0.945, alpha: 1)
    /// Secondary text — labels and hardware identifiers (`#A5A5AB`).
    static let softGray = NSColor(calibratedWhite: 0.647, alpha: 1)
    /// Restrained STATE colors — ONLY for engaged toggles / running
    /// operations / signal status. Never decoration.
    /// 48V / Dim: amber when engaged.
    static let stateAmber = NSColor(calibratedRed: 0.82, green: 0.60, blue: 0.22, alpha: 1)
    /// Soft Limit / Polarity / Mono / running ops: blue when engaged.
    static let stateBlue = NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.92, alpha: 1)
    /// Mute: red when engaged.
    static let stateRed = NSColor(calibratedRed: 0.88, green: 0.27, blue: 0.23, alpha: 1)
    /// Red — clipping / prominent warnings (a mute is a state, not a warning).
    static let warning = stateRed

    static let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let sectionFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let nameFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let labelFont = NSFont.systemFont(ofSize: 11)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)

    /// Style a card: graphite surface, 1pt border, 14pt radius, flat.
    static func applyCardStyle(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.backgroundColor = card.cgColor
        v.layer?.borderColor = cardBorder.cgColor
        v.layer?.borderWidth = 1
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
    }
}

/// A compact horizontal signal meter: 20 segments, green → amber → red.
/// Level is 0…1; segments light from the left. Quiet at rest.
final class GGLevelMeter: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        NSColor(white: 0, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: h * 0.35), xRadius: 2, yRadius: 2).fill()
        let lit = Int((min(max(level, 0), 1) * 20).rounded())
        let segs = 20
        let gap = bounds.width * 0.012
        let w = (bounds.width - gap * CGFloat(segs - 1)) / CGFloat(segs)
        for s in 0..<lit {
            let x = CGFloat(s) * (w + gap)
            let c: NSColor = s < 13 ? NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.62, alpha: 0.95)
                : s < 17 ? NSColor(calibratedRed: 0.9, green: 0.62, blue: 0.1, alpha: 0.95)
                : GGTheme.warning.withAlphaComponent(0.95)
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: h * 0.32, width: w, height: h * 0.36),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

// MARK: - Neutral slider (gray track, light thumb — no permanent blue)

/// A linear slider with a neutral graphite track, a slightly brighter
/// filled portion before the knob, and a small light-gray thumb — drawn
/// from scratch (the system slider is SwiftUI-hosted on this macOS,
/// ignores cell drawing, and its track is permanently blue).
///
/// A slider's position and numeric value carry its meaning: the track
/// never looks "enabled". Keyboard focus shows a thin accent ring;
/// arrow keys adjust (⇧ for fine steps). Optional: double-click resets
/// to unity (output trim).
final class NeutralSlider: NSControl {

    var minValue: Double = 0 { didSet { _value = min(max(_value, minValue), maxValue); needsDisplay = true } }
    var maxValue: Double = 1 { didSet { _value = min(max(_value, minValue), maxValue); needsDisplay = true } }
    var sendsContinuously = true
    /// Double-click resets to 0 dB (unity) — output-trim sliders.
    var doubleClickResets = false

    private var _value: Double = 0
    override var doubleValue: Double {
        get { _value }
        set { _value = min(max(newValue, minValue), maxValue); needsDisplay = true }
    }

    static let trackColor = NSColor(calibratedWhite: 0.27, alpha: 1)   // #454549
    static let fillColor = NSColor(calibratedWhite: 0.38, alpha: 1)    // brighter before the knob
    static let thumbColor = NSColor(calibratedWhite: 0.89, alpha: 1)    // #E3E3E6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior   // thin accent outline, keyboard focus only
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 16) }
    override var acceptsFirstResponder: Bool { isEnabled }

    // MARK: drawing
    override func draw(_ dirtyRect: NSRect) {
        let enabled = isEnabled
        let h: CGFloat = 4
        let bar = NSRect(x: 0, y: bounds.midY - h / 2, width: bounds.width, height: h)
        (enabled ? Self.trackColor : Self.trackColor.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
        let knobX = bar.minX + CGFloat(fraction) * bar.width
        let w = min(max(knobX - bar.minX, 0), bar.width)
        if w > 2 {
            (enabled ? Self.fillColor : Self.fillColor.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: w, height: h),
                         xRadius: h / 2, yRadius: h / 2).fill()
        }
        let size: CGFloat = 12
        (enabled ? Self.thumbColor : NSColor(calibratedWhite: 0.55, alpha: 1)).setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - size / 2, y: bounds.midY - size / 2,
                                    width: size, height: size)).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }

    // MARK: value helpers
    private var fraction: Double {
        maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
    }
    private func setFraction(_ f: Double) {
        let clamped = min(max(f, 0), 1)
        doubleValue = minValue + clamped * (maxValue - minValue)
    }
    @discardableResult
    private func send() -> Bool { sendAction(action, to: target) }

    // MARK: mouse tracking (double-click → unity on trim sliders)
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if doubleClickResets, event.clickCount >= 2 {
            doubleValue = 0
            send()
            return
        }
        track(at: event)
        if sendsContinuously { send() }
        var keep = true
        while keep {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            track(at: ev)
            if ev.type == .leftMouseUp { keep = false }
            if sendsContinuously { send() }
        }
        send()
    }
    private func track(at event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setFraction(Double(p.x / max(bounds.width, 1)))
    }

    // MARK: keyboard
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        let fine = event.modifierFlags.contains(.shift)
        let step = fine ? max((maxValue - minValue) / 100, 0.01) : 1.0
        switch event.specialKey {
        case .leftArrow, .downArrow:
            doubleValue -= step
            send()
        case .rightArrow, .upArrow:
            doubleValue += step
            send()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - controller

final class QuartetControlController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    static let shared = QuartetControlController()

    // MARK: plumbing (set by AppDelegate)

    var onWriteDouble: (([UInt8], Double) -> Void)?
    var onWriteBool: (([UInt8], Bool) -> Void)?
    var onWriteInt: (([UInt8], Int32) -> Void)?
    var onRequestTree: (() -> Void)?
    var isGlueConnected: (() -> Bool)?
    /// The last tree the app received (seeds the window with real values).
    var onSeedTree: (() -> [String: Any]?)?
    /// Toolbar settings button → Settings window.
    var onOpenSettings: (() -> Void)?
    /// The connected interface's name, for the title-bar subtitle.
    var interfaceName: String = "Apogee Quartet"

    // MARK: state

    struct InputState {
        var name: String?
        var refLevel: Int?
        var micGain: Double?
        var instGain: Double?
        var phantom: Bool?
        var softLimit: Bool?
        var polarity: Bool?
    }
    /// Monitor outputs: 0 = Main Out (speakers), 1 = Headphones.
    struct MonitorState {
        var gain: Double?
        var mute: Bool?
        var dim: Bool?
        var sum: Bool?
    }
    private var inputs: [InputState] = (0..<4).map { _ in InputState() }
    private var monitors: [MonitorState] = [.init(), .init()]

    private var window: NSWindow?
    private var suppressActions = false
    private var pollTimer: Timer?

    // Learn mode (unchanged mechanism from the old console)
    private var learnQueue: [(key: String, tag: UInt8, label: String)] = []
    private var learningColumn: LearnColumn?
    /// True while a Learn capture session runs — AppDelegate gates its own
    /// hardware writes on this so echoes can't pollute the capture.
    var isLearning: Bool { !learnQueue.isEmpty }

    // Auto Gain status line
    private var autoGainStatus: String?
    private var autoGainStatusTimer: Timer?

    enum LearnColumn: Equatable { case input(Int), monitor(Int) }

    // MARK: show / refresh

    func show() {
        if window == nil { build() }
        if let tree = onSeedTree?() {
            interfaceName = Self.interfaceName(from: tree)
            updateTree(tree)
        } else { refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPoll()
        onRequestTree?()
    }

    /// The interface's display name from the tree (serial, when present).
    private static func interfaceName(from tree: [String: Any]) -> String {
        if let serial = GlueClient.quartetSerial(in: tree) {
            return "Apogee Quartet · \(serial)"
        }
        return "Apogee Quartet"
    }

    func refresh() {
        guard window != nil, statusField != nil else { return }
        suppressActions = true
        defer { suppressActions = false }
        let connected = isGlueConnected?() ?? false
        let learning = isLearning
        let autoRunning = AutoGainEngine.shared.runningInputs

        // INPUTS
        for i in 0..<4 {
            let st = inputs[i]
            let t = PathIds.active
            let lineMode = st.refLevel == 2 || st.refLevel == 3
            levelPopups[i].isEnabled = connected && !learning && t.hwinRefLevel[i] != nil && autoRunning.isEmpty
            if let rl = st.refLevel {
                selectPopup(levelPopups[i], value: rl)
            } else {
                levelPopups[i].selectItem(withTitle: "—")
            }

            // Mode-dependent controls: the preamp only applies in Mic /
            // Instrument; the meter + gain block hides at the line levels.
            gainSectionFields[i]?.isHidden = lineMode
            gainSliders[i].isHidden = lineMode
            gainFields[i].isHidden = lineMode
            meters[i].isHidden = lineMode
            autoGainButtons[i].isHidden = lineMode
            toggles48V[i].isHidden = lineMode || st.refLevel == 4

            let mineRunning = autoRunning.contains(i)
            autoGainButtons[i].title = mineRunning ? "Cancel" : "Auto Gain"
            autoGainButtons[i].isEnabled = connected && !learning
                && (mineRunning || autoRunning.isEmpty)
            // Auto Gain is an action, not a persistent state: neutral at
            // rest, blue accent + progress semantics only while running.
            if #available(macOS 13.0, *) {
                autoGainButtons[i].bezelColor =
                    mineRunning ? GGTheme.stateBlue.withAlphaComponent(0.32) : nil
            }

            let micId = t.hwinMicGain[i], instId = t.hwinInstGain[i]
            gainSliders[i].isEnabled = connected && !learning && micId != nil && instId != nil && autoRunning.isEmpty
            let shown: Double
            if st.refLevel == 4 { shown = st.instGain ?? st.micGain ?? 0 }
            else { shown = st.micGain ?? st.instGain ?? 0 }
            if gainSliders[i].doubleValue != shown { gainSliders[i].doubleValue = shown }
            updateGainField(i)

            setToggle(toggles48V[i], st.phantom,
                      enabled: connected && !learning && t.hwinPhantom[i] != nil,
                      activeColor: GGTheme.stateAmber)
            setToggle(softLimitToggles[i], st.softLimit,
                      enabled: connected && !learning && t.hwinSoftLimit[i] != nil,
                      activeColor: GGTheme.stateBlue)
            setToggle(polarityToggles[i], st.polarity,
                      enabled: connected && !learning && t.hwinPolarity[i] != nil,
                      activeColor: GGTheme.stateBlue)

            inputHeaders[i]?.stringValue = st.name ?? "Analog In \(i + 1)"

            let missing = missingInputTargets(i)
            inputLearnButtons[i].isHidden = missing.isEmpty && !isLearning
            inputLearnButtons[i].isEnabled = (learning && learningColumn == .input(i)) || !missing.isEmpty
        }

        // OUTPUTS & ROUTING (InsertServer state)
        let server = InsertServer.shared
        let live = server.running
        for i in 0..<4 {
            if nameFields[i].stringValue != Self.savedName(i) {
                nameFields[i].stringValue = Self.savedName(i)
            }

            let srcPopup = sourcePopups[i]
            srcPopup.removeAllItems()
            for src in InsertServer.sourceOptions(i) {
                srcPopup.addItem(withTitle: InsertServer.sourceLabel(src, for: i))
                srcPopup.lastItem?.representedObject = src.rawValue
            }
            srcPopup.selectItem(at: srcPopup.indexOfItem(withObjectValue: server.source(i).rawValue).getOrElse { 0 })
            srcPopup.isEnabled = live

            // "Include source processing" — mirrored sources only.
            let mirrored = server.source(i).copyIndex != nil && server.source(i) != .off
            let include = includeChecks[i]
            include.isHidden = !mirrored
            if mirrored {
                include.state = server.mirrorPre(i) ? .off : .on
                include.isEnabled = live
            }

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

            // Processing slot: WITH a plug-in → enable switch + picker + Open.
            // WITHOUT → one neutral "Add Plug-in…" control; the switch, picker
            // and Open hide (never disabled/dead), and the fixed slot height
            // keeps every card's layout identical.
            let hasPlugin = server.pluginName(i) != nil
            enabledChecks[i].state = (server.enabled(i) && !server.bypassAll) ? .on : .off
            enabledChecks[i].isEnabled = live && hasPlugin
            enabledChecks[i].isHidden = !hasPlugin
            plugPopup.isHidden = !hasPlugin
            openButtons[i].isEnabled = live && hasPlugin
            openButtons[i].isHidden = !hasPlugin
            addPluginButtons[i].isHidden = hasPlugin
            addPluginButtons[i].isEnabled = live

            let trim = server.trim(i)
            if trimSliders[i].doubleValue != trim { trimSliders[i].doubleValue = trim }
            let text = String(format: "%+.1f dB", trim)
            if trimFields[i].stringValue != text { trimFields[i].stringValue = text }
            trimFields[i].textColor = trim > 0.01 ? GGTheme.warning : GGTheme.softGray
        }

        // MONITOR
        for o in 0..<2 {
            let st = monitors[o]
            let t = PathIds.active
            let gainId = o == 0 ? t.hwout0Gain : t.hwout1Gain
            let muteId = o == 0 ? t.hwout0Mute : t.hwout1Mute
            let dimId = o == 0 ? t.hwout0Dim : t.hwout1Dim
            let sumId = o == 0 ? t.hwout0Sum : t.hwout1Sum

            monSliders[o].isEnabled = connected && !learning && !gainId.isEmpty
            let g = min(max(st.gain ?? 0, AppDelegate.minDB), AppDelegate.maxDB)
            if monSliders[o].doubleValue != g { monSliders[o].doubleValue = g }
            let text = String(format: "%.1f dB", st.gain ?? 0)
            if monFields[o].stringValue != text { monFields[o].stringValue = text }

            setToggle(muteToggles[o], st.mute, enabled: connected && !learning && !muteId.isEmpty,
                      activeColor: GGTheme.stateRed)
            setToggle(dimToggles[o], st.dim, enabled: connected && !learning && dimId != nil,
                      activeColor: GGTheme.stateAmber)
            setToggle(monoToggles[o], st.sum, enabled: connected && !learning && sumId != nil,
                      activeColor: GGTheme.stateBlue)

            // Mute gets the clearest active state: filled button + badge.
            mutedBadges[o]?.isHidden = !(st.mute ?? false)
            let missing = missingMonitorTargets(o)
            monLearnButtons[o].isHidden = missing.isEmpty && !isLearning
            monLearnButtons[o].isEnabled = (learning && learningColumn == .monitor(o)) || !missing.isEmpty
        }

        statusField.stringValue = learnStatus()
            ?? autoGainStatus
            ?? (connected ? "" : "Not connected — waiting for Apogee Control 2 / ApogeeGlue…")
        // NOTE: no geometry work here — resizing during a refresh cancels
        // slider drags mid-flight. The window's size is the user's.
    }

    /// Full-state sync from the glue tree (AppDelegate.onTree → here).
    func updateTree(_ tree: [String: Any]) {
        interfaceName = Self.interfaceName(from: tree)
        subtitleField?.stringValue = interfaceName
        for i in 0..<4 {
            var st = InputState()
            if let node = findTyped(tree, "hwin\(i)") {
                st.name = (node["props"] as? [String: Any])?["name"] as? String
                st.refLevel = GlueClient.intProp(node, "analogRefLevel")
                st.softLimit = (GlueClient.intProp(node, "softLimit") ?? 0) == 1
                st.polarity = (GlueClient.intProp(node, "polarityInvert") ?? 0) == 1
                if let mic = findTyped(node, "micSettings") {
                    st.phantom = (GlueClient.intProp(mic, "phantom") ?? 0) == 1
                    if let pre = findTyped(mic, "PreModelQuartet") {
                        st.micGain = GlueClient.doubleProp(pre, "gain")
                    }
                }
                if let inst = findTyped(node, "instSettings"),
                   let pre = findTyped(inst, "PreModelQuartet") {
                    st.instGain = GlueClient.doubleProp(pre, "gain")
                }
            }
            inputs[i] = st
        }
        for o in 0..<2 {
            var st = MonitorState()
            if let node = findTyped(tree, "hwout\(o)") {
                st.gain = GlueClient.doubleProp(node, "gain")
                st.mute = (GlueClient.intProp(node, "mute") ?? 0) == 1
                st.dim = (GlueClient.intProp(node, "dim") ?? 0) == 1
                st.sum = (GlueClient.intProp(node, "sum") ?? 0) == 1
            }
            monitors[o] = st
        }
        refresh()
    }

    /// Live setProperty events: update whichever control the id belongs to.
    /// While Learn mode runs, the stream instead feeds the capture.
    func handle(_ event: GlueClient.SetPropertyEvent) {
        if isLearning { learnHandle(event); return }
        if AutoGainEngine.shared.isRunning {
            AutoGainEngine.shared.noteGlueEvent(id: event.id, tag: event.tag, value: event.value)
        }
        let t = PathIds.active
        for i in 0..<4 {
            if event.tag == 1, let id = t.hwinRefLevel[i], id == event.id,
               let v = event.value.readInt32() { inputs[i].refLevel = Int(v); refresh() }
            if event.tag == 4, let id = t.hwinMicGain[i], id == event.id,
               let v = event.value.readDouble() { inputs[i].micGain = v; refresh() }
            if event.tag == 4, let id = t.hwinInstGain[i], id == event.id,
               let v = event.value.readDouble() { inputs[i].instGain = v; refresh() }
            if event.tag == 3, let id = t.hwinPhantom[i], id == event.id {
                inputs[i].phantom = event.value.first == 1; refresh() }
            if event.tag == 3, let id = t.hwinSoftLimit[i], id == event.id {
                inputs[i].softLimit = event.value.first == 1; refresh() }
            if event.tag == 3, let id = t.hwinPolarity[i], id == event.id {
                inputs[i].polarity = event.value.first == 1; refresh() }
        }
        for o in 0..<2 {
            if event.tag == 4, o == 0, t.hwout0Gain == event.id,
               let v = event.value.readDouble() { monitors[0].gain = v; refresh() }
            if event.tag == 4, o == 1, t.hwout1Gain == event.id,
               let v = event.value.readDouble() { monitors[1].gain = v; refresh() }
            if event.tag == 3, o == 0, t.hwout0Mute == event.id { monitors[0].mute = event.value.first == 1; refresh() }
            if event.tag == 3, o == 1, t.hwout1Mute == event.id { monitors[1].mute = event.value.first == 1; refresh() }
            if event.tag == 3, o == 0, t.hwout0Dim == event.id { monitors[0].dim = event.value.first == 1; refresh() }
            if event.tag == 3, o == 1, t.hwout1Dim == event.id { monitors[1].dim = event.value.first == 1; refresh() }
            if event.tag == 3, o == 0, t.hwout0Sum == event.id { monitors[0].sum = event.value.first == 1; refresh() }
            if event.tag == 3, o == 1, t.hwout1Sum == event.id { monitors[1].sum = event.value.first == 1; refresh() }
        }
    }

    // MARK: - Learn mode

    private func missingInputTargets(_ i: Int) -> [(String, UInt8, String)] {
        var out: [(String, UInt8, String)] = []
        for (key, tag, label) in Self.inputTargets(i) where idForKey(key) == nil {
            out.append((key, tag, label))
        }
        return out
    }

    private func missingMonitorTargets(_ o: Int) -> [(String, UInt8, String)] {
        let t = PathIds.active
        var out: [(String, UInt8, String)] = []
        if o == 0 {
            if t.hwout0Gain.isEmpty { out.append(("hwout0Gain", 4, "Level fader")) }
            if t.hwout0Mute.isEmpty { out.append(("hwout0Mute", 3, "Mute")) }
            if t.hwout0Dim.isEmpty { out.append(("hwout0Dim", 3, "Dim")) }
            if t.hwout0Sum == nil { out.append(("hwout0Sum", 3, "Sum / Mono")) }
        } else {
            if t.hwout1Gain.isEmpty { out.append(("hwout1Gain", 4, "Level fader")) }
            if t.hwout1Mute.isEmpty { out.append(("hwout1Mute", 3, "Mute")) }
            if t.hwout1Dim == nil { out.append(("hwout1Dim", 3, "Dim")) }
            if t.hwout1Sum == nil { out.append(("hwout1Sum", 3, "Sum / Mono")) }
        }
        return out
    }

    /// All learnable targets for an input card, in capture order.
    static func inputTargets(_ i: Int) -> [(String, UInt8, String)] {[
        ("hwinRefLevel.\(i)", 1, "Analog Level (Mic/Instrument/+4/−10)"),
        ("hwinMicGain.\(i)", 4, "Gain — mic mode"),
        ("hwinInstGain.\(i)", 4, "Gain — instrument mode"),
        ("hwinPhantom.\(i)", 3, "+48V Phantom"),
        ("hwinSoftLimit.\(i)", 3, "Soft Limit"),
        ("hwinPolarity.\(i)", 3, "Polarity Ø"),
    ]}

    private func idForKey(_ key: String) -> [UInt8]? {
        let t = PathIds.active
        let parts = key.split(separator: ".").map(String.init)
        let idx = parts.count > 1 ? Int(parts[1]) ?? -1 : -1
        switch parts[0] {
        case "hwinRefLevel": return idx >= 0 ? t.hwinRefLevel[idx] : nil
        case "hwinMicGain": return idx >= 0 ? t.hwinMicGain[idx] : nil
        case "hwinInstGain": return idx >= 0 ? t.hwinInstGain[idx] : nil
        case "hwinPhantom": return idx >= 0 ? t.hwinPhantom[idx] : nil
        case "hwinSoftLimit": return idx >= 0 ? t.hwinSoftLimit[idx] : nil
        case "hwinPolarity": return idx >= 0 ? t.hwinPolarity[idx] : nil
        case "hwout0Sum": return t.hwout0Sum
        case "hwout1Sum": return t.hwout1Sum
        case "hwout1Dim": return t.hwout1Dim
        case "hwout0Gain": return t.hwout0Gain
        case "hwout1Gain": return t.hwout1Gain
        case "hwout0Mute": return t.hwout0Mute
        case "hwout1Mute": return t.hwout1Mute
        case "hwout0Dim": return t.hwout0Dim
        default: return nil
        }
    }

    private func startLearn(_ column: LearnColumn) {
        let targets: [(String, UInt8, String)]
        switch column {
        case .input(let i): targets = missingInputTargets(i)
        case .monitor(let o): targets = missingMonitorTargets(o)
        }
        guard !targets.isEmpty else { return }
        learnQueue = targets
        learningColumn = column
        QBLog.log("control: learn session started (\(targets.count) controls)")
        refresh()
    }

    private func learnHandle(_ event: GlueClient.SetPropertyEvent) {
        guard !learnQueue.isEmpty else { return }
        let target = learnQueue[0]
        guard event.tag == target.tag,
              !PathIds.active.knownIds.contains(event.id) else { return }
        switch event.tag {
        case 4:
            guard let v = event.value.readDouble(), v >= -1, v <= 80 else { return }
        case 1:
            guard let v = event.value.readInt32(), (1...4).contains(v) else { return }
        default: break
        }
        PathIds.learn(id: event.id, key: target.key)
        learnQueue.removeFirst()
        if learnQueue.isEmpty {
            QBLog.log("control: learn session complete")
            learningColumn = nil
        }
        refresh()
    }

    private func learnStatus() -> String? {
        guard isLearning, let target = learnQueue.first else { return nil }
        let where_: String
        switch learningColumn {
        case .input(let i): where_ = "Analog In \(i + 1)"
        case .monitor(let o): where_ = o == 0 ? "Main Speakers" : "Headphones"
        case nil: return nil
        }
        return "Learn (\(learnQueue.count) left) — in Apogee Control 2, wiggle “\(target.label)” " +
               "for \(where_), then come back. Click that card’s Learn button again to skip."
    }

    // MARK: - build

    // input cards (index 0…3)
    private var inputHeaders: [NSTextField?] = []
    private var levelPopups: [NSPopUpButton] = []
    private var meters: [GGLevelMeter] = []
    private var gainSectionFields: [NSTextField?] = []
    private var gainSliders: [NeutralSlider] = []
    private var gainFields: [NSTextField] = []
    private var autoGainButtons: [NSButton] = []
    private var toggles48V: [NSButton] = []
    private var softLimitToggles: [NSButton] = []
    private var polarityToggles: [NSButton] = []
    private var inputLearnButtons: [NSButton] = []

    // routing cards (index 0…3)
    private var nameFields: [NSTextField] = []
    private var physLabels: [NSTextField] = []
    private var sourcePopups: [NSPopUpButton] = []
    private var includeChecks: [NSButton] = []
    private var pluginPopups: [NSPopUpButton] = []
    private var enabledChecks: [NSButton] = []
    private var openButtons: [NSButton] = []
    private var addPluginButtons: [NSButton] = []
    private var trimSliders: [NeutralSlider] = []
    private var trimFields: [NSTextField] = []

    // monitor strip (index 0 = Main Speakers, 1 = Headphones)
    private var monSliders: [NeutralSlider] = []
    private var monFields: [NSTextField] = []
    private var muteToggles: [NSButton] = []
    private var dimToggles: [NSButton] = []
    private var monoToggles: [NSButton] = []
    private var monLearnButtons: [NSButton] = []
    private var mutedBadges: [NSTextField?] = []

    private var statusField: NSTextField!
    private var subtitleField: NSTextField!

    private static let nameKey: (Int) -> String = { "insertPair.\($0).name" }
    /// Current custom name for a pair ("" when unset).
    static func savedName(_ i: Int) -> String {
        UserDefaults.standard.string(forKey: nameKey(i)) ?? ""
    }

    // tag namespaces (kept well apart so `tag - base` never collides):
    //   inputs:  100/200/250/300/400/500/1200/600 + i
    //   routing: 2050/2100/2200/2300/2400/2450/2600/2650 + i
    //   monitor: 700/750/800/900/1000/1100 + o
    private let cardWidth: CGFloat = 268

    private func build() {
        // Window: one resizable 1200×820 workspace.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 820))

        // Translucency reserved for the title bar + monitor strip: a warm
        // charcoal tint over the blur carries the Golden Gate tone.
        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        content.addSubview(blur, positioned: .below, relativeTo: nil)
        let tint = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        tint.layer?.backgroundColor = GGTheme.windowTint.cgColor
        content.addSubview(tint, positioned: .above, relativeTo: blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: content.topAnchor),
            blur.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tint.topAnchor.constraint(equalTo: content.topAnchor),
            tint.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // --- assemble: three regions pinned with autolayout. The header
        // MUST be fully constrained horizontally (title…settings chain) or
        // the engine breaks the whole tree — verified by offscreen render.
        let header = makeHeader()
        let monitor = makeMonitorStrip()
        let scroll = makeScrollArea()
        content.addSubview(header)
        content.addSubview(scroll)
        content.addSubview(monitor)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 68),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: monitor.topAnchor),

            monitor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            monitor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            monitor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Audio Control"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentView = content
        w.delegate = self
        w.minSize = NSSize(width: 900, height: 680)
        window = w
        // default size 1,200 × 820 — NSWindow sizes to the contentView's
        // fitting size otherwise, and the intrinsic size is tiny
        w.setContentSize(NSSize(width: 1200, height: 820))
        w.center()
    }

    /// Title bar: title + interface subtitle on the left, toolbar on the
    /// right ("Auto Gain All" + settings). Lightly translucent, with a
    /// subtle divider separating it from the controls.
    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Audio Control")
        title.font = GGTheme.titleFont
        title.textColor = GGTheme.primary
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let subtitle = NSTextField(labelWithString: interfaceName)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = GGTheme.softGray
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(subtitle)
        subtitleField = subtitle

        let settings = NSButton(title: "⚙︎", target: self, action: #selector(settingsClicked(_:)))
        settings.bezelStyle = .texturedRounded
        settings.controlSize = .small
        settings.font = NSFont.systemFont(ofSize: 13)
        settings.toolTip = "Settings…"
        settings.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(settings)

        let all = NSButton(title: "Auto Gain All", target: self,
                           action: #selector(autoGainAllClicked(_:)))
        all.bezelStyle = .rounded
        all.controlSize = .small
        all.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        all.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(all)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(divider)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            settings.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            settings.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            // REQUIRED: close the horizontal chain (title…settings) — an
            // underconstrained header breaks the whole window's layout.
            settings.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            all.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -10),
            all.centerYAnchor.constraint(equalTo: settings.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    /// Scroll view: the inputs + outputs sections scroll together; the
    /// monitor strip stays pinned below.
    private func makeScrollArea() -> NSScrollView {
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        // TIFA=false: the doc's edges are driven by the stack constraints
        // below, NOT by the clip view's autoresizing — leaving the default
        // over-constrains the whole tree and breaks the window's layout.
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        doc.addSubview(stack)

        // INPUTS section header: title left, target/duration right.
        let inputsHeader = sectionHeader(
            title: "Inputs",
            trailingViews: [
                popupLabel("Target", items: AutoGainEngine.targetOptions.map {
                    (String(format: "%.0f dBFS peak", $0), $0) }, action: #selector(targetChanged(_:))),
                popupLabel("Duration", items: AutoGainEngine.listenOptions.map {
                    (String(format: "%.0f s", $0), $0) }, action: #selector(timeChanged(_:))),
            ])
        stack.addArrangedSubview(inputsHeader)

        let inputGrid = makeInputGrid()
        stack.addArrangedSubview(inputGrid)

        // OUTPUTS & ROUTING header: title + supporting label.
        let outHeader = NSStackView()
        outHeader.orientation = .vertical
        outHeader.alignment = .leading
        outHeader.spacing = 2
        let outTitle = NSTextField(labelWithString: "Outputs & Routing")
        outTitle.font = GGTheme.sectionFont
        outTitle.textColor = GGTheme.primary
        let outSupport = NSTextField(labelWithString: "Choose a source, apply processing, and set output trim.")
        outSupport.font = NSFont.systemFont(ofSize: 11)
        outSupport.textColor = GGTheme.softGray
        outHeader.addArrangedSubview(outTitle)
        outHeader.addArrangedSubview(outSupport)
        stack.addArrangedSubview(outHeader)

        let outGrid = makeRoutingGrid()
        stack.addArrangedSubview(outGrid)

        statusField = NSTextField(labelWithString: "")
        statusField.font = NSFont.systemFont(ofSize: 11)
        statusField.textColor = GGTheme.softGray
        statusField.lineBreakMode = .byWordWrapping
        statusField.preferredMaxLayoutWidth = 1000
        stack.addArrangedSubview(statusField)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -8),
            inputsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // full-width header (internal .leading alignment) so the
            // "Outputs & Routing" title sits left, aligned with "Inputs"
            outHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // doc tracks the clip view's width (no h-scroll) and is at least
        // as tall — v-scroll when the window is short.
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
        ])
        doc.scroll(NSPoint(x: 0, y: 0))
        return scroll
    }

    /// A section header row: title on the left, compact controls right.
    private func sectionHeader(title: String, trailingViews: [NSView]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        let t = NSTextField(labelWithString: title)
        t.font = GGTheme.sectionFont
        t.textColor = GGTheme.primary
        row.addArrangedSubview(t)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        for v in trailingViews { row.addArrangedSubview(v) }
        return row
    }

    /// A compact "Label [popup]" control pair for section headers.
    private func popupLabel(_ label: String, items: [(String, Any)],
                            action: Selector) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = GGTheme.labelFont
        l.textColor = GGTheme.softGray
        let p = NSPopUpButton()
        p.target = self
        p.action = action
        p.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        p.controlSize = .small
        for (title, obj) in items {
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = obj
        }
        if let first = items.first, let v = first.1 as? Double {
            for item in p.itemArray where (item.representedObject as? Double) == v { p.select(item); break }
        }
        p.autoenablesItems = true
        let pair = NSStackView(views: [l, p])
        pair.spacing = 6
        pair.alignment = .centerY
        // keep a handle so selection changes route correctly
        if action == #selector(targetChanged(_:)) { targetLevelPopup = p }
        else { timeLevelPopup = p }
        return pair
    }

    private var targetLevelPopup: NSPopUpButton!
    private var timeLevelPopup: NSPopUpButton!

    // MARK: input cards

    private func makeInputGrid() -> NSView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        // One shared 4-column grid for BOTH sections — same card width, same
        // 16-pt gaps, so the output cards line up under the input cards.
        grid.columnSpacing = 16
        grid.rowSpacing = 12

        for i in 0..<4 {
            let card = NSView()
            card.translatesAutoresizingMaskIntoConstraints = false
            GGTheme.applyCardStyle(card)
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 8
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14),
            ])

            // channel title
            let head = NSTextField(labelWithString: "Analog In \(i + 1)")
            head.font = GGTheme.nameFont
            head.textColor = GGTheme.primary
            col.addArrangedSubview(head)
            inputHeaders.append(head)

            // input-type selector
            let p = NSPopUpButton()
            p.addItem(withTitle: "—")
            for (v, label) in [(1, "Mic"), (2, "+4 dBu"), (3, "−10 dBV"), (4, "Instrument")] {
                p.addItem(withTitle: label)
                p.lastItem?.representedObject = v
            }
            p.target = self
            p.action = #selector(levelChanged(_:))
            p.tag = 100 + i
            p.font = NSFont.systemFont(ofSize: 11)
            p.controlSize = .small
            col.addArrangedSubview(p)
            levelPopups.append(p)

            // compact horizontal meter
            let meter = GGLevelMeter()
            col.addArrangedSubview(meter)
            meter.heightAnchor.constraint(equalToConstant: 10).isActive = true
            meter.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            meters.append(meter)

            // gain readout (tabular numerals; click to type a value)
            let gainLbl = NSTextField(labelWithString: "Gain")
            gainLbl.font = GGTheme.labelFont
            gainLbl.textColor = GGTheme.softGray
            gainSectionFields.append(gainLbl)
            col.addArrangedSubview(gainLbl)

            let sl = NeutralSlider()
            sl.minValue = 0
            sl.maxValue = 75
            sl.doubleValue = 0
            sl.target = self
            sl.action = #selector(gainSlid(_:))
            sl.tag = 200 + i
            sl.sendsContinuously = true
            sl.widthAnchor.constraint(equalToConstant: cardWidth - 28).isActive = true
            col.addArrangedSubview(sl)
            gainSliders.append(sl)

            let f = NSTextField()
            f.placeholderString = "—"
            f.alignment = .center
            f.font = GGTheme.valueFont
            f.textColor = GGTheme.primary
            // clean text — no full-width lighter rectangle behind the value;
            // an edit background appears only while editing (focus ring)
            f.isBordered = false
            f.drawsBackground = false
            f.tag = 250 + i
            f.delegate = self
            f.toolTip = "Preamp gain — click to type an exact value"
            f.widthAnchor.constraint(equalToConstant: cardWidth - 28).isActive = true
            col.addArrangedSubview(f)
            gainFields.append(f)

            // quiet secondary Auto Gain button
            let b = NSButton(title: "Auto Gain", target: self,
                             action: #selector(autoGainClicked(_:)))
            b.tag = 1200 + i
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            col.addArrangedSubview(b)
            autoGainButtons.append(b)

            // bottom row: 48V / Soft Limit / Ø — independent toggles.
            // push-on/push-off recessed buttons: the active state is a
            // filled, tinted button (shape + text, not color alone).
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let tv = toggle("48V", 300 + i)
            row.addArrangedSubview(tv)
            toggles48V.append(tv)
            let soft = toggle("Soft Limit", 400 + i)
            row.addArrangedSubview(soft)
            softLimitToggles.append(soft)
            let pol = toggle("Ø", 500 + i)
            pol.toolTip = "Invert Polarity"
            row.addArrangedSubview(pol)
            polarityToggles.append(pol)
            col.addArrangedSubview(row)

            // learn fallback (only when ids are missing)
            let lb = NSButton(title: "Learn…", target: self, action: #selector(learnClicked(_:)))
            lb.tag = 600 + i
            lb.bezelStyle = .recessed
            lb.controlSize = .small
            lb.font = NSFont.systemFont(ofSize: 10)
            col.addArrangedSubview(lb)
            inputLearnButtons.append(lb)

            grid.addColumn(with: [card])
        }
        pinColumns(grid)
        return grid
    }

    // MARK: routing cards

    private func makeRoutingGrid() -> NSView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        // SAME grid geometry as the inputs (16-pt gaps, cardWidth columns)
        // so the two sections share one visual grid.
        grid.columnSpacing = 16
        grid.rowSpacing = 12

        for i in 0..<4 {
            let card = NSView()
            card.translatesAutoresizingMaskIntoConstraints = false
            GGTheme.applyCardStyle(card)
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 8
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14),
            ])

            // editable destination name, styled as a clean heading
            let nf = NSTextField()
            nf.placeholderString = "Unnamed Output"
            nf.font = GGTheme.nameFont
            nf.textColor = GGTheme.primary
            nf.isBordered = false
            nf.drawsBackground = false
            nf.tag = 2050 + i
            nf.delegate = self
            nf.toolTip = "Destination name — click to rename"
            col.addArrangedSubview(nf)
            nameFields.append(nf)

            // physical output label (never hidden by custom naming)
            let phys = NSTextField(labelWithString: InsertServer.pairNames[i])
            phys.font = GGTheme.labelFont
            phys.textColor = GGTheme.softGray
            col.addArrangedSubview(phys)
            physLabels.append(phys)

            // Source
            let srcLbl = NSTextField(labelWithString: "Source")
            srcLbl.font = GGTheme.labelFont
            srcLbl.textColor = GGTheme.softGray
            col.addArrangedSubview(srcLbl)
            let sp = NSPopUpButton()
            sp.target = self
            sp.action = #selector(sourceChanged(_:))
            sp.tag = 2100 + i
            sp.font = NSFont.systemFont(ofSize: 11)
            sp.controlSize = .small
            sp.widthAnchor.constraint(equalToConstant: cardWidth - 28).isActive = true
            col.addArrangedSubview(sp)
            sourcePopups.append(sp)

            // contextual "Include source processing" (mirrored sources only),
            // inside a CONSTANT-HEIGHT row: the checkbox hides for direct
            // sources but the row keeps its height, so Processing and
            // Output Trim stay aligned across all four cards.
            let inc = NSButton(checkboxWithTitle: "Include source processing",
                               target: self, action: #selector(includeChanged(_:)))
            inc.tag = 2200 + i
            inc.font = GGTheme.labelFont
            let incRow = NSView()
            incRow.translatesAutoresizingMaskIntoConstraints = false
            incRow.heightAnchor.constraint(equalToConstant: 22).isActive = true
            incRow.addSubview(inc)
            NSLayoutConstraint.activate([
                inc.leadingAnchor.constraint(equalTo: incRow.leadingAnchor, constant: -3),
                inc.centerYAnchor.constraint(equalTo: incRow.centerYAnchor),
            ])
            col.addArrangedSubview(incRow)
            includeChecks.append(inc)

            // Processing slot: enable switch + plug-in + Open + replace menu
            let plugLbl = NSTextField(labelWithString: "Processing")
            plugLbl.font = GGTheme.labelFont
            plugLbl.textColor = GGTheme.softGray
            col.addArrangedSubview(plugLbl)

            let plugRow = NSStackView()
            plugRow.orientation = .horizontal
            plugRow.spacing = 6
            plugRow.alignment = .centerY
            plugRow.translatesAutoresizingMaskIntoConstraints = false

            let en = NSButton(checkboxWithTitle: "", target: self,
                               action: #selector(enabledChanged(_:)))
            en.tag = 2400 + i
            en.toolTip = "Enable / bypass the plug-in"
            plugRow.addArrangedSubview(en)
            enabledChecks.append(en)

            let pp = NSPopUpButton()
            pp.target = self
            pp.action = #selector(pluginChanged(_:))
            pp.tag = 2300 + i
            pp.font = NSFont.systemFont(ofSize: 11)
            pp.controlSize = .small
            pp.toolTip = "Add / replace / remove the plug-in"
            plugRow.addArrangedSubview(pp)
            pluginPopups.append(pp)

            let open = NSButton(title: "Open", target: self,
                                action: #selector(rowEditorOpened(_:)))
            open.tag = 2450 + i
            open.bezelStyle = .recessed
            open.controlSize = .small
            open.font = NSFont.systemFont(ofSize: 11)
            plugRow.addArrangedSubview(open)
            openButtons.append(open)

            // No plug-in assigned: ONE neutral "Add Plug-in…" control (opens
            // the same picker); enable switch + Open + picker stay hidden —
            // never dead controls. addPluginButtons toggles in refresh().
            let add = NSButton(title: "Add Plug-in…", target: self,
                               action: #selector(addPluginClicked(_:)))
            add.tag = 2500 + i
            add.bezelStyle = .recessed
            add.controlSize = .small
            add.font = NSFont.systemFont(ofSize: 11)
            plugRow.addArrangedSubview(add)
            addPluginButtons.append(add)

            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.wantsLayer = true
            slot.layer?.backgroundColor = NSColor(white: 0, alpha: 0.18).cgColor
            slot.layer?.cornerRadius = 8
            slot.addSubview(plugRow)
            NSLayoutConstraint.activate([
                plugRow.topAnchor.constraint(equalTo: slot.topAnchor, constant: 6),
                plugRow.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: 8),
                plugRow.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: -8),
                plugRow.bottomAnchor.constraint(equalTo: slot.bottomAnchor, constant: -6),
                slot.widthAnchor.constraint(equalToConstant: cardWidth - 28),
                // fixed slot height: identical cards whether a plug-in
                // exists or the slot shows the neutral Add control
                slot.heightAnchor.constraint(equalToConstant: 32),
            ])
            col.addArrangedSubview(slot)

            // Output trim: slider above an editable numeric value,
            // visually secondary to the monitor strip below.
            let trimLbl = NSTextField(labelWithString: "Output Trim")
            trimLbl.font = GGTheme.labelFont
            trimLbl.textColor = GGTheme.softGray
            col.addArrangedSubview(trimLbl)

            let tsl = NeutralSlider()
            tsl.minValue = -64
            tsl.maxValue = 6
            tsl.doubleValue = 0
            tsl.target = self
            tsl.action = #selector(trimSlid(_:))
            tsl.tag = 2600 + i
            tsl.sendsContinuously = true
            tsl.doubleClickResets = true   // double-click the knob → 0 dB
            tsl.widthAnchor.constraint(equalToConstant: cardWidth - 28).isActive = true
            col.addArrangedSubview(tsl)
            trimSliders.append(tsl)

            let tf = NSTextField()
            tf.placeholderString = "+0.0 dB"
            tf.alignment = .center
            tf.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            tf.textColor = GGTheme.softGray
            tf.isBordered = false
            tf.drawsBackground = false
            tf.tag = 2650 + i
            tf.delegate = self
            tf.widthAnchor.constraint(equalToConstant: cardWidth - 28).isActive = true
            col.addArrangedSubview(tf)
            trimFields.append(tf)

            grid.addColumn(with: [card])
        }
        pinColumns(grid)
        return grid
    }

    /// Pin every cell's contentView to the fixed card width — sliders and
    /// text fields have no intrinsic width and collapse to zero otherwise.
    private func pinColumns(_ grid: NSGridView) {
        for c in 0..<grid.numberOfColumns {
            for r in 0..<grid.numberOfRows {
                if let cellView = grid.cell(atColumnIndex: c, rowIndex: r).contentView {
                    cellView.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
                }
            }
        }
    }

    // MARK: monitor strip

    /// The persistent bottom strip: Main Speakers + Headphones, side by
    /// side. Background sits close to the window color — a thin top
    /// divider does the separation, not a contrast panel.
    private func makeMonitorStrip() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = GGTheme.monitorStrip.cgColor

        // thin top divider (subtle border against the routing area)
        let topDivider = NSBox()
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(topDivider)

        let title = NSTextField(labelWithString: "Monitor")
        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = GGTheme.softGray
        title.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(title)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        row.distribution = .fillEqually
        row.addArrangedSubview(makeMonitorGroup(0))
        // subtle vertical divider between the two monitor groups
        let vDivider = NSView()
        vDivider.wantsLayer = true
        vDivider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        vDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        row.addArrangedSubview(vDivider)
        row.addArrangedSubview(makeMonitorGroup(1))
        strip.addSubview(row)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: strip.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            title.topAnchor.constraint(equalTo: strip.topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 20),
            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -20),
            row.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -12),
        ])
        return strip
    }

    private func makeMonitorGroup(_ o: Int) -> NSView {
        let heading: String = o == 0 ? "Main Speakers" : "Headphones"
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6

        let head = NSTextField(labelWithString: heading)
        head.font = GGTheme.nameFont
        head.textColor = GGTheme.primary
        let badge = NSTextField(labelWithString: "Muted")
        badge.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = GGTheme.warning
        badge.isHidden = true
        mutedBadges.append(badge)
        let headRow = NSStackView(views: [head, badge])
        headRow.spacing = 8
        headRow.alignment = .centerY
        group.addArrangedSubview(headRow)

        let sub = NSTextField(labelWithString: "Monitor Level")
        sub.font = GGTheme.labelFont
        sub.textColor = GGTheme.softGray
        group.addArrangedSubview(sub)

        // wide volume slider + numeric readout
        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 10
        sliderRow.alignment = .centerY
        let sl = NeutralSlider()
        sl.minValue = -64
        sl.maxValue = 0
        sl.doubleValue = 0
        sl.target = self
        sl.action = #selector(monSlid(_:))
        sl.tag = 700 + o
        sl.sendsContinuously = true
        sl.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        sliderRow.addArrangedSubview(sl)
        monSliders.append(sl)

        let f = NSTextField()
        f.placeholderString = "—"
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        f.textColor = GGTheme.primary
        f.isBordered = false
        f.drawsBackground = false
        f.alignment = .center
        f.tag = 750 + o
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        f.toolTip = "Monitor level — click to type an exact value"
        sliderRow.addArrangedSubview(f)
        monFields.append(f)
        group.addArrangedSubview(sliderRow)

        // Mute / Dim / Mono — filled (tinted) when active.
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 6
        let mute = toggle("Mute", 800 + o)
        btnRow.addArrangedSubview(mute)
        muteToggles.append(mute)
        let dim = toggle("Dim", 900 + o)
        btnRow.addArrangedSubview(dim)
        dimToggles.append(dim)
        let mono = toggle("Mono", 1000 + o)
        btnRow.addArrangedSubview(mono)
        monoToggles.append(mono)

        let learn = NSButton(title: "Learn…", target: self, action: #selector(learnClicked(_:)))
        learn.tag = 1100 + o
        learn.bezelStyle = .recessed
        learn.controlSize = .small
        learn.font = NSFont.systemFont(ofSize: 10)
        learn.isHidden = true
        btnRow.addArrangedSubview(learn)
        monLearnButtons.append(learn)
        group.addArrangedSubview(btnRow)

        return group
    }

    // MARK: - actions (all clamped — bad ranges crash the unit)

    @objc private func settingsClicked(_ sender: NSButton) {
        onOpenSettings?()
    }

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 100
        guard !suppressActions, !isLearning, !AutoGainEngine.shared.isRunning,
              let v = sender.selectedItem?.representedObject as? Int,
              let id = PathIds.active.hwinRefLevel[i] else { return refresh() }
        guard (1...4).contains(v) else { return refresh() }
        inputs[i].refLevel = v
        onWriteInt?(id, Int32(v))
        refresh()
    }

    /// Preamp gain: writes the ACTIVE mode's gain only — mic and instrument
    /// keep their own values, so switching modes doesn't carry the gain over.
    @objc private func gainSlid(_ sender: NSControl) {
        let i = sender.tag - 200
        guard !suppressActions, !isLearning, !AutoGainEngine.shared.isRunning else { return }
        if let rl = inputs[i].refLevel, rl == 2 || rl == 3 { return }
        let v = min(max(sender.doubleValue, 0), 75)
        let t = PathIds.active
        if inputs[i].refLevel == 4, let id = t.hwinInstGain[i] {
            onWriteDouble?(id, v)
            inputs[i].instGain = v
        } else if let id = t.hwinMicGain[i] {
            onWriteDouble?(id, v)
            inputs[i].micGain = v
        }
        updateGainField(i)
    }

    /// The gain readout shows the ACTIVE mode's gain only — "32.0 dB",
    /// never a "M x · I y" pair.
    private func updateGainField(_ i: Int) {
        let st = inputs[i]
        var text = "—"
        if st.refLevel == 4 {
            if let inst = st.instGain { text = String(format: "%.1f dB", inst) }
        } else if let m = st.micGain {
            text = String(format: "%.1f dB", m)
        }
        if gainFields[i].stringValue != text { gainFields[i].stringValue = text }
    }

    // Auto Gain

    @objc private func autoGainClicked(_ sender: NSButton) {
        let i = sender.tag - 1200
        if AutoGainEngine.shared.isRunning {
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
            return
        }
        startAutoGain(for: [i])
    }

    @objc private func autoGainAllClicked(_ sender: NSButton) {
        if AutoGainEngine.shared.isRunning {
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
            return
        }
        let calibratable = (0..<4).filter { i in
            if let rl = inputs[i].refLevel { return rl == 1 || rl == 4 }
            return false
        }
        guard !calibratable.isEmpty else {
            showAutoStatus("Auto Gain All — no inputs in Mic/Instrument mode", clearAfter: 8)
            return
        }
        startAutoGain(for: calibratable)
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? Double else { return }
        AutoGainEngine.targetDBFS = v
    }

    @objc private func timeChanged(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? Double else { return }
        AutoGainEngine.listenSeconds = v
    }

    private func startAutoGain(for indices: [Int]) {
        guard (isGlueConnected?() ?? false) else { return }
        var params: [AutoGainEngine.StartParams] = []
        for i in indices {
            guard let rl = inputs[i].refLevel, rl == 1 || rl == 4 else { continue }
            let t = PathIds.active
            let gainId = rl == 4 ? t.hwinInstGain[i] : t.hwinMicGain[i]
            let current = rl == 4 ? inputs[i].instGain : inputs[i].micGain
            guard let gainId, let current else { continue }
            params.append(AutoGainEngine.StartParams(
                input: i,
                activeGainId: gainId,
                refLevelId: t.hwinRefLevel[i],
                currentGain: current))
        }
        guard !params.isEmpty else {
            showAutoStatus("Auto Gain — no Mic/Instrument inputs ready", clearAfter: 8)
            return
        }
        AutoGainEngine.shared.start(params)
    }

    /// Engine → hardware + window state: write an input's ACTIVE mode
    /// preamp gain (the engine clamps and floors; same plumbing as the slider).
    func applyAutoGain(_ i: Int, _ v: Double) {
        let t = PathIds.active
        let clamped = min(max(v, AutoGainEngine.minGainDB), AutoGainEngine.maxGainDB)
        if inputs[i].refLevel == 4, let id = t.hwinInstGain[i] {
            onWriteDouble?(id, clamped)
            inputs[i].instGain = clamped
        } else if let id = t.hwinMicGain[i] {
            onWriteDouble?(id, clamped)
            inputs[i].micGain = clamped
        }
        refresh()
    }

    /// Show an Auto Gain line in the status area.
    func showAutoStatus(_ line: String, clearAfter seconds: TimeInterval?) {
        autoGainStatus = line
        autoGainStatusTimer?.invalidate()
        if let seconds {
            autoGainStatusTimer = Timer.scheduledTimer(withTimeInterval: seconds,
                                                       repeats: false) { [weak self] _ in
                self?.autoGainStatus = nil
                self?.autoGainStatusTimer = nil
                self?.refresh()
            }
        }
        refresh()
    }

    /// +48V / Soft Limit / Polarity (per input).
    @objc private func inputToggleChanged(_ sender: NSButton) {
        let tag = sender.tag
        let on = sender.state == .on
        let i = tag % 100
        let t = PathIds.active
        let id: [UInt8]?
        switch tag - i {
        case 300: id = t.hwinPhantom[i]; inputs[i].phantom = on
        case 400: id = t.hwinSoftLimit[i]; inputs[i].softLimit = on
        case 500: id = t.hwinPolarity[i]; inputs[i].polarity = on
        default: id = nil
        }
        guard !suppressActions, !isLearning, let id else { return refresh() }
        onWriteBool?(id, on)
    }

    // Routing actions (InsertServer)

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 2100
        guard !suppressActions, let raw = sender.selectedItem?.representedObject as? String,
              let src = InsertServer.PairSource(rawValue: raw) else { return refresh() }
        InsertServer.shared.setSource(i, src)
        refresh()
    }

    /// "Include source processing" — on = mirror AFTER the source's plug-in
    /// (destination inherits its processing); off = before (raw channels).
    @objc private func includeChanged(_ sender: NSButton) {
        let i = sender.tag - 2200
        guard !suppressActions else { return refresh() }
        InsertServer.shared.setMirrorPre(i, sender.state == .off)
        refresh()
    }

    @objc private func pluginChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 2300
        guard !suppressActions, let key = sender.selectedItem?.representedObject as? String else { return refresh() }
        let desc = key.isEmpty ? nil
            : InsertServer.listPlugins().first { InsertServer.descKey($0.desc) == key }?.desc
        InsertServer.shared.setPlugin(i, desc)
        refresh()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        let i = sender.tag - 2400
        guard !suppressActions else { return refresh() }
        InsertServer.shared.setEnabled(i, sender.state == .on)
        refresh()
    }

    @objc private func rowEditorOpened(_ sender: NSButton) {
        InsertServer.shared.showPluginUI(sender.tag - 2450)
    }

    /// "Add Plug-in…" — opens the same picker (popup's menu) at the slot.
    @objc private func addPluginClicked(_ sender: NSButton) {
        let i = sender.tag - 2500
        pluginPopups[i].performClick(nil)
    }

    /// Output-trim slider (tag = 2600 + pair). Soft-snaps to unity.
    @objc private func trimSlid(_ sender: NSControl) {
        let i = sender.tag - 2600
        var v = sender.doubleValue
        if abs(v) < 0.5 { v = 0 }
        InsertServer.shared.setTrim(i, v, notify: false)
        suppressActions = true
        let text = String(format: "%+.1f dB", min(6.0, max(-64.0, v)))
        trimFields[i].stringValue = text
        trimFields[i].textColor = v > 0.01 ? GGTheme.warning : GGTheme.softGray
        suppressActions = false
    }

    // Monitor actions

    @objc private func monSlid(_ sender: NSControl) {
        let o = sender.tag - 700
        guard !suppressActions, !isLearning else { return }
        let v = min(max(sender.doubleValue, AppDelegate.minDB), AppDelegate.maxDB)
        guard AppDelegate.isValidDB(v) else { return }
        let id = o == 0 ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain
        guard !id.isEmpty else { return }
        monitors[o].gain = v
        onWriteDouble?(id, v)
        monFields[o].stringValue = String(format: "%.1f dB", v)
    }

    /// Mute / Dim / Mono for Main Speakers + Headphones.
    @objc private func monToggleChanged(_ sender: NSButton) {
        let tag = sender.tag
        let on = sender.state == .on
        let o = tag % 100
        let t = PathIds.active
        let id: [UInt8]?
        switch tag - o {
        case 800: id = o == 0 ? t.hwout0Mute : t.hwout1Mute; monitors[o].mute = on
        case 900: id = o == 0 ? t.hwout0Dim : t.hwout1Dim; monitors[o].dim = on
        case 1000: id = o == 0 ? t.hwout0Sum : t.hwout1Sum; monitors[o].sum = on
        default: id = nil
        }
        guard !suppressActions, !isLearning, let id, !id.isEmpty else { return refresh() }
        onWriteBool?(id, on)
    }

    /// Learn buttons: start a capture session for the card — or skip the
    /// current target while one runs.
    @objc private func learnClicked(_ sender: NSButton) {
        let tag = sender.tag
        if isLearning {
            if !learnQueue.isEmpty {
                let skipped = learnQueue.removeFirst()
                QBLog.log("control: learn skipped \(skipped.key)")
            }
            if learnQueue.isEmpty { learningColumn = nil }
            refresh()
            return
        }
        switch tag {
        case 600...603: startLearn(.input(tag - 600))
        case 1100...1101: startLearn(.monitor(tag - 1100))
        default: break
        }
    }

    // MARK: - field editing (return key)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, !suppressActions, !isLearning else { return }
        switch field.tag {
        case 250..<254:
            // input gain (dB) — active mode's gain only
            let i = field.tag - 250
            guard let db = parseDB(field.stringValue) else { return refresh() }
            let v = min(max(db, 0), 75)
            let t = PathIds.active
            if inputs[i].refLevel == 4, let id = t.hwinInstGain[i] {
                onWriteDouble?(id, v)
                inputs[i].instGain = v
            } else if let id = t.hwinMicGain[i] {
                onWriteDouble?(id, v)
                inputs[i].micGain = v
            } else {
                return refresh()
            }
            refresh()
        case 750..<752:
            // monitor level (dB)
            let o = field.tag - 750
            guard let db = parseDB(field.stringValue), AppDelegate.isValidDB(db) else { return refresh() }
            let id = o == 0 ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain
            guard !id.isEmpty else { return refresh() }
            let v = min(max(db, AppDelegate.minDB), AppDelegate.maxDB)
            onWriteDouble?(id, v)
            monitors[o].gain = v
            refresh()
        case 2050..<2054:
            // custom destination name
            let i = field.tag - 2050
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.nameKey(i))
            } else {
                UserDefaults.standard.set(name, forKey: Self.nameKey(i))
            }
            QBLog.log("control: output \(i) named '\(name)'")
            refresh()
        case 2650..<2654:
            // output trim (dB)
            let i = field.tag - 2650
            if let db = parseDB(field.stringValue) {
                InsertServer.shared.setTrim(i, db)
            }
            refresh()
        default:
            break
        }
    }

    // MARK: - polling

    private func startPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true,
                  self.isGlueConnected?() == true else { return }
            self.onRequestTree?()
        }
    }

    // MARK: - helpers

    /// A small push-on/push-off button. OFF: neutral gray, no accent. ON: a
    /// restrained colored tint (bezelColor at low alpha) + an explicit ✓ in
    /// the title, so state never rides on color alone. Disabled: muted text,
    /// no accent. The tint color is per-function (amber/blue/red) and is
    /// applied by `setToggle` from the LIVE state — never baked at creation.
    private func toggle(_ title: String, _ tag: Int) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        // route by tag range: inputs → inputToggleChanged, monitor → monToggleChanged
        if tag >= 700 { b.action = #selector(monToggleChanged(_:)) }
        else { b.action = #selector(inputToggleChanged(_:)) }
        b.target = self
        b.tag = tag
        b.bezelStyle = .rounded
        b.setButtonType(.pushOnPushOff)
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 11)
        return b
    }

    /// Apply the full OFF/ON/DISABLED treatment to a toggle button.
    /// OFF: neutral gray bezel, secondary label. ON: restrained tinted
    /// bezel + ✓ + primary label. DISABLED: muted label, no accent.
    private func setToggle(_ b: NSButton, _ value: Bool?, enabled: Bool,
                           activeColor: NSColor? = nil) {
        b.isEnabled = enabled
        let base = (b.attributedTitle.string as NSString)
            .replacingOccurrences(of: "✓ ", with: "")
        let on = (value ?? false) && enabled
        let font = NSFont.systemFont(ofSize: 11)
        if on {
            b.bezelColor = (activeColor ?? GGTheme.stateBlue).withAlphaComponent(0.32)
            b.attributedTitle = NSAttributedString(string: "✓ " + base, attributes: [
                .font: font, .foregroundColor: GGTheme.primary])
        } else {
            b.bezelColor = nil
            b.attributedTitle = NSAttributedString(string: base, attributes: [
                .font: font,
                .foregroundColor: enabled ? GGTheme.softGray : NSColor.disabledControlTextColor])
        }
    }

    private func selectPopup(_ p: NSPopUpButton, value: Int) {
        for item in p.itemArray where (item.representedObject as? Int) == value {
            p.select(item)
            return
        }
    }

    private func findTyped(_ node: [String: Any], _ type: String) -> [String: Any]? {
        GlueClient.findNode(in: node, type: type)
    }

    private func parseDB(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "dB", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") { t.removeFirst() }
        return Double(t.split(separator: " ").first ?? "")
    }

    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        learnQueue = []
        learningColumn = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if AutoGainEngine.shared.isRunning {
            AutoGainEngine.shared.cancelAll(reason: "control window closed")
        }
    }
}

private extension Data {
    func readDouble() -> Double? {
        guard count >= 8 else { return nil }
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(self[startIndex + i])
        }
        return Double(bitPattern: v)
    }
    func readInt32() -> Int32? {
        guard count >= 4 else { return nil }
        var v: UInt32 = 0
        for i in stride(from: 3, through: 0, by: -1) {
            v = (v << 8) | UInt32(self[startIndex + i])
        }
        return Int32(bitPattern: v)
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