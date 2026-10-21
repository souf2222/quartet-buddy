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
/// Visual direction: "Obsidian" — one continuous smoked-black glass
/// window (cool graphite, desktop bleeding softly through the blur),
/// slightly lighter graphite cards with fine white borders, soft-white
/// type. The interface stays quiet: electric blue carries focus,
/// selection and slider fills; each audio function owns ONE saturated
/// accent that appears ONLY while engaged (solid vivid fill, near-black
/// label). Inactive toggles share a single neutral treatment, so
/// "available" vs "enabled" is always obvious at a glance.
///
/// Plumbing is unchanged from the two windows it replaces: hardware reads
/// come from the glue tree (live 2 s poll while visible), writes go through
/// setProperty path-ids (all clamped — out-of-range writes crash the unit),
/// routing state lives in InsertServer, and Learn mode captures missing
/// ids by listening to the live event stream.

// MARK: - Theme (Obsidian: smoked black glass, graphite panes, vivid accents)

enum GGTheme {
    // Base surfaces — dark, translucent, cool. The window composes to
    // roughly `#101115`-deep charcoal even over a plain black desktop.

    /// Opaque fallback — the charcoal the glass composes to when there is
    /// nothing (interesting) behind the window.
    static let windowFallback = hex("101115")
    /// Smoked-glass window tint over the blurred desktop — near-black
    /// with a cool-blue undertone; wallpaper bleeds through softly.
    static let windowTint = NSColor(srgbRed: 12 / 255, green: 14 / 255, blue: 19 / 255, alpha: 0.78)
    /// Title bar + monitor strip — subtle framing bands of the same glass.
    static let headerFooterTint = NSColor(srgbRed: 15 / 255, green: 17 / 255, blue: 23 / 255, alpha: 0.55)
    /// Channel cards — slightly lighter graphite panes: translucent fills
    /// over the window glass, not separate frosted-glass tiles.
    static let card = NSColor(srgbRed: 35 / 255, green: 39 / 255, blue: 49 / 255, alpha: 0.62)
    /// The selected card — a deliberate surface lift, still graphite.
    static let cardSelected = NSColor(srgbRed: 48 / 255, green: 53 / 255, blue: 66 / 255, alpha: 0.66)
    /// Fine card outline — light catching the edge of dark glass.
    static let cardBorder = NSColor(white: 1, alpha: 0.085)
    /// Hovered cards / important boundaries.
    static let cardBorderEmphasized = NSColor(white: 1, alpha: 0.16)
    /// Recessed areas — plug-in wells, meter beds.
    static let inset = NSColor(white: 0, alpha: 0.22)

    // Text

    /// Primary text — titles, gain values, monitor levels (`#F2F4F8`).
    /// Values the user must read quickly are always this bright.
    static let primary = hex("F2F4F8")
    /// Secondary text — labels like "Source" and "Output Trim" (`#A4ACBA`).
    static let softGray = hex("A4ACBA")
    /// Muted text — supporting metadata and inactive indicators only
    /// (`#747D8D`). Never for anything read at a glance.
    static let muted = hex("747D8D")
    /// Coral — clipping warnings in text (a mute is a state, not a
    /// warning; meter reds live in GGLevelMeter).
    static let warning = hex("FF637A")

    /// Near-black text used ON vivid engaged fills.
    static let darkText = hex("101318")
    /// DISABLED function controls — quieter than idle-but-available.
    static let subduedFill = NSColor(white: 1, alpha: 0.03)

    // Accents — one interaction color + one semantic color per function.
    // Concentrated in toggles, indicators and focused controls — never
    // spread across whole cards.

    /// Electric blue — focus, selection, primary actions, slider fills, SUM.
    static let electricBlue = hex("438DFF")
    /// Mint — Soft Limit engaged; healthy signal.
    static let mint = hex("36E3A0")
    /// Warm amber — 48V engaged; DIM engaged.
    static let amber = hex("FFBC47")
    /// Vivid violet — polarity inversion engaged.
    static let violet = hex("AC88FF")
    /// Coral — Mute engaged; clipping.
    static let coral = hex("FF637A")
    /// Ice cyan — linked / mirrored routing indicator.
    static let iceCyan = hex("50D8F4")

    /// The ONE idle treatment every toggle shares — neutral, understated:
    /// clearly "clickable but off", never mistakable for an engaged function.
    static let toggleIdleFill = NSColor(white: 1, alpha: 0.055)
    static let toggleIdleBorder = NSColor(white: 1, alpha: 0.07)
    static let toggleIdleLabel = hex("929BAA")
    /// A restrained hover lift, shared by all raised controls.
    static let hoverSurface = NSColor(white: 1, alpha: 0.105)

    /// `#RRGGBB` → NSColor (sRGB).
    static func hex(_ h: String) -> NSColor {
        var v = h.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("#") { v.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: v).scanHexInt64(&rgb)
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let sectionFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let nameFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let labelFont = NSFont.systemFont(ofSize: 11)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
}

/// A graphite pane: translucent fill over the window's glass, a fine
/// white border, and a faint top-edge light — like light on dark glass.
/// Hover quietly lifts the border; the SELECTED card gets a thin
/// electric-blue border at ~55% and a slightly lighter surface — never a
/// big outer glow. `selected` is set by the keyboard-shortcut highlight.
final class CardView: NSView {
    var selected = false { didSet { restyle() } }
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    /// White ≈8% fading down from the top edge — the "light on glass" cue.
    private let topLight = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        topLight.colors = [NSColor(white: 1, alpha: 0.08).cgColor, NSColor.clear.cgColor]
        topLight.startPoint = CGPoint(x: 0.5, y: 1)
        topLight.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(topLight)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // bright at the very top, gone by mid-card — barely visible
        topLight.frame = CGRect(x: 0, y: bounds.height * 0.6,
                                width: bounds.width, height: bounds.height * 0.4)
    }

    private func restyle() {
        layer?.backgroundColor = (selected ? GGTheme.cardSelected : GGTheme.card).cgColor
        layer?.borderColor = selected
            ? GGTheme.electricBlue.withAlphaComponent(0.55).cgColor
            : (hovering ? GGTheme.cardBorderEmphasized : GGTheme.cardBorder).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        hoverArea = t
        addTrackingArea(t)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
}

/// A 1pt hairline divider (header bottom, monitor top) — the palette's
/// standard border, exactly.
final class Hairline: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = GGTheme.cardBorder.cgColor
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A tiny circular status indicator — the coral "muted" mark, the blue
/// "plug-in present" mark. Small hits of saturated color, per the theme.
final class StatusDot: NSView {
    init(color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 3
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 6) }
}

/// A compact horizontal signal meter: 20 segments, mint → amber → coral,
/// sitting in a recessed dark bed. Level is 0…1; segments light from the
/// left. Quiet at rest.
final class GGLevelMeter: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        GGTheme.inset.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: h * 0.35), xRadius: 2, yRadius: 2).fill()
        let lit = Int((min(max(level, 0), 1) * 20).rounded())
        let segs = 20
        let gap = bounds.width * 0.012
        let w = (bounds.width - gap * CGFloat(segs - 1)) / CGFloat(segs)
        for s in 0..<lit {
            let x = CGFloat(s) * (w + gap)
            let c: NSColor = s < 13 ? GGTheme.mint.withAlphaComponent(0.95)
                : s < 17 ? GGTheme.amber.withAlphaComponent(0.95)
                : GGTheme.coral.withAlphaComponent(0.95)
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: h * 0.32, width: w, height: h * 0.36),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

// MARK: - Split-track slider (quiet white bed, electric-blue fill)

/// A linear slider with a split treatment: a subdued white unfilled bed,
/// an electric-blue filled track, and a small soft-white thumb with a
/// gentle shadow — drawn from scratch (the system slider is
/// SwiftUI-hosted on this macOS, ignores cell drawing, and its track
/// is permanently system-blue).
///
/// The fill sits slightly subdued at rest and snaps to the full accent
/// while dragging — active controls glow with purpose through vivid
/// fills and sharp contrast, not big outer glows. The numeric readouts
/// stay white; the track carries the color. Keyboard focus shows a
/// thin accent ring; arrow keys adjust (⇧ for fine steps). Optional:
/// double-click resets to unity (output trim).
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

    static let trackColor = NSColor(white: 1, alpha: 0.12)   // subdued unfilled bed
    static let thumbColor = GGTheme.primary                    // small soft-white thumb
    /// Electric blue, slightly subdued at rest — the full accent while dragging.
    static let fillRest = GGTheme.electricBlue.blended(withFraction: 0.18, of: .black)
        ?? GGTheme.electricBlue
    private var isDragging = false

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
        (enabled ? Self.trackColor : NSColor(white: 1, alpha: 0.05)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
        let knobX = bar.minX + CGFloat(fraction) * bar.width
        let w = min(max(knobX - bar.minX, 0), bar.width)
        if w > 2 {
            let fill: NSColor
            if !enabled { fill = Self.fillRest.withAlphaComponent(0.35) }
            else if isDragging { fill = GGTheme.electricBlue }
            else { fill = Self.fillRest }
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY,
                                             width: w, height: h),
                         xRadius: h / 2, yRadius: h / 2).fill()
        }
        let size: CGFloat = 12
        // thumb with a small, soft black shadow
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.set()
        (enabled ? Self.thumbColor : NSColor(white: 1, alpha: 0.45)).setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - size / 2, y: bounds.midY - size / 2,
                                    width: size, height: size)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
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
        isDragging = true
        needsDisplay = true
        track(at: event)
        if sendsContinuously { send() }
        var keep = true
        while keep {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            track(at: ev)
            if ev.type == .leftMouseUp { keep = false }
            if sendsContinuously { send() }
        }
        isDragging = false
        needsDisplay = true
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

// MARK: - Function-accent controls (idle = neutral, engaged = vivid accent)

/// Base for the per-function controls. Fully custom-drawn NSButtons — the
/// cell never renders — so all states are ours:
///   OFF       the ONE shared neutral treatment (quiet fill, muted label)
///   HOVER     a restrained lift of the same neutral surface
///   ON        the function's vivid accent as a SOLID fill, near-black text
///   DISABLED  quieter than idle (no accent at all)
///   FOCUS     thin exterior ring (keyboard only)
class FunctionButton: NSButton {
    var accent: NSColor
    var hovering = false
    private var hoverArea: NSTrackingArea?

    init(tag: Int, accent: NSColor, target: AnyObject?, action: Selector) {
        self.accent = accent
        super.init(frame: .zero)
        self.tag = tag
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    var isEngaged: Bool { isEnabled && state == .on }

    /// Brighten a color (hover lift on engaged fills).
    static func lift(_ c: NSColor, _ fraction: CGFloat) -> NSColor {
        c.blended(withFraction: fraction, of: .white) ?? c
    }

    // hover: a restrained lift, same neutral family when idle
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        hoverArea = t
        addTrackingArea(t)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    // toggle on mouse-up-inside (cell tracking is bypassed entirely)
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        while true {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
            guard ev.type == .leftMouseUp else { continue }
            let p = convert(ev.locationInWindow, from: nil)
            if bounds.contains(p) {
                state = (state == .on) ? .off : .on
                _ = sendAction(action, to: target)
            }
            return
        }
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        state = (state == .on) ? .off : .on
        _ = sendAction(action, to: target)
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }
}

/// The labeled toggle (48V / SL / Ø / Mute / DIM / SUM / Include): OFF =
/// the shared neutral treatment (quiet fill, muted label), ON = the
/// function's vivid solid accent + near-black label — the color IS the
/// state indicator (no checkmark). Punchy against the dark shell
/// precisely because everything around it stays quiet.
final class FunctionToggle: FunctionButton {
    let baseTitle: String
    static let font = NSFont.systemFont(ofSize: 11)

    init(title: String, tag: Int, accent: NSColor,
         target: AnyObject?, action: Selector) {
        self.baseTitle = title
        super.init(tag: tag, accent: accent, target: target, action: action)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let s = NSAttributedString(string: baseTitle, attributes: [.font: Self.font]).size()
        return NSSize(width: ceil(s.width) + 24, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.10) : accent }
        else { fill = hovering ? GGTheme.hoverSurface : GGTheme.toggleIdleFill }
        fill.setFill()
        path.fill()
        if enabled {
            let border = engaged
                ? (accent.blended(withFraction: 0.30, of: .black) ?? accent)
                : (hovering ? NSColor(white: 1, alpha: 0.12) : GGTheme.toggleIdleBorder)
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let label = baseTitle
        let text: NSColor = !enabled ? .disabledControlTextColor
            : engaged ? GGTheme.darkText : GGTheme.toggleIdleLabel
        let attr = NSAttributedString(string: label, attributes: [.font: Self.font, .foregroundColor: text])
        let s = attr.size()
        attr.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                              y: (bounds.height - s.height) / 2 - 0.5))
    }
}

/// The small enable/bypass pill switch for plug-ins — neutral graphite
/// track when off, electric-blue track with a white knob when on.
final class FunctionSwitch: FunctionButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.10) : accent }
        else { fill = hovering ? GGTheme.hoverSurface : GGTheme.toggleIdleFill }
        fill.setFill()
        path.fill()
        if enabled {
            let border = engaged
                ? (accent.blended(withFraction: 0.30, of: .black) ?? accent)
                : (hovering ? NSColor(white: 1, alpha: 0.12) : GGTheme.toggleIdleBorder)
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let inset: CGFloat = 3
        let d = rect.height - inset * 2
        let travel = rect.width - inset * 2 - d
        let x = engaged ? rect.minX + inset + travel : rect.minX + inset
        let knob = !enabled ? NSColor(white: 1, alpha: 0.45)
            : GGTheme.primary
        knob.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: rect.minY + inset, width: d, height: d)).fill()
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
            autoGainButtons[i].isEnabled = connected && !learning
                && (mineRunning || autoRunning.isEmpty)
            // Auto Gain is an action, not a persistent state: neutral at
            // rest; while running it becomes an electric-blue "Cancel" chip.
            let agTitle = mineRunning ? "Cancel" : "Auto Gain"
            let agColor = mineRunning ? GGTheme.darkText : GGTheme.softGray
            autoGainButtons[i].bezelColor = mineRunning ? GGTheme.electricBlue : nil
            autoGainButtons[i].attributedTitle = NSAttributedString(
                string: agTitle,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: agColor])

            let micId = t.hwinMicGain[i], instId = t.hwinInstGain[i]
            gainSliders[i].isEnabled = connected && !learning && micId != nil && instId != nil && autoRunning.isEmpty
            let shown: Double
            if st.refLevel == 4 { shown = st.instGain ?? st.micGain ?? 0 }
            else { shown = st.micGain ?? st.instGain ?? 0 }
            if gainSliders[i].doubleValue != shown { gainSliders[i].doubleValue = shown }
            updateGainField(i)

            setToggle(toggles48V[i], st.phantom,
                      enabled: connected && !learning && t.hwinPhantom[i] != nil)
            setToggle(softLimitToggles[i], st.softLimit,
                      enabled: connected && !learning && t.hwinSoftLimit[i] != nil)
            setToggle(polarityToggles[i], st.polarity,
                      enabled: connected && !learning && t.hwinPolarity[i] != nil)

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
            // the plug-in's small blue presence mark in the processing well
            pluginDots[i].isHidden = !hasPlugin

            let trim = server.trim(i)
            if trimSliders[i].doubleValue != trim { trimSliders[i].doubleValue = trim }
            let text = String(format: "%+.1f dB", trim)
            if trimFields[i].stringValue != text { trimFields[i].stringValue = text }
            // white readout at rest (values stay readable); coral only as
            // the clipping warning when the trim is boosted above unity
            trimFields[i].textColor = trim > 0.01 ? GGTheme.warning : GGTheme.primary
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

            setToggle(muteToggles[o], st.mute, enabled: connected && !learning && !muteId.isEmpty)
            setToggle(dimToggles[o], st.dim, enabled: connected && !learning && dimId != nil)
            setToggle(monoToggles[o], st.sum, enabled: connected && !learning && sumId != nil)

            // Mute gets the clearest active state: filled coral button,
            // a coral "Muted" badge and its dot — the section itself
            // never turns red.
            mutedBadges[o]?.isHidden = !(st.mute ?? false)
            mutedDots[o].isHidden = !(st.mute ?? false)
            let missing = missingMonitorTargets(o)
            monLearnButtons[o].isHidden = missing.isEmpty && !isLearning
            monLearnButtons[o].isEnabled = (learning && learningColumn == .monitor(o)) || !missing.isEmpty
        }

        updateCardHighlights()
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
    private var pluginDots: [StatusDot] = []
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
    private var mutedDots: [StatusDot] = []

    private var statusField: NSTextField!
    private var subtitleField: NSTextField!
    /// The scroll area's document view (top-scroll on open).
    private var scrollDoc: NSView?

    // MARK: keyboard-shortcut selection state (see extension at file end)

    /// Card views for the input / routing grids (index 0…3) — the shortcut
    /// selection highlight drives their `selected` state (CardView owns
    /// the blue border + lifted surface).
    var inputCards: [CardView] = []
    var outputCards: [CardView] = []
    /// The card each "selected…" shortcut acts on (gain, trim, processing).
    var selectedInputIndex = 0
    var selectedOutputIndex = 0

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

        // The whole shell is ONE continuous smoked-glass material: the
        // blur view samples the desktop, the cool near-black tint (78%)
        // sits on top — wallpaper bleeds through softly, never clearly
        // enough to distract. Header + monitor add subtle framing bands
        // of the same glass; cards are translucent fills, not frosted
        // tiles, so the glass reads as one surface.
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
        w.title = "Quartet Control"
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
        // open at the TOP of the sections: the doc is NOT flipped, so its
        // origin is the bottom — scrolling to 0 shows the bottom (status
        // line) and leaves the Inputs header clipped at the top.
        content.layoutSubtreeIfNeeded()
        if let d = scrollDoc {
            d.scroll(NSPoint(x: 0, y: d.bounds.maxY))
        }
    }

    /// Title bar: title + interface subtitle on the left, toolbar on the
    /// right (settings). A subtle band of the same glass, framed by a
    /// hairline at its bottom — it blends into the window, never a
    /// separate strip.
    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = GGTheme.headerFooterTint.cgColor

        let title = NSTextField(labelWithString: "Quartet Control")
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
        settings.font = NSFont.systemFont(ofSize: 16)
        settings.toolTip = "Settings…"
        settings.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(settings)

        let divider = Hairline()
        header.addSubview(divider)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            settings.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            settings.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            // REQUIRED: close the horizontal chain (title…settings) — an
            // underconstrained header breaks the whole window's layout.
            settings.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            // comfortably-sized settings button (30 × 28)
            settings.widthAnchor.constraint(equalToConstant: 30),
            settings.heightAnchor.constraint(equalToConstant: 28),
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
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 8, right: 0)
        doc.addSubview(stack)

        // INPUTS section header: title left; Target / Duration / Auto Gain
        // All right (the batch action lives with the settings it uses).
        let autoGainAll = NSButton(title: "Auto Gain All", target: self,
                                   action: #selector(autoGainAllClicked(_:)))
        autoGainAll.bezelStyle = .rounded
        autoGainAll.controlSize = .regular
        autoGainAll.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        autoGainAll.toolTip = "Calibrate every Mic/Instrument input with the Target/Duration settings above"
        let inputsHeader = sectionHeader(
            title: "Inputs",
            trailingViews: [
                popupLabel("Target", items: AutoGainEngine.targetOptions.map {
                    (String(format: "%.0f dBFS peak", $0), $0) }, action: #selector(targetChanged(_:))),
                popupLabel("Duration", items: AutoGainEngine.listenOptions.map {
                    (String(format: "%.0f s", $0), $0) }, action: #selector(timeChanged(_:))),
                autoGainAll,
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
        scrollDoc = doc
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
            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            inputCards.append(card)
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

            // bottom row: 48V / SL / Ø — independent toggles. Neutral
            // chips at rest; engaged = the function's vivid accent fill
            // with a near-black label (amber / mint / violet).
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let tv = toggle("48V", 300 + i, GGTheme.amber)
            row.addArrangedSubview(tv)
            toggles48V.append(tv)
            let soft = toggle("SL", 400 + i, GGTheme.mint)
            row.addArrangedSubview(soft)
            softLimitToggles.append(soft)
            let pol = toggle("Ø", 500 + i, GGTheme.violet)
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
            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            outputCards.append(card)
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

            // physical output label (never hidden by custom naming) —
            // supporting metadata, so it takes the muted tone
            let phys = NSTextField(labelWithString: InsertServer.pairNames[i])
            phys.font = GGTheme.labelFont
            phys.textColor = GGTheme.muted
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

            // "Include" — the linked/mirrored-routing chip: ice cyan when
            // engaged (the mirrored pair inherits the source's processing).
            // Inside a CONSTANT-HEIGHT row: it hides for direct sources
            // but the row keeps its height, so Processing and Output Trim
            // stay aligned across all four cards.
            let inc = FunctionToggle(title: "Include", tag: 2200 + i,
                                     accent: GGTheme.iceCyan,
                                     target: self, action: #selector(includeChanged(_:)))
            inc.toolTip = "Include source processing — mirror after the source’s plug-in"
            let incRow = NSView()
            incRow.translatesAutoresizingMaskIntoConstraints = false
            incRow.heightAnchor.constraint(equalToConstant: 22).isActive = true
            incRow.addSubview(inc)
            NSLayoutConstraint.activate([
                inc.leadingAnchor.constraint(equalTo: incRow.leadingAnchor),
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

            // small blue presence mark for an inserted plug-in
            let dot = StatusDot(color: GGTheme.electricBlue)
            dot.isHidden = true
            plugRow.addArrangedSubview(dot)
            pluginDots.append(dot)

            let en = FunctionSwitch(tag: 2400 + i, accent: GGTheme.electricBlue,
                                    target: self, action: #selector(enabledChanged(_:)))
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

            // the processing well: darker than its card, like a recessed
            // slot; an inserted plug-in reads as a raised graphite pill
            // (system picker + Open) with the small blue indicator
            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.wantsLayer = true
            slot.layer?.backgroundColor = GGTheme.inset.cgColor
            slot.layer?.cornerRadius = 10
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
    /// side. A slightly darker band of the same glass material, framed by
    /// a thin top hairline — not a contrast panel. Both groups stay
    /// visually balanced; when headphones are muted only the Mute button
    /// goes coral (plus the badge + dot), never the whole section.
    private func makeMonitorStrip() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = GGTheme.headerFooterTint.cgColor

        // thin top hairline (subtle border against the routing area)
        let topDivider = Hairline()
        strip.addSubview(topDivider)

        let title = NSTextField(labelWithString: "Monitor")
        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = GGTheme.muted
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
        vDivider.layer?.backgroundColor = GGTheme.cardBorder.cgColor
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
        badge.textColor = GGTheme.coral
        badge.isHidden = true
        mutedBadges.append(badge)
        let muteDot = StatusDot(color: GGTheme.coral)
        muteDot.isHidden = true
        mutedDots.append(muteDot)
        let headRow = NSStackView(views: [head, muteDot, badge])
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

        // Mute / DIM / SUM — neutral at rest; coral / amber / electric
        // blue solid fills when engaged.
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 6
        let mute = toggle("Mute", 800 + o, GGTheme.coral)
        btnRow.addArrangedSubview(mute)
        muteToggles.append(mute)
        let dim = toggle("DIM", 900 + o, GGTheme.amber)
        btnRow.addArrangedSubview(dim)
        dimToggles.append(dim)
        let mono = toggle("SUM", 1000 + o, GGTheme.electricBlue)
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

    /// +48V / Soft Limit / Polarity toggles (per input).
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
        trimFields[i].textColor = v > 0.01 ? GGTheme.warning : GGTheme.primary
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

    /// A per-function toggle: OFF = the shared neutral treatment, ON =
    /// the function's vivid accent fill + near-black text (the color
    /// highlight IS the state), DISABLED = quieter than idle. The accent
    /// rides with the control (FunctionToggle draws all states);
    /// `setToggle` only applies live state.
    private func toggle(_ title: String, _ tag: Int,
                        _ accent: NSColor) -> FunctionToggle {
        FunctionToggle(title: title, tag: tag, accent: accent, target: self,
                       action: tag >= 700 ? #selector(monToggleChanged(_:))
                                          : #selector(inputToggleChanged(_:)))
    }

    /// Apply the live state to a function toggle (colors/shapes are the
    /// control's own).
    private func setToggle(_ b: NSButton, _ value: Bool?, enabled: Bool) {
        b.isEnabled = enabled
        b.state = (value ?? false) ? .on : .off
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

// MARK: - Keyboard-shortcut APIs (Shortcuts settings → ShortcutManager)

/// App-only shortcut targets: card selection + the per-card actions. These
/// reuse the window's existing @objc selector bodies by invoking them with
/// the real controls (the selectors decode their index from `sender.tag`),
/// so a shortcut and a mouse click run EXACTLY the same code.
extension QuartetControlController {

    /// True while the Quartet Control window is the key window — the gate
    /// for app-only shortcut bindings (AppDelegate's local event monitor).
    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    /// Show / hide the window (the global "Show / hide Quartet Control").
    func toggleShown() {
        guard let window, window.isVisible else { show(); return }
        window.orderOut(nil)
    }

    // MARK: selection

    func selectOutput(_ i: Int) {
        guard (0..<4).contains(i) else { return }
        selectedOutputIndex = i
        updateCardHighlights()
    }

    func selectInput(_ i: Int) {
        guard (0..<4).contains(i) else { return }
        selectedInputIndex = i
        updateCardHighlights()
    }

    /// Next / previous output card (wraps).
    func selectAdjacentOutput(_ delta: Int) {
        selectOutput((selectedOutputIndex + delta + 4) % 4)
    }

    /// Selection visual: the selected card gets the thin electric-blue
    /// border (≈55%) and the slightly lighter surface — CardView owns the
    /// styling; selection should look deliberate, not like every card
    /// competing for attention.
    func updateCardHighlights() {
        for (i, card) in inputCards.enumerated() {
            card.selected = i == selectedInputIndex
        }
        for (i, card) in outputCards.enumerated() {
            card.selected = i == selectedOutputIndex
        }
    }

    // MARK: outputs & routing (selected card)

    func shortcutOutputTrim(up: Bool, step: Double) {
        let i = selectedOutputIndex
        trimSliders[i].doubleValue = min(max(trimSliders[i].doubleValue + (up ? step : -step), -64), 6)
        trimSlid(trimSliders[i])
    }

    func shortcutEditOutputTrim() {
        let i = selectedOutputIndex
        window?.makeFirstResponder(trimFields[i])
        trimFields[i].selectText(nil)
    }

    func shortcutOpenSourceSelector() {
        sourcePopups[selectedOutputIndex].performClick(nil)
    }

    func shortcutToggleIncludeSource() {
        let i = selectedOutputIndex
        includeChecks[i].state = includeChecks[i].state == .on ? .off : .on
        includeChanged(includeChecks[i])
    }

    func shortcutBypassSelectedOutput() {
        let i = selectedOutputIndex
        enabledChecks[i].state = enabledChecks[i].state == .on ? .off : .on
        enabledChanged(enabledChecks[i])
    }

    func shortcutOpenSelectedPlugin() {
        InsertServer.shared.showPluginUI(selectedOutputIndex)
    }

    // MARK: inputs (selected card)

    func shortcutInputGain(up: Bool, step: Double) {
        let i = selectedInputIndex
        gainSliders[i].doubleValue = min(max(gainSliders[i].doubleValue + (up ? step : -step), 0), 75)
        gainSlid(gainSliders[i])
    }

    func shortcutEditInputGain() {
        let i = selectedInputIndex
        window?.makeFirstResponder(gainFields[i])
        gainFields[i].selectText(nil)
    }

    func shortcutAutoGainSelected() {
        autoGainClicked(autoGainButtons[selectedInputIndex])
    }

    func shortcutAutoGainAll() {
        autoGainAllClicked(autoGainButtons[0])
    }

    func shortcutCancelAutoGain() {
        AutoGainEngine.shared.cancelAll(reason: "cancelled")
        showAutoStatus("Auto Gain cancelled", clearAfter: 4)
    }

    func shortcutToggleSoftLimit() {
        let i = selectedInputIndex
        softLimitToggles[i].state = softLimitToggles[i].state == .on ? .off : .on
        inputToggleChanged(softLimitToggles[i])
    }

    func shortcutTogglePolarity() {
        let i = selectedInputIndex
        polarityToggles[i].state = polarityToggles[i].state == .on ? .off : .on
        inputToggleChanged(polarityToggles[i])
    }
}