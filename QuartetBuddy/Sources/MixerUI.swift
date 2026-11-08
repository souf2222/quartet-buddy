import AppKit

// MARK: - The hardware-mixer channel-strip UI (Settings ▸ Hardware Mixers)
//
// A presentation redesign (11/8): one mixer at a time via the segmented
// selector, a horizontal bank of vertical channel strips (Analog 1-4,
// Digital 1-8, Playback), graphite styling on the pane's charcoal. The
// control model is untouched — the strips drive the VERIFIED registers
// through SettingsWindowController's closures: the input gains = the 0x10
// blocks (one per stereo side), the playback = slots 12/13, pan = the L/R
// balance, mute/solo = app-level (gains to −48, the state remembered).

/// The vertical level fader: −48…+6 dB, a slim dark track, a unity tick
/// and a compact graphite handle. ⌘+click = 0 dB; the wheel nudges ±1 dB.
final class VFaderControl: NSView {
    static let minDB: Double = -48
    static let maxDB: Double = 6

    /// −48…+6 dB (set directly when reflecting the hardware — no callback)
    var dB: Double = VFaderControl.minDB { didSet { needsDisplay = true } }
    var faderEnabled = true { didSet { needsDisplay = true } }
    /// fired on every user change (drag ticks, ⌘-reset, the wheel)
    var onValue: ((Double) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 128) }

    private var dragging = false

    private var trackRect: NSRect {
        NSRect(x: (bounds.width - 4) / 2, y: 10,
               width: 4, height: bounds.height - 20)
    }
    // bottom-up coordinates: −48 dB at the track's BOTTOM, +6 dB at the
    // top — the handle's center rides the track's full travel.
    private func y(forDB db: Double) -> CGFloat {
        let t = (db - Self.minDB) / (Self.maxDB - Self.minDB)
        return trackRect.minY + CGFloat(t) * trackRect.height
    }
    private func dB(forY y: CGFloat) -> Double {
        let t = max(0, min(1, (y - trackRect.minY) / trackRect.height))
        return Self.minDB + Double(t) * (Self.maxDB - Self.minDB)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tr = trackRect
        let track = NSBezierPath(roundedRect: tr, xRadius: 2, yRadius: 2)
        NSColor(white: 0.15, alpha: 1).setFill()
        track.fill()
        NSColor(white: 0.3, alpha: 1).setStroke()
        track.lineWidth = 1
        track.stroke()
        // the unity tick (0 dB)
        NSColor(white: 1, alpha: 0.26).setFill()
        NSRect(x: tr.minX - 5, y: y(forDB: 0) - 0.5, width: tr.width + 10, height: 1).fill()
        // the handle
        let hy = y(forDB: dB)
        let handle = NSRect(x: (bounds.width - 26) / 2, y: hy - 6, width: 26, height: 12)
        let hp = NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3)
        NSColor(white: faderEnabled ? 0.33 : 0.24, alpha: 1).setFill()
        hp.fill()
        NSColor(white: faderEnabled ? 0.52 : 0.36, alpha: 1).setStroke()
        hp.lineWidth = 1
        hp.stroke()
        NSColor(white: 0.88, alpha: faderEnabled ? 1 : 0.35).setFill()
        NSRect(x: handle.midX - 9, y: hy - 0.5, width: 18, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard faderEnabled else { return }
        if event.modifierFlags.contains(.command) {   // the reset gesture
            applyDB(0)
            return
        }
        dragging = true
        applyDB(dB(forY: convert(event.locationInWindow, from: nil).y))
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, faderEnabled else { return }
        applyDB(dB(forY: convert(event.locationInWindow, from: nil).y))
    }
    override func mouseUp(with event: NSEvent) { dragging = false }
    override func scrollWheel(with event: NSEvent) {
        guard faderEnabled else { return }
        applyDB(dB + (event.deltaY < 0 ? 1 : -1))
    }
    private func applyDB(_ v: Double) {
        let clamped = min(Self.maxDB, max(Self.minDB, v.rounded()))
        guard clamped != dB else { return }
        dB = clamped
        onValue?(clamped)
    }
}

/// The short center-marked pan/balance control: 0…128, 64 = center.
final class HPanControl: NSView {
    var panByte: Int = 64 { didSet { needsDisplay = true } }
    var faderEnabled = true { didSet { needsDisplay = true } }
    var onValue: ((Int) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 16) }

    private var dragging = false

    private var trackRect: NSRect {
        NSRect(x: 1, y: (bounds.height - 3) / 2, width: bounds.width - 2, height: 3)
    }
    private func x(forByte b: Int) -> CGFloat {
        trackRect.minX + CGFloat(max(0, min(128, b))) / 128 * trackRect.width
    }
    private func byte(forX x: CGFloat) -> Int {
        let t = max(0, min(1, (x - trackRect.minX) / trackRect.width))
        return Int(round(t * 128))
    }

    override func draw(_ dirtyRect: NSRect) {
        let tr = trackRect
        let track = NSBezierPath(roundedRect: tr, xRadius: 1.5, yRadius: 1.5)
        NSColor(white: 0.15, alpha: 1).setFill()
        track.fill()
        NSColor(white: 0.3, alpha: 1).setStroke()
        track.lineWidth = 1
        track.stroke()
        // the center tick
        NSColor(white: 1, alpha: 0.26).setFill()
        NSRect(x: bounds.midX - 0.5, y: 1, width: 1, height: bounds.height - 2).fill()
        // the thumb
        let tx = x(forByte: panByte)
        let thumb = NSRect(x: tx - 5, y: (bounds.height - 9) / 2, width: 10, height: 9)
        let tp = NSBezierPath(roundedRect: thumb, xRadius: 2.5, yRadius: 2.5)
        NSColor(white: faderEnabled ? 0.33 : 0.24, alpha: 1).setFill()
        tp.fill()
        NSColor(white: faderEnabled ? 0.52 : 0.36, alpha: 1).setStroke()
        tp.lineWidth = 1
        tp.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard faderEnabled else { return }
        if event.modifierFlags.contains(.command) { applyByte(64); return }
        dragging = true
        applyByte(byte(forX: convert(event.locationInWindow, from: nil).x))
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, faderEnabled else { return }
        applyByte(byte(forX: convert(event.locationInWindow, from: nil).x))
    }
    override func mouseUp(with event: NSEvent) { dragging = false }
    override func scrollWheel(with event: NSEvent) {
        guard faderEnabled else { return }
        applyByte(panByte + (event.deltaY < 0 ? 2 : -2))
    }
    private func applyByte(_ v: Int) {
        let clamped = max(0, min(128, v))
        guard clamped != panByte else { return }
        panByte = clamped
        onValue?(clamped)
    }
}

/// The Mute / Solo button: graphite when inactive; a muted red for the
/// active mute and an amber for the active solo — fill + label contrast.
final class MSButton: NSView {
    enum Kind { case mute, solo }
    var kind: Kind = .mute { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    var faderEnabled = true { didSet { needsDisplay = true } }
    var onToggle: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 18) }
    private var label: String { kind == .mute ? "M" : "S" }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                             xRadius: 4, yRadius: 4)
        let active: NSColor = kind == .mute
            ? NSColor(red: 0.75, green: 0.30, blue: 0.24, alpha: 1)
            : NSColor(red: 0.80, green: 0.60, blue: 0.20, alpha: 1)
        let lit = isOn && faderEnabled
        (lit ? active : NSColor(white: 0.2, alpha: 1)).setFill()
        r.fill()
        NSColor(white: lit ? 0.55 : 0.3, alpha: 1).setStroke()
        r.lineWidth = 1
        r.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: lit ? NSColor.white
                : (faderEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor),
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                           y: (bounds.height - sz.height) / 2 + 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard faderEnabled else { return }
        isOn.toggle()
        onToggle?(isOn)
    }
}

/// One channel strip: the label, the pan (with its position readout), the
/// vertical fader, the numeric level and the M/S buttons — fixed frames,
/// no cards, on the pane's continuous charcoal.
final class MixerStrip: NSView {
    static let height: CGFloat = 232
    /// the Playback strip is wider so its label fits
    let stripWidth: CGFloat

    let fader = VFaderControl(frame: .zero)
    let pan = HPanControl(frame: .zero)
    let muteButton = MSButton(frame: .zero)
    let soloButton = MSButton(frame: .zero)
    private let nameLabel: NSTextField
    private let panReadout: NSTextField
    private let levelReadout: NSTextField

    var faderDB: Double { fader.dB }
    var panByte: Int { pan.panByte }

    var faderEnabled = true {
        didSet {
            fader.faderEnabled = faderEnabled
            pan.faderEnabled = faderEnabled
            muteButton.faderEnabled = faderEnabled
            soloButton.faderEnabled = faderEnabled
        }
    }

    init(title: String, width: CGFloat = 46) {
        stripWidth = width
        nameLabel = NSTextField(labelWithString: title)
        panReadout = NSTextField(labelWithString: "C")
        levelReadout = NSTextField(labelWithString: "−48")
        super.init(frame: NSRect(x: 0, y: 0, width: stripWidth, height: Self.height))

        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.alignment = .center
        panReadout.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        panReadout.alignment = .center
        levelReadout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        levelReadout.alignment = .center
        levelReadout.textColor = .labelColor

        // fixed frames — top-down → AppKit bottom-up (h = 232)
        nameLabel.frame = NSRect(x: 0, y: Self.height - 16, width: stripWidth, height: 14)
        panReadout.frame = NSRect(x: 0, y: Self.height - 31, width: stripWidth, height: 12)
        pan.frame = NSRect(x: 2, y: Self.height - 49, width: stripWidth - 4, height: 16)
        fader.frame = NSRect(x: 2, y: 54, width: stripWidth - 4, height: 128)
        levelReadout.frame = NSRect(x: 0, y: 34, width: stripWidth, height: 14)
        muteButton.frame = NSRect(x: 0, y: 8, width: 22, height: 18)
        soloButton.frame = NSRect(x: stripWidth - 22, y: 8, width: 22, height: 18)
        soloButton.kind = .solo          // (the default = .mute — the missing
                                         // kind made both buttons read "M")

        fader.toolTip = "Level, dB — ⌘+click = 0 dB"
        pan.toolTip = "Pan — ⌘+click = center"
        muteButton.toolTip = "Mute the row in this mixer"
        soloButton.toolTip = "Solo the row in this mixer (the others duck to −48 dB)"

        [nameLabel, panReadout, levelReadout, pan, fader, muteButton, soloButton]
            .forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    func setFader(_ db: Double) {
        fader.dB = db
        levelReadout.stringValue = Self.levelText(db)
    }
    func setPan(_ byte: Int) {
        pan.panByte = max(0, min(128, byte))
        panReadout.stringValue = Self.panText(pan.panByte)
    }
    func setMute(_ on: Bool) { muteButton.isOn = on }
    func setSolo(_ on: Bool) { soloButton.isOn = on }

    static func levelText(_ db: Double) -> String {
        let v = Int(db.rounded())
        if v == 0 { return "0" }
        return v > 0 ? "+\(v)" : "\u{2212}\(-v)"
    }
    static func panText(_ byte: Int) -> String {
        byte == 64 ? "C" : (byte < 64 ? "L \(64 - byte)" : "R \(byte - 64)")
    }
}

/// The shared dB scale at the left of a channel group: the ticks at +6 /
/// 0 (unity, stronger) / −12 / −24 / −48 on the same linear-in-dB mapping
/// as the faders, aligned with the fader travel.
final class MixerScaleColumn: NSView {
    /// the ticks as (dB, label, isUnity)
    private static let ticks: [(Double, String, Bool)] = [
        (6, "+6", false), (0, "0", true), (-12, "\u{2212}12", false),
        (-24, "\u{2212}24", false), (-48, "\u{2212}48", false),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let lb = NSTextField(labelWithString: "dB")
        lb.font = .systemFont(ofSize: 9, weight: .medium)
        lb.textColor = .secondaryLabelColor
        lb.alignment = .center
        lb.frame = NSRect(x: 0, y: frame.height + 3, width: frame.width, height: 11)
        addSubview(lb)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        for (db, text, unity) in Self.ticks {
            let y = (db - VFaderControl.minDB) / (VFaderControl.maxDB - VFaderControl.minDB) * h
            let alpha: CGFloat = unity ? 0.5 : 0.22
            NSColor(white: 1, alpha: alpha).setFill()
            NSRect(x: bounds.width - 8, y: y - 0.5, width: unity ? 8 : 5, height: 1).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: unity ? .medium : .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.width - 10 - sz.width, y: y - sz.height / 2 + 0.5))
            if unity {
                let u = NSAttributedString(string: "unity", attributes: [
                    .font: NSFont.systemFont(ofSize: 6.5),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
                let usz = u.size()
                u.draw(at: NSPoint(x: bounds.width - 10 - usz.width, y: y - sz.height / 2 - usz.height - 1))
            }
        }
    }
}

/// The horizontal bank: 13 strips (Analog 1-4, Digital 1-8, Playback),
/// a dB scale column at the left of each group, subtle separators +
/// slightly larger gaps between the groups, the group headings on top.
/// Fixed frames; the hosting scroll view scrolls horizontally at narrow
/// widths.
final class MixerBankView: NSView {
    private(set) var strips: [MixerStrip] = []

    static let height: CGFloat = MixerStrip.height + 16

    init(rowTitles: [String]) {
        let n = rowTitles.count
        // the strip widths: the Playback gets extra room for its label
        let widthFor: (Int) -> CGFloat = { i in rowTitles[i] == "Playback" ? 66 : 46 }
        let stripGap: CGFloat = 6
        let groupGap: CGFloat = 16
        let scaleW: CGFloat = 30

        var frames = [NSRect](repeating: .zero, count: n)
        var scaleFrames: [NSRect] = []
        var separatorXs: [CGFloat] = []
        var x: CGFloat = 0
        let groups = [(0, 3), (4, 11), (12, n - 1)]
        for (gi, group) in groups.enumerated() {
            scaleFrames.append(NSRect(x: x, y: 64, width: scaleW, height: 108))
            x += scaleW + 3
            for i in group.0...group.1 {
                frames[i] = NSRect(x: x, y: 0, width: widthFor(i), height: MixerStrip.height)
                x += widthFor(i)
                if i < group.1 { x += stripGap }
            }
            if gi < groups.count - 1 {
                x += groupGap / 2
                separatorXs.append(x)
                x += groupGap / 2
            }
        }

        super.init(frame: NSRect(x: 0, y: 0, width: x, height: Self.height))

        // the group headings (tight against the strips)
        let headings: [(String, Int, Int)] = [("ANALOG", 0, 3), ("DIGITAL", 4, 11),
                                              ("PLAYBACK", 12, n - 1)]
        for (text, from, to) in headings {
            let x0 = scaleFrames[headings.firstIndex(where: { $0.0 == text })!].minX
            let x1 = frames[to].maxX
            let lb = NSTextField(labelWithString: text)
            lb.font = .systemFont(ofSize: 9, weight: .medium)
            lb.textColor = .secondaryLabelColor
            lb.alignment = .center
            lb.frame = NSRect(x: x0, y: MixerStrip.height + 2,
                              width: x1 - x0, height: 12)
            addSubview(lb)
        }
        // the separators
        for sx in separatorXs {
            let v = NSView(frame: NSRect(x: sx, y: 6, width: 1, height: Self.height - 24))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            addSubview(v)
        }
        // the scale columns
        for sf in scaleFrames {
            let col = MixerScaleColumn(frame: sf)
            addSubview(col)
        }
        // the strips
        for (i, title) in rowTitles.enumerated() {
            let s = MixerStrip(title: title, width: widthFor(i))
            s.frame = frames[i]
            s.autoresizingMask = []
            strips.append(s)
            addSubview(s)
        }
    }

    required init?(coder: NSCoder) { fatalError("no nib") }
}
