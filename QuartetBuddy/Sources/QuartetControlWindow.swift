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
/// Visual direction: minimal + utilitarian — professional audio software,
/// not a dashboard. One flat smoked-glass window: nearly black, strong
/// macOS blur, only a subtle hint of the desktop behind it. Square
/// corners everywhere — panels, buttons, dropdowns, fields, selection
/// outlines — with thin #34373C dividers, flat surfaces only slightly
/// different from the window, no gradients, gloss, glows or decorative
/// shadows. Input panels are compact: a header (name + type dropdown)
/// over one control row — an 80-pt flat rotary knob (value inside, thin
/// green setting-arc around a 270° dark track) beside Auto Gain and a
/// row of three equal toggles. Color means state and nothing else:
/// blue for focus, selection, active slider tracks, DIM and the other
/// active functions; yellow ONLY for Soft Limit; purple ONLY for
/// polarity and SUM; red ONLY for 48V, Mute and warnings; green only in
/// meters and the knob arc. Inactive controls are neutral gray.
///
/// Plumbing is unchanged from the two windows it replaces: hardware reads
/// come from the glue tree (live 2 s poll while visible), writes go through
/// setProperty path-ids (all clamped — out-of-range writes crash the unit),
/// routing state lives in InsertServer, and Learn mode captures missing
/// ids by listening to the live event stream.

// MARK: - Theme (minimal: flat smoked glass, square geometry, restrained color)

enum GGTheme {
    // Base surfaces — flat smoked glass. The window composes to near-black
    // charcoal; panels are only slightly different from it. No gradients,
    // gloss, glows or decorative shadows — every surface is flat.

    /// Opaque fallback — the charcoal the glass composes to.
    static let windowFallback = hex("101113")
    /// Smoked-glass window tint over the strong background blur —
    /// nearly black; just a subtle hint of whatever is behind the window.
    static let windowTint = NSColor(srgbRed: 16 / 255, green: 17 / 255, blue: 19 / 255, alpha: 0.85)
    /// Title bar + monitor strip — slightly darker framing bands, same glass.
    static let headerFooterTint = NSColor(srgbRed: 16 / 255, green: 17 / 255, blue: 19 / 255, alpha: 0.55)
    /// Panels — flat, only slightly different from the main window.
    static let card = NSColor(srgbRed: 32 / 255, green: 34 / 255, blue: 38 / 255, alpha: 0.50)
    /// The selected panel — a deliberate flat lift.
    static let cardSelected = NSColor(srgbRed: 44 / 255, green: 47 / 255, blue: 52 / 255, alpha: 0.55)
    /// Borders + dividers — subtle gray.
    static let cardBorder = hex("34373C")
    /// Hovered panels — a slightly brighter neutral.
    static let cardBorderEmphasized = hex("4A4E55")
    /// Recessed areas — plug-in wells, meter beds.
    static let inset = NSColor(white: 0, alpha: 0.25)

    // Text — quiet labels, prominent values.

    /// Primary text — names, gain values, monitor levels (`#E6E8EB`).
    static let primary = hex("E6E8EB")
    /// Secondary text — labels (`#9A9FA8`).
    static let softGray = hex("9A9FA8")
    /// Muted text — supporting metadata only (`#7A808A`).
    static let muted = hex("7A808A")
    /// Red — mute + clipping warnings.
    static let warning = hex("E3636D")

    /// Near-black label ON flat accent fills.
    static let darkText = hex("101318")
    /// DISABLED function controls — dimmer than idle-but-available.
    static let subduedFill = NSColor(white: 1, alpha: 0.03)

    // Accents — color only where it means something: blue for focus /
    // selection / active tracks / DIM / everything "else" active; yellow
    // only for Soft Limit; purple only for polarity + SUM; red only for
    // 48V, Mute and warnings; green only in meters and the knob arc.

    /// Clear blue — focus, selection, active slider tracks, DIM, and the
    /// remaining active functions (Include, plug-in enable, Auto Gain).
    static let accent = hex("5294E8")
    /// Yellow — Soft Limit engaged.
    static let amber = hex("E7AE49")
    /// Purple — polarity (Ø) + SUM engaged.
    static let violet = hex("AC88FF")
    /// Red — 48V + Mute engaged; clipping warnings.
    static let red = hex("E3636D")
    /// Green — healthy signal (meters) only.
    static let green = hex("46C58A")

    // Knob — the input preamp dial.
    /// Flat, nearly black knob body.
    static let knobBody = hex("111315")
    /// Thin dark-gray track around the body.
    static let knobTrack = hex("34383C")
    /// The green value arc — the setting, not the live signal.
    static let knobArc = hex("65D98B")

    /// Idle controls — the flat neutral gray every share: quiet,
    /// clearly "clickable but off", never mistakable for an engaged function.
    static let toggleIdleFill = hex("202226")
    static let toggleIdleBorder = hex("34373C")
    static let toggleIdleLabel = hex("9A9FA8")
    /// Hover — a slightly lighter flat gray.
    static let hoverSurface = hex("282B30")
    /// Unfilled slider bed — flat neutral gray.
    static let sliderTrack = hex("2A2D31")

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

/// A flat panel: square corners, a 1pt hairline border, a background
/// only slightly different from the window. No radius, gradient, glow or
/// shadow. Hover brightens the border slightly; the SELECTED panel gets
/// a thin square blue outline. `selected` is set by the keyboard-shortcut
/// highlight.
final class CardView: NSView {
    var selected = false { didSet { restyle() } }
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func restyle() {
        layer?.backgroundColor = (selected ? GGTheme.cardSelected : GGTheme.card).cgColor
        layer?.borderColor = selected
            ? GGTheme.accent.cgColor
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

/// A tiny square status mark — the red "muted" dot, the blue
/// "plug-in present" dot. Small hits of color, only where meaningful.
final class StatusDot: NSView {
    init(color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: 5, height: 5))
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: 5, height: 5) }
}

/// A compact horizontal signal meter: 20 square segments, green → amber →
/// red, in a flat recessed bed. Level is 0…1; segments light from the
/// left. Quiet at rest.
final class GGLevelMeter: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        GGTheme.inset.setFill()
        NSBezierPath(rect: bounds.insetBy(dx: 0, dy: h * 0.35)).fill()
        let lit = Int((min(max(level, 0), 1) * 20).rounded())
        let segs = 20
        let gap = bounds.width * 0.012
        let w = (bounds.width - gap * CGFloat(segs - 1)) / CGFloat(segs)
        for s in 0..<lit {
            let x = CGFloat(s) * (w + gap)
            let c: NSColor = s < 13 ? GGTheme.green
                : s < 17 ? GGTheme.amber
                : GGTheme.red
            c.setFill()
            NSBezierPath(rect: NSRect(x: x, y: h * 0.32, width: w, height: h * 0.36)).fill()
        }
    }
}

// MARK: - Slider (thin track, small square handle, flat blue fill)

/// A linear slider drawn from scratch (the system slider is
/// SwiftUI-hosted on this macOS, ignores cell drawing, and its track is
/// permanently system-blue): a thin flat neutral bed, a flat blue fill
/// up to the knob, and a small square handle. No rounded ends, no
/// shadows, no glow — the geometry carries it. Keyboard focus shows a
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

    static let thumbColor = GGTheme.primary   // small, simple handle

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
        let h: CGFloat = 3
        let bar = NSRect(x: 0, y: bounds.midY - h / 2, width: bounds.width, height: h)
        (enabled ? GGTheme.sliderTrack : NSColor(white: 1, alpha: 0.05)).setFill()
        NSBezierPath(rect: bar).fill()
        let knobX = bar.minX + CGFloat(fraction) * bar.width
        let w = min(max(knobX - bar.minX, 0), bar.width)
        if w > 1 {
            let fill = !enabled ? GGTheme.accent.withAlphaComponent(0.35) : GGTheme.accent
            fill.setFill()
            NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: w, height: h)).fill()
        }
        let size: CGFloat = 10
        (enabled ? Self.thumbColor : NSColor(white: 1, alpha: 0.40)).setFill()
        NSBezierPath(roundedRect: NSRect(x: knobX - size / 2, y: bounds.midY - size / 2,
                                         width: size, height: size),
                     xRadius: 2, yRadius: 2).fill()
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

// MARK: - Gain knob (flat dial: value inside, green arc around)

/// A flat rotary knob — the input preamp control. Nearly black circular
/// body with a subtle dark-gray outline, the gain value centered inside
/// (off-white, tabular numerals) and a smaller muted "dB" beneath it.
/// Around the body, separated by a small consistent gap, a thin 270°
/// dark-gray track — starting at 7:30, clockwise through the left side
/// and the top, ending at 4:30 — with a flat green arc that grows
/// clockwise from the lower-left as the value rises (midpoint = 12
/// o'clock, full = the whole track). The arc shows the SETTING, not the
/// live signal. No pointer, tick marks, shadows, gradients or glow.
///
/// Interaction: drag vertically (up = more, ⇧ = fine), arrow keys adjust
/// (⇧ fine), double-click to type an exact value into an inline editor
/// (`valueField` — same tag + delegate the old numeric field used).
final class GainKnob: NSControl {

    var minValue: Double = 0 { didSet { _value = min(max(_value, minValue), maxValue); needsDisplay = true } }
    var maxValue: Double = 75 { didSet { _value = min(max(_value, minValue), maxValue); needsDisplay = true } }
    var sendsContinuously = true
    /// False while no gain is known (device offline) — draws "—", no arc.
    var hasValue = true { didSet { needsDisplay = true } }

    private var _value: Double = 0
    override var doubleValue: Double {
        get { _value }
        set { _value = min(max(newValue, minValue), maxValue); needsDisplay = true }
    }

    /// The inline precise-entry field (double-click). The controller
    /// wires it with the old numeric field's tag + delegate.
    let valueField = NSTextField()
    private var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior   // thin accent outline, keyboard focus only
        valueField.isHidden = true
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.alignment = .center
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = GGTheme.primary
        valueField.toolTip = "Preamp gain — double-click the knob to type an exact value"
        valueField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueField)
        NSLayoutConstraint.activate([
            valueField.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 5),
            valueField.widthAnchor.constraint(equalToConstant: 64),
            valueField.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 80) }
    override var acceptsFirstResponder: Bool { isEnabled }

    // MARK: geometry
    private static let bodyRadius: CGFloat = 30
    private static let trackRadius: CGFloat = 37
    private static let stroke: CGFloat = 3
    /// Track: start 7:30 (225°), sweep 270° clockwise to 4:30 (-45°).
    private static let startAngle: CGFloat = 225
    private static let sweepAngle: CGFloat = 270

    private var fraction: Double {
        maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
    }
    @discardableResult
    private func send() -> Bool { sendAction(action, to: target) }

    // MARK: drawing
    override func draw(_ dirtyRect: NSRect) {
        let enabled = isEnabled
        let alpha: CGFloat = enabled ? 1 : 0.45
        let c = NSPoint(x: bounds.midX, y: bounds.midY)

        func arc(_ sweep: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: Self.trackRadius,
                        startAngle: Self.startAngle,
                        endAngle: Self.startAngle - sweep, clockwise: true)
            p.lineWidth = Self.stroke
            p.lineCapStyle = .butt
            return p
        }

        // surrounding track
        GGTheme.knobTrack.withAlphaComponent(alpha).setStroke()
        arc(Self.sweepAngle).stroke()

        // green value arc — clockwise from the lower-left start
        let f = hasValue ? fraction : 0
        if f > 0.002 {
            GGTheme.knobArc.withAlphaComponent(alpha).setStroke()
            arc(CGFloat(f) * Self.sweepAngle).stroke()
        }

        // flat body with a subtle dark-gray outline
        let bodyRect = NSRect(x: c.x - Self.bodyRadius, y: c.y - Self.bodyRadius,
                               width: Self.bodyRadius * 2, height: Self.bodyRadius * 2)
        let body = NSBezierPath(ovalIn: bodyRect)
        GGTheme.knobBody.setFill()
        body.fill()
        GGTheme.knobTrack.withAlphaComponent(alpha).setStroke()
        body.lineWidth = 1
        body.stroke()

        guard !isEditing else { return }

        if hasValue {
            let value = NSAttributedString(
                string: String(format: "%.1f", doubleValue),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: GGTheme.primary.withAlphaComponent(enabled ? 1 : 0.5)])
            let vs = value.size()
            value.draw(at: NSPoint(x: c.x - vs.width / 2, y: c.y + 5 - vs.height / 2))
            let unit = NSAttributedString(
                string: "dB",
                attributes: [.font: NSFont.systemFont(ofSize: 8),
                             .foregroundColor: GGTheme.muted.withAlphaComponent(enabled ? 1 : 0.5)])
            let us = unit.size()
            unit.draw(at: NSPoint(x: c.x - us.width / 2, y: c.y - 6 - us.height / 2))
        } else {
            let dash = NSAttributedString(
                string: "—",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: GGTheme.muted])
            let ds = dash.size()
            dash.draw(at: NSPoint(x: c.x - ds.width / 2, y: c.y - ds.height / 2))
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }

    // MARK: precise entry (double-click the number)
    func beginEditing() {
        guard isEnabled, !isEditing, let window else { return }
        isEditing = true
        valueField.stringValue = String(format: "%.1f", doubleValue)
        valueField.isHidden = false
        needsDisplay = true
        window.makeFirstResponder(valueField)
        valueField.selectText(nil)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        if valueField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
        valueField.isHidden = true
        needsDisplay = true
    }

    // MARK: mouse (vertical drag; ⇧ = fine; double-click → type a value)
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount >= 2 {
            beginEditing()
            return
        }
        var lastY = event.locationInWindow.y
        var keep = true
        while keep {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch ev.type {
            case .leftMouseDragged:
                let dy = ev.locationInWindow.y - lastY
                lastY = ev.locationInWindow.y
                let fine = ev.modifierFlags.contains(.shift)
                let step = (maxValue - minValue) / (fine ? 400 : 120)
                doubleValue += Double(dy) * step
                if sendsContinuously { send() }
            default:
                keep = false
            }
        }
        send()
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

// MARK: - Function-accent controls (idle = flat neutral gray, engaged = flat accent)

/// Base for the per-function controls. Fully custom-drawn NSButtons — the
/// cell never renders — so all states are ours:
///   OFF       the ONE shared flat neutral treatment (gray fill, gray label)
///   HOVER     a slightly lighter flat gray — no color creep
///   ON        the function's accent as a FLAT solid fill, near-black text
///   DISABLED  dimmer than idle (no accent at all)
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
/// the shared flat neutral gray, ON = the function's flat accent fill +
/// near-black label — the color IS the state indicator (no checkmark).
/// Square corners, compact height, no pill shapes.
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
        let path = NSBezierPath(rect: rect)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.08) : accent }
        else { fill = hovering ? GGTheme.hoverSurface : GGTheme.toggleIdleFill }
        fill.setFill()
        path.fill()
        if enabled {
            let border = engaged
                ? (accent.blended(withFraction: 0.30, of: .black) ?? accent)
                : (hovering ? GGTheme.cardBorderEmphasized : GGTheme.toggleIdleBorder)
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

/// The small enable/bypass switch for plug-ins — flat neutral gray track
/// when off, flat blue track with a small square knob when on. No pill.
final class FunctionSwitch: FunctionButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.08) : accent }
        else { fill = hovering ? GGTheme.hoverSurface : GGTheme.toggleIdleFill }
        fill.setFill()
        path.fill()
        if enabled {
            let border = engaged
                ? (accent.blended(withFraction: 0.30, of: .black) ?? accent)
                : (hovering ? GGTheme.cardBorderEmphasized : GGTheme.toggleIdleBorder)
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
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + inset, width: d, height: d),
                     xRadius: 1, yRadius: 1).fill()
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
            // Instrument; the meter + knob hide at the line levels.
            gainKnobs[i].isHidden = lineMode
            meters[i].isHidden = lineMode
            autoGainButtons[i].isHidden = lineMode
            toggles48V[i].isHidden = lineMode || st.refLevel == 4

            let mineRunning = autoRunning.contains(i)
            autoGainButtons[i].isEnabled = connected && !learning
                && (mineRunning || autoRunning.isEmpty)
            // Auto Gain is an action, not a persistent state: neutral at
            // rest; while running it becomes a flat blue "Cancel" chip.
            let agTitle = mineRunning ? "Cancel" : "Auto Gain"
            let agColor = mineRunning ? GGTheme.darkText : GGTheme.softGray
            autoGainButtons[i].bezelColor = mineRunning ? GGTheme.accent : nil
            autoGainButtons[i].attributedTitle = NSAttributedString(
                string: agTitle,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: agColor])

            let micId = t.hwinMicGain[i], instId = t.hwinInstGain[i]
            gainKnobs[i].isEnabled = connected && !learning && micId != nil && instId != nil && autoRunning.isEmpty
            let shown: Double
            if st.refLevel == 4 { shown = st.instGain ?? st.micGain ?? 0 }
            else { shown = st.micGain ?? st.instGain ?? 0 }
            if gainKnobs[i].doubleValue != shown { gainKnobs[i].doubleValue = shown }
            gainKnobs[i].hasValue = st.micGain != nil || st.instGain != nil
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
            // off-white readout at rest (values stay readable); red only as
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

            // Mute gets the clearest active state: filled red button,
            // a red "Muted" badge and its dot — the section itself
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
    private var gainKnobs: [GainKnob] = []
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
    /// Shared card width for BOTH grids (input panels + routing cards) —
    /// the knob panel is ~300 px wide; 4 columns + 16-pt gaps must fit
    /// the window's minimum width.
    private let cardWidth: CGFloat = 300

    private func build() {
        // Window: one resizable 1200×820 workspace.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 760))

        // The whole shell is ONE flat smoked-glass surface: the blur view
        // samples the desktop behind a strong system blur, the nearly
        // black tint (85%) sits on top — only a subtle hint of the
        // wallpaper reads through. Header + monitor are slightly darker
        // bands of the same glass, framed by hairlines; panels are flat
        // fills only slightly different from the window.
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
        // minimum: all four 300-pt panels + gaps + margins must fit —
        // the pinned column widths are hard requirements, not wishes
        w.minSize = NSSize(width: 1290, height: 620)
        window = w
        // default size 1,300 × 760 — NSWindow sizes to the contentView's
        // fitting size otherwise, and the intrinsic size is tiny
        w.setContentSize(NSSize(width: 1300, height: 760))
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
        square(settings)
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
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 900))
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
        square(autoGainAll)
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
        square(p)
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
            col.spacing = 14
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14),
            ])

            // HEADER — input name left, compact type dropdown right
            let head = NSTextField(labelWithString: "Analog In \(i + 1)")
            head.font = GGTheme.nameFont
            head.textColor = GGTheme.primary
            head.lineBreakMode = .byTruncatingTail
            inputHeaders.append(head)

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
            square(p)
            p.widthAnchor.constraint(equalToConstant: 132).isActive = true
            levelPopups.append(p)

            let headerRow = NSStackView()
            headerRow.orientation = .horizontal
            headerRow.alignment = .centerY
            headerRow.spacing = 8
            headerRow.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addArrangedSubview(head)
            let headerSpacer = NSView()
            headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            headerRow.addArrangedSubview(headerSpacer)
            headerRow.addArrangedSubview(p)
            headerRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            col.addArrangedSubview(headerRow)

            // thin signal meter between the header and the controls
            let meter = GGLevelMeter()
            meter.heightAnchor.constraint(equalToConstant: 8).isActive = true
            meter.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            col.addArrangedSubview(meter)
            meters.append(meter)

            // CONTROL ROW — knob left, Auto Gain + toggles right
            let knob = GainKnob()
            knob.minValue = 0
            knob.maxValue = 75
            knob.doubleValue = 0
            knob.target = self
            knob.action = #selector(gainSlid(_:))
            knob.tag = 200 + i
            knob.sendsContinuously = true
            knob.widthAnchor.constraint(equalToConstant: 80).isActive = true
            knob.heightAnchor.constraint(equalToConstant: 80).isActive = true
            gainKnobs.append(knob)

            // precise entry: the knob's inline editor carries the old
            // numeric field's tag + delegate, so commit runs the same code
            knob.valueField.tag = 250 + i
            knob.valueField.delegate = self
            gainFields.append(knob.valueField)

            let ag = NSButton(title: "Auto Gain", target: self,
                              action: #selector(autoGainClicked(_:)))
            ag.tag = 1200 + i
            square(ag)
            ag.controlSize = .small
            ag.font = NSFont.systemFont(ofSize: 11)
            ag.widthAnchor.constraint(equalToConstant: 168).isActive = true
            ag.heightAnchor.constraint(equalToConstant: 28).isActive = true
            autoGainButtons.append(ag)

            // one row of three equally sized toggles — 48V / SL / Ø.
            // Flat neutral chips at rest; engaged = the function's flat
            // accent fill with a near-black label (red / yellow / purple).
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 168).isActive = true
            func chip(_ title: String, _ tag: Int, _ accent: NSColor, _ tip: String) -> FunctionToggle {
                let t = toggle(title, tag, accent)
                t.widthAnchor.constraint(equalToConstant: 52).isActive = true
                t.heightAnchor.constraint(equalToConstant: 28).isActive = true
                t.toolTip = tip
                return t
            }
            let tv = chip("48V", 300 + i, GGTheme.red, "+48V phantom power")
            row.addArrangedSubview(tv)
            toggles48V.append(tv)
            let soft = chip("SL", 400 + i, GGTheme.amber, "Soft Limit")
            row.addArrangedSubview(soft)
            softLimitToggles.append(soft)
            let pol = chip("Ø", 500 + i, GGTheme.violet, "Invert polarity")
            row.addArrangedSubview(pol)
            polarityToggles.append(pol)

            let right = NSStackView()
            right.orientation = .vertical
            right.spacing = 8
            right.translatesAutoresizingMaskIntoConstraints = false
            right.widthAnchor.constraint(equalToConstant: 168).isActive = true
            right.addArrangedSubview(ag)
            right.addArrangedSubview(row)

            let controlRow = NSStackView()
            controlRow.orientation = .horizontal
            controlRow.alignment = .centerY
            controlRow.spacing = 24
            controlRow.translatesAutoresizingMaskIntoConstraints = false
            controlRow.addArrangedSubview(knob)
            controlRow.addArrangedSubview(right)
            controlRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            col.addArrangedSubview(controlRow)

            // learn fallback (only when ids are missing)
            let lb = NSButton(title: "Learn…", target: self, action: #selector(learnClicked(_:)))
            lb.tag = 600 + i
            square(lb)
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
            square(sp)
            col.addArrangedSubview(sp)
            sourcePopups.append(sp)

            // "Include" — the linked/mirrored-routing chip: flat blue when
            // engaged (the mirrored pair inherits the source's processing).
            // Inside a CONSTANT-HEIGHT row: it hides for direct sources
            // but the row keeps its height, so Processing and Output Trim
            // stay aligned across all four cards.
            let inc = FunctionToggle(title: "Include", tag: 2200 + i,
                                     accent: GGTheme.accent,
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
            let dot = StatusDot(color: GGTheme.accent)
            dot.isHidden = true
            plugRow.addArrangedSubview(dot)
            pluginDots.append(dot)

            let en = FunctionSwitch(tag: 2400 + i, accent: GGTheme.accent,
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
            square(pp)
            plugRow.addArrangedSubview(pp)
            pluginPopups.append(pp)

            let open = NSButton(title: "Open", target: self,
                                action: #selector(rowEditorOpened(_:)))
            open.tag = 2450 + i
            square(open)
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
            square(add)
            add.controlSize = .small
            add.font = NSFont.systemFont(ofSize: 11)
            plugRow.addArrangedSubview(add)
            addPluginButtons.append(add)

            // the processing well: a flat recessed slot, darker than its
            // panel and square, like a cut-out; an inserted plug-in reads
            // as the picker + Open row with the small blue indicator
            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.wantsLayer = true
            slot.layer?.backgroundColor = GGTheme.inset.cgColor
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
    /// goes red (plus the badge + dot), never the whole section.
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
        badge.textColor = GGTheme.red
        badge.isHidden = true
        mutedBadges.append(badge)
        let muteDot = StatusDot(color: GGTheme.red)
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

        // Mute / DIM / SUM — flat neutral gray at rest; red / blue / purple
        // flat fills when engaged.
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 6
        let mute = toggle("Mute", 800 + o, GGTheme.red)
        btnRow.addArrangedSubview(mute)
        muteToggles.append(mute)
        let dim = toggle("DIM", 900 + o, GGTheme.accent)
        btnRow.addArrangedSubview(dim)
        dimToggles.append(dim)
        let mono = toggle("SUM", 1000 + o, GGTheme.violet)
        btnRow.addArrangedSubview(mono)
        monoToggles.append(mono)

        let learn = NSButton(title: "Learn…", target: self, action: #selector(learnClicked(_:)))
        learn.tag = 1100 + o
        square(learn)
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

    /// The gain editor (the knob's inline field) shows the ACTIVE
    /// mode's gain only — "32.0", never a "M x · I y" pair. Skipped
    /// while the user is typing (a live poll must not clobber the edit).
    private func updateGainField(_ i: Int) {
        let st = inputs[i]
        var text = "—"
        if st.refLevel == 4 {
            if let inst = st.instGain { text = String(format: "%.1f", inst) }
        } else if let m = st.micGain {
            text = String(format: "%.1f", m)
        }
        guard gainFields[i].currentEditor() == nil else { return }
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
            // input gain (dB) — the knob's inline editor, active mode only
            let i = field.tag - 250
            defer { gainKnobs[i].endEditing() }
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

    /// A per-function toggle: OFF = the shared flat neutral gray, ON =
    /// the function's flat accent fill + near-black text (the color IS
    /// the state), DISABLED = dimmer than idle. The accent rides with
    /// the control (FunctionToggle draws all states); `setToggle` only
    /// applies live state.
    private func toggle(_ title: String, _ tag: Int,
                        _ accent: NSColor) -> FunctionToggle {
        FunctionToggle(title: title, tag: tag, accent: accent, target: self,
                       action: tag >= 700 ? #selector(monToggleChanged(_:))
                                          : #selector(inputToggleChanged(_:)))
    }

    /// Square, flat system bezel — the geometry for every button in the
    /// window (native rendering, no custom drawing, no rounded corners).
    private func square(_ b: NSButton) {
        b.bezelStyle = .shadowlessSquare
    }

    /// Same for dropdowns: square-edged popups instead of the rounded
    /// default bezel.
    private func square(_ p: NSPopUpButton) {
        (p.cell as? NSButtonCell)?.bezelStyle = .shadowlessSquare
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

    /// Selection visual: the selected panel gets the thin square blue
    /// outline and a slightly lighter flat surface — CardView owns the
    /// styling; selection should look deliberate, not like every panel
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
        gainKnobs[i].doubleValue = min(max(gainKnobs[i].doubleValue + (up ? step : -step), 0), 75)
        gainSlid(gainKnobs[i])
    }

    func shortcutEditInputGain() {
        gainKnobs[selectedInputIndex].beginEditing()
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