import AppKit

/// Guided setup for a NEW Quartet: captures the unit's setProperty
/// path-ids live and stores them (PathIds.adopt → UserDefaults), so any
/// Quartet can be set up without touching code or the Terminal.
///
/// Why this exists: path-ids are a hash of the property path including
/// the device serial, so every physical Quartet has its own ids. Reads
/// (the glue tree) are identical on all units — but fader/mute writes
/// from an unknown table hit nothing. The wizard watches the glue
/// setProperty stream while the user wiggges ONE control at a time, in
/// a fixed order, and assigns the observed id to that control.
///
/// Capture rules (see docs/protocol-notes.md):
///  • gain  → var-tag 4 (double)  • mute/dim → var-tag 3 (bool)
///  • ids already captured in earlier steps are ignored in later ones —
///    this is what disambiguates the Quartet's mute ganging (toggling
///    Main mute also auto-mutes the HP monitor bus, firing BOTH mute
///    ids; the HP-mute step therefore ignores the already-known main id)
///
/// While a session runs, the app suppresses its own OS-slider/mute
/// writes so their echoes can't pollute the capture
/// (see AppDelegate.setupOSSlider / handleSetPropertyEvent).
final class PathIdSetupController: NSObject, NSWindowDelegate {

    static let shared = PathIdSetupController()

    /// True while a capture session is running (AppDelegate gates its
    /// own writes on this).
    private(set) var sessionActive = false

    // MARK: - steps

    private struct Step {
        let label: String       // short instruction
        let hint: String       // where to find the control
        let tag: UInt8         // expected var-tag
        let name: String       // control name for the checklist
        let apply: (inout PathIds.DeviceTable, [UInt8]) -> Void
        let skippable: Bool
    }

    private static var steps: [Step] {[
        Step(label: "Move the Main Out fader up and down",
             hint: "In Apogee Control 2 (or on the Quartet touchscreen) — drag the “Main Out” fader a few times.",
             tag: 4, name: "Main Out fader",
             apply: { $0.hwout0Gain = $1 }, skippable: false),
        Step(label: "Move the Headphones fader up and down",
             hint: "Drag the “HP” fader a few times — the headphones volume, NOT Main Out.",
             tag: 4, name: "Headphones fader",
             apply: { $0.hwout1Gain = $1 }, skippable: false),
        Step(label: "Toggle the Main Out mute ON, then OFF",
             hint: "Click Main Out's mute button once to mute, once to unmute.",
             tag: 3, name: "Main Out mute",
             apply: { $0.hwout0Mute = $1 }, skippable: false),
        Step(label: "Toggle the Headphones mute ON, then OFF",
             hint: "HP's own mute button — not Main Out's. (Muting Main also fires HP's mute; only HP's own button reveals its id.)",
             tag: 3, name: "Headphones mute",
             apply: { $0.hwout1Mute = $1 }, skippable: false),
        Step(label: "Toggle the Main Out dim ON, then OFF",
             hint: "Main Out's dim button. Skip if your unit doesn't expose dim.",
             tag: 3, name: "Main Out dim",
             apply: { $0.hwout0Dim = $1 }, skippable: true),
    ]}

    // MARK: - state

    private var window: NSWindow?
    private var serial: String?
    private var captured: [[UInt8]] = []          // ids captured in earlier steps
    private var current = PathIds.DeviceTable(
        hwout0Gain: [], hwout1Gain: [], hwout0Mute: [], hwout1Mute: [], hwout0Dim: [])
    private var stepIndex = 0
    private var doneLabels: [String] = []

    // UI
    private var stepField: NSTextField!
    private var hintField: NSTextField!
    private var progressField: NSTextField!
    private var doneField: NSTextField!
    private var skipButton: NSButton!

    // MARK: - session

    /// Start (or restart) the wizard for the connected Quartet.
    func begin() {
        guard let serial = PathIds.activeSerial else {
            Self.alert(title: "No Quartet detected",
                       text: "Quartet Buddy can't see a Quartet serial yet. " +
                             "Make sure the Quartet is connected and Apogee Control 2 is running, then try again.")
            return
        }
        self.serial = serial
        captured = []
        burstIds = []
        if let t = burstTimer { t.invalidate(); burstTimer = nil }
        current = PathIds.DeviceTable(hwout0Gain: [], hwout1Gain: [], hwout0Mute: [],
                                      hwout1Mute: [], hwout0Dim: [])
        stepIndex = 0
        doneLabels = []
        sessionActive = true
        QBLog.log("setup: begin wizard for \(serial)")
        if window == nil { build() }
        showStep()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func end() {
        sessionActive = false
        window?.orderOut(nil)
        QBLog.log("setup: wizard closed")
    }

    /// Every glue setProperty event, forwarded from AppDelegate.
    ///
    /// Gain and dim steps take the first unknown id of the right tag.
    /// The Main-mute step is special: Apogee Control 2 GANGS the mute —
    /// toggling Main also auto-mutes the HP monitor bus, so BOTH mute ids
    /// fire in one burst (live-observed). We collect the burst for ~1.5 s
    /// (main = first id, hp = second) and auto-skip the HP-mute step; if
    /// only one id fires (no gang), we keep the HP step.
    func handle(_ event: GlueClient.SetPropertyEvent) {
        guard sessionActive, window != nil, stepIndex < Self.steps.count else { return }
        let step = Self.steps[stepIndex]
        guard event.tag == step.tag else { return }
        let id = event.id
        // ids captured in earlier steps belong to other controls — never
        // re-capture them (this is also what disambiguates the mute gang
        // in the HP-mute step).
        guard !captured.contains(id) else { return }
        if stepIndex == 2 {   // Main mute — burst capture (gang)
            burstIds.append(id)
            captured.append(id)
            if burstIds.count == 1 {
                burstTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.resolveMuteBurst()
                }
            }
            showStep()   // show "listening…" while the burst collects
            return
        }
        captured.append(id)
        step.apply(&current, id)
        doneLabels.append("✓ " + step.name + "  " + id.map { String(format: "%02x", $0) }.joined())
        QBLog.log("setup: captured \(step.name) = \(id.map { String(format: "%02x", $0) }.joined())")
        advance()
    }

    private var burstIds: [[UInt8]] = []
    private var burstTimer: Timer?

    /// End of the Main-mute burst: 2 ids → ganged (main first, hp second)
    /// — both mutes captured, skip the HP step. 1 id → main only, keep it.
    private func resolveMuteBurst() {
        burstTimer = nil
        let ids = burstIds
        burstIds = []
        guard !ids.isEmpty else { return }
        let mainId = ids[0]
        current.hwout0Mute = mainId
        doneLabels.append("✓ Main Out mute  " + mainId.map { String(format: "%02x", $0) }.joined())
        QBLog.log("setup: captured Main Out mute = \(mainId.map { String(format: "%02x", $0) }.joined())")
        if ids.count >= 2 {
            let hpId = ids[1]
            current.hwout1Mute = hpId
            doneLabels.append("✓ Headphones mute  " + hpId.map { String(format: "%02x", $0) }.joined())
            QBLog.log("setup: captured Headphones mute = \(hpId.map { String(format: "%02x", $0) }.joined()) (mute gang — skipping the HP step)")
            advance()   // past Main mute
            advance()   // past HP mute
        } else {
            advance()
        }
    }

    // MARK: - UI

    private func build() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "Set Up This Quartet")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(labelWithString:
            "This Quartet uses its own control ids (they're derived from the device serial). " +
            "Follow the steps below — wiggle ONE control at a time and the capture is automatic.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 520
        intro.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(intro)

        progressField = NSTextField(labelWithString: "")
        progressField.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        progressField.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(progressField)

        stepField = NSTextField(labelWithString: "")
        stepField.font = .systemFont(ofSize: 13, weight: .semibold)
        stepField.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(stepField)

        hintField = NSTextField(labelWithString: "")
        hintField.font = .systemFont(ofSize: 12)
        hintField.textColor = .secondaryLabelColor
        hintField.preferredMaxLayoutWidth = 520
        hintField.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(hintField)

        doneField = NSTextField(labelWithString: "")
        doneField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        doneField.textColor = .systemGreen
        doneField.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(doneField)

        let buttons = NSStackView(views: [])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        skipButton = NSButton(title: "Skip This Control", target: self, action: #selector(skip(_:)))
        buttons.addArrangedSubview(skipButton)
        buttons.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(.init()) // spacer
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
        ])

        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Quartet Setup"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.delegate = self
        w.center()
        window = w
    }

    private func showStep() {
        let all = Self.steps
        guard stepIndex < all.count else { return }
        let step = all[stepIndex]
        progressField.stringValue = "Step \(stepIndex + 1) of \(all.count) · serial \(serial ?? "?")"
        stepField.stringValue = step.label
        hintField.stringValue = step.hint
        doneField.stringValue = doneLabels.joined(separator: "\n")
        skipButton.isEnabled = step.skippable
        skipButton.isHidden = !step.skippable
    }

    private func advance() {
        stepIndex += 1
        if stepIndex >= Self.steps.count {
            finish()
        } else {
            showStep()
        }
    }

    private func finish() {
        guard let serial else { end(); return }
        // Skipped dim → borrow the default table's dim id (best effort;
        // dim is the least critical of the five).
        if current.hwout0Dim.isEmpty {
            current.hwout0Dim = PathIds.defaultTable.hwout0Dim
            QBLog.log("setup: dim skipped — using the default table's dim id (may be wrong on this unit)")
        }
        PathIds.adopt(table: current, for: serial)
        sessionActive = false
        window?.orderOut(nil)
        Self.alert(title: "Quartet set up",
                   text: "Ids captured and saved for \(serial).\n" +
                         "Volume keys, mute and dim now work with this Quartet.")
        QBLog.log("setup: done for \(serial)")
    }

    // MARK: - actions

    @objc private func cancel(_ sender: NSButton) { end() }

    @objc private func skip(_ sender: NSButton) {
        guard stepIndex < Self.steps.count, Self.steps[stepIndex].skippable else { return }
        doneLabels.append("– " + Self.steps[stepIndex].name + " (skipped)")
        advance()
    }

    // NSWindowDelegate — closing the window cancels the session
    func windowWillClose(_ notification: Notification) {
        end()
    }

    private static func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
