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
/// Visual direction: NATIVE macOS — a standard Golden Gate window, not a
/// custom glass dashboard. Standard window frame, traffic lights, system
/// corner radius, unified title bar (device name + connection quiet), one
/// dark standard background material with subtle behind-window blur —
/// and native popups, buttons, fields everywhere, keeping their system
/// appearance. Channels are NOT floating cards: four equal columns per
/// section, separated by thin vertical rules and spacing. Channel
/// SELECTION is the header: click the name to select the strip — a thin
/// accent marker appears beside the title; the panel itself never
/// changes (no border, no tint). The separate "Learn…" button (only
/// present when ids are missing) stays its own distinct action. The
/// custom element is the KNOB (input gain, output trim, monitor level):
/// flat, no body circle — a thin subdued 270° track with the opening at
/// the bottom, a flat green value arc (the SETTING, not live signal)
/// growing clockwise from 7:30, and ONLY the whole-number value (12pt)
/// centered inside — no "dB" — with precise entry by double-click.
/// Color is meaning:
/// system accent for focus/selection and the neutral functions (Ø, SUM,
/// Include, plug-in enable); green only for Soft Limit + the arcs;
/// amber for 48V/DIM; red for Mute + clipping. Everything else is quiet.
///
/// Plumbing is unchanged from the two windows it replaces: hardware reads
/// come from the glue tree (live 2 s poll while visible), writes go through
/// setProperty path-ids (all clamped — out-of-range writes crash the unit),
/// routing state lives in InsertServer, and Learn mode captures missing
/// ids by listening to the live event stream.

// MARK: - Theme (native macOS: system colors + a few app accents)

enum GGTheme {
    // Text — the system label hierarchy (dark appearance in effect).

    /// Primary text — names, values, titles.
    static let primary = NSColor.labelColor
    /// Secondary text — labels.
    static let softGray = NSColor.secondaryLabelColor
    /// Muted text — supporting metadata only.
    static let muted = NSColor.tertiaryLabelColor

    /// The ONE interaction color — the system accent (focus, selection,
    /// and the neutral active functions: Ø, SUM, Include, plug-in enable,
    /// Auto Gain running).
    static let accent = NSColor.controlAccentColor

    // Function accents — flat fills when engaged, neutral otherwise.

    /// Cyan — Soft Limit engaged.
    static let cyan = hex("50D8F4")
    /// Green — healthy-signal meters; Talkback active.
    static let green = hex("46C58A")
    /// Amber — 48V + DIM engaged.
    static let amber = hex("E7AE49")
    /// Red — Mute engaged, global mute, clipping warnings.
    static let red = hex("E3636D")
    static let warning = red

    /// Near-black label ON flat accent fills.
    static let darkText = hex("101318")

    // Knob — the app's one custom control.

    /// Thin, subdued 270° track — the system separator gray.
    static let knobTrack = NSColor.separatorColor
    /// The green value arc — the setting, not the live signal.
    static let knobArc = hex("65D98B")

    // Idle custom controls — quiet, system-adjacent neutrals.

    static let idleFill = NSColor(white: 1, alpha: 0.08)
    static let idleBorder = NSColor.separatorColor
    static let idleLabel = NSColor.secondaryLabelColor
    static let hoverFill = NSColor(white: 1, alpha: 0.13)
    /// DISABLED function controls — dimmer than idle-but-available.
    static let subduedFill = NSColor(white: 1, alpha: 0.04)
    /// Recessed areas — plug-in well, meter bed.
    static let inset = NSColor(white: 0, alpha: 0.18)

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

    static let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    static let sectionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let labelFont = NSFont.systemFont(ofSize: 11)
}

/// A borderless channel-strip container. Native direction: channels are
/// separated by thin vertical rules and spacing — no floating cards, no
/// heavy outlines. Selection never touches the panel: it's shown by a
/// thin accent marker beside the strip's header (see updateCardHighlights).
final class CardView: NSView {}

/// A 1pt hairline divider — the system separator, exactly.
final class Hairline: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A title that becomes an editable field on double-click — NOT a text
/// box. Plain title text and an arrow cursor until the second click
/// starts editing (the system focus ring shows the editing state).
/// A SINGLE click selects the strip (see `onClick`).
final class TitleField: NSTextField {
    /// Single-click selects the channel strip.
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        onClick?()   // single click: select the strip
        guard event.clickCount >= 2 else { return }   // double click: edit
        isEditable = true
        isSelectable = true
        super.mouseDown(with: event)   // begins editing
        // safety: if editing didn't engage, revert to title mode
        if currentEditor() == nil {
            isEditable = false
            isSelectable = false
        }
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditable = false
        isSelectable = false
    }
}

/// A read-only channel title that SELECTS its strip on any click
/// (input names — they come from the hardware, so there's nothing to
/// edit; the click is pure selection).
final class SelectLabel: NSTextField {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A small monochrome glyph beside a monitor group's title — speaker
/// (Main Speakers) or headphones. 14pt, quiet secondary color.
final class TinyGlyphView: NSView {
    enum Glyph { case speaker, headphones }
    private let glyph: Glyph

    init(_ glyph: Glyph) {
        self.glyph = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }
    override func draw(_ dirtyRect: NSRect) {
        let color = GGTheme.softGray
        let u = bounds.width / 16
        let ox = bounds.midX - 8 * u, oy = bounds.midY - 8 * u
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
        color.setFill()
        color.setStroke()
        switch glyph {
        case .speaker:
            // classic speaker + one sound wave (after flaticon
            // speaker_650504), optically centered in the 16-space
            NSBezierPath(rect: NSRect(x: ox + 2.5 * u, y: oy + 6 * u,
                                      width: 3 * u, height: 4 * u)).fill()
            let cone = NSBezierPath()
            cone.move(to: pt(5.5, 6.5))
            cone.line(to: pt(5.5, 9.5))
            cone.line(to: pt(9, 11.5))
            cone.line(to: pt(9, 4.5))
            cone.close()
            cone.fill()
            let wave = NSBezierPath()
            wave.appendArc(withCenter: pt(9.5, 8), radius: 3.5 * u,
                           startAngle: -35, endAngle: 35, clockwise: false)
            wave.lineWidth = 1.3 * u
            wave.lineCapStyle = .round
            wave.stroke()
        case .headphones:
            // band over the top + two ear pads
            let band = NSBezierPath()
            band.appendArc(withCenter: pt(8, 8.5), radius: 6 * u,
                           startAngle: 20, endAngle: 160, clockwise: false)
            band.lineWidth = 1.6 * u
            band.lineCapStyle = .round
            band.stroke()
            NSBezierPath(roundedRect: NSRect(x: ox + 0.5 * u, y: oy + 3.5 * u,
                                             width: 3 * u, height: 5 * u),
                         xRadius: 1.4 * u, yRadius: 1.4 * u).fill()
            NSBezierPath(roundedRect: NSRect(x: ox + 12.5 * u, y: oy + 3.5 * u,
                                             width: 3 * u, height: 5 * u),
                         xRadius: 1.4 * u, yRadius: 1.4 * u).fill()
        }
    }
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

// MARK: - Knob (thin dial arc, just the number inside)

/// The app's one custom control — a flat dial used for input gain,
/// output trim and monitor level, ONE compact size everywhere (52pt —
/// as tall as the Auto Gain + toggle block beside it): a thin, subdued
/// 270° track (start 7:30, clockwise through left and top to 4:30 — a
/// small opening at the bottom) with a flat green value arc growing
/// clockwise from the lower-left as the value rises (midpoint = 12
/// o'clock, full = the whole track). The arc shows the SETTING, not
/// the live signal. Inside: ONLY the whole-number value — 12pt tabular
/// numerals, centered — no knob body, no "dB". No gradients, bevels,
/// glow or decorative shadows; the whole control area is the drag
/// target.
///
/// Interaction: drag vertically (up = more, ⇧ = slower), arrow keys step
/// ±1, double-click the number to type an exact value into an inline
/// editor (`valueField` — the editor is the precise path; typed
/// decimals still reach the hardware).
final class GainKnob: NSControl {

    var minValue: Double = 0 { didSet { _value = (min(max(_value, minValue), maxValue)).rounded(); needsDisplay = true } }
    var maxValue: Double = 75 { didSet { _value = (min(max(_value, minValue), maxValue)).rounded(); needsDisplay = true } }
    var sendsContinuously = true
    /// False while no value is known (device offline) — draws "—".
    var hasValue = true { didSet { needsDisplay = true } }
    /// Monitor knobs are larger and ALSO show a small "dB" beneath the
    /// value; gain/trim knobs show only the number.
    var showsUnit = false {
        didSet {
            editorY?.constant = showsUnit ? 4 : 3
            needsDisplay = true
        }
    }
    /// Optional override tint for the value text — e.g. red as the clip
    /// warning on positive output trim.
    var valueTint: NSColor? { didSet { needsDisplay = true } }

    private var _value: Double = 0
    /// Values are WHOLE numbers — the setter rounds (display + writes).
    override var doubleValue: Double {
        get { _value }
        set { _value = (min(max(newValue, minValue), maxValue)).rounded(); needsDisplay = true }
    }

    /// The inline precise-entry field (double-click). The controller
    /// wires it with a tag + delegate matching the numeric field each
    /// knob replaces.
    let valueField = NSTextField()
    private var isEditing = false
    private var editorY: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior   // thin accent outline, keyboard focus only
        valueField.isHidden = true
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.alignment = .center
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueField.textColor = GGTheme.primary
        valueField.toolTip = "Double-click the knob to type an exact value"
        valueField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueField)
        editorY = valueField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3)
        NSLayoutConstraint.activate([
            valueField.centerXAnchor.constraint(equalTo: centerXAnchor),
            editorY!,
            valueField.widthAnchor.constraint(equalToConstant: 44),
            valueField.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ONE size everywhere — as tall as the Auto Gain + toggle block it
    /// sits beside (24 + 6 + 22 = 52).
    override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }
    override var acceptsFirstResponder: Bool { isEnabled }

    @discardableResult
    private func send() -> Bool { sendAction(action, to: target) }

    // MARK: geometry — the 270° dial scales with bounds
    private var trackRadius: CGFloat { bounds.width / 2 - 1.5 }
    private static let stroke: CGFloat = 2.5
    /// Track: start 7:30 (225°), sweep 270° clockwise to 4:30 (-45°).
    private static let startAngle: CGFloat = 225
    private static let sweepAngle: CGFloat = 270

    private var fraction: Double {
        maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
    }

    // MARK: drawing — the dial arcs + ONLY the number inside (no dB)
    override func draw(_ dirtyRect: NSRect) {
        let enabled = isEnabled
        let alpha: CGFloat = enabled ? 1 : 0.45
        let c = NSPoint(x: bounds.midX, y: bounds.midY)

        func arc(_ sweep: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: trackRadius,
                        startAngle: Self.startAngle,
                        endAngle: Self.startAngle - sweep, clockwise: true)
            p.lineWidth = Self.stroke
            p.lineCapStyle = .butt
            return p
        }

        // subdued track + green value arc — the SETTING, not live signal
        GGTheme.knobTrack.withAlphaComponent(alpha).setStroke()
        arc(Self.sweepAngle).stroke()
        let f = hasValue ? fraction : 0
        if f > 0.002 {
            GGTheme.knobArc.withAlphaComponent(alpha).setStroke()
            arc(CGFloat(f) * Self.sweepAngle).stroke()
        }

        guard !isEditing else { return }

        // the number — 12pt centered (gain/trim), or 13pt with a small
        // "dB" beneath it (the larger monitor knobs)
        let text: NSColor = hasValue
            ? (valueTint ?? GGTheme.primary)
            : GGTheme.muted
        let value = NSAttributedString(
            string: hasValue ? String(format: "%.0f", doubleValue) : "—",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: showsUnit ? 13 : 12, weight: .medium),
                         .foregroundColor: text.withAlphaComponent(enabled ? 1 : 0.5)])
        let vs = value.size()
        value.draw(at: NSPoint(x: c.x - vs.width / 2,
                               y: c.y + (showsUnit ? 4 : 0) - vs.height / 2))
        if showsUnit, hasValue {
            let unit = NSAttributedString(
                string: "dB",
                attributes: [.font: NSFont.systemFont(ofSize: 8),
                             .foregroundColor: GGTheme.muted.withAlphaComponent(enabled ? 1 : 0.5)])
            let us = unit.size()
            unit.draw(at: NSPoint(x: c.x - us.width / 2, y: c.y - 5 - us.height / 2))
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }

    // MARK: precise entry (double-click the number)
    func beginEditing() {
        guard isEnabled, !isEditing, let window else { return }
        isEditing = true
        valueField.stringValue = String(format: "%.0f", doubleValue)
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

    // MARK: mouse (vertical drag; ⇧ = slow; double-click → type a value)
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
                let rate = (maxValue - minValue) / (fine ? 320 : 110)
                doubleValue += Double(dy) * rate   // setter rounds to whole
                if sendsContinuously { send() }
            default:
                keep = false
            }
        }
        send()
    }

    // MARK: keyboard (±1 whole steps)
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        switch event.specialKey {
        case .leftArrow, .downArrow:
            doubleValue -= 1
            send()
        case .rightArrow, .upArrow:
            doubleValue += 1
            send()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: scroll wheel — hover + scroll adjusts
    //   mouse wheel: INVERTED direction (wheel down = more), ~1 dB per notch
    //   trackpad:    natural direction (up = more); precise deltas accumulate
    //                to a whole step (values are whole numbers)
    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, !isEditing else { super.scrollWheel(with: event); return }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        var threshold = 8.0
        if event.hasPreciseScrollingDeltas {
            scrollAccum += Double(dy)
        } else {
            // classic mouse wheel: inverted, and one notch ≈ one step —
            // wheels report small non-precise deltas, so a low threshold
            // (not the trackpad's) is what makes the wheel FEEL working
            let d = Double(-dy)
            scrollAccum += min(max(d, -3), 3)
            threshold = 1.0
        }
        while abs(scrollAccum) >= threshold {
            let dir = scrollAccum > 0 ? 1.0 : -1.0
            doubleValue += dir
            scrollAccum -= dir * threshold
            send()
        }
    }
    private var scrollAccum: Double = 0
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

    /// NSButton draws in a FLIPPED coordinate system (y grows downward);
    /// our glyph math (the power symbol, arc angles) is written y-up like
    /// the knob's. Draw y-up here — paths and centered text are unaffected.
    override var isFlipped: Bool { false }

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
/// the shared flat neutral treatment, ON = the function's flat accent
/// fill + near-black label — the color IS the state indicator (no
/// checkmark). Compact, rounded like a native small button.
final class FunctionToggle: FunctionButton {
    let baseTitle: String
    /// Glyph buttons (M / D / ∑) draw larger; text chips keep the default.
    var titleFont: NSFont = NSFont.systemFont(ofSize: 11)

    init(title: String, tag: Int, accent: NSColor,
         target: AnyObject?, action: Selector) {
        self.baseTitle = title
        super.init(tag: tag, accent: accent, target: target, action: action)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let s = NSAttributedString(string: baseTitle, attributes: [.font: titleFont]).size()
        return NSSize(width: ceil(s.width) + 18, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.08) : accent }
        else { fill = hovering ? GGTheme.hoverFill : GGTheme.idleFill }
        fill.setFill()
        path.fill()
        if enabled, !engaged {
            let border = hovering ? GGTheme.idleBorder.withAlphaComponent(0.8) : GGTheme.idleBorder
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let label = baseTitle
        let text: NSColor = !enabled ? .disabledControlTextColor
            : engaged ? GGTheme.darkText : GGTheme.idleLabel
        let attr = NSAttributedString(string: label, attributes: [.font: titleFont, .foregroundColor: text])
        let s = attr.size()
        attr.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                              y: (bounds.height - s.height) / 2 - 0.5))
    }
}

/// The compact enable/bypass "power" button for a processing slot — one
/// small rounded chip with a hand-drawn power glyph (broken circle +
/// stem), replacing the large capsule switch. System-accent fill with a
/// near-black glyph when processing is ON; quiet neutral when bypassed.
/// No redundant status dot — the button IS the state.
final class PowerToggle: FunctionButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.08) : accent }
        else { fill = hovering ? GGTheme.hoverFill : GGTheme.idleFill }
        fill.setFill()
        path.fill()
        if enabled, !engaged {
            GGTheme.idleBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // power glyph: circle broken at the top + a stem through the gap
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r = bounds.height * 0.26
        let color: NSColor = !enabled ? .disabledControlTextColor
            : engaged ? GGTheme.darkText : GGTheme.idleLabel
        color.setStroke()
        let glyph = NSBezierPath()
        glyph.appendArc(withCenter: c, radius: r,
                        startAngle: 120, endAngle: 60, clockwise: false)
        glyph.lineWidth = 1.6
        glyph.lineCapStyle = .round
        glyph.stroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: c.x, y: c.y - r * 0.1))
        stem.line(to: NSPoint(x: c.x, y: c.y + r * 1.35))
        stem.lineWidth = 1.6
        stem.lineCapStyle = .round
        stem.stroke()
    }
}

// MARK: - Icon utility buttons (Talkback mic · global Mute-All speaker)

/// A compact square ICON utility button (32×32) — the same flat dark
/// surfaces, corner radius, hover lift and focus treatment as the M/D/∑
/// chips, but drawing a centered glyph instead of a letter. Engaged =
/// flat accent fill + near-black glyph; idle = neutral fill, light-gray
/// glyph, hairline border. Subclasses implement drawGlyph.
class IconButton: FunctionButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        // radius 4 — crisper than the chips (6), so these read as small
        // utility controls, not toolbar tiles
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let fill: NSColor
        if !enabled { fill = GGTheme.subduedFill }
        else if engaged { fill = hovering ? Self.lift(accent, 0.08) : accent }
        else { fill = hovering ? GGTheme.hoverFill : GGTheme.idleFill }
        fill.setFill()
        path.fill()
        if enabled, !engaged {
            GGTheme.idleBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let color: NSColor = !enabled ? .disabledControlTextColor
            : engaged ? GGTheme.darkText : GGTheme.idleLabel
        drawGlyph(color: color)
    }

    /// Subclasses draw their centered glyph in the given color.
    func drawGlyph(color: NSColor) {}
}

/// Talkback — HOLD to talk, release to stop (a quick tap is a blip).
/// Latched talkback via the hotkey/MIDI still works; the chip mirrors
/// the live state either way. Solid green with a near-black microphone
/// while talking.
final class TalkbackIconButton: IconButton {
    var hold: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = .on
        hold?(true)
        var keep = true
        while keep {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if ev.type == .leftMouseUp { keep = false }
        }
        state = .off
        hold?(false)
    }

    override func drawGlyph(color: NSColor) {
        // compact microphone silhouette — capsule body, U cradle, stem,
        // base — ~15pt of ink in the 32pt frame, 1.5 stroke weight to
        // MATCH the speaker (neither dominates), optically centered
        let u = bounds.height / 32
        let ox = bounds.midX - 16 * u, oy = bounds.midY - 16 * u
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: ox + 12.5 * u, y: oy + 13 * u,
                                         width: 7 * u, height: 10 * u),
                     xRadius: 3.5 * u, yRadius: 3.5 * u).fill()
        color.setStroke()
        let cradle = NSBezierPath()
        cradle.appendArc(withCenter: pt(16, 17.5), radius: 7 * u,
                         startAngle: 180, endAngle: 0, clockwise: false)
        cradle.lineWidth = 1.5 * u
        cradle.lineCapStyle = .round
        cradle.stroke()
        let stem = NSBezierPath()
        stem.move(to: pt(16, 10.5))
        stem.line(to: pt(16, 8))
        stem.lineWidth = 1.5 * u
        stem.lineCapStyle = .round
        stem.stroke()
        let base = NSBezierPath()
        base.move(to: pt(12.5, 8))
        base.line(to: pt(19.5, 8))
        base.lineWidth = 1.5 * u
        base.lineCapStyle = .round
        base.stroke()
    }
}

/// Global mute — one click mutes BOTH monitor outputs (Main Speakers +
/// Headphones — every hardware mute the app controls), clicking again
/// unmutes them. Coral red with a SLASHED speaker while all outputs are
/// muted; plain speaker on a neutral chip otherwise.
final class MuteAllIconButton: IconButton {
    override func drawGlyph(color: NSColor) {
        // speaker (housing + cone) with sound waves — the classic volume
        // glyph, ~15pt wide with breathing room, 1.5 stroke weight
        // matching the mic; a diagonal slash is added while muted
        let u = bounds.height / 32
        let ox = bounds.midX - 16 * u, oy = bounds.midY - 16 * u
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
        color.setFill()
        NSBezierPath(rect: NSRect(x: ox + 9 * u, y: oy + 13 * u,
                                  width: 3.5 * u, height: 6 * u)).fill()
        let cone = NSBezierPath()
        cone.move(to: pt(12.5, 13.5))
        cone.line(to: pt(12.5, 18.5))
        cone.line(to: pt(16.5, 21))
        cone.line(to: pt(16.5, 11))
        cone.close()
        cone.fill()
        color.setStroke()
        for r in [CGFloat(4.5), CGFloat(7.5)] {
            let wave = NSBezierPath()
            wave.appendArc(withCenter: pt(17, 16), radius: r * u,
                           startAngle: -30, endAngle: 30, clockwise: false)
            wave.lineWidth = 1.5 * u
            wave.lineCapStyle = .round
            wave.stroke()
        }
        if isEngaged {
            let slash = NSBezierPath()
            slash.move(to: pt(8, 24))
            slash.line(to: pt(24, 8))
            slash.lineWidth = 2.2 * u
            slash.lineCapStyle = .round
            slash.stroke()
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
    /// Talkback — pressed/released by the strip's button; wired to
    /// AppDelegate's setTalkback. State reads back for display.
    var onTalkback: ((Bool) -> Void)?
    var talkbackState: (() -> Bool)?
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

    // Auto Gain status (shown in the footer's feedback strip)
    private var autoGainStatus: String?
    private var autoGainStatusTimer: Timer?

    /// Feedback-strip message kinds — the DOT carries the color (blue
    /// activity, green success, amber warning, red error); the text
    /// stays neutral and readable.
    enum FeedbackKind {
        case idle, activity, success, warning, error
        var dotColor: NSColor? {
            switch self {
            case .idle: return nil
            case .activity: return GGTheme.accent
            case .success: return GGTheme.green
            case .warning: return GGTheme.amber
            case .error: return GGTheme.red
            }
        }
    }
    private var autoGainKind: FeedbackKind = .activity

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
        guard window != nil, feedbackLabel != nil else { return }
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
            // Instrument mode. Instead of HIDING controls at the line
            // levels, they stay in place GRAYED OUT — the strip never
            // moves.
            let preampActive = !lineMode

            let mineRunning = autoRunning.contains(i)
            autoGainButtons[i].isEnabled = preampActive && connected && !learning
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
            gainKnobs[i].isEnabled = preampActive && connected && !learning
                && micId != nil && instId != nil && autoRunning.isEmpty
            let shown: Double
            if st.refLevel == 4 { shown = st.instGain ?? st.micGain ?? 0 }
            else { shown = st.micGain ?? st.instGain ?? 0 }
            if gainKnobs[i].doubleValue != shown { gainKnobs[i].doubleValue = shown }
            gainKnobs[i].hasValue = st.micGain != nil || st.instGain != nil

            // 48V applies to Mic mode only — visible but grayed elsewhere
            setToggle(toggles48V[i], st.phantom,
                      enabled: preampActive && st.refLevel != 4
                          && connected && !learning && t.hwinPhantom[i] != nil)
            setToggle(softLimitToggles[i], st.softLimit,
                      enabled: connected && !learning && t.hwinSoftLimit[i] != nil)
            setToggle(polarityToggles[i], st.polarity,
                      enabled: connected && !learning && t.hwinPolarity[i] != nil)

            inputHeaders[i]?.stringValue = st.name ?? "Analog In \(i + 1)"

            let missing = missingInputTargets(i)
            inputLearnButtons[i].isHidden = missing.isEmpty && !isLearning
            inputLearnButtons[i].isEnabled = (learning && learningColumn == .input(i)) || !missing.isEmpty
        }

        // OUTPUTS & ROUTING (InsertServer state). The controls are NEVER
        // disabled by the engine's state — a routing edit is intent, and
        // the action handlers auto-start the insert if it's off. Only the
        // plug-in-specific controls depend on a plug-in being loaded.
        let server = InsertServer.shared
        let live = server.running
        for i in 0..<4 {
            // the title always shows something: the custom name, or the
            // physical pair name by default ("Out 1–2")
            let saved = Self.savedName(i)
            let display = saved.isEmpty ? InsertServer.pairNames[i] : saved
            if nameFields[i].stringValue != display {
                nameFields[i].stringValue = display
            }

            let srcPopup = sourcePopups[i]
            srcPopup.removeAllItems()
            for src in InsertServer.sourceOptions(i) {
                srcPopup.addItem(withTitle: InsertServer.sourceLabel(src, for: i))
                srcPopup.lastItem?.representedObject = src.rawValue
            }
            srcPopup.selectItem(at: srcPopup.indexOfItem(withObjectValue: server.source(i).rawValue).getOrElse { 0 })

            // "Include source processing" — mirrored sources only.
            let mirrored = server.source(i).copyIndex != nil && server.source(i) != .off
            let include = includeChecks[i]
            include.isHidden = !mirrored
            if mirrored {
                include.state = server.mirrorPre(i) ? .off : .on
            }

            let plugPopup = pluginPopups[i]
            plugPopup.removeAllItems()
            plugPopup.addItem(withTitle: "None")
            plugPopup.lastItem?.representedObject = ""
            for (name, desc) in InsertServer.listPlugins() {
                // short name in the selector — the manufacturer stays in
                // the menu's full title where there's room for it
                plugPopup.addItem(withTitle: InsertServer.shortName(name))
                plugPopup.lastItem?.representedObject = InsertServer.descKey(desc)
            }
            let key = UserDefaults.standard.string(forKey: "insertPair.\(i).plugin") ?? ""
            plugPopup.selectItem(at: plugPopup.indexOfItem(withObjectValue: key).getOrElse { 0 })

            // Processing slot: everything stays in place in both states —
            // the power + Open buttons gray out when no plug-in is loaded
            // (they never hide), the selector always shows ("None" = empty).
            let hasPlugin = server.pluginName(i) != nil
            enabledChecks[i].state = (server.enabled(i) && !server.bypassAll) ? .on : .off
            enabledChecks[i].isEnabled = hasPlugin
            openButtons[i].isEnabled = hasPlugin

            let trim = server.trim(i)
            if trimKnobs[i].doubleValue != trim { trimKnobs[i].doubleValue = trim }
            // red value text as the clip warning on boosted trim
            trimKnobs[i].valueTint = trim > 0.5 ? GGTheme.red : nil
        }

        // MONITOR
        for o in 0..<2 {
            let st = monitors[o]
            let t = PathIds.active
            let gainId = o == 0 ? t.hwout0Gain : t.hwout1Gain
            let muteId = o == 0 ? t.hwout0Mute : t.hwout1Mute
            let dimId = o == 0 ? t.hwout0Dim : t.hwout1Dim
            let sumId = o == 0 ? t.hwout0Sum : t.hwout1Sum

            monKnobs[o].isEnabled = connected && !learning && !gainId.isEmpty
            let g = min(max(st.gain ?? 0, AppDelegate.minDB), AppDelegate.maxDB)
            if monKnobs[o].doubleValue != g { monKnobs[o].doubleValue = g }
            monKnobs[o].hasValue = st.gain != nil

            setToggle(muteToggles[o], st.mute, enabled: connected && !learning && !muteId.isEmpty)
            setToggle(dimToggles[o], st.dim, enabled: connected && !learning && dimId != nil)
            setToggle(monoToggles[o], st.sum, enabled: connected && !learning && sumId != nil)

            // Mute's clearest active state: the red M glyph itself — no
            // extra badge or dot. (Learn lives in the group-title menu.)
        }

        updateCardHighlights()
        // Utility pair mirrors the live state: the mic shows Talkback
        // (hotkeys/MIDI/menu can all change it), the speaker is ON while
        // BOTH monitor outputs are muted. Tooltips follow the states.
        let tbActive = talkbackState?() ?? false
        let bothMuted = (monitors[0].mute ?? false) && (monitors[1].mute ?? false)
        talkbackButton?.state = tbActive ? .on : .off
        talkbackButton?.isEnabled = connected && !learning
        talkbackButton?.toolTip = tbActive ? "Talkback active" : "Talkback"
        muteAllButton?.state = bothMuted ? .on : .off
        muteAllButton?.isEnabled = connected && !learning
        muteAllButton?.toolTip = bothMuted ? "Unmute all outputs" : "Mute all outputs"

        updateFeedback(connected: connected, insertLive: live)
        // NOTE: no geometry work here — resizing during a refresh cancels
        // slider drags mid-flight. The window's size is the user's.
    }

    /// The footer's feedback strip: [dot] [message] — progress/time only
    /// when the engine actually reports it — with Cancel while Auto Gain
    /// runs and Dismiss on lingering results. Priority: learn → auto
    /// gain → connection → insert hint → Ready. The strip's height is
    /// reserved, so messages never move the monitor controls.
    private func updateFeedback(connected: Bool, insertLive: Bool) {
        let kind: FeedbackKind
        let message: String
        var action: (title: String, running: Bool)? = nil

        if let learn = learnStatus() {
            kind = .activity
            message = learn
        } else if let ag = autoGainStatus {
            kind = autoGainKind
            message = ag
            if AutoGainEngine.shared.isRunning {
                action = ("Cancel", true)
            } else if autoGainStatusTimer != nil {
                action = ("Dismiss", false)
            }
        } else if !connected {
            kind = .warning
            message = "Not connected — waiting for Apogee Control 2 / ApogeeGlue…"
        } else if !insertLive {
            kind = .idle
            message = "Plug-in insert is off — loading a plug-in or changing a source turns it on"
        } else {
            kind = .idle
            message = "Ready"
        }

        feedbackDot?.layer?.backgroundColor = (kind.dotColor ?? NSColor.clear).cgColor
        if feedbackLabel?.stringValue != message { feedbackLabel?.stringValue = message }
        feedbackLabel?.textColor = kind == .idle ? GGTheme.muted : GGTheme.primary
        if let act = action {
            feedbackAction?.title = act.title
            feedbackAction?.isHidden = false
            feedbackRunning = act.running
        } else {
            feedbackAction?.isHidden = true
            feedbackRunning = false
        }
    }

    /// Cancel (Auto Gain running) / Dismiss (lingering result).
    @objc private func feedbackActionClicked(_ sender: NSButton) {
        if feedbackRunning {
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
        } else {
            autoGainStatus = nil
            autoGainStatusTimer?.invalidate()
            autoGainStatusTimer = nil
        }
        refresh()
    }

    /// Long messages expand into a popover on click — the footer never
    /// grows.
    private func showFeedbackPopover() {
        let text = feedbackLabel?.stringValue ?? ""
        guard !text.isEmpty, text != "Ready" else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = GGTheme.primary
        label.preferredMaxLayoutWidth = 320
        let vc = NSViewController()
        vc.view = label
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 340, height: 60)
        if let feedbackLabel {
            popover.show(relativeTo: feedbackLabel.bounds, of: feedbackLabel, preferredEdge: .maxY)
        }
        feedbackPopover = popover
    }
    private var feedbackPopover: NSPopover?

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
               "for \(where_), then come back. Click Learn again to skip."
    }

    // MARK: - build

    // input cards (index 0…3)
    private var inputHeaders: [NSTextField?] = []
    private var levelPopups: [NSPopUpButton] = []
    private var meters: [GGLevelMeter] = []
    private var gainKnobs: [GainKnob] = []
    private var autoGainButtons: [NSButton] = []
    private var toggles48V: [NSButton] = []
    private var softLimitToggles: [NSButton] = []
    private var polarityToggles: [NSButton] = []
    private var inputLearnButtons: [NSButton] = []

    // routing cards (index 0…3)
    private var nameFields: [NSTextField] = []
    private var sourcePopups: [NSPopUpButton] = []
    private var includeChecks: [NSButton] = []
    private var pluginPopups: [NSPopUpButton] = []
    private var enabledChecks: [NSButton] = []
    private var openButtons: [NSButton] = []
    private var trimKnobs: [GainKnob] = []

    // monitor strip (index 0 = Main Speakers, 1 = Headphones)
    private var monKnobs: [GainKnob] = []
    private var muteToggles: [NSButton] = []
    private var dimToggles: [NSButton] = []
    private var monoToggles: [NSButton] = []
    private var talkbackButton: TalkbackIconButton?
    private var muteAllButton: MuteAllIconButton?

    // footer feedback strip
    private var feedbackDot: NSView?
    private var feedbackLabel: SelectLabel?
    private var feedbackAction: NSButton?
    private var feedbackRunning = false

    private var subtitleField: NSTextField!
    /// The scroll area's document view (top-scroll on open).
    private var scrollDoc: NSView?

    // MARK: keyboard-shortcut selection state (see extension at file end)

    /// Selection markers (index 0…3) — a thin accent bar beside each
    /// strip's header, visible only on the selected strip.
    private var inputMarkers: [NSView] = []
    private var outputMarkers: [NSView] = []
    /// The strip each "selected…" shortcut acts on (gain, trim, processing).
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
    /// ONE strip width for BOTH sections — input and output boxes are
    /// the same size; all four strips + rules must fit the window width.
    private let cardWidth: CGFloat = 240

    private func build() {
        // Window: one resizable workspace — default 1,060 × 632: the
        // minimal width that fits all four strips + rules + margins, and
        // a height measured to fit EVERYTHING (header + inputs + outputs
        // + footer ≈ 624pt) with no scrollbar at the default size.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 632))

        // NATIVE background: the standard dark window material over a
        // subtle system blur — no manually simulated black overlay, no
        // per-panel glass. The whole content area is ONE stable material;
        // Liquid Glass stays with the native toolbar controls.
        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .windowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        content.addSubview(blur, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: content.topAnchor),
            blur.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
            header.heightAnchor.constraint(equalToConstant: 60),

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
        // minimum: all four 240-pt strips + rules + margins must fit —
        // the pinned strip widths are hard requirements, not wishes
        w.minSize = NSSize(width: 1060, height: 520)
        window = w
        // default size = the minimal width, measured no-scroll height —
        // NSWindow sizes to the contentView's fitting size otherwise,
        // and the intrinsic size is tiny
        w.setContentSize(NSSize(width: 1060, height: 632))
        w.center()
        // open at the TOP of the sections: the doc is NOT flipped, so its
        // origin is the bottom — scrolling to 0 shows the bottom (status
        // line) and leaves the Inputs header clipped at the top.
        content.layoutSubtreeIfNeeded()
        if let d = scrollDoc {
            d.scroll(NSPoint(x: 0, y: d.bounds.maxY))
        }
    }

    /// Unified title bar: title + quiet device name on the left, a
    /// native toolbar-style settings button on the right — the same
    /// window material throughout, framed by a hairline at its bottom.
    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Quartet Control")
        title.font = GGTheme.titleFont
        title.textColor = GGTheme.primary
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let subtitle = NSTextField(labelWithString: interfaceName)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = GGTheme.muted
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(subtitle)
        subtitleField = subtitle

        let settings = NSButton(title: "⚙︎", target: self, action: #selector(settingsClicked(_:)))
        settings.bezelStyle = .rounded
        settings.font = NSFont.systemFont(ofSize: 15)
        settings.toolTip = "Settings…"
        settings.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(settings)

        let divider = Hairline()
        header.addSubview(divider)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 7),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            settings.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            settings.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            // REQUIRED: close the horizontal chain (title…settings) — an
            // underconstrained header breaks the whole window's layout.
            settings.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            // comfortably-sized settings button (32 × 26)
            settings.widthAnchor.constraint(equalToConstant: 32),
            settings.heightAnchor.constraint(equalToConstant: 26),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    /// Scroll view: the inputs + outputs sections scroll together; the
    /// monitor strip stays pinned below.
    private func makeScrollArea() -> NSScrollView {
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 900))
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
        autoGainAll.controlSize = .small
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

        // thin system separator between the two sections
        let sectionRule = Hairline()
        stack.addArrangedSubview(sectionRule)

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
        outSupport.textColor = GGTheme.muted
        outHeader.addArrangedSubview(outTitle)
        outHeader.addArrangedSubview(outSupport)
        stack.addArrangedSubview(outHeader)

        let outGrid = makeRoutingGrid()
        stack.addArrangedSubview(outGrid)

        // Scroll content edges at 999 (NOT required): during the window's
        // first, zero-size layout pass the required strip widths would
        // otherwise conflict with the required edges — the engine would
        // break the STRIP widths and the window would momentarily
        // collapse to the status label's width before recovering.
        // Breakable edges make that pass deterministic: the strips always
        // hold, and once real sizes exist the edges are fully honored.
        let stackLeading = stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20)
        let stackTrailing = stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20)
        stackLeading.priority = .init(999)
        stackTrailing.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stackLeading,
            stackTrailing,
            stack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -8),
            inputsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // full-width header (internal .leading alignment) so the
            // "Outputs & Routing" title sits left, aligned with "Inputs"
            outHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sectionRule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // the channel strips HUG their fixed content (4 strips + 3
            // rules) and center — pinning them to the stack width would
            // over-constrain the fixed strip widths
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

    /// One horizontal strip of four equal channel panels separated by
    /// thin vertical rules — native direction: no floating cards, no
    /// heavy outlines, just spacing + rules. Each panel: header (name +
    /// type dropdown) over a thin meter, then the compact gain knob with
    /// Auto Gain + the 48V/SL/Ø chips beside it.
    private func makeInputGrid() -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 8
        strip.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<4 {
            if i > 0 { addRule(to: strip) }

            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 10
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
            ])

            // HEADER — the channel NAME is the selector: clicking it
            // selects this strip (a thin accent marker beside the title
            // shows the selection; the panel itself never changes).
            // The compact type dropdown sits at the right.
            let head = SelectLabel(frame: .zero)
            head.stringValue = "Analog In \(i + 1)"
            head.font = GGTheme.nameFont
            head.textColor = GGTheme.primary
            head.lineBreakMode = .byTruncatingTail
            head.onClick = { [weak self] in self?.selectInput(i) }
            inputHeaders.append(head)

            let marker = makeMarker()
            inputMarkers.append(marker)

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
            p.widthAnchor.constraint(equalToConstant: 108).isActive = true
            levelPopups.append(p)

            let headerRow = NSStackView()
            headerRow.orientation = .horizontal
            headerRow.alignment = .centerY
            headerRow.spacing = 6
            headerRow.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addArrangedSubview(marker)
            headerRow.addArrangedSubview(head)
            let headerSpacer = NSView()
            headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            headerRow.addArrangedSubview(headerSpacer)
            headerRow.addArrangedSubview(p)
            // join the hierarchy BEFORE constraining against col — a
            // constraint between views with no common ancestor throws
            // NSGenericException and aborts the whole window build
            col.addArrangedSubview(headerRow)
            headerRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

            // thin signal meter between the header and the controls
            let meter = GGLevelMeter()
            meter.heightAnchor.constraint(equalToConstant: 7).isActive = true
            col.addArrangedSubview(meter)
            meter.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            meters.append(meter)

            // CONTROL ROW — compact knob left, Auto Gain + chips right.
            // The knob's height EQUALS the Auto Gain + toggle block:
            // 24 (Auto Gain) + 6 (gap) + 22 (chips) = 52.
            let knob = GainKnob()
            knob.minValue = 0
            knob.maxValue = 75
            knob.doubleValue = 0
            knob.target = self
            knob.action = #selector(gainSlid(_:))
            knob.tag = 200 + i
            knob.sendsContinuously = true
            knob.widthAnchor.constraint(equalToConstant: 52).isActive = true
            knob.heightAnchor.constraint(equalToConstant: 52).isActive = true
            gainKnobs.append(knob)

            // precise entry: the knob's inline editor carries the numeric
            // tag + delegate, so commit runs the same write path
            knob.valueField.tag = 250 + i
            knob.valueField.delegate = self

            let ag = NSButton(title: "Auto Gain", target: self,
                              action: #selector(autoGainClicked(_:)))
            ag.tag = 1200 + i
            ag.bezelStyle = .recessed
            ag.controlSize = .small
            ag.font = NSFont.systemFont(ofSize: 11)
            ag.heightAnchor.constraint(equalToConstant: 24).isActive = true
            autoGainButtons.append(ag)

            // one compact row of toggles — 48V / SL / Ø (amber / cyan /
            // system accent when engaged; small intrinsic chips).
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            let tv = toggle("48V", 300 + i, GGTheme.amber)
            tv.toolTip = "+48V phantom power"
            row.addArrangedSubview(tv)
            toggles48V.append(tv)
            let soft = toggle("SL", 400 + i, GGTheme.cyan)
            soft.toolTip = "Soft Limit"
            row.addArrangedSubview(soft)
            softLimitToggles.append(soft)
            let pol = toggle("Ø", 500 + i, GGTheme.accent)
            pol.toolTip = "Invert polarity"
            row.addArrangedSubview(pol)
            polarityToggles.append(pol)

            let right = NSStackView()
            right.orientation = .vertical
            right.alignment = .leading
            right.spacing = 6
            right.translatesAutoresizingMaskIntoConstraints = false
            right.addArrangedSubview(ag)
            right.addArrangedSubview(row)
            // Auto Gain spans exactly the width of the three chips below
            ag.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

            // the number + button block spans the WHOLE box width: number
            // at the left edge, Auto Gain + chips at the right edge, one
            // flexible spacer in between
            let controlRow = NSStackView()
            controlRow.orientation = .horizontal
            controlRow.alignment = .centerY
            controlRow.spacing = 14
            controlRow.translatesAutoresizingMaskIntoConstraints = false
            controlRow.addArrangedSubview(knob)
            let midSpacer = NSView()
            midSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            controlRow.addArrangedSubview(midSpacer)
            controlRow.addArrangedSubview(right)
            col.addArrangedSubview(controlRow)
            controlRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

            // learn fallback (only when ids are missing)
            let lb = NSButton(title: "Learn…", target: self, action: #selector(learnClicked(_:)))
            lb.tag = 600 + i
            lb.bezelStyle = .recessed
            lb.controlSize = .small
            lb.font = NSFont.systemFont(ofSize: 10)
            col.addArrangedSubview(lb)
            inputLearnButtons.append(lb)

            strip.addArrangedSubview(card)
        }
        return strip
    }

    /// A thin full-height vertical rule between channel panels. Added to
    /// the strip BEFORE its edge constraints activate (common-ancestor
    /// rule).
    private func addRule(to strip: NSStackView) {
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        strip.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rule.topAnchor.constraint(equalTo: strip.topAnchor).isActive = true
        rule.bottomAnchor.constraint(equalTo: strip.bottomAnchor).isActive = true
    }

    // MARK: routing cards

    /// Four aligned output strips separated by the same thin vertical
    /// rules as the inputs. Compact two-column layout per strip:
    /// header (editable name + small physical identifier on ONE line),
    /// full-width source dropdown, then the trim knob (with a small
    /// "Trim" caption beneath) beside a two-row processing area —
    /// plug-in selector on top, compact power + Open row below. The
    /// processing well, the status dot and the large switch are gone;
    /// empty and loaded slots share identical dimensions.
    private func makeRoutingGrid() -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 8
        strip.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<4 {
            if i > 0 { addRule(to: strip) }

            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 8
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
            ])

            // HEADER — the output NAME as a title. It defaults to the
            // physical pair ("Out 1–2"), renames on double-click, and a
            // SINGLE click selects this strip (the accent marker beside
            // the title shows the selection).
            let nf = TitleField(frame: .zero)
            nf.font = GGTheme.nameFont
            nf.textColor = GGTheme.primary
            nf.stringValue = InsertServer.pairNames[i]
            nf.lineBreakMode = .byTruncatingTail
            nf.tag = 2050 + i
            nf.delegate = self
            nf.toolTip = "Destination name — double-click to rename"
            nf.onClick = { [weak self] in self?.selectOutput(i) }
            nameFields.append(nf)

            let marker = makeMarker()
            outputMarkers.append(marker)
            let headerRow = NSStackView()
            headerRow.orientation = .horizontal
            headerRow.alignment = .centerY
            headerRow.spacing = 6
            headerRow.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addArrangedSubview(marker)
            headerRow.addArrangedSubview(nf)
            col.addArrangedSubview(headerRow)
            nf.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor).isActive = true

            // Source — full-width native dropdown, no separate label
            let sp = NSPopUpButton()
            sp.target = self
            sp.action = #selector(sourceChanged(_:))
            sp.tag = 2100 + i
            sp.font = NSFont.systemFont(ofSize: 11)
            sp.controlSize = .small
            col.addArrangedSubview(sp)
            sp.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            sourcePopups.append(sp)

            // "Include" — the linked/mirrored-routing chip: system accent
            // when engaged. Constant-height row (hidden for direct
            // sources) keeps every strip's geometry identical.
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

            // BODY — trim knob left, two-row processing area right
            let tsl = GainKnob()
            tsl.minValue = -64
            tsl.maxValue = 6
            tsl.doubleValue = 0
            tsl.target = self
            tsl.action = #selector(trimSlid(_:))
            tsl.tag = 2600 + i
            tsl.sendsContinuously = true
            tsl.widthAnchor.constraint(equalToConstant: 52).isActive = true
            tsl.heightAnchor.constraint(equalToConstant: 52).isActive = true
            trimKnobs.append(tsl)

            // precise entry — the old trim field's tag + delegate
            tsl.valueField.tag = 2650 + i
            tsl.valueField.delegate = self

            // the "Trim" caption sits ABOVE the number now
            let trimCaption = NSTextField(labelWithString: "Trim")
            trimCaption.font = GGTheme.labelFont
            trimCaption.textColor = GGTheme.muted
            let knobCol = NSStackView()
            knobCol.orientation = .vertical
            knobCol.alignment = .centerX
            knobCol.spacing = 3
            knobCol.translatesAutoresizingMaskIntoConstraints = false
            knobCol.addArrangedSubview(trimCaption)
            knobCol.addArrangedSubview(tsl)

            // processing column — label, plug-in selector, power + Open.
            // Everything stays in place in BOTH states: the selector
            // always shows (None = the empty slot — picking a plug-in
            // adds it), and the power + Open buttons gray out instead of
            // hiding when no plug-in is loaded.
            let procLbl = NSTextField(labelWithString: "Processing")
            procLbl.font = GGTheme.labelFont
            procLbl.textColor = GGTheme.softGray

            let pp = NSPopUpButton()
            pp.target = self
            pp.action = #selector(pluginChanged(_:))
            pp.tag = 2300 + i
            pp.font = NSFont.systemFont(ofSize: 11)
            pp.controlSize = .small
            pp.toolTip = "Add / replace / remove the plug-in"
            pluginPopups.append(pp)

            let power = PowerToggle(tag: 2400 + i, accent: GGTheme.accent,
                                    target: self, action: #selector(enabledChanged(_:)))
            power.toolTip = "Bypass processing."
            power.setAccessibilityLabel("Enable processing")
            enabledChecks.append(power)

            let open = NSButton(title: "Open", target: self,
                                action: #selector(rowEditorOpened(_:)))
            open.tag = 2450 + i
            open.bezelStyle = .recessed
            open.controlSize = .small
            open.font = NSFont.systemFont(ofSize: 11)
            openButtons.append(open)

            let row2 = NSStackView()
            row2.orientation = .horizontal
            row2.spacing = 6
            row2.alignment = .centerY
            row2.translatesAutoresizingMaskIntoConstraints = false
            row2.addArrangedSubview(power)
            let row2Spacer = NSView()
            row2Spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            row2.addArrangedSubview(row2Spacer)
            row2.addArrangedSubview(open)

            let procCol = NSStackView()
            procCol.orientation = .vertical
            procCol.alignment = .leading
            procCol.spacing = 4
            procCol.translatesAutoresizingMaskIntoConstraints = false
            procCol.addArrangedSubview(procLbl)
            procCol.addArrangedSubview(pp)
            procCol.addArrangedSubview(row2)

            // the trim knob comes AFTER the plug-in area
            let body = NSStackView()
            body.orientation = .horizontal
            body.spacing = 12
            body.alignment = .top
            body.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(procCol)
            body.addArrangedSubview(knobCol)
            // join the hierarchy BEFORE cross-view constraints (common
            // ancestor required at activation time)
            col.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            procCol.widthAnchor.constraint(equalTo: body.widthAnchor,
                                           constant: -(52 + 12)).isActive = true
            pp.widthAnchor.constraint(equalTo: procCol.widthAnchor).isActive = true

            strip.addArrangedSubview(card)
        }
        return strip
    }

    // MARK: footer — monitor controls above, feedback strip below

    /// The fixed two-row footer. TOP row: the two monitor groups
    /// adjacent on the left (each: small speaker/headphones glyph +
    /// title, the 64-pt level knob, M/D/∑ beneath the title), a fine
    /// vertical rule between them, and Talkback + Mute-All at the far
    /// right, vertically centered. BOTTOM row: a slim, full-width
    /// RESERVED feedback strip (status dot + message + optional
    /// Cancel/Dismiss) — messages never move the monitor controls.
    private func makeMonitorStrip() -> NSView {
        let footer = NSStackView()
        footer.orientation = .vertical
        footer.spacing = 0
        footer.translatesAutoresizingMaskIntoConstraints = false

        // top hairline (subtle border against the routing area)
        let topDivider = Hairline()
        footer.addSubview(topDivider)

        // --- monitor controls row
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(makeMonitorGroup(0))
        // fine vertical rule between the two monitor groups
        let vDivider = NSView()
        vDivider.wantsLayer = true
        vDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        vDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        row.addArrangedSubview(vDivider)
        row.addArrangedSubview(makeMonitorGroup(1))
        // flexible gap, then the global utility pair at the far right
        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(rowSpacer)
        row.addArrangedSubview(makeUtilityPair())
        footer.addArrangedSubview(row)

        // --- slim feedback strip below the controls
        let rule = Hairline()
        footer.addArrangedSubview(rule)

        feedbackDot = NSView()
        feedbackDot?.translatesAutoresizingMaskIntoConstraints = false
        feedbackDot?.wantsLayer = true
        feedbackDot?.layer?.cornerRadius = 2.5
        feedbackDot?.widthAnchor.constraint(equalToConstant: 5).isActive = true
        feedbackDot?.heightAnchor.constraint(equalToConstant: 5).isActive = true

        feedbackLabel = SelectLabel(frame: .zero)
        feedbackLabel?.font = NSFont.systemFont(ofSize: 11)
        feedbackLabel?.lineBreakMode = .byTruncatingTail
        feedbackLabel?.onClick = { [weak self] in
            self?.showFeedbackPopover()
        }

        feedbackAction = NSButton(title: "Cancel", target: self,
                                  action: #selector(feedbackActionClicked(_:)))
        feedbackAction?.bezelStyle = .recessed
        feedbackAction?.controlSize = .small
        feedbackAction?.font = NSFont.systemFont(ofSize: 11)
        feedbackAction?.isHidden = true

        let feedbackRow = NSStackView()
        feedbackRow.orientation = .horizontal
        feedbackRow.alignment = .centerY
        feedbackRow.spacing = 8
        feedbackRow.translatesAutoresizingMaskIntoConstraints = false
        if let dot = feedbackDot { feedbackRow.addArrangedSubview(dot) }
        if let label = feedbackLabel { feedbackRow.addArrangedSubview(label) }
        let feedbackSpacer = NSView()
        feedbackSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        feedbackRow.addArrangedSubview(feedbackSpacer)
        if let action = feedbackAction { feedbackRow.addArrangedSubview(action) }
        footer.addArrangedSubview(feedbackRow)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            row.topAnchor.constraint(equalTo: footer.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            vDivider.topAnchor.constraint(equalTo: row.topAnchor),
            vDivider.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            // fixed, reserved height — messages NEVER shift the controls
            feedbackRow.heightAnchor.constraint(equalToConstant: 30),
            feedbackRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            feedbackRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            feedbackRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4),
        ])
        return footer
    }

    /// The bottom-right utility pair: Talkback mic + global Mute-All.
    private func makeUtilityPair() -> NSView {
        let mic = TalkbackIconButton(tag: 0, accent: GGTheme.green,
                                     target: self, action: #selector(talkbackToggled(_:)))
        mic.toolTip = "Talkback"
        mic.setAccessibilityLabel("Talkback")
        mic.hold = { [weak self] on in self?.onTalkback?(on) }
        talkbackButton = mic

        let mute = MuteAllIconButton(tag: 0, accent: GGTheme.red,
                                     target: self, action: #selector(muteAllToggled(_:)))
        mute.toolTip = "Mute all outputs"
        mute.setAccessibilityLabel("Mute all outputs")
        muteAllButton = mute

        let pair = NSStackView(views: [mic, mute])
        pair.spacing = 6
        pair.translatesAutoresizingMaskIntoConstraints = false
        return pair
    }

    private func makeMonitorGroup(_ o: Int) -> NSView {
        let heading: String = o == 0 ? "Main Speakers" : "Headphones"

        // the LARGER 64-pt level knob — value AND a small "dB" inside —
        // with the title row and M/D/∑ directly beneath the title
        let body = NSStackView()
        body.orientation = .horizontal
        body.spacing = 12
        body.alignment = .centerY
        body.translatesAutoresizingMaskIntoConstraints = false

        let sl = GainKnob()
        sl.minValue = AppDelegate.minDB
        sl.maxValue = AppDelegate.maxDB
        sl.doubleValue = 0
        sl.target = self
        sl.action = #selector(monSlid(_:))
        sl.tag = 700 + o
        sl.sendsContinuously = true
        sl.showsUnit = true
        sl.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sl.heightAnchor.constraint(equalToConstant: 64).isActive = true
        body.addArrangedSubview(sl)
        monKnobs.append(sl)

        // precise entry — the old level field's tag + delegate
        sl.valueField.tag = 750 + o
        sl.valueField.delegate = self

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        right.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(right)

        // title row: small monochrome output glyph + the group title.
        // Clicking the title opens the "Learn Control…" menu (the old
        // permanent Learn button is gone).
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addArrangedSubview(TinyGlyphView(o == 0 ? .speaker : .headphones))
        let head = SelectLabel(frame: .zero)
        head.stringValue = heading
        head.font = GGTheme.nameFont
        head.textColor = GGTheme.primary
        head.onClick = { [weak self] in self?.showLearnMenu(for: o, from: head) }
        titleRow.addArrangedSubview(head)
        right.addArrangedSubview(titleRow)

        // M / D / ∑ — equal square glyph buttons directly beneath the
        // title: Mute (coral red), DIM (amber), Sum to mono (system
        // accent) when active; neutral dark gray at rest. Full names
        // live in tooltips + accessibility.
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 5
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        let mute = glyphToggle("M", 800 + o, GGTheme.red, "Mute")
        btnRow.addArrangedSubview(mute)
        muteToggles.append(mute)
        let dim = glyphToggle("D", 900 + o, GGTheme.amber, "DIM")
        btnRow.addArrangedSubview(dim)
        dimToggles.append(dim)
        let mono = glyphToggle("∑", 1000 + o, GGTheme.accent, "Sum to mono")
        btnRow.addArrangedSubview(mono)
        monoToggles.append(mono)
        right.addArrangedSubview(btnRow)

        return body
    }

    /// The group title's menu — hardware mapping lives here now, not in
    /// a permanent third row. "Learn Control…" starts the capture (or
    /// skips the current target while one runs); disabled when there's
    /// nothing to learn.
    private func showLearnMenu(for o: Int, from view: NSView) {
        let menu = NSMenu()
        let learning = isLearning
        let item = NSMenuItem(title: learning ? "Skip current control…" : "Learn Control…",
                              action: #selector(learnClicked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = 1100 + o
        item.isEnabled = learning || !missingMonitorTargets(o).isEmpty
        menu.items = [item]
        menu.popUp(positioning: item, at: NSPoint(x: 0, y: -4), in: view)
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
            showAutoStatus("Auto Gain All — no inputs in Mic/Instrument mode", clearAfter: 8,
                           kind: .warning)
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
            showAutoStatus("Auto Gain — no Mic/Instrument inputs ready", clearAfter: 8,
                           kind: .warning)
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
    func showAutoStatus(_ line: String, clearAfter seconds: TimeInterval?,
                       kind: FeedbackKind = .activity) {
        autoGainStatus = line
        autoGainKind = kind
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

    /// A routing edit is intent: if the AU insert engine is off, start it
    /// (the exact path the menubar toggle uses) so the change takes
    /// effect. Called AFTER the state write, so a fresh start loads it.
    private func ensureInsertRunning() {
        guard !InsertServer.shared.running else { return }
        InsertServer.shared.setRunning(true)
        QBLog.log("control: routing edit started the plug-in insert")
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 2100
        guard !suppressActions, let raw = sender.selectedItem?.representedObject as? String,
              let src = InsertServer.PairSource(rawValue: raw) else { return refresh() }
        InsertServer.shared.setSource(i, src)
        ensureInsertRunning()
        refresh()
    }

    /// "Include source processing" — on = mirror AFTER the source's plug-in
    /// (destination inherits its processing); off = before (raw channels).
    @objc private func includeChanged(_ sender: NSButton) {
        let i = sender.tag - 2200
        guard !suppressActions else { return refresh() }
        InsertServer.shared.setMirrorPre(i, sender.state == .off)
        ensureInsertRunning()
        refresh()
    }

    @objc private func pluginChanged(_ sender: NSPopUpButton) {
        let i = sender.tag - 2300
        guard !suppressActions, let key = sender.selectedItem?.representedObject as? String else { return refresh() }
        let desc = key.isEmpty ? nil
            : InsertServer.listPlugins().first { InsertServer.descKey($0.desc) == key }?.desc
        InsertServer.shared.setPlugin(i, desc)
        if !key.isEmpty { ensureInsertRunning() }   // picking "None" doesn't start it
        refresh()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        let i = sender.tag - 2400
        guard !suppressActions else { return refresh() }
        let on = sender.state == .on
        InsertServer.shared.setEnabled(i, on)
        if on { ensureInsertRunning() }   // enabling processing means intent to run it
        refresh()
    }

    @objc private func rowEditorOpened(_ sender: NSButton) {
        InsertServer.shared.showPluginUI(sender.tag - 2450)
    }

    /// Output-trim knob (tag = 2600 + pair) — whole-number steps.
    @objc private func trimSlid(_ sender: NSControl) {
        let i = sender.tag - 2600
        let v = sender.doubleValue   // already whole (knob rounds)
        InsertServer.shared.setTrim(i, v, notify: false)
        // red value text as the clip warning on boosted trim
        trimKnobs[i].valueTint = v > 0.5 ? GGTheme.red : nil
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

    /// Talkback chip (toggle mode; momentary mode drives `hold` directly).
    @objc private func talkbackToggled(_ sender: NSButton) {
        guard !suppressActions else { return }
        onTalkback?(sender.state == .on)
    }

    /// Global mute — one click flips BOTH monitor outputs together
    /// ("all" = every hardware mute this app controls: Main Speakers +
    /// Headphones). Not all-muted → mute both; all-muted → unmute both.
    @objc private func muteAllToggled(_ sender: NSButton) {
        guard !suppressActions, !isLearning else { return refresh() }
        let t = PathIds.active
        let bothMuted = (monitors[0].mute ?? false) && (monitors[1].mute ?? false)
        let target = !bothMuted
        for o in 0..<2 {
            let id = o == 0 ? t.hwout0Mute : t.hwout1Mute
            guard !id.isEmpty, monitors[o].mute != target else { continue }
            monitors[o].mute = target
            onWriteBool?(id, target)
        }
        refresh()
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
            // monitor level (dB) — the monitor knob's inline editor
            let o = field.tag - 750
            defer { monKnobs[o].endEditing() }
            guard let db = parseDB(field.stringValue), AppDelegate.isValidDB(db) else { return refresh() }
            let id = o == 0 ? PathIds.active.hwout0Gain : PathIds.active.hwout1Gain
            guard !id.isEmpty else { return refresh() }
            let v = min(max(db, AppDelegate.minDB), AppDelegate.maxDB)
            onWriteDouble?(id, v)
            monitors[o].gain = v
            refresh()
        case 2050..<2054:
            // destination name — empty or the default pair name keeps
            // the default (nothing saved)
            let i = field.tag - 2050
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == InsertServer.pairNames[i] {
                UserDefaults.standard.removeObject(forKey: Self.nameKey(i))
            } else {
                UserDefaults.standard.set(name, forKey: Self.nameKey(i))
            }
            QBLog.log("control: output \(i) named '\(name)'")
            refresh()
        case 2650..<2654:
            // output trim (dB) — the trim knob's inline editor
            let i = field.tag - 2650
            defer { trimKnobs[i].endEditing() }
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

    /// A compact square glyph button (M / D / ∑) — the monitor functions.
    /// The visible title is a single letter; the full function name stays
    /// in the tooltip + accessibility label.
    private func glyphToggle(_ glyph: String, _ tag: Int,
                             _ accent: NSColor, _ name: String) -> FunctionToggle {
        let t = toggle(glyph, tag, accent)
        t.titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        t.widthAnchor.constraint(equalToConstant: 28).isActive = true
        t.heightAnchor.constraint(equalToConstant: 28).isActive = true
        t.toolTip = name
        t.setAccessibilityLabel(name)
        return t
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

    /// The thin vertical selection marker beside a strip's header —
    /// 2×14pt, space always reserved, invisible until selected (so
    /// selecting never shifts the layout).
    private func makeMarker() -> NSView {
        let m = NSView()
        m.translatesAutoresizingMaskIntoConstraints = false
        m.wantsLayer = true
        m.layer?.backgroundColor = NSColor.clear.cgColor
        m.layer?.cornerRadius = 1
        m.widthAnchor.constraint(equalToConstant: 2).isActive = true
        m.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return m
    }

    /// Selection visual: a thin accent marker beside the SELECTED
    /// strip's header — the panel itself never changes (no border, no
    /// tint, no dimming; unselected strips simply have no marker).
    func updateCardHighlights() {
        for (i, m) in inputMarkers.enumerated() {
            m.layer?.backgroundColor = (i == selectedInputIndex
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor)
        }
        for (i, m) in outputMarkers.enumerated() {
            m.layer?.backgroundColor = (i == selectedOutputIndex
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor)
        }
    }

    // MARK: outputs & routing (selected card)

    func shortcutOutputTrim(up: Bool, step: Double) {
        let i = selectedOutputIndex
        trimKnobs[i].doubleValue = min(max(trimKnobs[i].doubleValue + (up ? step : -step), -64), 6)
        trimSlid(trimKnobs[i])
    }

    func shortcutEditOutputTrim() {
        trimKnobs[selectedOutputIndex].beginEditing()
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
        showAutoStatus("Auto Gain cancelled", clearAfter: 4, kind: .idle)
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