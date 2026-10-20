import AppKit

/// The "Quartet Console" window: every input- and monitor-side hardware
/// function in one place, off the menubar so the core features stay clean.
///
/// Per analog input (IN 1-4): analog level, preamp gain (mic + instrument
/// are written together so the fader is right whichever mode the channel is
/// in), +48V phantom, soft limit, polarity. Per monitor (Main Out /
/// Headphones): level, mute, dim, sum/mono.
///
/// Reads come from the glue tree (live via a 2 s poll while visible — the
/// tree is the only source that works even for controls whose write id is
/// not captured yet). Writes go through setProperty path-ids; a control
/// whose id is missing on this unit is disabled and gets a one-click Learn
/// mode instead: click Learn…, wiggle the matching control in Apogee
/// Control 2, and the id is captured and saved (same mechanism as the
/// Setup wizard).
///
/// The window is a floating, non-activating panel: it stays above Apogee
/// Control 2 without stealing focus, so captures can be done side by side.
///
/// GAIN SAFETY: out-of-range writes crashed a unit once (see
/// docs/protocol-notes.md) — every write from this window is clamped:
/// monitor gain to -64…0 dB, preamp gain to 0…75 dB, ref level to 1…4.
final class ConsoleWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    static let shared = ConsoleWindowController()

    // MARK: - plumbing (set by AppDelegate, SettingsWindow pattern)

    var onWriteDouble: (([UInt8], Double) -> Void)?
    var onWriteBool: (([UInt8], Bool) -> Void)?
    var onWriteInt: (([UInt8], Int32) -> Void)?
    var onRequestTree: (() -> Void)?
    var isGlueConnected: (() -> Bool)?
    /// The last tree the app received (seed so the window opens with real
    /// values instead of blanks while the first poll comes in).
    var onSeedTree: (() -> [String: Any]?)?

    // MARK: - state

    struct InputState {
        var name: String?
        var refLevel: Int?
        var micGain: Double?
        var instGain: Double?
        var phantom: Bool?
        var softLimit: Bool?
        var polarity: Bool?
    }
    struct OutputState {
        var gain: Double?
        var mute: Bool?
        var dim: Bool?
        var sum: Bool?
    }
    private var inputs: [InputState] = (0..<4).map { _ in InputState() }
    private var outputs: [OutputState] = [.init(), .init()]

    private var window: NSWindow?
    private var suppressActions = false
    private var pollTimer: Timer?

    // Learn mode
    private var learnQueue: [(key: String, tag: UInt8, label: String)] = []
    private var learningColumn: LearnColumn?
    /// True while a Learn capture session runs (AppDelegate gates its own
    /// hardware writes on this so echoes can't pollute the capture).
    var isLearning: Bool { !learnQueue.isEmpty }

    enum LearnColumn: Equatable { case input(Int), output(Int) }

    // MARK: - show / refresh cycle

    func show() {
        if window == nil { build() }
        // open with real values: seed from the last tree, then pull a
        // fresh one immediately (don't wait out the first poll tick)
        if let tree = onSeedTree?() { updateTree(tree) } else { refresh() }
        // stay above Apogee Control 2 WITHOUT activating us (that would
        // pull focus from the app the user is wiggling controls in)
        window?.orderFrontRegardless()
        startPoll()
        onRequestTree?()
    }

    func refresh() {
        guard window != nil else { return }
        suppressActions = true
        defer { suppressActions = false }
        let connected = isGlueConnected?() ?? false
        let learning = isLearning

        // INPUTS
        for i in 0..<4 {
            let st = inputs[i]
            let t = PathIds.active
            let levelId = t.hwinRefLevel[i]
            levelPopups[i].isEnabled = connected && !learning && levelId != nil
            if let rl = st.refLevel {
                selectPopup(levelPopups[i], value: rl)
            } else {
                levelPopups[i].selectItem(withTitle: "—")
            }

            let micId = t.hwinMicGain[i], instId = t.hwinInstGain[i]
            let bothIds = micId != nil && instId != nil
            gainSliders[i].isEnabled = connected && !learning && bothIds
            let shown = st.micGain ?? st.instGain ?? 0
            if gainSliders[i].doubleValue != shown { gainSliders[i].doubleValue = shown }
            updateGainField(i)

            setCheck(phantomChecks[i], st.phantom, enabled: connected && !learning && t.hwinPhantom[i] != nil)
            setCheck(softLimitChecks[i], st.softLimit, enabled: connected && !learning && t.hwinSoftLimit[i] != nil)
            setCheck(polarityChecks[i], st.polarity, enabled: connected && !learning && t.hwinPolarity[i] != nil)

            inputHeaders[i]?.stringValue = st.name ?? "Analog IN \(i + 1)"
            let missing = missingInputTargets(i)
            inputLearnButtons[i].isEnabled = !learning ? !missing.isEmpty
                : learningColumn == .input(i)
            inputLearnButtons[i].title = (learning && learningColumn == .input(i)) ? "Skip ▸" : "Learn…"
        }

        // OUTPUTS
        for o in 0..<2 {
            let st = outputs[o]
            let t = PathIds.active
            let gainId = o == 0 ? t.hwout0Gain : t.hwout1Gain
            let muteId = o == 0 ? t.hwout0Mute : t.hwout1Mute
            let dimId = o == 0 ? t.hwout0Dim : t.hwout1Dim
            let sumId = o == 0 ? t.hwout0Sum : t.hwout1Sum

            outGainSliders[o].isEnabled = connected && !learning && !gainId.isEmpty
            let g = min(max(st.gain ?? 0, AppDelegate.minDB), AppDelegate.maxDB)
            if outGainSliders[o].doubleValue != g { outGainSliders[o].doubleValue = g }
            if let gain = st.gain, AppDelegate.isValidDB(gain) {
                let text = String(format: "%.1f dB", gain)
                if outGainFields[o].stringValue != text { outGainFields[o].stringValue = text }
            }

            setCheck(outMuteChecks[o], st.mute, enabled: connected && !learning && !muteId.isEmpty)
            setCheck(outDimChecks[o], st.dim, enabled: connected && !learning && dimId != nil)
            setCheck(outSumChecks[o], st.sum, enabled: connected && !learning && sumId != nil)

            let missing = missingOutputTargets(o)
            outLearnButtons[o].isEnabled = !learning ? !missing.isEmpty
                : learningColumn == .output(o)
            outLearnButtons[o].title = (learning && learningColumn == .output(o)) ? "Skip ▸" : "Learn…"
        }

        statusField.stringValue = learnStatus()
            ?? (connected ? "" : "Not connected — waiting for Apogee Control 2 / ApogeeGlue…")
        refit()
    }

    /// Full-state sync from the glue tree (AppDelegate.onTree → here).
    func updateTree(_ tree: [String: Any]) {
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
            var st = OutputState()
            if let node = findTyped(tree, "hwout\(o)") {
                st.gain = GlueClient.doubleProp(node, "gain")
                st.mute = (GlueClient.intProp(node, "mute") ?? 0) == 1
                st.dim = (GlueClient.intProp(node, "dim") ?? 0) == 1
                st.sum = (GlueClient.intProp(node, "sum") ?? 0) == 1
            }
            outputs[o] = st
        }
        refresh()
    }

    /// Live setProperty events (AppDelegate.onSetProperty → here): update
    /// whichever console control the id belongs to. While Learn mode is
    /// running, the event stream instead feeds the capture.
    func handle(_ event: GlueClient.SetPropertyEvent) {
        if isLearning { learnHandle(event); return }
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
            let t = PathIds.active
            if event.tag == 4, o == 0, t.hwout0Gain == event.id,
               let v = event.value.readDouble() { outputs[0].gain = v; refresh() }
            if event.tag == 4, o == 1, t.hwout1Gain == event.id,
               let v = event.value.readDouble() { outputs[1].gain = v; refresh() }
            if event.tag == 3, o == 0, t.hwout0Mute == event.id { outputs[0].mute = event.value.first == 1; refresh() }
            if event.tag == 3, o == 1, t.hwout1Mute == event.id { outputs[1].mute = event.value.first == 1; refresh() }
            if event.tag == 3, o == 0, t.hwout0Dim == event.id { outputs[0].dim = event.value.first == 1; refresh() }
            if event.tag == 3, o == 1, t.hwout1Dim == event.id { outputs[1].dim = event.value.first == 1; refresh() }
            if event.tag == 3, o == 0, t.hwout0Sum == event.id { outputs[0].sum = event.value.first == 1; refresh() }
            if event.tag == 3, o == 1, t.hwout1Sum == event.id { outputs[1].sum = event.value.first == 1; refresh() }
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

    private func missingOutputTargets(_ o: Int) -> [(String, UInt8, String)] {
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

    /// All learnable targets for an input column, in capture order.
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
        case .output(let o): targets = missingOutputTargets(o)
        }
        guard !targets.isEmpty else { return }
        learnQueue = targets
        learningColumn = column
        QBLog.log("console: learn session started (\(targets.count) controls)")
        refresh()
    }

    private func learnHandle(_ event: GlueClient.SetPropertyEvent) {
        guard !learnQueue.isEmpty else { return }
        let target = learnQueue[0]
        // tag must match, and the id must not already be assigned to any
        // control (wiggle of a different, known control can't pollute)
        guard event.tag == target.tag,
              !PathIds.active.knownIds.contains(event.id) else { return }
        // plausibility: gain must be a preamp value, ref level 1…4 —
        // cheap guard against capturing a stray event
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
            QBLog.log("console: learn session complete")
            learningColumn = nil
        }
        refresh()
    }

    private func learnStatus() -> String? {
        guard isLearning, let target = learnQueue.first else { return nil }
        let where_: String
        switch learningColumn {
        case .input(let i): where_ = "Analog IN \(i + 1)"
        case .output(let o): where_ = o == 0 ? "Main Out" : "Headphones"
        case nil: return nil
        }
        return "Learn (\(learnQueue.count) left) — in Apogee Control 2, wiggle “\(target.label)” " +
               "for \(where_), then come back. Click the column’s Skip ▸ button to skip."
    }

    // MARK: - build

    // input controls (index 0…3)
    private var inputHeaders: [NSTextField?] = []
    private var levelPopups: [NSPopUpButton] = []
    private var gainSliders: [NSSlider] = []
    private var gainFields: [NSTextField] = []
    private var phantomChecks: [NSButton] = []
    private var softLimitChecks: [NSButton] = []
    private var polarityChecks: [NSButton] = []
    private var inputLearnButtons: [NSButton] = []

    // output controls (index 0 = Main Out, 1 = Headphones)
    private var outGainSliders: [NSSlider] = []
    private var outGainFields: [NSTextField] = []
    private var outMuteChecks: [NSButton] = []
    private var outDimChecks: [NSButton] = []
    private var outSumChecks: [NSButton] = []
    private var outLearnButtons: [NSButton] = []

    private var inputGrid: NSGridView!
    private var outputGrid: NSGridView!
    private var statusField: NSTextField!

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))

        // dark, translucent — same surface as Outputs & Plug-ins
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

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        // --- INPUTS grid: one column per analog input ---
        inputGrid = NSGridView()
        let ig = inputGrid!
        ig.translatesAutoresizingMaskIntoConstraints = false
        ig.columnSpacing = 18
        ig.rowSpacing = 7

        ig.addRow(with: (0..<4).map { headerField("Analog IN \($0 + 1)") })
        inputHeaders = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 0).contentView as? NSTextField }

        ig.addRow(with: (0..<4).map { _ in sectionField("ANALOG LEVEL") })
        ig.addRow(with: (0..<4).map { i in
            let p = NSPopUpButton()
            p.addItem(withTitle: "—")
            for v in 1...4 { p.addItem(withTitle: "Level \(v)"); p.lastItem?.representedObject = v }
            p.target = self
            p.action = #selector(levelChanged(_:))
            p.tag = 100 + i
            p.font = .systemFont(ofSize: 11)
            levelPopups.append(p)
            return p
        })

        ig.addRow(with: (0..<4).map { _ in sectionField("GAIN") })
        ig.addRow(with: (0..<4).map { i in
            let sl = NSSlider(value: 0, minValue: 0, maxValue: 75, target: self,
                              action: #selector(gainSlid(_:)))
            sl.tag = 200 + i
            sl.isContinuous = true
            gainSliders.append(sl)
            return sl
        })
        ig.addRow(with: (0..<4).map { i in
            let f = NSTextField()
            f.placeholderString = "—"
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.tag = 250 + i
            f.delegate = self
            gainFields.append(f)
            return f
        })

        ig.addRow(with: (0..<4).map { i in check("+48V", 300 + i, #selector(boolChanged(_:))) })
        phantomChecks = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 6).contentView as! NSButton }
        ig.addRow(with: (0..<4).map { i in check("Soft Limit", 400 + i, #selector(boolChanged(_:))) })
        softLimitChecks = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 7).contentView as! NSButton }
        ig.addRow(with: (0..<4).map { i in check("Polarity Ø", 500 + i, #selector(boolChanged(_:))) })
        polarityChecks = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 8).contentView as! NSButton }

        ig.addRow(with: (0..<4).map { i in learnButton(600 + i) })
        inputLearnButtons = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 9).contentView as! NSButton }

        // --- OUTPUTS grid: Main Out + Headphones ---
        outputGrid = NSGridView()
        let og = outputGrid!
        og.translatesAutoresizingMaskIntoConstraints = false
        og.columnSpacing = 18
        og.rowSpacing = 7

        og.addRow(with: [headerField("Main Out"), headerField("Headphones")])
        og.addRow(with: (0..<2).map { _ in sectionField("LEVEL") })
        og.addRow(with: (0..<2).map { o in
            let sl = NSSlider(value: 0, minValue: -64, maxValue: 0, target: self,
                              action: #selector(outGainSlid(_:)))
            sl.tag = 700 + o
            sl.isContinuous = true
            outGainSliders.append(sl)
            return sl
        })
        og.addRow(with: (0..<2).map { o in
            let f = NSTextField()
            f.placeholderString = "—"
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.tag = 750 + o
            f.delegate = self
            outGainFields.append(f)
            return f
        })
        og.addRow(with: (0..<2).map { o in check("Mute", 800 + o, #selector(outBoolChanged(_:))) })
        outMuteChecks = (0..<2).map { og.cell(atColumnIndex: $0, rowIndex: 4).contentView as! NSButton }
        og.addRow(with: (0..<2).map { o in check("Dim", 900 + o, #selector(outBoolChanged(_:))) })
        outDimChecks = (0..<2).map { og.cell(atColumnIndex: $0, rowIndex: 5).contentView as! NSButton }
        og.addRow(with: (0..<2).map { o in check("Sum / Mono", 1000 + o, #selector(outBoolChanged(_:))) })
        outSumChecks = (0..<2).map { og.cell(atColumnIndex: $0, rowIndex: 6).contentView as! NSButton }
        og.addRow(with: (0..<2).map { o in learnButton(1100 + o) })
        outLearnButtons = (0..<2).map { og.cell(atColumnIndex: $0, rowIndex: 7).contentView as! NSButton }

        // --- assemble ---
        let inTitle = NSTextField(labelWithString: "INPUTS")
        inTitle.font = .systemFont(ofSize: 10, weight: .bold)
        inTitle.textColor = .tertiaryLabelColor
        let outTitle = NSTextField(labelWithString: "MONITORING")
        outTitle.font = .systemFont(ofSize: 10, weight: .bold)
        outTitle.textColor = .tertiaryLabelColor

        stack.addArrangedSubview(inTitle)
        stack.addArrangedSubview(ig)
        stack.addArrangedSubview(outTitle)
        stack.addArrangedSubview(og)

        statusField = NSTextField(labelWithString: "")
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byWordWrapping
        statusField.preferredMaxLayoutWidth = 700
        stack.addArrangedSubview(statusField)

        // uniform column widths
        for grid in [ig, og] {
            for c in 0..<grid.numberOfColumns {
                for r in 0..<grid.numberOfRows {
                    if let v = grid.cell(atColumnIndex: c, rowIndex: r).contentView {
                        v.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
                    }
                }
            }
        }
        for i in 0..<4 { ig.column(at: i).width = 150 }
        for i in 0..<2 { og.column(at: i).width = 150 }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        let p = NSPanel(contentRect: content.bounds,
                       styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                       backing: .buffered, defer: false)
        p.title = "Quartet Console"
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true            // stays above Apogee Control 2
        p.collectionBehavior = [.fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.contentView = content
        p.delegate = self
        window = p
        refit()
    }

    private func refit() {
        guard let w = window, inputGrid != nil else { return }
        w.contentView?.layoutSubtreeIfNeeded()
        let fit = stackFittingSize()
        let size = NSSize(width: max(fit.width + 44, 420), height: fit.height + 62)
        // compare against the ACTUAL current content size (see the operator-
        // precedence note in OutputsWindow.refit — the naive form always
        // re-centers the window on every refresh)
        let cur = w.contentView?.frame.size ?? .zero
        if abs(cur.width - size.width) > 1 || abs(cur.height - size.height) > 1 {
            w.setContentSize(size)
            w.center()
        }
    }

    private func stackFittingSize() -> NSSize {
        // content bounds already track the stack; just use fitting sizes
        let inFit = inputGrid.fittingSize, outFit = outputGrid.fittingSize
        let status = statusField?.intrinsicContentSize.width ?? 0
        let width = max(max(inFit.width, outFit.width), min(status, 700)) + 36
        let height = inFit.height + outFit.height + (statusField?.intrinsicContentSize.height ?? 0) + 90
        return NSSize(width: width, height: height)
    }

    // MARK: - actions (all clamped — bad ranges crash the unit)

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 100
        guard !suppressActions, !isLearning, let v = sender.selectedItem?.representedObject as? Int,
              let id = PathIds.active.hwinRefLevel[i] else { return refresh() }
        guard (1...4).contains(v) else { return refresh() }
        inputs[i].refLevel = v
        onWriteInt?(id, Int32(v))
    }

    /// Preamp gain: writes BOTH mic and instrument values so the slider is
    /// correct whichever mode the channel is in.
    @objc private func gainSlid(_ sender: NSSlider) {
        let i = sender.tag - 200
        guard !suppressActions, !isLearning else { return }
        let v = min(max(sender.doubleValue, 0), 75)
        let t = PathIds.active
        if let id = t.hwinMicGain[i] { onWriteDouble?(id, v); inputs[i].micGain = v }
        if let id = t.hwinInstGain[i] { onWriteDouble?(id, v); inputs[i].instGain = v }
        updateGainField(i)
    }

    private func updateGainField(_ i: Int) {
        let st = inputs[i]
        var text = "—"
        if let m = st.micGain, let inst = st.instGain {
            text = abs(m - inst) < 0.05 ? String(format: "%.1f dB", m)
                : String(format: "M %.1f · I %.1f", m, inst)
        } else if let m = st.micGain { text = String(format: "%.1f dB", m) }
        else if let inst = st.instGain { text = String(format: "%.1f dB", inst) }
        if gainFields[i].stringValue != text { gainFields[i].stringValue = text }
    }

    /// +48V / Soft Limit / Polarity (per input).
    @objc private func boolChanged(_ sender: NSButton) {
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

    @objc private func outGainSlid(_ sender: NSSlider) {
        let o = sender.tag - 700
        guard !suppressActions, !isLearning else { return }
        let v = min(max(sender.doubleValue, AppDelegate.minDB), AppDelegate.maxDB)
        guard AppDelegate.isValidDB(v) else { return }
        let id = o == 0 ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain
        guard !id.isEmpty else { return }
        outputs[o].gain = v
        onWriteDouble?(id, v)
        outGainFields[o].stringValue = String(format: "%.1f dB", v)
    }

    /// Mute / Dim / Sum for Main Out + Headphones.
    @objc private func outBoolChanged(_ sender: NSButton) {
        let tag = sender.tag
        let on = sender.state == .on
        let o = tag % 100
        let t = PathIds.active
        let id: [UInt8]?
        switch tag - o {
        case 800: id = o == 0 ? t.hwout0Mute : t.hwout1Mute; outputs[o].mute = on
        case 900: id = o == 0 ? t.hwout0Dim : t.hwout1Dim; outputs[o].dim = on
        case 1000: id = o == 0 ? t.hwout0Sum : t.hwout1Sum; outputs[o].sum = on
        default: id = nil
        }
        guard !suppressActions, !isLearning, let id, !id.isEmpty else { return refresh() }
        onWriteBool?(id, on)
    }

    /// Learn buttons: start a capture session for the column — or skip the
    /// current target while one is running.
    @objc private func learnClicked(_ sender: NSButton) {
        let tag = sender.tag
        if isLearning {
            if !learnQueue.isEmpty {
                let skipped = learnQueue.removeFirst()
                QBLog.log("console: learn skipped \(skipped.key)")
            }
            if learnQueue.isEmpty { learningColumn = nil }
            refresh()
            return
        }
        switch tag {
        case 600...603: startLearn(.input(tag - 600))
        case 1100...1101: startLearn(.output(tag - 1100))
        default: break
        }
    }

    // MARK: - gain field editing (return key)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, !suppressActions, !isLearning else { return }
        if field.tag >= 250, field.tag < 254 {
            // input gain (dB)
            let i = field.tag - 250
            guard let db = parseDB(field.stringValue), let id = PathIds.active.hwinMicGain[i] else { return refresh() }
            let v = min(max(db, 0), 75)
            onWriteDouble?(id, v)
            if let inst = PathIds.active.hwinInstGain[i] { onWriteDouble?(inst, v) }
            inputs[i].micGain = v; inputs[i].instGain = v
            refresh()
        } else if field.tag >= 750, field.tag < 752 {
            // monitor gain (dB)
            let o = field.tag - 750
            guard let db = parseDB(field.stringValue),
                  AppDelegate.isValidDB(db) else { return refresh() }
            let id = o == 0 ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain
            guard !id.isEmpty else { return refresh() }
            let v = min(max(db, AppDelegate.minDB), AppDelegate.maxDB)
            onWriteDouble?(id, v)
            outputs[o].gain = v
            refresh()
        }
    }

    // MARK: - polling (live tree reads even for uncaptured controls)

    private func startPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true,
                  self.isGlueConnected?() == true else { return }
            self.onRequestTree?()
        }
    }

    // MARK: - helpers

    private func check(_ title: String, _ tag: Int, _ action: Selector) -> NSButton {
        let c = NSButton(checkboxWithTitle: title, target: self, action: action)
        c.tag = tag
        c.font = .systemFont(ofSize: 11)
        return c
    }

    private func learnButton(_ tag: Int) -> NSButton {
        let b = NSButton(title: "Learn…", target: self, action: #selector(learnClicked(_:)))
        b.tag = tag
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 10)
        return b
    }

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

    private func setCheck(_ c: NSButton, _ value: Bool?, enabled: Bool) {
        c.isEnabled = enabled
        c.state = (value ?? false) ? .on : .off
    }

    private func selectPopup(_ p: NSPopUpButton, value: Int) {
        for item in p.itemArray where (item.representedObject as? Int) == value {
            p.select(item)
            return
        }
    }

    /// findTyped: like GlueClient.findNode but matches a prefix, because the
    /// tree's node types are exactly "hwin0"…"hwin3", "hwout0"…, while props
    /// live on the SAME node we search by full type name otherwise.
    private func findTyped(_ node: [String: Any], _ type: String) -> [String: Any]? {
        GlueClient.findNode(in: node, type: type)
    }

    private func parseDB(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "dB", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "M", with: "")
            .replacingOccurrences(of: "I", with: "")
            .replacingOccurrences(of: "·", with: "")
            .trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") { t.removeFirst() }
        return Double(t)
    }

    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        learnQueue = []
        learningColumn = nil
        pollTimer?.invalidate()
        pollTimer = nil
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
