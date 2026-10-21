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
///   • Title bar          — the app title + the connected device name,
///                          with the device-wide sample rate at the right
///   • Monitor bar        — Speakers + Headphones monitoring (knob, glyph,
///                          M/D/∑) on the left; Talkback · Mute-All ·
///                          Settings on the right. Directly under the
///                          title bar — the controls you reach for most
///                          never scroll away.
///   • Inputs / Outputs   — four analog-input cards + four stereo-output
///                          cards (same 4-column grid), in a scroll view
///
/// The Inputs and Outputs sections live in a scroll view and HUG their
/// content (no stretched empty bands); a slim feedback strip is pinned
/// to the bottom. The window itself hugs that content, so a layout
/// change makes the window shorter rather than the rows taller.
///
/// LIVE vs UNAVAILABLE: a value is only shown when it is KNOWN. A live
/// hardware reading (input gain, monitor level) gets the green arc; a
/// SAVED app-side setting (the output trim) gets a neutral arc and is
/// labelled "saved"; an unknown value (the device is unreachable) shows
/// "—" and no arc at all. The sample-rate dropdown says "Sample rate —"
/// rather than passing a default off as live, and the footer says
/// "Device unavailable — waiting for Apogee Control 2." with a Details…
/// diagnostic. Only the controls that genuinely need the device are
/// disabled; every label stays readable.
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
/// changes (no border, no tint). The LEARN action lives in the input
/// strip's header menu (the chevron beside the name), never as a
/// permanent row of buttons. The custom element is the KNOB (input
/// gain, output trim, monitor level): a LAYERED flat dial — a thick
/// subdued 270° charcoal track with the opening at the bottom, a flat
/// value arc riding on it clockwise from 7:30, a solid center disk a
/// clear step lighter than the panel, and the signed whole-number value
/// with its "dB" unit inside. No pointer, no notch: the arc's end is
/// the position.
/// Color is meaning:
/// system accent for focus/selection and the neutral functions (Ø, SUM,
/// Include, plug-in enable); green only for Soft Limit + the live value
/// arcs; amber for 48V/DIM; red for Mute + clipping. Everything else is
/// quiet.
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
    // ONE job per color:
    //   blue   — selection, focus, enabled processing
    //   green  — knob arcs + healthy-signal meters (+ talkback)
    //   cyan   — enabled Soft Limit
    //   purple — enabled polarity (Ø)
    //   amber  — enabled DIM
    //   red    — enabled 48V, active mute, errors
    //   gray   — everything inactive

    /// Green — knob value arcs, healthy-signal meters, talkback.
    static let green = hex("46C58A")
    /// Cyan — Soft Limit engaged.
    static let cyan = hex("50D8F4")
    /// Purple — polarity (Ø) engaged.
    static let purple = hex("B08CFF")
    /// Amber — DIM engaged.
    static let amber = hex("E7AE49")
    /// Red — 48V engaged, Mute engaged, global mute, clipping warnings.
    static let red = hex("E3636D")
    static let warning = red

    /// Near-black label ON flat accent fills.
    static let darkText = hex("101318")

    // The Auto Gain scanning light — flat, crisp, pixel-like.

    /// The bright head of the scan — pale electric blue.
    static let scanHead = hex("A8E4FF")
    /// The trail behind the head — medium blue, fading by OPACITY into
    /// the background (no glow, no blur).
    static let scanTrail = hex("3FA9F5")
    /// Off-white — the bright end of the breathing "Measuring…" label.
    static let offWhite = hex("E6E8EB")
    /// The row when the gain is applied — the app's green.
    static let scanDone = green
    /// The row when something went wrong — the app's amber.
    static let scanFail = amber

    // Knob — the app's one custom control: a LAYERED FLAT dial. A thick
    // charcoal track → a lighter solid center disk → the off-white
    // value. The depth comes from CONTRASTING FLAT SURFACES — never
    // gradients, bevels, glow or shadows — and every neutral is an
    // alpha-white, so the layers adapt to whatever dark panel they sit
    // on:
    //   near-black panel  <  track (lifted charcoal)  <  disk (a clear
    //   step lighter)  <  value (off-white, the brightest detail).

    /// The CENTER DISK — the knob's solid "body": a clear step lighter
    /// than the panel, so it reads as the top layer inside the track.
    /// Kept DARK enough to sit IN the panel rather than float above it.
    static let knobCenter = NSColor(white: 1, alpha: 0.22)
    /// The UNFILLED portion of the thick outer track — charcoal lifted
    /// just enough to stay visible on the near-black panel, and still
    /// clearly darker than the center disk.
    static let knobTrack = NSColor(white: 1, alpha: 0.14)
    /// The green value arc riding on the track — a LIVE, known value
    /// (input gain, monitor level). The SAME green as every other
    /// "active" green in the app.
    static let knobArc = green
    /// The arc of a SAVED value (the output trim) — an app-side setting,
    /// real and applied, but NOT a hardware reading: neutral, so green
    /// stays reserved for live values.
    static let knobSavedArc = NSColor(white: 1, alpha: 0.34)
    /// The numeric value inside the knob — off-white, tabular numerals.
    static let knobValue = NSColor(white: 0.94, alpha: 1)

    /// The flow connectors — a hairline in a quiet, but VISIBLE, gray:
    /// enough to read as a path, never louder than the controls it
    /// joins.
    static let flowLine = NSColor(white: 1, alpha: 0.32)

    // Idle custom controls — quiet, system-adjacent neutrals.

    static let idleFill = NSColor(white: 1, alpha: 0.10)
    static let idleBorder = NSColor.separatorColor
    static let idleLabel = NSColor.secondaryLabelColor
    static let hoverFill = NSColor(white: 1, alpha: 0.16)
    /// DISABLED function controls — dimmer than idle-but-available (an
    /// available-but-off button must never look unusable).
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

/// The window's ONE spacing scale. Every gap in the interface comes
/// from here — there are no ad-hoc numbers scattered through the
/// layout code:
///
///     tight     6 pt   closely related controls (a chip beside its label)
///     related   8 pt   a control and its neighbour in a strip
///     knob     14 pt   a knob and the controls beside it
///     heading  16 pt   a section heading and its content
///     section  22 pt   outer section padding
///
/// Controls stay CONTENT-SIZED vertically: the window gets shorter
/// instead of the rows growing to fill it.
enum GGSpace {
    static let tight: CGFloat = 6
    static let related: CGFloat = 8
    static let knob: CGFloat = 14
    static let heading: CGFloat = 16
    static let section: CGFloat = 22
    /// A section heading and the first row of its strips — the strip's
    /// own padding adds the rest of the gap.
    static let sectionHead: CGFloat = 8
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

/// Bundled monochrome icon assets (flaticon PNGs in assets/: speaker,
/// headphones, microphone-black-shape, mute, unmute). Drawn tint-only —
/// the PNG's own dark fill is replaced by the caller's color via a
/// source-in compositing pass — and cached per name + appearance +
/// resolved tint (the tints are dynamic label colors).
enum GGIconAsset {
    private static var cache: [String: NSImage] = [:]

    static func tinted(_ name: String, _ tint: NSColor) -> NSImage? {
        let appearance = NSApp?.effectiveAppearance.name.rawValue ?? "none"
        let rgb = tint.usingColorSpace(.deviceRGB)
        let key = "\(name)|\(appearance)|\(rgb?.redComponent ?? 0)-\(rgb?.greenComponent ?? 0)-\(rgb?.blueComponent ?? 0)-\(rgb?.alphaComponent ?? 1)"
        if let hit = cache[key] { return hit }
        guard let raw = Bundle.main.image(forResource: name) else { return nil }
        let size = raw.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        raw.draw(in: NSRect(origin: .zero, size: size))
        tint.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceIn)
        tinted.unlockFocus()
        cache[key] = tinted
        return tinted
    }

    /// Aspect-fit draw of a bundled icon, tinted, centered in `rect`
    /// (the icon's own aspect ratio is preserved).
    static func draw(_ name: String, tint: NSColor, in rect: NSRect) {
        guard let icon = tinted(name, tint) else { return }
        let s = icon.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        icon.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }
}

/// The Auto Gain activity display — a RESTRAINED animated border on the
/// button: while the input is being measured, a short blue light segment
/// travels CLOCKWISE around the button's actual perimeter — a bright
/// head with a subtle fading tail riding behind it. The stroke is thin
/// and clipped to the outline: no outer glow, no animated background,
/// and the button's dimensions, corner shape and flat dark fill are left
/// untouched. Inside, the label "Measuring…" breathes its brightness
/// between soft gray and off-white (no size, position or weight change);
/// on success the outline turns green with "Done" for a beat before the
/// button returns to normal.
///
/// Everything runs on CORE ANIMATION (GPU-composited) — there is no
/// timer and no per-frame redraw, so it costs (almost) no CPU.
final class GGBorderScanLight: NSView {

    enum Mode { case idle, measuring, done }

    /// The recessed bezel's corner radius — the outline follows it.
    private static let cornerRadius: CGFloat = 4
    /// A thin, quiet stroke.
    private static let lineWidth: CGFloat = 1.5
    /// One full lap around the perimeter, in seconds.
    private static let lap: CFTimeInterval = 2.6
    /// The bright head's length along the perimeter.
    private static let headLength: CGFloat = 7
    /// The dim tail's length behind the head.
    private static let tailLength: CGFloat = 26
    /// One bright-dim-bright TICK of the streak, in seconds — the streak
    /// itself is the ticker (the label stays perfectly still).
    private static let tick: CFTimeInterval = 1.1

    private var mode: Mode = .idle
    private let glow = CAShapeLayer()   // the halo UNDER the stroke
    private let tail = CAShapeLayer()
    private let head = CAShapeLayer()
    private let text = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        // the halo first (UNDER the stroke), then the stroke itself
        glow.fillColor = nil
        layer?.addSublayer(glow)
        for l in [tail, head] {
            l.fillColor = nil
            l.lineWidth = Self.lineWidth
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        text.alignmentMode = .center
        layer?.addSublayer(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Purely visual — clicks belong to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - geometry

    /// The stroke sits INSIDE the bezel's corner, so the outline follows
    /// the button's own shape, shrunk by half the stroke.
    private var outlineRadius: CGFloat { max(0, Self.cornerRadius - Self.lineWidth / 2) }

    /// The button's actual outline, traced CLOCKWISE on screen (top →
    /// right → bottom → left) — the direction the light travels.
    private func outlinePath() -> CGPath {
        let r = outlineRadius
        let rect = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX + r, y: maxY))
        p.addLine(to: CGPoint(x: maxX - r, y: maxY))
        p.addArc(tangent1End: CGPoint(x: maxX, y: maxY),
                 tangent2End: CGPoint(x: maxX, y: maxY - r), radius: r)
        p.addLine(to: CGPoint(x: maxX, y: minY + r))
        p.addArc(tangent1End: CGPoint(x: maxX, y: minY),
                 tangent2End: CGPoint(x: maxX - r, y: minY), radius: r)
        p.addLine(to: CGPoint(x: minX + r, y: minY))
        p.addArc(tangent1End: CGPoint(x: minX, y: minY),
                 tangent2End: CGPoint(x: minX, y: minY + r), radius: r)
        p.addLine(to: CGPoint(x: minX, y: maxY - r))
        p.addArc(tangent1End: CGPoint(x: minX, y: maxY),
                 tangent2End: CGPoint(x: minX + r, y: maxY), radius: r)
        p.closeSubpath()
        return p
    }

    /// The outline's exact length (straight runs + quarter circles) —
    /// the dash pattern's period, so the sweep loops without a seam.
    private var perimeter: CGFloat {
        let r = outlineRadius
        let w = bounds.width - Self.lineWidth, h = bounds.height - Self.lineWidth
        return max(2 * (w + h) - 8 * r + 2 * CGFloat.pi * r,
                   Self.headLength + Self.tailLength + 8)
    }

    private func dash(_ lengths: [CGFloat]) -> [NSNumber] {
        lengths.map { NSNumber(value: Double($0)) }
    }

    // MARK: - states

    /// Start (or keep) the sweep — idempotent: the engine reports status
    /// ~10×/s, and restarting each time would jump the head back.
    func startMeasuring() {
        layer?.opacity = 1
        guard mode != .measuring else { return }
        mode = .measuring
        rebuild()
    }

    /// The beat of green after a successful run — solid outline + "Done".
    func showDone() {
        layer?.opacity = 1
        guard mode != .done else { return }
        mode = .done
        rebuild()
    }

    /// Dark — the button shows its normal surface again.
    func setIdle() {
        guard mode != .idle else { return }
        mode = .idle
        head.removeAllAnimations()
        tail.removeAllAnimations()
        glow.removeAllAnimations()
        text.removeAllAnimations()
        layer?.opacity = 0
    }

    // MARK: - the animation (all on the render server)

    override func layout() {
        super.layout()
        guard bounds.width > 8, bounds.height > 8 else { return }
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.fontSize = 11
        text.font = NSFont.systemFont(ofSize: 11)
        rebuild()
    }

    /// Size the label to its string and CENTER the layer in the button —
    /// CATextLayer's own contentsGravity centering is unreliable, so the
    /// frame itself is placed on center (crisp: rounded to whole pixels).
    private func centerText(_ string: String) {
        let font = NSFont.systemFont(ofSize: 11)
        text.string = string
        let size = NSAttributedString(string: string,
                                      attributes: [.font: font]).size()
        let w = ceil(size.width), h = ceil(size.height)
        text.frame = CGRect(x: ((bounds.width - w) / 2).rounded(),
                            y: ((bounds.height - h) / 2).rounded(),
                            width: w, height: h)
    }

    /// (Re)build the layers for the current mode. The dash pattern's
    /// period EQUALS the perimeter, so animating the phase by exactly
    /// one period loops seamlessly — the light travels round and round
    /// with no seam, no jump, nothing but the outline.
    private func rebuild() {
        head.path = outlinePath()
        tail.path = outlinePath()
        glow.path = outlinePath()
        glow.lineWidth = Self.lineWidth * 2.6       // the halo — wider + soft
        glow.lineCap = .round
        head.removeAllAnimations()
        tail.removeAllAnimations()
        glow.removeAllAnimations()
        text.removeAllAnimations()
        switch mode {
        case .idle:
            head.strokeColor = nil
            tail.strokeColor = nil
            glow.strokeColor = nil
        case .measuring:
            let per = perimeter
            head.strokeColor = GGTheme.scanHead.cgColor
            tail.strokeColor = GGTheme.scanTrail.withAlphaComponent(0.45).cgColor
            // the halo UNDER the stroke — the head's own color, low alpha
            glow.strokeColor = GGTheme.scanHead.withAlphaComponent(0.35).cgColor
            // the label sits STILL — the streak is the ticker, the text
            // never animates (no fade-in, no breathing, no fade-out)
            centerText("Measuring…")
            text.foregroundColor = GGTheme.offWhite.cgColor
            head.lineDashPattern = dash([Self.headLength, per - Self.headLength])
            tail.lineDashPattern = dash([Self.tailLength, per - Self.tailLength])
            glow.lineDashPattern = dash([Self.headLength, per - Self.headLength])

            // the glow — shadows bloom off the light segments themselves
            for l in [head, tail, glow] {
                l.shadowColor = GGTheme.scanHead.cgColor
                l.shadowOpacity = 0.9
                l.shadowRadius = 4
                l.shadowOffset = .zero
            }

            // the sweep: phase 0 → −perimeter moves the dash FORWARD
            // along the path (clockwise); the tail's phase starts a
            // tail-length back, so it rides just behind the head.
            let travel = CABasicAnimation(keyPath: "lineDashPhase")
            travel.duration = Self.lap
            travel.repeatCount = .infinity
            travel.isRemovedOnCompletion = false
            travel.fromValue = 0
            travel.toValue = -per
            head.add(travel, forKey: "travel")
            glow.add(travel, forKey: "travel")
            travel.fromValue = Self.tailLength
            travel.toValue = Self.tailLength - per
            tail.add(travel, forKey: "travel")

            // THE TICKER — the streak itself blinks its beat: the head
            // + halo swell bright and settle dim, once per tick, in
            // time with the sweep's laps. The label never moves.
            for l in [head, glow] {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = Self.tick / 2
                pulse.autoreverses = true
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.repeatCount = .infinity
                pulse.isRemovedOnCompletion = false
                l.add(pulse, forKey: "tick")
            }
        case .done:
            head.strokeColor = GGTheme.scanDone.cgColor
            head.lineDashPattern = nil          // the whole outline, solid
            tail.strokeColor = nil
            // the success halo — green, wider, softly shadowed
            glow.strokeColor = GGTheme.scanDone.withAlphaComponent(0.4).cgColor
            glow.lineDashPattern = nil
            glow.shadowColor = GGTheme.scanDone.cgColor
            glow.shadowOpacity = 0.9
            glow.shadowRadius = 5
            glow.shadowOffset = .zero
            centerText("Done")
            text.foregroundColor = GGTheme.scanDone.cgColor
        }
    }
}

/// A small monochrome glyph beside a monitor group's title — speaker
/// (Main Speakers) or headphones. Configurable size (14pt default, the
/// monitor groups use the full mute-button height), quiet secondary color.
final class TinyGlyphView: NSView {
    enum Glyph { case speaker, headphones }
    private let glyph: Glyph
    private let side: CGFloat

    /// Optional click handler (the monitor groups open their
    /// "Learn Control…" menu from the glyph).
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    init(_ glyph: Glyph, side: CGFloat = 14) {
        self.glyph = glyph
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func draw(_ dirtyRect: NSRect) {
        let color = GGTheme.softGray
        let u = bounds.width / 16
        let ox = bounds.midX - 8 * u, oy = bounds.midY - 8 * u
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
        color.setFill()
        color.setStroke()
        switch glyph {
        case .speaker:
            // bundled flaticon artwork (assets/speaker.png), tinted to the
            // quiet secondary color, aspect-fit in the box
            GGIconAsset.draw("speaker", tint: color, in: bounds)
            guard GGIconAsset.tinted("speaker", color) == nil else { return }
            // fallback if the asset is ever missing: speaker + one sound wave
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
            // bundled flaticon artwork (assets/headphones.png), tinted to
            // the quiet secondary color, aspect-fit in the box
            GGIconAsset.draw("headphones", tint: color, in: bounds)
            guard GGIconAsset.tinted("headphones", color) == nil else { return }
            // fallback: band over the top + two ear pads
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

// MARK: - Knob (layered flat dial: thick track, solid disk, number inside)

/// The app's one custom control — a LAYERED FLAT dial used for input
/// gain, output trim and monitor level, ONE compact size everywhere
/// (the layout pins it at 60 pt): a THICK subdued charcoal 270° track
/// (start 7:30, clockwise through left and top to 4:30 — the opening at
/// the bottom) with a flat value arc riding ON it, growing clockwise
/// from the lower-left as the value rises (midpoint = 12 o'clock, full =
/// the whole track — the arc is the fraction of the FULL RANGE from the
/// minimum). Inside the track: a SOLID center disk a clear step
/// lighter than the panel, carrying the value itself — the signed whole
/// number ("+19", "-5", bare "0"), 12pt tabular numerals, CENTERED in
/// the disk. No unit inside: the dial shows the number only, and the
/// unit lives in the caption above ("Trim (dB)") and in the tooltip.
/// There is NO pointer or notch on the dial: the arc's end IS the
/// position. Depth is contrasting flat surfaces only: no gradients,
/// bevels, glow or decorative shadows; the whole control area is the
/// drag target.
///
/// WHAT the value is decides how it is drawn (see `ValueKind`): a LIVE
/// hardware reading gets the green arc, a SAVED app-side setting gets a
/// neutral arc, and an UNKNOWN value (the device is unreachable) shows
/// "—" with no arc at all. A control whose arc carries its own meaning
/// (the output trim: gray at unity, green below it, red above it)
/// overrides the default with `arcColor` — the ARC is always the color
/// carrier, so the number inside stays off-white.
///
/// Interaction: drag vertically (up = more, ⇧ = slower), arrow keys step
/// ±1, double-click the number to type an exact value into an inline
/// editor (`valueField` — the editor is the precise path; typed
/// decimals still reach the hardware).
final class GainKnob: NSControl {

    /// What the knob's value represents — it decides the arc's color
    /// and whether a value is shown at all.
    enum ValueKind {
        /// A LIVE hardware reading (input preamp gain, monitor level) —
        /// green arc: known, active, read from the device.
        case live
        /// A SAVED app-side setting (the output trim) — the value is
        /// real and applied, but it is not a hardware reading, so the
        /// arc stays neutral and the value is identified as saved.
        case saved
        /// Nothing is known yet (the device is unreachable) — no arc,
        /// no marker, "—".
        case unknown
    }

    var minValue: Double = 0 { didSet { _value = (min(max(_value, minValue), maxValue)).rounded(); needsDisplay = true; updateAccessibility() } }
    var maxValue: Double = 75 { didSet { _value = (min(max(_value, minValue), maxValue)).rounded(); needsDisplay = true; updateAccessibility() } }
    var sendsContinuously = true
    /// What the value represents — live, saved, or unknown.
    var valueKind: ValueKind = .live {
        didSet { needsDisplay = true; updateAccessibility() }
    }
    /// True when a value is known (live or saved).
    private var hasValue: Bool { valueKind != .unknown }
    /// The ARC's color, when the control's own state decides it (the
    /// output trim: gray at unity, green below it, red above it). nil =
    /// the default for the value's kind — green for a live reading,
    /// neutral for a saved setting. The number inside the knob always
    /// stays off-white: the ARC is the color carrier.
    var arcColor: NSColor? { didSet { needsDisplay = true } }
    /// The control's name — the tooltip and the accessibility label
    /// read "Preamp gain: +19 dB".
    var controlName: String = "Level" { didSet { updateAccessibility() } }
    /// The unit — in the tooltip and the accessibility label only; the
    /// dial itself shows the number alone.
    var unit: String = "dB" { didSet { updateAccessibility() } }

    private var _value: Double = 0
    /// Values are WHOLE numbers — the setter rounds (display + writes).
    override var doubleValue: Double {
        get { _value }
        set {
            _value = (min(max(newValue, minValue), maxValue)).rounded()
            needsDisplay = true
            updateAccessibility()
        }
    }

    /// The value in words: "+19 dB" (or "—" when nothing is known).
    private var valueText: String {
        guard hasValue else { return "—" }
        let n = Int(doubleValue)
        return "\(n > 0 ? "+" : "")\(n) \(unit)"
    }

    /// The full value and unit live here — the tooltip and the
    /// accessibility label — because the dial itself shows the number
    /// only.
    private func updateAccessibility() {
        let shown = hasValue ? valueText : "unknown"
        toolTip = "\(controlName): \(shown) — double-click to type an exact value"
        setAccessibilityLabel(hasValue ? "\(controlName), \(shown)" : "\(controlName), unknown")
    }

    /// The inline precise-entry field (double-click). The controller
    /// wires it with a tag + delegate matching the numeric field each
    /// knob replaces.
    let valueField = NSTextField()
    private var isEditing = false
    private var editorY: NSLayoutConstraint?
    private var fieldWidth: NSLayoutConstraint?

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
        fieldWidth = valueField.widthAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            valueField.centerXAnchor.constraint(equalTo: centerXAnchor),
            editorY!,
            fieldWidth!,
            valueField.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    /// The editor is never wider than the knob it sits in.
    override func layout() {
        super.layout()
        if let fieldWidth {
            fieldWidth.constant = min(44, max(24, bounds.width - 4))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Fallback size only — the window layout pins every knob at 60 pt
    /// (as tall as the Auto Gain + toggle block it sits beside).
    override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }
    override var acceptsFirstResponder: Bool { isEnabled }

    @discardableResult
    private func send() -> Bool { sendAction(action, to: target) }

    // MARK: geometry — the layered dial scales with bounds
    /// The track's radius — the CENTER line of the thick stroke,
    /// inset so its outer edge never clips the bounds.
    private var trackRadius: CGFloat { bounds.width / 2 - stroke / 2 - 0.75 }
    /// The THICK track + value-arc stroke weight, scaling with the dial
    /// (a 60-pt knob = 5.1, a 40-pt one = 3.4) — the reference dial's
    /// charcoal band, not a thin ring.
    private var stroke: CGFloat { max(2.2, bounds.width * 0.085) }
    /// The solid CENTER DISK — ~62% of the dial's width, leaving a ring
    /// of panel visible between disk and track (the layered look).
    private var diskRadius: CGFloat { bounds.width / 2 * 0.62 }
    /// Type scale — the value/unit follow the dial's size (never smaller
    /// than 78%, so the number stays readable on a 32-pt dial).
    private var typeScale: CGFloat { max(0.78, min(bounds.width / 52, 1)) }
    /// Track: start 7:30 (225°), sweep 270° clockwise to 4:30 (-45°).
    private static let startAngle: CGFloat = 225
    private static let sweepAngle: CGFloat = 270

    private var fraction: Double {
        maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
    }

    // MARK: drawing — four flat layers, depth by contrast (no shading)
    override func draw(_ dirtyRect: NSRect) {
        let enabled = isEnabled
        let c = NSPoint(x: bounds.midX, y: bounds.midY)

        // LAYER 1 — the CENTER DISK: a solid flat circle a clear step
        // LIGHTER than the panel (the knob's "body"). Disabled: a little
        // less lifted — an idle surface, present but inactive. NB
        // withAlphaComponent SETS the alpha — it does not scale it.
        let disk = enabled ? GGTheme.knobCenter
            : GGTheme.knobCenter.withAlphaComponent(0.15)
        disk.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - diskRadius, y: c.y - diskRadius,
                                    width: diskRadius * 2,
                                    height: diskRadius * 2)).fill()

        // LAYER 2 — the THICK charcoal track (the quiet remainder of the
        // dial, 270° with the opening at the bottom) + the flat value
        // arc riding ON it. Disabled: a neutral gray track, no value arc.
        func arc(_ sweep: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: trackRadius,
                        startAngle: Self.startAngle,
                        endAngle: Self.startAngle - sweep, clockwise: true)
            p.lineWidth = stroke
            p.lineCapStyle = .butt   // flat ends, like the reference dial
            return p
        }
        let track = enabled ? GGTheme.knobTrack
            : NSColor(white: 1, alpha: 0.09)
        track.setStroke()
        arc(Self.sweepAngle).stroke()
        let f = hasValue ? fraction : 0
        if f > 0.002, enabled {
            // GREEN is the default for a LIVE, known value; a SAVED
            // setting rides a neutral arc — unless the control's own
            // state says otherwise (the trim's level scale).
            let arcColor = self.arcColor
                ?? (valueKind == .live ? GGTheme.knobArc : GGTheme.knobSavedArc)
            arcColor.setStroke()
            arc(CGFloat(f) * Self.sweepAngle).stroke()
        }

        // LAYER 3 — the VALUE, inside the disk. There is no pointer or
        // notch on the dial: the arc's end IS the position, and the
        // number in the middle says what it is.

        guard !isEditing else { return }

        // LAYER 4 — the value: off-white, tabular, with an EXPLICIT sign
        // (+ positive, - negative, bare 0 at zero). The NUMBER only —
        // the unit lives in the caption above and in the tooltip. It is
        // CENTERED in the disk: horizontally on the dial's axis, and
        // vertically on the ink itself (the font's cap height), not on
        // the line box. No value known: "—". Disabled: still READABLE.
        let text: NSColor = hasValue ? GGTheme.knobValue : GGTheme.muted
        let n = Int(doubleValue)   // whole numbers only — the setter rounds
        let valueString = hasValue
            ? (n > 0 ? "+\(n)" : n < 0 ? "\(n)" : "0")
            : "—"
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12 * typeScale, weight: .medium)
        let value = NSAttributedString(
            string: valueString,
            attributes: [.font: valueFont,
                         .foregroundColor: text.withAlphaComponent(enabled ? 1 : 0.8)])
        let vs = value.size()
        if hasValue {
            // the digits stand ON the baseline: the baseline sits half a
            // cap height below the ink's centre
            value.draw(at: NSPoint(x: c.x - vs.width / 2,
                                   y: c.y - valueFont.capHeight / 2))
        } else {
            // the em dash is a bar a little above the baseline — put the
            // BAR (not the line box) in the middle of the disk.
            value.draw(at: NSPoint(x: c.x - vs.width / 2,
                                   y: c.y - valueFont.capHeight * 0.25))
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    /// The focus ring hugs the DIAL (a circle), not the square bounds.
    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - trackRadius,
                                    y: bounds.midY - trackRadius,
                                    width: trackRadius * 2,
                                    height: trackRadius * 2)).fill()
    }

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
    //   natural direction everywhere (scroll up = more, down = less);
    //   optional INVERTED direction via Settings ▸ General ▸ Knobs
    //   ("wheel down = more"); trackpad precise deltas accumulate to a
    //   whole step (values are whole numbers), classic mouse wheels one
    //   notch ≈ one step
    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, !isEditing else { super.scrollWheel(with: event); return }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        // Settings ▸ General ▸ Knobs: optional inverted direction
        // (wheel down = more, the classic mouse convention).
        let flip = UserDefaults.standard.bool(forKey: SettingsWindowController.invertScrollKey)
        var threshold = 8.0
        if event.hasPreciseScrollingDeltas {
            scrollAccum += Double(flip ? -dy : dy)
        } else {
            // classic mouse wheel: natural direction (up = more) and one
            // notch ≈ one step — wheels report small non-precise deltas,
            // so a low threshold (not the trackpad's) is what makes the
            // wheel FEEL working
            let d = Double(flip ? -dy : dy)
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

// MARK: - Signal-flow connector (the routing diagram's only decoration)

/// A thin, QUIET connector between two stages of the output path: a
/// hairline with a small arrowhead, drawn in the system separator
/// color. It says "this feeds that" and nothing more — no boxes, no
/// labels, no glow, no shadows, no patchbay.
final class FlowArrow: NSView {

    enum Direction { case down, right }

    private let direction: Direction
    /// The arrowhead's size — the SAME for every connector.
    private static let head: CGFloat = 3.5
    private static let lineWidth: CGFloat = 1

    init(_ direction: Direction) {
        self.direction = direction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        switch direction {
        case .down: return NSSize(width: 12, height: 8)
        case .right: return NSSize(width: 16, height: 8)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        GGTheme.flowLine.setStroke()
        let p = NSBezierPath()
        p.lineWidth = Self.lineWidth
        p.lineCapStyle = .butt
        p.lineJoinStyle = .miter
        let h = Self.head
        switch direction {
        case .down:
            // the view is NOT flipped — y grows upward, so "down" is
            // toward minY
            let x = bounds.midX
            p.move(to: NSPoint(x: x, y: bounds.maxY))
            p.line(to: NSPoint(x: x, y: bounds.minY + h))
            p.move(to: NSPoint(x: x - h / 2, y: bounds.minY + h))
            p.line(to: NSPoint(x: x, y: bounds.minY))
            p.line(to: NSPoint(x: x + h / 2, y: bounds.minY + h))
        case .right:
            let y = bounds.midY
            p.move(to: NSPoint(x: bounds.minX, y: y))
            p.line(to: NSPoint(x: bounds.maxX - h, y: y))
            p.move(to: NSPoint(x: bounds.maxX - h, y: y + h / 2))
            p.line(to: NSPoint(x: bounds.maxX, y: y))
            p.line(to: NSPoint(x: bounds.maxX - h, y: y - h / 2))
        }
        p.stroke()
    }
}

// MARK: - Disclosure chevron (the input strip's menu trigger)

/// A small "⌄" beside an input's name — the strip's MENU trigger. It
/// opens the strip's header menu (the home of the Learn action); the
/// name beside it stays the strip's SELECTOR, so the two never fight
/// over the same click.
final class ChevronView: NSControl {

    var onClick: (() -> Void)?
    /// Accent when the menu has something to offer (a control to learn),
    /// quiet gray otherwise.
    var isActive = false { didSet { needsDisplay = true } }
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = isActive ? GGTheme.accent
            : hovering ? GGTheme.softGray : GGTheme.muted
        let p = NSBezierPath()
        p.move(to: NSPoint(x: bounds.minX + 2.5, y: bounds.midY + 2.5))
        p.line(to: NSPoint(x: bounds.midX, y: bounds.midY - 1))
        p.line(to: NSPoint(x: bounds.maxX - 2.5, y: bounds.midY + 2.5))
        p.lineWidth = 1.2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
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
    /// Corner radius of the chip — the glyph buttons use a SMALLER one
    /// (their taller box would otherwise read as a pill).
    var cornerRadius: CGFloat = 6

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
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: cornerRadius, yRadius: cornerRadius)
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
        // A DISABLED control keeps a READABLE label — only its fill
        // recedes. Dimming the text as well would make a section of the
        // interface unreadable just because the device is away.
        let text: NSColor = !enabled ? GGTheme.muted
            : engaged ? GGTheme.darkText : GGTheme.idleLabel
        let attr = NSAttributedString(string: label, attributes: [.font: titleFont, .foregroundColor: text])
        let s = attr.size()
        attr.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                              y: (bounds.height - s.height) / 2 - 0.5))
    }
}

// MARK: - Plug-in slot (hover-reveal: name ⇄ power | open | browse)

/// A purely visual paint layer inside the plug-in slot — it draws what
/// its `drawBlock` draws and never intercepts anything.
private final class PaintView: NSView {
    var drawBlock: ((NSRect) -> Void)?
    override func draw(_ dirtyRect: NSRect) { drawBlock?(bounds) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The processing slot for an output pair — ONE compact component where
/// the old layout had three controls (plug-in selector popup + power
/// button + Open button):
///
///     NORMAL       [      RVox (m)      ]   the loaded plug-in's SHORT
///                                           name, centered, truncated
///                                           only when necessary; a
///                                           subtle accent WASH while
///                                           processing is enabled,
///                                           neutral gray when bypassed;
///                                           "Add Plug-in…" when empty
///     HOVER/FOCUS  [  ⏻  |  ≡≡  |  ▾  ]   the SAME bounds: the name
///                                           crossfades (0.12 s, alpha
///                                           only — nothing slides, the
///                                           slot never resizes) into
///                                           three action areas with
///                                           quiet vertical separators —
///                                           power (bypass toggle),
///                                           sliders (open the editor,
///                                           the WIDEST area), chevron
///                                           (choose / replace plug-in)
///
/// The flat fill is drawn ONCE by the slot and never changes on hover —
/// the reveal itself is the hover feedback; the enabled distinction
/// stays visible while the controls are shown (the accent wash persists
/// and the power glyph is accent-colored). The controls stay up while
/// the browse menu tracks (`beginMenuSession`/`endMenuSession`) or the
/// slot has keyboard focus (arrows pick an area, Return activates, Esc
/// resigns). Empty slot: no hover controls — the whole slot opens the
/// plug-in menu on click. Tooltips are per action: "Bypass processing.",
/// "Open plug-in", "Choose plug-in." Flat only: no gradients, bevels or
/// shadows; the corner radius matches the other chips.
final class PluginSlotView: NSControl {

    // MARK: state — set by the controller's refresh

    /// The loaded plug-in's SHORT display name; nil = the empty slot.
    var pluginName: String? {
        didSet {
            guard pluginName != oldValue else { return }
            namePaint.needsDisplay = true
            refreshTooltips()
            refreshAccessibility()
            syncReveal(animated: false)   // an emptied slot never shows controls
        }
    }
    /// Processing enabled — the accent wash + the accent power glyph.
    /// (The controller folds `bypassAll` into this.)
    var processingEnabled = false {
        didSet {
            guard processingEnabled != oldValue else { return }
            needsDisplay = true                // the wash
            controlsPaint.needsDisplay = true   // the power glyph tint
            refreshAccessibility()
        }
    }
    /// The output pair this slot drives (used by the controller's menu).
    var pairIndex = 0

    // MARK: actions — the controller wires these at build time

    var onPower: (() -> Void)?
    var onOpen: (() -> Void)?
    var onBrowse: (() -> Void)?

    // MARK: presentation state

    private var hovering = false
    private var focused = false
    private var menuOpen = false
    private var controlsVisible = false
    /// The area under the pointer (0 power / 1 open / 2 browse) — the
    /// per-area hover highlight.
    private var hoverArea = -1
    /// The keyboard-picked area while the slot holds focus.
    private var selectedArea = 1

    private let namePaint = PaintView()
    private let controlsPaint = PaintView()

    private var hasPlugin: Bool { pluginName != nil }
    /// Chip geometry — the M/D/∑ chips' height, the chips' corner.
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }
    private var radius: CGFloat { 6 }
    /// The narrow side areas (power, browse); the open area gets the rest.
    private var sideWidth: CGFloat { 26 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
        wantsLayer = true
        for p in [namePaint, controlsPaint] {
            p.translatesAutoresizingMaskIntoConstraints = false
            p.wantsLayer = true
            addSubview(p)
        }
        controlsPaint.alphaValue = 0        // the name is up first
        namePaint.drawBlock = { [weak self] rect in self?.drawName(rect) }
        controlsPaint.drawBlock = { [weak self] rect in self?.drawControls(rect) }
        NSLayoutConstraint.activate([
            namePaint.leadingAnchor.constraint(equalTo: leadingAnchor),
            namePaint.trailingAnchor.constraint(equalTo: trailingAnchor),
            namePaint.topAnchor.constraint(equalTo: topAnchor),
            namePaint.bottomAnchor.constraint(equalTo: bottomAnchor),
            controlsPaint.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsPaint.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsPaint.topAnchor.constraint(equalTo: topAnchor),
            controlsPaint.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        namePaint.needsDisplay = true
        controlsPaint.needsDisplay = true
        refreshTooltips()
    }

    // MARK: areas

    /// 0 = power, 1 = open, 2 = browse — by x position.
    private func area(at p: NSPoint) -> Int {
        p.x < sideWidth ? 0 : (p.x > bounds.width - sideWidth ? 2 : 1)
    }
    private func areaRect(_ a: Int) -> NSRect {
        switch a {
        case 0: return NSRect(x: 0, y: 0, width: sideWidth, height: bounds.height)
        case 2: return NSRect(x: bounds.width - sideWidth, y: 0,
                              width: sideWidth, height: bounds.height)
        default: return NSRect(x: sideWidth, y: 0,
                               width: bounds.width - sideWidth * 2, height: bounds.height)
        }
    }

    // MARK: the flat fill — the slot's own background (never animated)

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        // enabled = a subtle accent wash; bypassed/empty = the shared
        // idle fill. It does NOT change on hover — the reveal is the
        // hover feedback, and the enabled state stays legible while
        // the controls are shown.
        let fill = hasPlugin && processingEnabled
            ? GGTheme.accent.withAlphaComponent(0.14)
            : GGTheme.idleFill
        fill.setFill()
        path.fill()
        GGTheme.idleBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: the name layer (normal state)

    private func drawName(_ rect: NSRect) {
        if let name = pluginName {
            drawCentered(name, in: rect,
                         color: processingEnabled ? GGTheme.primary : GGTheme.softGray)
        } else {
            // the empty slot's invitation — quiet, but the same weight
            drawCentered("Add Plug-in…", in: rect, color: GGTheme.softGray)
        }
    }

    private func drawCentered(_ s: String, in rect: NSRect, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail   // only when necessary
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
        // VERTICAL CENTERING: draw(in:) lays the line from the TOP of
        // the rect, so a full-height rect leaves the ink sitting high
        // in a 22-pt slot. Draw into a LINE-BOX-height rect centered
        // in the slot instead — the measured ink centroid lands within
        // 0.2 pt of the slot's center. Truncation still applies — the
        // box keeps the slot's full inset width.
        let box = rect.insetBy(dx: 10, dy: 0)
        let h = ceil(attr.size().height)
        attr.draw(in: NSRect(x: box.minX,
                             y: box.midY - h / 2,
                             width: box.width, height: h))
    }

    // MARK: the controls layer (hover/focus state)

    private func drawControls(_ rect: NSRect) {
        // quiet vertical separators between the three areas
        GGTheme.idleBorder.withAlphaComponent(0.7).setStroke()
        for x in [sideWidth, bounds.width - sideWidth] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 4))
            line.line(to: NSPoint(x: x, y: bounds.height - 4))
            line.lineWidth = 1
            line.stroke()
        }
        // the keyboard-picked area — the accent follows the selection
        if focused, hoverArea < 0 {
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: areaRect(selectedArea).insetBy(dx: 1.5, dy: 1.5),
                         xRadius: radius - 1.5, yRadius: radius - 1.5).fill()
        }
        // the hovered area — a restrained lift
        if hoverArea >= 0 {
            NSColor(white: 1, alpha: 0.08).setFill()
            NSBezierPath(roundedRect: areaRect(hoverArea).insetBy(dx: 1.5, dy: 1.5),
                         xRadius: radius - 1.5, yRadius: radius - 1.5).fill()
        }
        // power — accent while enabled, quiet gray while bypassed (the
        // distinction is visible IN the hover state too)
        drawPowerGlyph(in: areaRect(0).center,
                       color: processingEnabled ? GGTheme.accent : GGTheme.idleLabel)
        // open — the sliders, the widest area
        drawSlidersGlyph(in: areaRect(1).center, color: GGTheme.idleLabel)
        // browse — the chevron
        drawChevronGlyph(in: areaRect(2).center, color: GGTheme.idleLabel)
    }

    private func drawPowerGlyph(in c: NSPoint, color: NSColor) {
        // circle broken at the top + a stem through the gap
        let r = bounds.height * 0.22
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

    private func drawSlidersGlyph(in c: NSPoint, color: NSColor) {
        // three mini faders — track lines with staggered handle ticks
        color.setStroke()
        for (dx, handle) in [(CGFloat(-5), CGFloat(2.5)), (0, -2.5), (5, 0.5)] {
            let track = NSBezierPath()
            track.move(to: NSPoint(x: c.x + dx, y: c.y - 6))
            track.line(to: NSPoint(x: c.x + dx, y: c.y + 6))
            track.lineWidth = 1.3
            track.lineCapStyle = .round
            track.stroke()
            let h = NSBezierPath()
            h.move(to: NSPoint(x: c.x + dx - 2.2, y: c.y + handle))
            h.line(to: NSPoint(x: c.x + dx + 2.2, y: c.y + handle))
            h.lineWidth = 1.8
            h.lineCapStyle = .round
            h.stroke()
        }
    }

    private func drawChevronGlyph(in c: NSPoint, color: NSColor) {
        color.setStroke()
        let v = NSBezierPath()
        v.move(to: NSPoint(x: c.x - 4, y: c.y + 1.8))
        v.line(to: NSPoint(x: c.x, y: c.y - 2.2))
        v.line(to: NSPoint(x: c.x + 4, y: c.y + 1.8))
        v.lineWidth = 1.6
        v.lineCapStyle = .round
        v.lineJoinStyle = .round
        v.stroke()
    }

    // MARK: the reveal (a quick subtle crossfade — nothing slides)

    private func syncReveal(animated: Bool = true) {
        let want = hasPlugin && (hovering || focused || menuOpen)
        guard want != controlsVisible else { return }
        controlsVisible = want
        refreshTooltips()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                namePaint.animator().alphaValue = want ? 0 : 1
                controlsPaint.animator().alphaValue = want ? 1 : 0
            }
        } else {
            namePaint.alphaValue = want ? 0 : 1
            controlsPaint.alphaValue = want ? 1 : 0
        }
    }

    // MARK: hover

    private var hoverTracker: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracker { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                               owner: self, userInfo: nil)
        hoverTracker = t
        addTrackingArea(t)
        syncPointerInside()   // bounds changed — maybe under the pointer
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        syncReveal()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if menuOpen { return }   // the menu keeps the controls up
        syncReveal()
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let a = controlsVisible && bounds.contains(p) ? area(at: p) : -1
        if a != hoverArea {
            hoverArea = a
            controlsPaint.needsDisplay = true
        }
    }

    /// Re-evaluate "pointer inside" from the window's live mouse
    /// location — used after bounds changes and after the menu closes
    /// (the exited event may never have arrived while it tracked).
    private func syncPointerInside() {
        guard let w = window else { return }
        hovering = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        if !menuOpen { syncReveal() }
    }

    // MARK: the menu session — controls stay up while it tracks

    func beginMenuSession() {
        menuOpen = true
        hovering = true   // the click that opened it was inside
        syncReveal(animated: false)
    }
    func endMenuSession() {
        menuOpen = false
        syncPointerInside()
        syncReveal()
    }

    // MARK: mouse — name state = browse; controls = three areas

    override func mouseDown(with event: NSEvent) {
        // NAME state (or the empty slot): the whole slot is the browse
        // action, and menus open on PRESS — like a popup button.
        if !controlsVisible {
            onBrowse?()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let start = area(at: p)
        if start == 2 {   // browse opens on press too
            onBrowse?()
            return
        }
        // power + open commit on mouse-UP inside their area — the
        // deliberate chip behavior; dragging between areas follows
        var a: Int = start
        defer { syncPointerInside() }
        while true {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
            switch ev.type {
            case .leftMouseDragged:
                let q = convert(ev.locationInWindow, from: nil)
                let na = bounds.contains(q) ? area(at: q) : -1
                if na != a {
                    a = na
                    hoverArea = na
                    controlsPaint.needsDisplay = true
                }
            default:
                if a == 0 { onPower?() }
                else if a == 1 { onOpen?() }
                return
            }
        }
    }

    // MARK: keyboard — focus shows the controls; arrows + Return drive them

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            focused = true
            selectedArea = 1   // open — the widest, most-used action
            controlsPaint.needsDisplay = true
            syncReveal()
        }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            focused = false
            syncReveal()
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow:
            selectedArea = selectedArea <= 0 ? 2 : selectedArea - 1
            controlsPaint.needsDisplay = true
        case .rightArrow:
            selectedArea = selectedArea >= 2 ? 0 : selectedArea + 1
            controlsPaint.needsDisplay = true
        case .carriageReturn:
            activate(selectedArea)
        default:
            // space (49) activates; escape (53) gives the focus back
            switch event.keyCode {
            case 49: activate(selectedArea)
            case 53: window?.makeFirstResponder(nil)
            default: super.keyDown(with: event)
            }
        }
    }

    /// Fire one of the three actions (the empty slot only ever browses).
    private func activate(_ a: Int) {
        guard hasPlugin else { onBrowse?(); return }
        switch a {
        case 0: onPower?()
        case 1: onOpen?()
        default: onBrowse?()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    /// The focus ring hugs the slot's rounded shape.
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    // MARK: tooltips — one per action

    private func refreshTooltips() {
        removeAllToolTips()
        guard bounds.width > 0 else { return }
        if !hasPlugin || !controlsVisible {
            // the whole slot browses in the name state
            _ = addToolTip(bounds, owner: self, userData: nil)
        } else {
            for a in 0...2 { _ = addToolTip(areaRect(a), owner: self, userData: nil) }
        }
    }

    /// The tooltip OWNER method (`view:stringForToolTip:point:userData:`
    /// — the ObjC NSViewToolTipOwner selector; the protocol isn't
    /// imported into Swift, so it's @objc by hand).
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        if !hasPlugin || !controlsVisible { return "Choose plug-in." }
        let a = point.x < sideWidth ? 0
            : point.x > bounds.width - sideWidth ? 2 : 1
        switch a {
        case 0: return "Bypass processing."
        case 1: return "Open plug-in"
        default: return "Choose plug-in."
        }
    }

    // MARK: accessibility

    private func refreshAccessibility() {
        if let n = pluginName {
            setAccessibilityLabel("Plug-in \(n), processing " +
                                  (processingEnabled ? "enabled" : "bypassed"))
        } else {
            setAccessibilityLabel("Empty plug-in slot")
        }
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Bypass processing",
                                        target: self, selector: #selector(axPower)),
            NSAccessibilityCustomAction(name: "Open plug-in",
                                        target: self, selector: #selector(axOpen)),
            NSAccessibilityCustomAction(name: "Choose plug-in",
                                        target: self, selector: #selector(axBrowse)),
        ])
    }

    @objc private func axPower(_ action: NSAccessibilityCustomAction) -> Bool {
        activate(0); return true
    }
    @objc private func axOpen(_ action: NSAccessibilityCustomAction) -> Bool {
        activate(1); return true
    }
    @objc private func axBrowse(_ action: NSAccessibilityCustomAction) -> Bool {
        activate(2); return true
    }
}

private extension NSRect {
    /// A rect's center point (glyph anchor).
    var center: NSPoint { NSPoint(x: midX, y: midY) }
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
        // bundled flaticon artwork (assets/microphone-black-shape.png),
        // tinted to the state color, aspect-fit in a centered 17pt box
        GGIconAsset.draw("microphone-black-shape", tint: color,
                         in: bounds.insetBy(dx: 7.5, dy: 7.5))
        if GGIconAsset.tinted("microphone-black-shape", color) != nil { return }
        // fallback: compact microphone silhouette — capsule body, U cradle,
        // stem, base — ~15pt of ink in the 32pt frame, 1.5 stroke weight to
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

/// Auto Gain — the top-bar chip: one click calibrates the SELECTED
/// input's preamp. The ANIMATION lives on each input's own Auto Gain
/// button (so "Auto Gain All" lights every running input); this chip
/// stays a plain action.
final class AutoGainIconButton: IconButton {
    override func drawGlyph(color: NSColor) {
        // bundled flaticon artwork (assets/equalizer.png — faders), tinted
        // to the state color, aspect-fit in a centered 18pt box
        GGIconAsset.draw("equalizer", tint: color, in: bounds.insetBy(dx: 7, dy: 7))
        if GGIconAsset.tinted("equalizer", color) != nil { return }
        // fallback: three vertical faders
        let u = bounds.height / 32
        let ox = bounds.midX - 16 * u, oy = bounds.midY - 16 * u
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
        color.setStroke()
        for (x, y) in [(CGFloat(11), CGFloat(20)), (CGFloat(16), CGFloat(23)), (CGFloat(21), CGFloat(18))] {
            let track = NSBezierPath()
            track.move(to: pt(x, 9))
            track.line(to: pt(x, 23))
            track.lineWidth = 1.4 * u
            track.lineCapStyle = .round
            track.stroke()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: ox + (x - 2.5) * u, y: oy + (y - 2) * u,
                                             width: 5 * u, height: 4 * u),
                         xRadius: 1 * u, yRadius: 1 * u).fill()
        }
    }
}

/// Global mute — one click mutes BOTH monitor outputs (Main Speakers +
/// Headphones — every hardware mute the app controls), clicking again
/// unmutes them. Coral red with a SLASHED speaker while all outputs are
/// muted; plain speaker on a neutral chip otherwise.
final class MuteAllIconButton: IconButton {
    override func drawGlyph(color: NSColor) {
        // bundled flaticon artwork (assets/unmute.png — speaker with sound
        // waves — while live, assets/mute.png — speaker with an ✕ — while
        // all outputs are muted), tinted to the state color, aspect-fit in
        // a centered 18pt box
        let name = isEngaged ? "mute" : "unmute"
        GGIconAsset.draw(name, tint: color, in: bounds.insetBy(dx: 7, dy: 7))
        if GGIconAsset.tinted(name, color) != nil { return }
        // fallback: speaker (housing + cone) with sound waves — the classic
        // volume glyph, ~15pt wide with breathing room, 1.5 stroke weight
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

/// Settings — opens the Settings window. The same 32-pt icon chip as
/// its neighbors (Talkback · Mute-All) at the header's top right, but a
/// plain MOMENTARY button: no engaged state, the click just fires.
final class SettingsIconButton: IconButton {
    override func drawGlyph(color: NSColor) {
        // bundled flaticon artwork (assets/setting.png — gear), tinted to
        // the state color, aspect-fit in a centered 18pt box
        GGIconAsset.draw("setting", tint: color, in: bounds.insetBy(dx: 7, dy: 7))
        if GGIconAsset.tinted("setting", color) != nil { return }
        // fallback: a simple gear — circle + notched rim
        let u = bounds.height / 32
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        color.setStroke()
        let gear = NSBezierPath()
        gear.appendArc(withCenter: c, radius: 8 * u,
                       startAngle: 0, endAngle: 360, clockwise: false)
        gear.lineWidth = 2 * u
        gear.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3 * u, y: c.y - 3 * u,
                                    width: 6 * u, height: 6 * u)).fill()
    }

    /// Momentary: fire the action WITHOUT toggling state — the chip has
    /// no engaged appearance (settings is a plain action, not a toggle).
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        while true {
            guard let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { return }
            guard ev.type == .leftMouseUp else { continue }
            let p = convert(ev.locationInWindow, from: nil)
            if bounds.contains(p) { _ = sendAction(action, to: target) }
            return
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
    /// The readings behind the strip's short message — shown in the
    /// expandable detail popover.
    private var autoGainDetail: String?
    /// Seconds left in the running measurement (the countdown beside
    /// Cancel) — nil when nothing is counting.
    private var autoGainRemaining: Double?
    private var autoGainStatusTimer: Timer?

    /// Feedback-strip message kinds — the INDICATOR slot carries the
    /// color (blue activity, green success, amber warning, red error);
    /// the text stays neutral and readable.
    enum FeedbackKind {
        case idle, activity, success, warning, error
        /// The color of the indicator's single square (nil = empty slot).
        var indicatorColor: NSColor? {
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

    /// Coalesced refresh for the 10 Hz status bursts: with ALL inputs
    /// calibrating, each tick fires onStatus once per input (four, and the
    /// footer shows only ONE message anyway). Setting the fields is cheap;
    /// the full refresh is not — so batch every burst in this runloop turn
    /// into a single refresh. (Refreshes from other paths are untouched.)
    private var autoGainRefreshQueued = false
    private func scheduleAutoGainRefresh() {
        guard !autoGainRefreshQueued else { return }
        autoGainRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.autoGainRefreshQueued = false
            self.refresh()
        }
    }

    func show() {
        if window == nil { build() }
        refreshSampleRatePopup()
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
        // keep the title-bar dropdown on the ACTUAL live hardware rate
        // (rebuilds only when the advertised list changes)
        refreshSampleRatePopup()
        let connected = isGlueConnected?() ?? false
        let learning = isLearning
        let autoRunning = AutoGainEngine.shared.runningInputs

        // INPUTS
        for i in 0..<4 {
            let st = inputs[i]
            let t = PathIds.active
            let lineMode = st.refLevel == 2 || st.refLevel == 3
            levelPopups[i].isEnabled = connected && !learning && t.hwinRefLevel[i] != nil && autoRunning.isEmpty
            // the hardware level is UNKNOWN while the device is away —
            // the tree still holds the last value, but it is not live
            if connected, let rl = st.refLevel {
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
            // disabled while ANY calibration runs — the channel button is
            // an action at rest and a quiet activity display while its own
            // input is measuring
            autoGainButtons[i].isEnabled = preampActive && connected && !learning
                && autoRunning.isEmpty
            // Auto Gain is an ACTION at rest. While THIS input is being
            // measured (or in its beat of green after a success), the
            // label clears and the animated BORDER owns the button's
            // own outline — "Measuring…" breathing inside while it runs,
            // "Done" in green for a beat after (the ONE Cancel lives in
            // the feedback strip below).
            let done = !mineRunning && autoGainDoneInput == i
            let agTitle = (mineRunning || done) ? "" : "Auto Gain"
            autoGainButtons[i].bezelColor = nil
            autoGainButtons[i].attributedTitle = NSAttributedString(
                string: agTitle,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: GGTheme.softGray])
            let border = autoGainBorders[i]
            border.isHidden = !mineRunning && !done
            if mineRunning { border.startMeasuring() }
            else if done { border.showDone() }
            else { border.setIdle() }

            let micId = t.hwinMicGain[i], instId = t.hwinInstGain[i]
            gainKnobs[i].isEnabled = preampActive && connected && !learning
                && micId != nil && instId != nil && autoRunning.isEmpty
            let shown: Double
            if st.refLevel == 4 { shown = st.instGain ?? st.micGain ?? 0 }
            else { shown = st.micGain ?? st.instGain ?? 0 }
            if gainKnobs[i].doubleValue != shown { gainKnobs[i].doubleValue = shown }
            // a LIVE hardware reading — or "—" when the device is
            // unreachable: the tree still holds the last value, but it
            // is stale, so it is not shown as if it were live
            gainKnobs[i].valueKind = (connected && (st.micGain != nil || st.instGain != nil))
                ? .live : .unknown

            // 48V applies to Mic mode only — visible but grayed elsewhere
            setToggle(toggles48V[i], st.phantom,
                      enabled: preampActive && st.refLevel != 4
                          && connected && !learning && t.hwinPhantom[i] != nil)
            setToggle(softLimitToggles[i], st.softLimit,
                      enabled: connected && !learning && t.hwinSoftLimit[i] != nil)
            setToggle(polarityToggles[i], st.polarity,
                      enabled: connected && !learning && t.hwinPolarity[i] != nil)

            inputHeaders[i]?.stringValue = st.name ?? "Analog In \(i + 1)"

            // the strip's menu — the Learn action lives there now (no
            // permanent Learn button under the strip). The chevron
            // lights up only when there is something to learn AND the
            // device is there to learn it from.
            let missing = missingInputTargets(i)
            inputChevrons[i].isActive = connected
                && (!missing.isEmpty || (learning && learningColumn == .input(i)))
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

            // Processing slot — ONE component carries the whole state:
            // the plug-in's short name (or "Add Plug-in…" when empty)
            // and the enabled treatment (the subtle accent wash).
            let slot = pluginSlots[i]
            slot.pluginName = server.pluginName(i).map { InsertServer.shortName($0) }
            slot.processingEnabled = server.enabled(i) && !server.bypassAll

            let trim = server.trim(i)
            if trimKnobs[i].doubleValue != trim { trimKnobs[i].doubleValue = trim }
            // the trim is a SAVED app-side setting — a real, applied
            // value, but not a hardware reading (the caption above the
            // knob says so)
            trimKnobs[i].valueKind = .saved
            // The ARC carries the level: gray at unity (0 dB), green
            // below it (attenuation — the safe direction), red above it
            // (boost — it can clip). The number stays off-white.
            trimKnobs[i].arcColor = Self.trimArcColor(trimKnobs[i].doubleValue)
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
            // a LIVE hardware reading — or "—" when the device is
            // unreachable: the tree still holds the last value, but it
            // is stale, so it is not shown as if it were live
            monKnobs[o].valueKind = (connected && st.gain != nil) ? .live : .unknown

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
        // the top-bar Auto Gain chip is a plain action: it calibrates
        // EVERY Mic/Instrument input at once. The animation lives on each
        // input's own button, and the footer owns the Cancel.
        let agRunning = !autoRunning.isEmpty
        autoGainTopButton?.state = .off
        autoGainTopButton?.isEnabled = connected && !learning && !agRunning
        autoGainTopButton?.setAccessibilityLabel(agRunning ? "Auto Gain running" : "Auto Gain all inputs")
        autoGainTopButton?.toolTip = agRunning
            ? "Auto Gain — a calibration is running"
            : "Auto Gain — all inputs"
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
    /// runs, Dismiss on lingering results and Details… while the device
    /// is unavailable. Priority: learn → auto gain → connection → insert
    /// hint → Ready. The strip's height is reserved, so messages never
    /// move the monitor controls.
    private func updateFeedback(connected: Bool, insertLive: Bool) {
        let kind: FeedbackKind
        let message: String
        var action: FeedbackAction = .none

        if let learn = learnStatus() {
            kind = .activity
            message = learn
        } else if let ag = autoGainStatus {
            kind = autoGainKind
            message = ag
            if AutoGainEngine.shared.isRunning {
                action = .cancel
            } else if autoGainStatusTimer != nil {
                action = .dismiss
            }
        } else if !connected {
            // The device is not there: say so plainly, and offer the
            // diagnostic that explains WHY.
            kind = .warning
            message = "Device unavailable — waiting for Apogee Control 2."
            action = .details
        } else if !insertLive {
            kind = .idle
            message = "Plug-in insert is off — loading a plug-in or changing a source turns it on"
        } else {
            kind = .idle
            message = "Ready"
        }

        // the status dot carries the message's color
        feedbackDot?.layer?.backgroundColor = (kind.indicatorColor ?? NSColor.clear).cgColor

        if feedbackLabel?.stringValue != message { feedbackLabel?.stringValue = message }
        feedbackLabel?.textColor = kind == .idle ? GGTheme.muted : GGTheme.primary

        // the remaining time sits NEXT TO Cancel — the message text
        // itself never changes while it counts down
        if let left = autoGainRemaining {
            feedbackTime?.stringValue = String(format: "%.0f s left", max(0, left))
            feedbackTime?.isHidden = false
        } else {
            feedbackTime?.isHidden = true
        }

        feedbackActionKind = action
        switch action {
        case .cancel:
            feedbackAction?.title = "Cancel"
            feedbackAction?.isHidden = false
        case .dismiss:
            feedbackAction?.title = "Dismiss"
            feedbackAction?.isHidden = false
        case .details:
            feedbackAction?.title = "Details…"
            feedbackAction?.isHidden = false
        case .none:
            feedbackAction?.isHidden = true
        }
    }

    /// What the footer's action button does.
    private enum FeedbackAction {
        case none
        case cancel      // Auto Gain is running
        case dismiss     // a lingering Auto Gain result
        case details     // the device is unavailable — show diagnostics
    }

    /// Cancel (Auto Gain running) / Dismiss (lingering result) /
    /// Details… (the diagnostic behind "Device unavailable").
    @objc private func feedbackActionClicked(_ sender: NSButton) {
        switch feedbackActionKind {
        case .cancel:
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
        case .dismiss:
            autoGainStatus = nil
            autoGainStatusTimer?.invalidate()
            autoGainStatusTimer = nil
        case .details:
            showFeedbackPopover()
            return
        case .none:
            break
        }
        refresh()
    }

    /// Why the device is not there — the details behind the footer's
    /// "Device unavailable" message.
    private func deviceDiagnostics() -> String {
        let glue = (isGlueConnected?() ?? false)
            ? "connected" : "not connected"
        let live = InsertServer.deviceSampleRate()
        let device = live == nil ? "not found" : "found"
        let rate = live.map { Self.rateLabel($0) } ?? "—"
        let insert = InsertServer.shared.running ? "running" : "off"
        return """
        Apogee Control 2 (Glue): \(glue)
        Core Audio device: \(device)
        Sample rate: \(rate)
        Plug-in insert: \(insert)
        """
    }

    /// Long messages expand into a popover on click — the footer never
    /// grows. Auto Gain's readings live here, not in the strip; the
    /// device diagnostic lives here too.
    private func showFeedbackPopover() {
        let text = feedbackLabel?.stringValue ?? ""
        guard !text.isEmpty, text != "Ready" else { return }
        let detail = autoGainDetail ?? ""
        var body = detail.isEmpty ? text : text + "\n\n" + detail
        if feedbackActionKind == .details {
            body = "Device unavailable\n\n" + deviceDiagnostics()
        }
        let label = NSTextField(wrappingLabelWithString: body)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = GGTheme.primary
        label.preferredMaxLayoutWidth = 320
        let vc = NSViewController()
        vc.view = label
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 340, height: body.isEmpty ? 60 : 110)
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
        case .monitor(let o): where_ = o == 0 ? "Speakers" : "Headphones"
        case nil: return nil
        }
        return "Learn (\(learnQueue.count) left) — in Apogee Control 2, wiggle “\(target.label)” " +
               "for \(where_), then come back. Choose the same menu again to skip."
    }

    // MARK: - build

    // input cards (index 0…3)
    private var inputHeaders: [NSTextField?] = []
    private var levelPopups: [NSPopUpButton] = []
    private var meters: [GGLevelMeter] = []
    private var gainKnobs: [GainKnob] = []
    private var autoGainButtons: [NSButton] = []
    /// The animated border inside each input's Auto Gain button — one
    /// per channel, so "Auto Gain All" lights every running input.
    private var autoGainBorders: [GGBorderScanLight] = []
    /// The input whose run just SUCCEEDED — its button holds a beat of
    /// green ("Done") before returning to normal.
    private var autoGainDoneInput: Int?
    private var toggles48V: [NSButton] = []
    private var softLimitToggles: [NSButton] = []
    private var polarityToggles: [NSButton] = []
    /// The header chevron of each input strip — the trigger for the
    /// strip's menu (the home of the Learn action).
    private var inputChevrons: [ChevronView] = []

    // routing cards (index 0…3)
    private var nameFields: [NSTextField] = []
    private var sourcePopups: [NSPopUpButton] = []
    private var includeChecks: [NSButton] = []
    private var pluginSlots: [PluginSlotView] = []
    private var trimKnobs: [GainKnob] = []

    // monitor strip (index 0 = Main Speakers, 1 = Headphones)
    private var monKnobs: [GainKnob] = []
    private var muteToggles: [NSButton] = []
    private var dimToggles: [NSButton] = []
    private var monoToggles: [NSButton] = []
    private var talkbackButton: TalkbackIconButton?
    private var muteAllButton: MuteAllIconButton?
    /// The top-bar Auto Gain chip (equalizer icon).
    private var autoGainTopButton: AutoGainIconButton?

    // footer feedback strip
    private var feedbackDot: NSView?
    private var feedbackLabel: SelectLabel?
    private var feedbackAction: NSButton?
    /// The remaining time, next to Cancel (the message text stays steady).
    private var feedbackTime: NSTextField?
    /// What the footer's action button does right now.
    private var feedbackActionKind: FeedbackAction = .none

    private var subtitleField: NSTextField!
    /// Compact sample-rate dropdown at the far right of the title bar —
    /// a device-wide setting, kept apart from monitoring / Auto Gain.
    private var sampleRatePopup: NSPopUpButton!
    /// True while the dropdown shows the "Sample rate —" placeholder
    /// (the device is unreachable, so the active rate is unknown).
    private var sampleRateUnknown = false
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
    //   routing: 2050/2100/2200/2600/2650 + i (the plug-in slot's menu
    //            items carry the bare pair index instead)
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

        // --- assemble: four regions pinned with autolayout — title bar,
        // the MONITOR BAR (monitoring + global controls), the scrolling
        // inputs/outputs, and the feedback strip at the bottom.
        let header = makeHeader()
        let monitorBar = makeMonitorBar()
        let scroll = makeScrollArea()
        let monitor = makeMonitorStrip()
        content.addSubview(header)
        content.addSubview(monitorBar)
        content.addSubview(scroll)
        content.addSubview(monitor)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            monitorBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            monitorBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            monitorBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            monitorBar.heightAnchor.constraint(equalToConstant: 72),

            scroll.topAnchor.constraint(equalTo: monitorBar.bottomAnchor, constant: 0),
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
        w.minSize = NSSize(width: 1060, height: 420)
        window = w
        // The window HUGS its content: every control stays content-sized
        // vertically, so when the layout changes the window gets shorter
        // (or taller) instead of the rows growing to fill it. NSWindow
        // sizes to the contentView's fitting size otherwise, and the
        // intrinsic size is tiny — so the height is measured from the
        // laid-out document.
        content.layoutSubtreeIfNeeded()
        let docHeight = scrollDoc?.frame.height ?? 0
        let footerHeight = monitor.frame.height
        let needed = 44 + 72 + docHeight + footerHeight
        w.setContentSize(NSSize(width: 1060, height: max(420, needed.rounded(.up))))
        w.center()
        // open at the TOP of the sections: the doc is NOT flipped, so its
        // origin is the bottom — scrolling to 0 shows the bottom (status
        // line) and leaves the Inputs header clipped at the top.
        content.layoutSubtreeIfNeeded()
        if let d = scrollDoc {
            d.scroll(NSPoint(x: 0, y: d.bounds.maxY))
        }
    }

    /// Unified title bar: title + quiet device name on the left — the
    /// same window material throughout, framed by a hairline at its
    /// bottom. The global controls (Talkback · Mute-All · Settings) live
    /// in the monitor bar right below.
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

        let divider = Hairline()
        header.addSubview(divider)

        // FAR RIGHT — the device-wide sample rate: value + unit only
        // ("48 kHz ▾"), no permanent label, same compact dropdown
        // styling as the rest of the app. Vertically centered in the
        // bar, right edge aligned with the Settings button below.
        let rate = NSPopUpButton()
        rate.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rate.controlSize = .small
        rate.autoenablesItems = true
        rate.translatesAutoresizingMaskIntoConstraints = false
        rate.toolTip = "Sample rate"
        rate.setAccessibilityLabel("Sample rate")
        rate.target = self
        rate.action = #selector(sampleRateChanged(_:))
        header.addSubview(rate)
        sampleRatePopup = rate

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            rate.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            rate.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            // wide enough for the "Sample rate —" placeholder too, so
            // the title bar never reflows when the device goes away
            rate.widthAnchor.constraint(equalToConstant: 118),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    /// "48000" → "48 kHz" (one decimal when needed, e.g. 44.1 / 88.2).
    private static func rateLabel(_ r: Double) -> String {
        let khz = r / 1000
        let text = khz.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        return "\(text) kHz"
    }

    /// (Re)build the sample-rate menu from the rates the device
    /// advertises, selecting the ACTUAL live hardware rate — never just
    /// the last requested one. Rebuilds only when the list changes so
    /// an open menu is never disturbed.
    ///
    /// When the device is unreachable the ACTIVE rate is unknown, so the
    /// dropdown says "Sample rate —" instead of showing a default that
    /// reads as live; the control is disabled, because a rate cannot be
    /// written to a device that is not there.
    private func refreshSampleRatePopup() {
        guard let popup = sampleRatePopup else { return }
        // Source of truth = the LIVE CoreAudio hardware rate — it follows the
        // clock directly. The glue tree is only a fallback: lastTree is
        // refreshed on full-tree syncs only, NOT on setProperty echoes, so a
        // tree-sourced rate is STALE right after our own write (the popup
        // would "snap back" to the pre-write rate — live-tested Oct 21 2026).
        let treeRate = onSeedTree?().flatMap { tree -> Double? in
            guard let serial = GlueClient.quartetSerial(in: tree) else { return nil }
            func find(_ n: [String: Any]) -> [String: Any]? {
                if n["type"] as? String == serial { return n }
                for c in n["children"] as? [[String: Any]] ?? [] {
                    if let r = find(c) { return r }
                }
                return nil
            }
            return find(tree).flatMap { GlueClient.doubleProp($0, "samplerate") }
        }
        let deviceRate = InsertServer.deviceSampleRate()
        // A tree that belongs to a device that has gone away is STALE:
        // it may still carry the last rate, but it is not the active
        // one. Core Audio is the authority while the device is there.
        let live = deviceRate ?? ((isGlueConnected?() ?? false) ? treeRate : nil)

        guard let live else {
            // UNKNOWN: no device, no rate. Say so — never pass a default
            // off as a live value.
            if !sampleRateUnknown {
                popup.removeAllItems()
                popup.addItem(withTitle: "Sample rate —")
                sampleRateUnknown = true
            }
            popup.isEnabled = false
            popup.toolTip = "Sample rate — the device is unavailable"
            return
        }
        sampleRateUnknown = false
        popup.isEnabled = true
        popup.toolTip = "Sample rate"

        var rates = InsertServer.availableSampleRates()
        if !rates.contains(live) { rates = ([live] + rates).sorted() }
        let current = popup.itemArray.compactMap { ($0.representedObject as? NSNumber)?.doubleValue }
        if current != rates {
            // Rebuild through the popup's OWN item API (exactly like
            // popupLabel does for the working dropdowns): addItem +
            // representedObject, NO per-item target/action (item actions
            // shadow the button's and dispatch with the ITEM as sender —
            // the popup's action then never fires and the selection just
            // snaps back), and autoenablesItems on.
            popup.removeAllItems()
            for r in rates {
                popup.addItem(withTitle: Self.rateLabel(r))
                popup.lastItem?.representedObject = NSNumber(value: r)
            }
        }
        if let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? NSNumber)?.doubleValue == live }) {
            popup.selectItem(at: idx)
        }
    }

    @objc func sampleRateChanged(_ sender: Any?) {
        QBLog.log("control: sampleRateChanged fired")
        // The popup routes the action with the button as sender — but read
        // through the stored handle anyway, robust to either dispatch.
        let popup = (sender as? NSPopUpButton) ?? sampleRatePopup
        guard !suppressActions,
              let popup,
              let requested = (popup.selectedItem?.representedObject as? NSNumber)?.doubleValue,
              requested != InsertServer.deviceSampleRate() else {
            refreshSampleRatePopup()
            return
        }
        // Preferred path: the Quartet's OWN control protocol — setProperty on
        // the device node's `samplerate` (path-id = java31 hash, var-tag 4
        // double; live-verified Oct 21 2026, see docs/protocol-notes.md).
        // Fallback when Glue is offline: the plain CoreAudio property write.
        if isGlueConnected?() == true, let serial = PathIds.activeSerial {
            let id = PathIds.hash("/dev/\(serial)/samplerate")
            onWriteDouble?(id, requested)
            QBLog.log("control: setProperty samplerate \(Int(requested)) Hz via glue (id \(id.map { String(format: "%02x", $0) }.joined()))")
        } else {
            InsertServer.setDeviceSampleRate(requested)
            QBLog.log("control: setProperty samplerate \(Int(requested)) Hz via CoreAudio (glue offline)")
        }
        // The device re-locks its clock asynchronously — hold the requested
        // selection while polling, until the live rate CONFIRMS it (or the
        // poll times out and we resync to whatever is actually active).
        pollSampleRate(0, requested: requested)
    }

    /// ~4 s of 0.3 s checks after a rate request. While the clock is
    /// re-locking, CoreAudio may still report the OLD rate — don't let the
    /// popup snap back to it; hold the requested selection, and only resync
    /// from the live hardware once it confirms (or on timeout).
    private func pollSampleRate(_ attempt: Int, requested: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let popup = self.sampleRatePopup else { return }
            let live = InsertServer.deviceSampleRate()
            if let live, live == requested {
                // confirmed — show the truth and resync the insert's cache
                self.refreshSampleRatePopup()
                InsertServer.shared.refreshRate()
                return
            }
            if attempt >= 12 {
                // never settled — resync to whatever is actually active
                self.refreshSampleRatePopup()
                InsertServer.shared.refreshRate()
                return
            }
            self.pollSampleRate(attempt + 1, requested: requested)
        }
    }

    /// The MONITOR BAR — a compact strip directly below the title bar:
    /// the two monitor groups (Speakers · Headphones) together on the
    /// LEFT, the global controls (Talkback · Mute-All · Settings) on the
    /// RIGHT. One hairline under it; no card, no new background.
    private func makeMonitorBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        // LEFT — the two monitor groups, identical in size and layout,
        // separated by a short, low-contrast rule with space on both
        // sides. The cluster stays CONTENT-SIZED (the middle of the bar
        // is left empty on purpose).
        row.addArrangedSubview(makeMonitorGroup(0))
        let sepGap1 = NSView()
        sepGap1.translatesAutoresizingMaskIntoConstraints = false
        sepGap1.widthAnchor.constraint(equalToConstant: GGSpace.heading).isActive = true
        row.addArrangedSubview(sepGap1)
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(sep)
        let sepGap2 = NSView()
        sepGap2.translatesAutoresizingMaskIntoConstraints = false
        sepGap2.widthAnchor.constraint(equalToConstant: GGSpace.heading).isActive = true
        row.addArrangedSubview(sepGap2)
        row.addArrangedSubview(makeMonitorGroup(1))

        // flexible slack — the global controls sit at the far right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        // breathing room before the utility buttons
        let trioGap = NSView()
        trioGap.translatesAutoresizingMaskIntoConstraints = false
        trioGap.widthAnchor.constraint(equalToConstant: 20).isActive = true
        row.addArrangedSubview(trioGap)

        // RIGHT — the global controls
        let ag = AutoGainIconButton(tag: 0, accent: GGTheme.green,
                                     target: self, action: #selector(autoGainTopClicked(_:)))
        ag.toolTip = "Auto Gain — all inputs"
        ag.setAccessibilityLabel("Auto Gain all inputs")
        autoGainTopButton = ag

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

        let settings = SettingsIconButton(tag: 0, accent: GGTheme.accent,
                                          target: self, action: #selector(settingsClicked(_:)))
        settings.toolTip = "Settings…"
        settings.setAccessibilityLabel("Settings")

        let trio = NSStackView(views: [ag, mic, mute, settings])
        trio.spacing = 6
        trio.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(trio)

        bar.addSubview(row)
        let divider = Hairline()
        bar.addSubview(divider)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
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
        stack.spacing = GGSpace.related
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 6, right: 0)
        doc.addSubview(stack)

        // INPUTS section header: title left; the Auto Gain Target /
        // Duration settings right (the batch action lives in the top
        // bar now).
        let inputsHeader = sectionHeader(
            title: "Inputs",
            trailingViews: [
                popupLabel("Auto Gain Target", items: AutoGainEngine.targetOptions.map {
                    (String(format: "%.0f dBFS peak", $0), $0) }, action: #selector(targetChanged(_:))),
                popupLabel("Duration", items: AutoGainEngine.listenOptions.map {
                    (String(format: "%.0f s", $0), $0) }, action: #selector(timeChanged(_:))),
            ])
        stack.addArrangedSubview(inputsHeader)

        let inputGrid = makeInputGrid()
        stack.addArrangedSubview(inputGrid)

        // thin system separator between the two sections
        let sectionRule = Hairline()
        stack.addArrangedSubview(sectionRule)

        // OUTPUTS & ROUTING header: title only — no explanatory
        // subtitle (the visible controls say it all).
        let outTitle = NSTextField(labelWithString: "Outputs & Routing")
        outTitle.font = GGTheme.sectionFont
        outTitle.textColor = GGTheme.primary
        let outHeader = NSStackView()
        outHeader.orientation = .horizontal
        outHeader.alignment = .centerY
        outHeader.spacing = 10
        outHeader.translatesAutoresizingMaskIntoConstraints = false
        outHeader.addArrangedSubview(outTitle)
        let outSpacer = NSView()
        outSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        outHeader.addArrangedSubview(outSpacer)
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
        let stackLeading = stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: GGSpace.section)
        let stackTrailing = stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -GGSpace.section)
        stackLeading.priority = .init(999)
        stackTrailing.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stackLeading,
            stackTrailing,
            // EQUALITY both ends: the doc is exactly as tall as its
            // content — the sections hug their content (no stretched
            // empty bands); the scroll view handles overflow.
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            inputsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // full-width header (internal .leading alignment) so the
            // "Outputs & Routing" title sits left, aligned with "Inputs"
            outHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sectionRule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // the channel strips HUG their fixed content (4 strips + 3
            // rules) and center — pinning them to the stack width would
            // over-constrain the fixed strip widths
        ])
        // the spacing scale: a section heading sits close above its
        // strips, and the two sections are separated by a little more
        stack.setCustomSpacing(GGSpace.sectionHead, after: inputsHeader)
        stack.setCustomSpacing(GGSpace.sectionHead, after: outHeader)
        stack.setCustomSpacing(GGSpace.knob, after: inputGrid)
        stack.setCustomSpacing(GGSpace.knob, after: sectionRule)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // doc tracks the clip view's width (no h-scroll) and HUGS its
        // content's height — the sections size to their content instead
        // of being stretched to fill the window (that stretch was the
        // big empty band under every strip). The scroll view scrolls
        // when the content is taller than the window.
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            doc.heightAnchor.constraint(equalTo: stack.heightAnchor),
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
    /// its menu + type dropdown) over a thin meter, then the compact
    /// gain knob with Auto Gain + the 48V/SL/Ø chips beside it.
    ///
    /// There is NO permanent Learn row: the Learn action lives in the
    /// strip's header menu (the chevron beside the name), so the strip
    /// is exactly as tall as the controls it actually has.
    private func makeInputGrid() -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = GGSpace.related
        strip.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<4 {
            if i > 0 { addRule(to: strip) }

            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = GGSpace.related
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
            ])

            // HEADER — the channel NAME is the selector: clicking it
            // selects this strip (a thin accent marker beside the title
            // shows the selection; the panel itself never changes). The
            // chevron beside the name opens the strip's MENU — the home
            // of the Learn action. The compact type dropdown sits at
            // the right.
            let head = SelectLabel(frame: .zero)
            head.stringValue = "Analog In \(i + 1)"
            head.font = GGTheme.nameFont
            head.textColor = GGTheme.primary
            head.lineBreakMode = .byTruncatingTail
            head.onClick = { [weak self] in self?.selectInput(i) }
            inputHeaders.append(head)

            let marker = makeMarker()
            inputMarkers.append(marker)

            // the strip's menu trigger
            let chevron = ChevronView(frame: .zero)
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.toolTip = "Analog In \(i + 1) menu"
            chevron.onClick = { [weak self, weak chevron] in
                guard let self, let chevron else { return }
                self.showInputMenu(for: i, from: chevron)
            }
            inputChevrons.append(chevron)

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
            headerRow.spacing = GGSpace.tight
            headerRow.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addArrangedSubview(marker)
            headerRow.addArrangedSubview(head)
            headerRow.addArrangedSubview(chevron)
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
            // The knob is the standard 60-pt size (one component, two
            // sizes in the app) and shows the value only — no unit.
            let knob = GainKnob()
            knob.minValue = 0
            knob.maxValue = 75
            knob.doubleValue = 0
            knob.target = self
            knob.action = #selector(gainSlid(_:))
            knob.tag = 200 + i
            knob.sendsContinuously = true
            knob.controlName = "Preamp gain"
            knob.widthAnchor.constraint(equalToConstant: 60).isActive = true
            knob.heightAnchor.constraint(equalToConstant: 60).isActive = true
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
            ag.toolTip = "Auto Gain — measure this input's loudest level and set the preamp"
            autoGainButtons.append(ag)

            // the ACTIVITY DISPLAY lives in this button: while THIS input
            // is being measured, a thin blue light segment travels around
            // the button's OWN outline and "Measuring…" breathes inside —
            // the button's size, corners and flat fill never move. "Auto
            // Gain All" lights every running input's button at once.
            let border = GGBorderScanLight(frame: .zero)
            border.translatesAutoresizingMaskIntoConstraints = false
            border.isHidden = true
            ag.addSubview(border)
            NSLayoutConstraint.activate([
                border.leadingAnchor.constraint(equalTo: ag.leadingAnchor),
                border.trailingAnchor.constraint(equalTo: ag.trailingAnchor),
                border.topAnchor.constraint(equalTo: ag.topAnchor),
                border.bottomAnchor.constraint(equalTo: ag.bottomAnchor),
            ])
            autoGainBorders.append(border)

            // one compact row of toggles — 48V / SL / Ø (red / cyan /
            // purple when engaged; small intrinsic chips).
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            let tv = toggle("48V", 300 + i, GGTheme.red)
            tv.toolTip = "+48V phantom power"
            row.addArrangedSubview(tv)
            toggles48V.append(tv)
            let soft = toggle("SL", 400 + i, GGTheme.cyan)
            soft.toolTip = "Soft Limit"
            row.addArrangedSubview(soft)
            softLimitToggles.append(soft)
            let pol = toggle("Ø", 500 + i, GGTheme.purple)
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
            controlRow.spacing = GGSpace.knob
            controlRow.translatesAutoresizingMaskIntoConstraints = false
            controlRow.addArrangedSubview(knob)
            let midSpacer = NSView()
            midSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            controlRow.addArrangedSubview(midSpacer)
            controlRow.addArrangedSubview(right)
            col.addArrangedSubview(controlRow)
            controlRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

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
    /// rules as the inputs. Each strip reads as the actual SIGNAL PATH,
    /// top to bottom, with thin quiet connectors between the stages:
    ///
    ///     [ Playback 1–2 ▾ ]      the SOURCE
    ///     [ ] Include source processing
    ///           ↓
    ///     Audio FX          Trim  the two processing stages
    ///     [ Add Plug-in… ] → ( 0 dB )
    ///                    ↓
    ///                Out 1–2      the HARDWARE destination, last
    ///
    /// The source selector sits at the head of the path and the physical
    /// output pair at its end — the destination is no longer spelled out
    /// beside the source, where it read as a bypass of Audio FX and Trim.
    /// The plug-in slot is ONE hover-reveal control (the name ⇄ power |
    /// open | browse) and the trim is a knob; empty and loaded slots
    /// share identical dimensions.
    private func makeRoutingGrid() -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = GGSpace.related
        strip.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<4 {
            if i > 0 { addRule(to: strip) }

            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = GGSpace.related
            col.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                col.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
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
            headerRow.spacing = GGSpace.tight
            headerRow.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addArrangedSubview(marker)
            headerRow.addArrangedSubview(nf)
            col.addArrangedSubview(headerRow)
            nf.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor).isActive = true

            // SOURCE — the head of the path: a compact native dropdown
            // naming where the audio comes from.
            let sp = NSPopUpButton()
            sp.target = self
            sp.action = #selector(sourceChanged(_:))
            sp.tag = 2100 + i
            sp.font = NSFont.systemFont(ofSize: 11)
            sp.controlSize = .small
            sp.widthAnchor.constraint(equalToConstant: 124).isActive = true
            let srcRow = NSStackView()
            srcRow.orientation = .horizontal
            srcRow.alignment = .centerY
            srcRow.spacing = GGSpace.tight
            srcRow.translatesAutoresizingMaskIntoConstraints = false
            srcRow.addArrangedSubview(sp)
            // the dropdown keeps its own width; the rest of the row is
            // free space
            let srcGap = NSView()
            srcGap.translatesAutoresizingMaskIntoConstraints = false
            srcGap.setContentHuggingPriority(.init(1), for: .horizontal)
            srcGap.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            srcRow.addArrangedSubview(srcGap)
            col.addArrangedSubview(srcRow)
            srcRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            sourcePopups.append(sp)

            // "Include source processing" — a real CHECKBOX directly
            // beneath the source selector, in a reserved option row of
            // the SAME height in all four columns, so the processing
            // stages below line up. (Direct sources keep the row empty —
            // it never collapses.) The reserved height is the CHECKBOX's
            // own height — no magic number.
            let inc = NSButton(checkboxWithTitle: "Include source processing", target: self,
                               action: #selector(includeChanged(_:)))
            inc.tag = 2200 + i
            inc.font = NSFont.systemFont(ofSize: 11)
            inc.controlSize = .small
            inc.toolTip = "Mirror this output AFTER the source’s plug-in"
            let incRow = NSView()
            incRow.translatesAutoresizingMaskIntoConstraints = false
            incRow.addSubview(inc)
            NSLayoutConstraint.activate([
                inc.leadingAnchor.constraint(equalTo: incRow.leadingAnchor),
                inc.centerYAnchor.constraint(equalTo: incRow.centerYAnchor),
            ])
            // the reservation follows the checkbox, so the row is
            // exactly as tall as it needs to be — in every column
            incRow.heightAnchor.constraint(equalTo: inc.heightAnchor).isActive = true
            col.addArrangedSubview(incRow)
            includeChecks.append(inc)

            // CONNECTOR — the path drops from the source into the
            // processing stages. Thin and quiet: a hairline, no box. It
            // hangs under the MIDDLE of the source selector — the same
            // axis as the plug-in slot below it, so the chain reads
            // straight down. It is SHORT: a connector between nearby
            // stages, not a row of its own.
            let dropIn = FlowArrow(.down)
            let dropHolder = NSView()
            dropHolder.translatesAutoresizingMaskIntoConstraints = false
            dropHolder.addSubview(dropIn)
            col.addArrangedSubview(dropHolder)
            dropHolder.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            NSLayoutConstraint.activate([
                dropIn.centerXAnchor.constraint(equalTo: sp.centerXAnchor),
                dropIn.topAnchor.constraint(equalTo: dropHolder.topAnchor),
                dropIn.bottomAnchor.constraint(equalTo: dropHolder.bottomAnchor),
            ])
            col.setCustomSpacing(3, after: incRow)
            col.setCustomSpacing(3, after: dropHolder)

            // BODY — the two processing stages, side by side: Audio FX
            // (the plug-in slot) on the left, Trim (the knob) on the
            // right, joined by a short right-pointing connector.
            let tsl = GainKnob()
            tsl.minValue = -64
            tsl.maxValue = 6
            tsl.doubleValue = 0
            tsl.target = self
            tsl.action = #selector(trimSlid(_:))
            tsl.tag = 2600 + i
            tsl.sendsContinuously = true
            tsl.controlName = "Trim"
            tsl.widthAnchor.constraint(equalToConstant: 60).isActive = true
            tsl.heightAnchor.constraint(equalToConstant: 60).isActive = true
            trimKnobs.append(tsl)

            // precise entry — the old trim field's tag + delegate
            tsl.valueField.tag = 2650 + i
            tsl.valueField.delegate = self

            // the trim knob — alone in its column
            let knobCol = NSStackView()
            knobCol.orientation = .vertical
            knobCol.alignment = .centerX
            knobCol.spacing = 0
            knobCol.translatesAutoresizingMaskIntoConstraints = false
            knobCol.addArrangedSubview(tsl)

            // processing column — ONE hover-reveal plug-in slot (the
            // name ⇄ power | open | browse), replacing the old
            // selector + power + Open trio. Everything stays in place
            // in BOTH states: the empty slot shows "Add Plug-in…", a
            // loaded one shows its name; the three actions live in the
            // hover reveal.
            let slot = PluginSlotView()
            slot.pairIndex = i
            slot.onPower = { [weak self] in self?.slotPowerToggled(i) }
            slot.onOpen = { InsertServer.shared.showPluginUI(i) }
            slot.onBrowse = { [weak self, weak slot] in
                guard let self, let slot else { return }
                self.presentPluginMenu(for: slot)
            }
            pluginSlots.append(slot)

            let procCol = NSStackView()
            procCol.orientation = .vertical
            procCol.alignment = .leading
            procCol.spacing = GGSpace.tight
            procCol.translatesAutoresizingMaskIntoConstraints = false
            procCol.addArrangedSubview(slot)

            // ONE header row for the two stages — "Audio FX" over the
            // plug-in area, "Trim (dB)" over the knob — so the two
            // columns line up across all four strips. The two captions
            // share ONE baseline.
            let procLbl = NSTextField(labelWithString: "Audio FX")
            procLbl.font = GGTheme.labelFont
            procLbl.textColor = GGTheme.softGray
            // The unit rides in the caption, not inside the dial. The
            // trim is also a SAVED app-side setting, not a hardware
            // reading — that note lives in the caption's tooltip, out of
            // the label row.
            let trimCaption = NSTextField(labelWithString: "Trim (dB)")
            trimCaption.font = GGTheme.labelFont
            trimCaption.textColor = GGTheme.muted
            trimCaption.toolTip = "Saved setting — applied by the plug-in insert"
            // the caption sits in a 60-pt slot — the knob's width — so it
            // is centered exactly over the knob below it
            let trimSlot = NSView()
            trimSlot.translatesAutoresizingMaskIntoConstraints = false
            trimSlot.addSubview(trimCaption)
            trimCaption.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                trimSlot.widthAnchor.constraint(equalToConstant: 60),
                trimCaption.centerXAnchor.constraint(equalTo: trimSlot.centerXAnchor),
                trimCaption.centerYAnchor.constraint(equalTo: trimSlot.centerYAnchor),
            ])
            let colHeader = NSStackView()
            colHeader.orientation = .horizontal
            colHeader.spacing = GGSpace.knob
            colHeader.alignment = .firstBaseline
            colHeader.translatesAutoresizingMaskIntoConstraints = false
            colHeader.addArrangedSubview(procLbl)
            let headerSpacer = NSView()
            headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            colHeader.addArrangedSubview(headerSpacer)
            colHeader.addArrangedSubview(trimSlot)
            col.addArrangedSubview(colHeader)
            // the header row spans the card's width, so its "Trim" slot
            // sits exactly over the knob column below
            colHeader.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            // the captions sit close above the control row
            col.setCustomSpacing(4, after: colHeader)

            // The two stages, joined by the connector. The plug-in slot,
            // the arrow and the knob share ONE horizontal centre line —
            // that is what makes the path read as a path.
            let body = NSStackView()
            body.orientation = .horizontal
            body.spacing = GGSpace.tight
            body.alignment = .centerY
            body.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(procCol)
            let stageArrow = FlowArrow(.right)
            body.addArrangedSubview(stageArrow)
            body.addArrangedSubview(knobCol)
            // join the hierarchy BEFORE cross-view constraints (common
            // ancestor required at activation time)
            col.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            // the plug-in area takes the rest of the row: the row is the
            // slot + the connector + the 60-pt knob column
            procCol.widthAnchor.constraint(equalTo: body.widthAnchor,
                                           constant: -(60 + 16 + 6 + 6)).isActive = true
            slot.widthAnchor.constraint(equalTo: procCol.widthAnchor).isActive = true

            // DESTINATION — the hardware output pair, at the END of the
            // path. It sits under the trim column, exactly where the
            // signal leaves, so the chain reads straight down — and it
            // hugs the knob: the arrow and the label are one small
            // block, right beneath it.
            let dest = NSTextField(labelWithString: InsertServer.pairNames[i])
            dest.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            dest.textColor = GGTheme.softGray
            dest.alignment = .center
            dest.toolTip = "Hardware output pair \(InsertServer.pairNames[i])"
            let destBlock = NSStackView()
            destBlock.orientation = .vertical
            destBlock.alignment = .centerX
            destBlock.spacing = 1
            destBlock.translatesAutoresizingMaskIntoConstraints = false
            destBlock.addArrangedSubview(FlowArrow(.down))
            destBlock.addArrangedSubview(dest)
            destBlock.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let destRow = NSStackView()
            destRow.orientation = .horizontal
            destRow.alignment = .centerY
            destRow.spacing = 0
            destRow.translatesAutoresizingMaskIntoConstraints = false
            let destGap = NSView()
            destGap.translatesAutoresizingMaskIntoConstraints = false
            destGap.setContentHuggingPriority(.init(1), for: .horizontal)
            destRow.addArrangedSubview(destGap)
            destRow.addArrangedSubview(destBlock)
            col.addArrangedSubview(destRow)
            destRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            // the destination rides right under the knob
            col.setCustomSpacing(2, after: body)

            strip.addArrangedSubview(card)
        }
        return strip
    }

    // MARK: footer — monitor controls above, feedback strip below

    /// The footer is now ONLY the feedback strip: a slim, full-width
    /// RESERVED row (status dot + message + optional
    /// Cancel/Dismiss) — messages never move the monitor controls.
    private func makeMonitorStrip() -> NSView {
        let footer = NSStackView()
        footer.orientation = .vertical
        footer.spacing = 0
        footer.translatesAutoresizingMaskIntoConstraints = false

        // top hairline (subtle border against the routing area)
        let topDivider = Hairline()
        footer.addSubview(topDivider)

        // --- the feedback strip is now the ONLY thing in the footer
        // (the monitor controls live in the bar under the title bar)

        // the quiet status dot — it carries the message's color (blue
        // activity, green success, amber warning, red error)
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

        // the remaining time — sits NEXT TO Cancel, so the instruction
        // text itself stays steady while it counts down
        feedbackTime = NSTextField(labelWithString: "")
        feedbackTime?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        feedbackTime?.textColor = GGTheme.muted
        feedbackTime?.isHidden = true

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
        if let time = feedbackTime { feedbackRow.addArrangedSubview(time) }
        if let action = feedbackAction { feedbackRow.addArrangedSubview(action) }
        footer.addArrangedSubview(feedbackRow)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            // fixed, reserved height — messages NEVER move anything
            feedbackRow.heightAnchor.constraint(equalToConstant: 28),
            feedbackRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            feedbackRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            feedbackRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4),
        ])
        return footer
    }

    private func makeMonitorGroup(_ o: Int) -> NSView {
        // ONE balanced, FIXED-WIDTH group (both outputs are identical):
        //
        //     ( −32 )  Speakers             │   ( −36 )  Headphones
        //             [ M ] [ D ] [ ∑ ]     │             [ M ] [ D ] [ ∑ ]
        //
        // The knob is the volume control (the value only — no unit); the
        // title and the buttons below it share ONE left edge in both
        // groups.
        let body = NSStackView()
        body.orientation = .horizontal
        body.spacing = GGSpace.knob
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
        // the number only — the unit lives in the tooltip
        sl.controlName = o == 0 ? "Speakers level" : "Headphones level"
        sl.widthAnchor.constraint(equalToConstant: 60).isActive = true
        sl.heightAnchor.constraint(equalToConstant: 60).isActive = true
        body.addArrangedSubview(sl)
        monKnobs.append(sl)

        // precise entry — the old level field's tag + delegate
        sl.valueField.tag = 750 + o
        sl.valueField.delegate = self

        // the TEXT column — the title on top (clicking it opens the
        // "Learn Control…" menu), the three tiny chips below it, all
        // starting at the same left edge. Its width is FIXED, so the two
        // groups are exactly the same width.
        let textCol = NSStackView()
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = GGSpace.tight
        textCol.translatesAutoresizingMaskIntoConstraints = false
        textCol.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let name = SelectLabel(frame: .zero)
        name.stringValue = o == 0 ? "Speakers" : "Headphones"
        name.font = GGTheme.nameFont
        name.textColor = GGTheme.primary
        name.onClick = { [weak self] in self?.showLearnMenu(for: o, from: name) }
        textCol.addArrangedSubview(name)

        // M / D / ∑ — TINY chips under the name: Mute (coral red), DIM
        // (amber), Sum to mono (system accent) when active; neutral dark
        // gray at rest. Full names live in tooltips + accessibility.
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = GGSpace.tight
        btnRow.alignment = .centerY
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
        textCol.addArrangedSubview(btnRow)

        // the text column (the icon lives inside it, trailing the name)
        body.addArrangedSubview(textCol)

        return body
    }

    /// The input strip's header menu — the home of the Learn action
    /// (it used to be a permanent button row under every strip, which
    /// cost a whole row and made the strip taller than its content).
    /// "Learn Control…" starts the capture (or skips the current
    /// target while one runs); disabled when there's nothing to learn.
    private func showInputMenu(for i: Int, from view: NSView) {
        let menu = NSMenu()
        let learning = isLearning
        let item = NSMenuItem(title: learning ? "Skip current control…" : "Learn Control…",
                              action: #selector(learnClicked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = 600 + i
        // a capture listens to the device's own event stream — without
        // the device there is nothing to learn FROM
        item.isEnabled = learning || ((isGlueConnected?() ?? false)
                                      && !missingInputTargets(i).isEmpty)
        menu.items = [item]
        menu.popUp(positioning: item, at: NSPoint(x: 0, y: -4), in: view)
    }

    /// The group icon's menu — hardware mapping lives here now, not in
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
        // a capture listens to the device's own event stream — without
        // the device there is nothing to learn FROM
        item.isEnabled = learning || ((isGlueConnected?() ?? false)
                                      && !missingMonitorTargets(o).isEmpty)
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

    /// The keyboard shortcut's "calibrate every input" — the same batch
    /// the top-bar chip runs (the section's button is gone).
    @objc private func autoGainAllClicked(_ sender: NSButton) {
        if AutoGainEngine.shared.isRunning {
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
            return
        }
        startAutoGainAll()
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

    /// Show an Auto Gain line in the status area. `detail` carries the
    /// READINGS (preamp, peak) — they live in the expandable detail
    /// popover, not in the strip itself. `remaining` is the countdown
    /// shown NEXT TO Cancel (the message text itself stays steady).
    func showAutoStatus(_ line: String, clearAfter seconds: TimeInterval?,
                       detail: String? = nil, remaining: Double? = nil,
                       kind: FeedbackKind = .activity) {
        // FAST PATH: the message and readings are unchanged — only the
        // countdown ticked. Re-render the feedback strip (dot, text, the
        // seconds and the Cancel button) and skip the full window refresh,
        // which rebuilds every button's title/tooltip/accessibility and
        // costs orders of magnitude more.
        if autoGainStatus == line, autoGainDetail == detail,
           autoGainKind == kind, seconds == nil,
           let connected = isGlueConnected?() {
            autoGainRemaining = remaining
            updateFeedback(connected: connected, insertLive: InsertServer.shared.running)
            return
        }
        autoGainStatus = line
        autoGainDetail = detail
        autoGainRemaining = remaining
        autoGainKind = kind
        autoGainStatusTimer?.invalidate()
        if let seconds {
            autoGainStatusTimer = Timer.scheduledTimer(withTimeInterval: seconds,
                                                       repeats: false) { [weak self] _ in
                self?.autoGainStatus = nil
                self?.autoGainDetail = nil
                self?.autoGainRemaining = nil
                self?.autoGainStatusTimer = nil
                self?.refresh()
            }
        }
        // each running input's OWN button shows the activity display
        // (refresh() syncs the per-input borders) — coalesced, so a
        // four-input burst costs ONE full refresh
        scheduleAutoGainRefresh()
    }

    /// The calibration ENDED — the button restores itself, the footer
    /// explains the outcome:
    ///   success  → the footer says "Setting gain…" then "Gain set to
    ///              X dB."
    ///   cancelled→ the footer says "Auto Gain cancelled."
    ///   failed   → the footer states the problem
    /// The per-input buttons restore themselves — refresh() syncs them,
    /// and a successful input's button holds a beat of green ("Done")
    /// before it returns to normal.
    func showAutoGainResult(_ line: String, detail: String?, gain: Double?,
                            input: Int, outcome: AutoGainEngine.Outcome) {
        autoGainDetail = detail
        autoGainRemaining = nil
        autoGainStatusTimer?.invalidate()
        autoGainStatusTimer = nil

        switch outcome {
        case .success:
            // the button's beat of green — outline + "Done" — before it
            // returns to its normal surface
            autoGainDoneInput = input
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self, self.autoGainDoneInput == input,
                      !AutoGainEngine.shared.runningInputs.contains(input) else { return }
                self.autoGainDoneInput = nil
                self.refresh()
            }
            // APPLYING — the footer says so while the gain lands
            autoGainStatus = "Auto Gain · Setting gain…"
            autoGainKind = .activity
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                let value = gain.map { String(format: "%.1f dB", $0) } ?? "the new value"
                self.autoGainStatus = "Auto Gain · Gain set to \(value)."
                self.autoGainKind = .success
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    // …and the result line lingers a while (with a Dismiss
                    // action) before it clears
                    guard let self else { return }
                    self.autoGainStatusTimer = Timer.scheduledTimer(withTimeInterval: 12,
                                                                     repeats: false) { [weak self] _ in
                        self?.autoGainStatus = nil
                        self?.autoGainDetail = nil
                        self?.autoGainStatusTimer = nil
                        self?.refresh()
                    }
                    self.refresh()
                }
            }

        case .cancelled:
            autoGainDoneInput = nil
            autoGainStatus = "Auto Gain cancelled."
            autoGainKind = .idle
            autoGainStatusTimer = Timer.scheduledTimer(withTimeInterval: 4,
                                                       repeats: false) { [weak self] _ in
                self?.autoGainStatus = nil
                self?.autoGainDetail = nil
                self?.autoGainRemaining = nil
                self?.autoGainStatusTimer = nil
                self?.refresh()
            }
            scheduleAutoGainRefresh()

        case .failed:
            // the specific problem, in the footer
            autoGainDoneInput = nil
            autoGainStatus = line
            autoGainKind = .warning
            scheduleAutoGainRefresh()
            autoGainStatusTimer = Timer.scheduledTimer(withTimeInterval: 12,
                                                       repeats: false) { [weak self] _ in
                self?.autoGainStatus = nil
                self?.autoGainDetail = nil
                self?.autoGainRemaining = nil
                self?.autoGainStatusTimer = nil
                self?.refresh()
            }
        }
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

    /// The plug-in slot's POWER area — toggle processing for the pair
    /// (also the bypass shortcut's path). The flip is anchored to what
    /// the slot DISPLAYS (enabled minus the global bypass), exactly the
    /// old button's click semantics.
    private func slotPowerToggled(_ pair: Int) {
        guard !suppressActions else { return refresh() }
        let displayed = InsertServer.shared.enabled(pair) && !InsertServer.shared.bypassAll
        InsertServer.shared.setEnabled(pair, !displayed)
        if !displayed { ensureInsertRunning() }   // enabling means intent to run it
        refresh()
    }

    /// The plug-in slot's BROWSE area — the same menu the old selector
    /// popup carried (None + every AU, short names, a checkmark on the
    /// current choice), presented under the slot. The slot keeps its
    /// hover controls up while the menu tracks.
    private func presentPluginMenu(for slot: PluginSlotView) {
        let pair = slot.pairIndex
        let menu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "insertPair.\(pair).plugin") ?? ""
        func add(_ title: String, _ key: String) {
            let item = NSMenuItem(title: title,
                                   action: #selector(pluginMenuItemChosen(_:)),
                                   keyEquivalent: "")
            item.target = self
            item.tag = pair                  // the menu items carry the
            item.representedObject = key     // pair index + desc key
            item.state = key == current ? .on : .off
            menu.addItem(item)
        }
        add("None", "")
        for (name, desc) in InsertServer.listPlugins() {
            add(InsertServer.shortName(name), InsertServer.descKey(desc))
        }
        slot.beginMenuSession()
        menu.popUp(positioning: nil, at: NSPoint(x: 2, y: 0), in: slot)
        slot.endMenuSession()
    }

    /// A choice from the plug-in slot's browse menu (tag = the output
    /// pair, representedObject = the desc key, "" = None).
    @objc private func pluginMenuItemChosen(_ item: NSMenuItem) {
        let i = item.tag
        guard !suppressActions, let key = item.representedObject as? String else { return refresh() }
        let desc = key.isEmpty ? nil
            : InsertServer.listPlugins().first { InsertServer.descKey($0.desc) == key }?.desc
        InsertServer.shared.setPlugin(i, desc)
        if !key.isEmpty { ensureInsertRunning() }   // picking "None" doesn't start it
        refresh()
    }

    /// Output-trim knob (tag = 2600 + pair) — whole-number steps.
    @objc private func trimSlid(_ sender: NSControl) {
        let i = sender.tag - 2600
        let v = sender.doubleValue   // already whole (knob rounds)
        InsertServer.shared.setTrim(i, v, notify: false)
        // the ARC carries the level — it follows the drag live
        trimKnobs[i].arcColor = Self.trimArcColor(v)
    }

    /// The trim's arc color: gray at unity (0 dB), green BELOW it
    /// (attenuation — the safe direction), red ABOVE it (boost — it can
    /// clip). The number inside the knob stays off-white.
    private static func trimArcColor(_ v: Double) -> NSColor {
        v < 0 ? GGTheme.green : v > 0 ? GGTheme.red : GGTheme.knobSavedArc
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

    /// The top-bar Auto Gain chip: calibrate EVERY Mic/Instrument input
    /// at once (each running input's own button lights up). While a
    /// calibration runs the button is dimmed — the footer's Cancel owns
    /// that action.
    @objc private func autoGainTopClicked(_ sender: NSButton) {
        guard !suppressActions, !isLearning else { return refresh() }
        guard !AutoGainEngine.shared.isRunning else { return }
        startAutoGainAll()
    }

    /// Calibrate every input that can be calibrated (Mic / Instrument
    /// mode) in one batch.
    private func startAutoGainAll() {
        let calibratable = (0..<4).filter { i in
            if let rl = inputs[i].refLevel { return rl == 1 || rl == 4 }
            return false
        }
        guard !calibratable.isEmpty else {
            showAutoStatus("Auto Gain — no inputs in Mic/Instrument mode", clearAfter: 8,
                           kind: .warning)
            return
        }
        startAutoGain(for: calibratable)
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
        t.titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        // TINY chips — the same size as the per-input Ø (phase) button,
        // so they fit UNDER the output's name beside the knob
        t.widthAnchor.constraint(equalToConstant: 22).isActive = true
        t.heightAnchor.constraint(equalToConstant: 22).isActive = true
        t.cornerRadius = 4
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
        slotPowerToggled(selectedOutputIndex)
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
        // the engine's cancel path reports the outcome (and fades the
        // scanning light) — no extra status line here
        AutoGainEngine.shared.cancelAll(reason: "cancelled")
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