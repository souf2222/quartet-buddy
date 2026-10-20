import AppKit

/// The "Quartet Console" window: every input- and monitor-side hardware
/// function in one place, off the menubar so the core features stay clean.
///
/// Per analog input (IN 1-4): analog level, preamp gain (mic and instrument
/// keep their OWN values — the slider edits only the active mode's gain,
/// so switching modes never drags the gain along), +48V phantom, soft
/// limit, polarity. Per monitor (Main Out / Headphones): level, mute,
/// dim, sum/mono.
///
/// Mode-dependent controls: the preamp only applies in Mic and Instrument
/// modes, so the GAIN slider + dB field (and the section label) are hidden
/// while an input is at +4 dBu / −10 dBV; +48V is Mic-only. The dB field
/// shows the ACTIVE mode's gain — a single value, never "M x · I y".
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

    // Auto Gain — the console shows the engine's status lines; failures
    // clear themselves after a moment, the success line stays until the
    // next calibration. Multi-input runs show the LAST status/failure.
    private var autoGainStatus: String?
    private var autoGainStatusTimer: Timer?
    private var autoGainAllButton: NSButton!
    private var targetLevelPopup: NSPopUpButton!
    private var timeLevelPopup: NSPopUpButton!

    enum LearnColumn: Equatable { case input(Int), output(Int) }

    // MARK: - show / refresh cycle

    func show() {
        if window == nil { build() }
        // open with real values: seed from the last tree, then pull a
        // fresh one immediately (don't wait out the first poll tick)
        if let tree = onSeedTree?() { updateTree(tree) } else { refresh() }
        QBLog.log("console: opened — IN1 M\(inputs[0].micGain.map { String(format: "%.1f", $0) } ?? "?")/I\(inputs[0].instGain.map { String(format: "%.1f", $0) } ?? "?") ref\(inputs[0].refLevel.map(String.init) ?? "?"), IN2 M\(inputs[1].micGain.map { String(format: "%.1f", $0) } ?? "?")")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPoll()
        onRequestTree?()
    }

    func refresh() {
        guard window != nil else { return }
        suppressActions = true
        defer { suppressActions = false }
        let connected = isGlueConnected?() ?? false
        let learning = isLearning

        let autoRunning = AutoGainEngine.shared.runningInputs

        // INPUTS
        for i in 0..<4 {
            let st = inputs[i]
            let t = PathIds.active
            let levelId = t.hwinRefLevel[i]
            levelPopups[i].isEnabled = connected && !learning && levelId != nil && autoRunning.isEmpty
            if let rl = st.refLevel {
                selectPopup(levelPopups[i], value: rl)
            } else {
                levelPopups[i].selectItem(withTitle: "—")
            }

            // Mode-dependent controls: the preamp only applies in Mic /
            // Instrument (gain), phantom in Mic only. At the line levels
            // (+4 dBu / −10 dBV) the preamp is bypassed — hide those
            // cells so the column shows only what the mode can do.
            // (Unknown refLevel → show everything, harmless fallback.)
            let lineMode = st.refLevel == 2 || st.refLevel == 3
            gainSectionFields[i]?.isHidden = lineMode
            gainSliders[i].isHidden = lineMode
            gainFields[i].isHidden = lineMode
            autoGainButtons[i].isHidden = lineMode
            phantomChecks[i].isHidden = lineMode || st.refLevel == 4

            // Auto Gain: one batch at a time; a running column's button
            // becomes Cancel (any of them cancels), the rest wait.
            let mineRunning = autoRunning.contains(i)
            autoGainButtons[i].title = mineRunning ? "Cancel" : "Auto Gain…"
            autoGainButtons[i].isEnabled = connected && !learning
                && (mineRunning || autoRunning.isEmpty)

            let micId = t.hwinMicGain[i], instId = t.hwinInstGain[i]
            let bothIds = micId != nil && instId != nil
            gainSliders[i].isEnabled = connected && !learning && bothIds && autoRunning.isEmpty
            // the slider shows the ACTIVE mode's gain (Instrument = inst,
            // anything else = mic — the preamp applies in both Mic and
            // Instrument, only the line levels bypass it)
            let shown: Double
            if st.refLevel == 4 { shown = st.instGain ?? st.micGain ?? 0 }
            else { shown = st.micGain ?? st.instGain ?? 0 }
            if gainSliders[i].doubleValue != shown { gainSliders[i].doubleValue = shown }
            updateGainField(i)

            setCheck(phantomChecks[i], st.phantom, enabled: connected && !learning && t.hwinPhantom[i] != nil)
            setCheck(softLimitChecks[i], st.softLimit, enabled: connected && !learning && t.hwinSoftLimit[i] != nil)
            setCheck(polarityChecks[i], st.polarity, enabled: connected && !learning && t.hwinPolarity[i] != nil)

            inputHeaders[i]?.stringValue = st.name ?? "Analog IN \(i + 1)"
            let missing = missingInputTargets(i)
            // ids are always computed now — Learn is only a fallback
            inputLearnButtons[i].isHidden = missing.isEmpty && !isLearning
            inputLearnButtons[i].isEnabled = (learning && learningColumn == .input(i)) || !missing.isEmpty
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
            outLearnButtons[o].isHidden = missing.isEmpty && !isLearning
            outLearnButtons[o].isEnabled = (learning && learningColumn == .output(o)) || !missing.isEmpty
        }

        statusField.stringValue = learnStatus()
            ?? autoGainStatus
            ?? (connected ? "" : "Not connected — waiting for Apogee Control 2 / ApogeeGlue…")
        // NOTE: no geometry work here, ever — resizing/re-centering the
        // window during a refresh cancels slider drags mid-flight
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
    private var gainSectionFields: [NSTextField?] = []
    private var gainSliders: [NSSlider] = []
    private var gainFields: [NSTextField] = []
    private var autoGainButtons: [NSButton] = []
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
    private var stack: NSStackView!
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
        self.stack = stack
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
            // values verified live against Apogee Control 2: 1=Mic,
            // 2=+4 dBu, 3=−10 dBV, 4=Instrument (line modes hide the
            // preamp gain; Instrument switches to instSettings gain)
            for (v, label) in [(1, "Mic"), (2, "+4 dBu"), (3, "−10 dBV"), (4, "Instrument")] {
                p.addItem(withTitle: label)
                p.lastItem?.representedObject = v
            }
            p.target = self
            p.action = #selector(levelChanged(_:))
            p.tag = 100 + i
            p.font = .systemFont(ofSize: 11)
            levelPopups.append(p)
            return p
        })

        ig.addRow(with: (0..<4).map { _ in sectionField("GAIN") })
        gainSectionFields = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 3).contentView as? NSTextField }
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

        // Auto Gain: one-time preamp calibration (AutoGain.swift). Same
        // visibility as the gain block (Mic / Instrument only); becomes
        // "Cancel" while a calibration runs on this input.
        ig.addRow(with: (0..<4).map { i in
            let b = NSButton(title: "Auto Gain…", target: self,
                             action: #selector(autoGainClicked(_:)))
            b.tag = 1200 + i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 10)
            return b
        })
        autoGainButtons = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 6).contentView as! NSButton }

        ig.addRow(with: (0..<4).map { i in check("+48V", 300 + i, #selector(boolChanged(_:))) })
        phantomChecks = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 7).contentView as! NSButton }
        ig.addRow(with: (0..<4).map { i in check("Soft Limit", 400 + i, #selector(boolChanged(_:))) })
        softLimitChecks = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 8).contentView as! NSButton }
        ig.addRow(with: (0..<4).map { i in check("Polarity Ø", 500 + i, #selector(boolChanged(_:))) })
        polarityChecks = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 9).contentView as! NSButton }

        ig.addRow(with: (0..<4).map { i in learnButton(600 + i) })
        inputLearnButtons = (0..<4).map { ig.cell(atColumnIndex: $0, rowIndex: 10).contentView as! NSButton }

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

        // INPUTS header row: title + "All" button + target-level popup.
        // "All" calibrates every Mic/Instrument input in one batch; the
        // popup is the shared target (persisted setting, engine reads it
        // live each nudge so a change applies to the next run).
        let inHeader = NSStackView()
        inHeader.orientation = .horizontal
        inHeader.alignment = .centerY
        inHeader.spacing = 10
        inHeader.addArrangedSubview(inTitle)

        let allButton = NSButton(title: "Auto Gain All", target: self,
                                 action: #selector(autoGainAllClicked(_:)))
        allButton.bezelStyle = .rounded
        allButton.controlSize = .small
        allButton.font = .systemFont(ofSize: 10)
        inHeader.addArrangedSubview(allButton)
        autoGainAllButton = allButton

        let targetLabel = NSTextField(labelWithString: "target")
        targetLabel.font = .systemFont(ofSize: 10)
        targetLabel.textColor = .tertiaryLabelColor
        inHeader.addArrangedSubview(targetLabel)

        let targetPopup = NSPopUpButton()
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged(_:))
        targetPopup.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for v in AutoGainEngine.targetOptions {
            targetPopup.addItem(withTitle: String(format: "%.0f dBFS peak", v))
            targetPopup.lastItem?.representedObject = v
        }
        selectPopupValue(targetPopup, double: AutoGainEngine.targetDBFS)
        inHeader.addArrangedSubview(targetPopup)
        targetPopup.autoenablesItems = true
        inHeader.translatesAutoresizingMaskIntoConstraints = false
        targetLevelPopup = targetPopup

        // calibration time (persisted setting): how long the engine tracks
        // before verifying — read live, applies to the next run
        let timeLabel = NSTextField(labelWithString: "time")
        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .tertiaryLabelColor
        inHeader.addArrangedSubview(timeLabel)

        let timePopup = NSPopUpButton()
        timePopup.target = self
        timePopup.action = #selector(timeChanged(_:))
        timePopup.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for v in AutoGainEngine.listenOptions {
            timePopup.addItem(withTitle: String(format: "%.0f s", v))
            timePopup.lastItem?.representedObject = v
        }
        selectPopupValue(timePopup, double: AutoGainEngine.listenSeconds)
        inHeader.addArrangedSubview(timePopup)
        timePopup.autoenablesItems = true
        timeLevelPopup = timePopup

        stack.addArrangedSubview(inHeader)
        stack.addArrangedSubview(ig)
        stack.addArrangedSubview(outTitle)
        stack.addArrangedSubview(og)

        statusField = NSTextField(labelWithString: "")
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byWordWrapping
        statusField.preferredMaxLayoutWidth = 620
        stack.addArrangedSubview(statusField)

        // Fixed column widths — pin every cell's contentView to the column
        // width (same approach as OutputsWindow). NSSlider/NSTextField have
        // no intrinsic width, and `column.width` alone does not size them:
        // the GAIN slider and the dB field collapsed to ZERO width (knob
        // with no track, empty field — verified by rendering this exact
        // hierarchy offscreen; the pinned-width variant renders correctly).
        for i in 0..<4 {
            for r in 0..<ig.numberOfRows {
                ig.cell(atColumnIndex: i, rowIndex: r).contentView?.widthAnchor
                    .constraint(equalToConstant: 150).isActive = true
            }
        }
        for i in 0..<2 {
            for r in 0..<og.numberOfRows {
                og.cell(atColumnIndex: i, rowIndex: r).contentView?.widthAnchor
                    .constraint(equalToConstant: 150).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            // ≤ (not ==): the stack sizes itself from its grids — pinning it
            // to both edges fights the fixed column widths and makes the
            // geometry unstable, which used to re-center the window on every
            // refresh and cancel slider drags mid-flight
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        let w = NSWindow(contentRect: content.bounds,
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        w.title = "Quartet Console"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentView = content
        w.delegate = self
        window = w

        // Size ONCE from the real laid-out content, then never touch the
        // geometry again — the user owns the window's position and size.
        content.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        w.setContentSize(NSSize(width: fit.width + 44, height: fit.height + 62))
        w.center()
    }

    // MARK: - actions (all clamped — bad ranges crash the unit)

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 100
        guard !suppressActions, !isLearning, !AutoGainEngine.shared.isRunning,
              let v = sender.selectedItem?.representedObject as? Int,
              let id = PathIds.active.hwinRefLevel[i] else { return refresh() }
        guard (1...4).contains(v) else { return refresh() }
        inputs[i].refLevel = v
        onWriteInt?(id, Int32(v))
        // apply mode-dependent visibility + slider jump immediately —
        // don't wait for the echo/poll to hide gain at line levels etc.
        refresh()
    }

    /// Preamp gain: writes the ACTIVE mode's gain only — mic and instrument
    /// keep their own values, so switching modes doesn't carry the gain
    /// over (same as Apogee Control 2).
    @objc private func gainSlid(_ sender: NSSlider) {
        let i = sender.tag - 200
        guard !suppressActions, !isLearning, !AutoGainEngine.shared.isRunning else { return }
        // line modes bypass the preamp — the slider is hidden there, but a
        // drag already in flight when the mode flips must not write
        if let rl = inputs[i].refLevel, rl == 2 || rl == 3 { return }
        let v = min(max(sender.doubleValue, 0), 75)
        let t = PathIds.active
        if inputs[i].refLevel == 4, let id = t.hwinInstGain[i] {
            onWriteDouble?(id, v)
            inputs[i].instGain = v
            QBLog.log(String(format: "console: IN %d gain -> %.2f dB (inst id %@)",
                             i + 1, v, id.map { String(format: "%02x", $0) }.joined()))
        } else if let id = t.hwinMicGain[i] {
            onWriteDouble?(id, v)
            inputs[i].micGain = v
            QBLog.log(String(format: "console: IN %d gain -> %.2f dB (mic id %@)",
                             i + 1, v, id.map { String(format: "%02x", $0) }.joined()))
        }
        updateGainField(i)
    }

    /// The dB field shows the ACTIVE mode's gain only — "32.0 dB", never
    /// a "M x · I y" pair. Instrument = instSettings gain, anything
    /// else (Mic / unknown) = micSettings gain.
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

    // MARK: - Auto Gain (one-time preamp calibration — AutoGain.swift)

    /// The Auto Gain button: start a calibration, or cancel the running
    /// batch (any column's button cancels while one runs).
    @objc private func autoGainClicked(_ sender: NSButton) {
        let i = sender.tag - 1200
        if AutoGainEngine.shared.isRunning {
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
            return
        }
        startAutoGain(for: [i])
    }

    /// "Auto Gain All": calibrate every Mic/Instrument input in one batch
    /// (line-level inputs are skipped — no preamp to calibrate).
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

    /// Target-level popup (persisted; read live by the engine each nudge).
    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? Double else { return }
        AutoGainEngine.targetDBFS = v
    }

    /// Calibration-time popup (persisted; read live by the engine).
    @objc private func timeChanged(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? Double else { return }
        AutoGainEngine.listenSeconds = v
    }

    private func startAutoGain(for indices: [Int]) {
        guard (isGlueConnected?() ?? false) else { return }
        var params: [AutoGainEngine.StartParams] = []
        var skipped = 0
        for i in indices {
            guard let rl = inputs[i].refLevel, rl == 1 || rl == 4 else { skipped += 1; continue }
            let t = PathIds.active
            let gainId = rl == 4 ? t.hwinInstGain[i] : t.hwinMicGain[i]
            let current = rl == 4 ? inputs[i].instGain : inputs[i].micGain
            guard let gainId, let current else { skipped += 1; continue }
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
        _ = skipped
        AutoGainEngine.shared.start(params)
    }

    /// Engine → hardware + console state: write an input's ACTIVE mode
    /// preamp gain (the engine clamps and floors; same plumbing as the
    /// slider).
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

    /// Show an Auto Gain line in the console's status area.
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

    private func selectPopupValue(_ p: NSPopUpButton, double v: Double) {
        for item in p.itemArray where (item.representedObject as? Double) == v {
            p.select(item)
            return
        }
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
            // input gain (dB) — active mode's gain only, so mic and
            // instrument keep their own values
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
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
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
            AutoGainEngine.shared.cancelAll(reason: "console closed")
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
