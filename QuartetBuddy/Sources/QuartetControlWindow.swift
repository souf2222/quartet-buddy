import AppKit
import CoreText

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
/// "Device unavailable — waiting for Apogee Control 2." — clicking it
/// opens the diagnostic popover. Only the controls that genuinely need
/// the device are disabled; every label stays readable.
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
/// plug-in enable); green only for Soft Limit + the live value
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
    /// and the neutral active functions: Ø, SUM, plug-in enable,
    /// Auto Gain running).
    static let accent = NSColor.controlAccentColor

    /// The pin's SELECTED blue — every blue on the pin toggle (ink,
    /// bed, border) is this one flat color with alpha, not the system
    /// accent, so the toggle's selected look is its own.
    static let pinBlue = hex("266FB6")

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

    // Toolbar state palette — STATE-driven fills (never hover/focus):
    //   talkback orange while active · green while unmuted · red while
    //   muted · purple while Auto Gain runs · neutral gray at rest.
    /// Talkback ACTIVE — solid orange.
    static let talkbackActive = hex("E68A32")
    /// Global mute tile — green while the outputs are UNMUTED.
    static let muteIdle = hex("35BA68")
    /// Global mute tile — red while Mute All is engaged.
    static let muteEngaged = hex("E25560")
    /// Auto Gain All — solid purple for the WHOLE run (measure + apply).
    static let autoGainRun = hex("9255C8")

    /// Near-black label ON flat accent fills.
    static let darkText = hex("101318")

    // Sample-rate readout (monitor-bar selector) — a compact numeric
    // instrument display.
    /// The selector's flat charcoal container (legacy).
    static let sampleFill = hex("25262C")
    /// The readout's flat, NEARLY BLACK surface — just darker than the
    /// toolbar material (no gradient, no border, no glow).
    static let sampleReadoutFill = hex("14141A")
    /// The primary readout text — cool off-white.
    static let sampleValue = hex("DEE3ED")
    /// The unit ("Hz") — muted, less dominant than the number.
    static let sampleUnit = hex("A8AFBD")

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

/// Pin — a STATE TOGGLE in the utility tray, between Mute All and
/// Settings: clicking it (or ⌘P) floats the window above ordinary ones.
/// THE SAME bundled push-pin art in BOTH states — identical footprint,
/// identical size — COLOR carries the state:
///   unpinned → muted gray ink on the shared neutral bed + subtle
///              border (the inactive utility buttons' own treatment),
///              a neutral hover lift;
///   pinned   → control-accent blue ink on a subtle blue-tinted bed
///              with a restrained blue border — visible WITHOUT hover:
///              the look persists no matter where the pointer goes.
/// Keyboard focus stays a separate, system-level exterior ring (see
/// FunctionButton), so the blue border never reads as focus.
final class PinIconButton: IconButton {

    var isPinned: Bool {
        get { isEnabled && state == .on }
        set { state = newValue ? .on : .off }
    }

    private func refreshTooltip() {
        toolTip = (state == .on)
            ? "Window stays on top — click to unpin"
            : "Keep window on top"
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true; refreshTooltip() }
    }

    init(tag: Int, target: AnyObject?, action: Selector) {
        super.init(tag: tag, accent: GGTheme.pinBlue, target: target, action: action)
        refreshTooltip()
        setAccessibilityLabel("Pin window on top")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let pinned = state == .on
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        if pinned {
            // SELECTED: subtle blue bed + restrained blue border — steady;
            // shown whether or not the pointer is here. (Keyboard focus is
            // a SEPARATE, system-level exterior ring — see FunctionButton —
            // so the blue border never reads as focus.)
            GGTheme.pinBlue.withAlphaComponent(0.16).setFill()
            path.fill()
            GGTheme.pinBlue.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            // REST: the inactive utility buttons' own treatment — neutral
            // dark fill with the same subtle border — so the toggle reads
            // as part of the toolbar, not a loose attachment; hover gets
            // the shared lift.
            (hovering ? GGTheme.hoverFill : GGTheme.idleFill).setFill()
            path.fill()
            GGTheme.idleBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        drawGlyph(color: pinned ? GGTheme.pinBlue : GGTheme.softGray)
    }

    override func drawGlyph(color: NSColor) {
        // BOTH STATES: the same bundled filled art, shipped diagonal
        // (head upper-right, needle lower-left), aspect-fit and
        // centered — just under the Settings gear's 18 pt box.
        GGIconAsset.draw("push-pin", tint: color,
                         in: bounds.insetBy(dx: 8.5, dy: 8.5))
        if GGIconAsset.tinted("push-pin", color) != nil { return }
        drawVectorPin(color: color)
    }

    /// The pushpin as a vector fallback: ring head, angled shoulders,
    /// tapered needle — an UPRIGHT local frame rotated −45° into the
    /// art's rest pose (head upper-right, needle lower-left), filled.
    private func drawVectorPin(color: NSColor) {
        let u = bounds.height / 32
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        NSGraphicsContext.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: c.x, yBy: c.y)
        tr.rotate(byDegrees: -45)
        tr.translateX(by: -c.x, yBy: -c.y)
        tr.concat()
        // UPRIGHT local silhouette (y-up, stylized units):
        //   top of body → left wing tip → waist → needle tip (mirrored)
        let body = NSBezierPath()
        body.move(to: NSPoint(x: c.x - 1.5 * u, y: c.y + 2.6 * u))
        body.line(to: NSPoint(x: c.x - 4.2 * u, y: c.y + 0.6 * u))  // angled shoulder
        body.line(to: NSPoint(x: c.x - 1.2 * u, y: c.y - 1.0 * u))
        body.line(to: NSPoint(x: c.x, y: c.y - 7.4 * u))            // needle
        body.line(to: NSPoint(x: c.x + 1.2 * u, y: c.y - 1.0 * u))
        body.line(to: NSPoint(x: c.x + 4.2 * u, y: c.y + 0.6 * u))  // angled shoulder
        body.line(to: NSPoint(x: c.x + 1.5 * u, y: c.y + 2.6 * u))
        body.close()
        let head = NSBezierPath(ovalIn: NSRect(x: c.x - 2.9 * u, y: c.y + 1.9 * u,
                                               width: 5.8 * u, height: 5.4 * u))
        color.setFill()
        body.fill()
        head.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

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
/// The analog channel's INPUT LEVEL bargraph — the continuous
/// horizontal peak meter under the channel heading, spanning the
/// channel width. READ-ONLY, and deliberately SEPARATE from the gain
/// knob: the knob shows the hardware preamp GAIN, the bar shows the
/// incoming SIGNAL.
///
/// A flat 6-pt track with a recessed graphite bed; the level rises as a
/// CONTINUOUS fill through fixed color zones — green below −18 dBFS,
/// amber to −6, red above — so the bar's POSITION reads the level
/// instead of the whole strip changing color on every peak. A thin
/// off-white peak-hold marker rides inside the track (the tap's
/// instantiate-catch/2 s-hold/fall behavior drives it); at the far
/// right edge a small CLIP lamp — ignited when the channel's samples
/// touch full scale, staying red until CLICKED: entering the red zone
/// is a warning, the lamp is the record of an actual clip (its own
/// latch). No permanent numbers: the held peak reads in the tooltip
/// ("Peak −14 dBFS"), and the Auto Gain target shows as a transient
/// blue marker only while the channel is being calibrated.
final class GGLevelMeter: NSView {

    /// Fixed zone boundaries on the shared −60…0 dBFS display scale
    /// (fraction 1 = 0 dBFS): −18 dBFS = 0.7, −6 dBFS = 0.9 — the SAME
    /// thresholds the ADAT dial's arc uses.
    private static let amberZone: CGFloat = 0.7
    private static let redZone: CGFloat = 0.9

    /// The live level fraction (tap feed: fast rise, smooth decay).
    private(set) var level: Double = 0
    /// The held peak's fraction (tap's 2 s hold then fall; nil = below
    /// the display floor — nothing to show).
    private(set) var peakFraction: Double?
    /// The Auto Gain target's fraction — present ONLY while the channel
    /// is being calibrated (nil = the quiet interface).
    private(set) var targetFraction: Double?
    /// The lamp's latch — set by a full-scale sample, cleared by a click.
    private var clipLatched = false { didSet { needsDisplay = true } }

    /// ONE 10 Hz feed (adatUpdateTick): the live level, the held peak,
    /// the transient Auto Gain target and the engine's full-scale-sample
    /// flag — the LATCH itself lives here, so the lamp stays red until
    /// the user resets it even when the tick's flag auto-decays.
    func update(level: Double, peakFraction: Double?,
                targetFraction: Double?, clip: Bool) {
        self.level = level
        self.peakFraction = peakFraction
        self.targetFraction = targetFraction
        if clip { clipLatched = true }
        needsDisplay = true
        // the peak value reads in the hover tooltip — "Peak −14 dBFS"
        var tip = "Peak " + Self.dbfsText(peakFraction)
        if clipLatched { tip += " · clipped — click to reset" }
        if toolTip != tip { toolTip = tip }
    }

    /// A display fraction → "−14 dBFS" text (U+2212); no known peak →
    /// "−∞", so the tooltip stays honest about silence.
    private static func dbfsText(_ fraction: Double?) -> String {
        guard let f = fraction, f.isFinite, f > 0 else { return "−∞" }
        let db = Int((f * 60 - 60).rounded())
        return "\(db) dBFS".replacingOccurrences(of: "-", with: "−")
    }

    /// A 6-pt row is a needle to click — the lamp's reset target spans a
    /// taller band around the track (the row spacings, not the neighbor
    /// controls).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.x >= bounds.minX, local.x <= bounds.maxX else { return nil }
        return abs(local.y - bounds.midY) <= 10 ? self : nil
    }

    /// Click to reset the latched clip lamp (read-only otherwise).
    override func mouseDown(with event: NSEvent) {
        if clipLatched {
            clipLatched = false
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        GGTheme.inset.setFill()
        trackPath.fill()
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()

        // the CLIP lamp cell at the right edge — the fill's run stops
        // short of it (the lamp is drawn OVER the fill), so the lamp
        // reads as a separate indicator, never as more red zone
        let lamp = NSRect(x: track.maxX - 4.5, y: track.minY,
                          width: 4.5, height: track.height)
        (clipLatched ? GGTheme.red : NSColor(white: 1, alpha: 0.10)).setFill()
        lamp.fill()

        // continuous fill through the fixed zones — each zone is drawn
        // on top of the previous, so the color changes exactly at the
        // boundary fraction while the LEFT portion keeps its color
        let fill = min(max(level, 0), 1) * track.width
        if fill > 0 {
            GGTheme.green.setFill()
            NSRect(x: track.minX, y: track.minY, width: fill,
                   height: track.height).fill()
            let amberMin = track.minX + track.width * Self.amberZone
            if fill > amberMin {
                GGTheme.amber.setFill()
                NSRect(x: amberMin, y: track.minY, width: fill - amberMin,
                       height: track.height).fill()
            }
            let redMin = track.minX + track.width * Self.redZone
            if fill > redMin {
                GGTheme.red.setFill()
                NSRect(x: redMin, y: track.minY, width: fill - redMin,
                       height: track.height).fill()
            }
        }

        // the Auto Gain target — a thin blue marker, calibration only
        if let tf = targetFraction, tf > 0 {
            let x = track.minX + track.width * min(max(tf, 0), 1)
            GGTheme.scanTrail.withAlphaComponent(0.9).setFill()
            NSRect(x: x - 0.75, y: track.minY, width: 1.5,
                   height: track.height).fill()
        }

        // the held peak — a narrow off-white marker, clamped short of
        // the clip lamp
        if let pf = peakFraction, pf > 0 {
            let x = track.minX + track.width * min(max(pf, 0), 1)
            let markX = min(max(x - 1, track.minX + 1), lamp.minX - 2)
            GGTheme.offWhite.setFill()
            NSRect(x: markX, y: track.minY + 1, width: 2,
                   height: track.height - 2).fill()
        }

        NSGraphicsContext.restoreGraphicsState()
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
    /// False = an EMPTY-CENTER dial (the trim knob beside the plug-in
    /// slot: the readout lives in the slot, the dial shows only the
    /// track + position arc).
    var showsCenterValue = true

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
    /// True when the editor ended via Esc — commit nothing, keep the old value.
    var editCancelled = false
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

        // LAYER 3/4 — the VALUE inside the disk (unless this dial is an
        // empty-center one — the trim knob's readout lives in the slot).
        guard !isEditing, showsCenterValue else { return }

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
        // Draw on an EXPLICIT baseline (CTLine's origin IS the baseline —
        // unlike draw(at:), which places the line-box origin and leaves the
        // ink sitting off-center by the font's descent): the digits' ink
        // spans baseline…baseline+capHeight, so putting baseline half a cap
        // height below the dial's centre centers the INK exactly (both
        // axes). The em dash's ink sits just above the baseline — bias its
        // baseline accordingly.
        if let ctx = NSGraphicsContext.current?.cgContext {
            let line = CTLineCreateWithAttributedString(value)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let baseline = hasValue ? c.y - valueFont.capHeight / 2
                                    : c.y - valueFont.capHeight * 0.32
            ctx.textPosition = CGPoint(x: c.x - width / 2, y: baseline)
            CTLineDraw(line, ctx)
        } else {
            value.draw(at: NSPoint(x: c.x - vs.width / 2,
                                   y: c.y - valueFont.capHeight / 2))
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
        editCancelled = false
        valueField.stringValue = String(format: "%.0f", doubleValue)
        valueField.isHidden = false
        needsDisplay = true
        window.makeFirstResponder(valueField)
        valueField.selectText(nil)
    }

    /// Cancel the inline editor WITHOUT committing (Esc).
    func cancelEditing() {
        guard isEditing else { return }
        editCancelled = true
        endEditing()
        editCancelled = false
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

    // MARK: mouse (vertical drag; ⇧ = slow; ⌘ = zero; double-click → type)
    /// True while the pointer DRAGS the knob (mouseDown runs its own
    /// synchronous event loop until release). Observers get onDragChange
    /// at both the start and the end — scroll/keyboard steps never flip
    /// it.
    private(set) var isDragging = false
    var onDragChange: ((GainKnob, Bool) -> Void)?
    private var lastDragSend: TimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // ⌘-CLICK — reset to zero (the same path a typed 0 takes).
        if event.modifierFlags.contains(.command) {
            doubleValue = 0
            send()
            return
        }
        if event.clickCount >= 2 {
            beginEditing()
            return
        }
        var lastY = event.locationInWindow.y
        lastDragSend = event.timestamp
        isDragging = true
        onDragChange?(self, true)
        defer {
            isDragging = false
            onDragChange?(self, false)
        }
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
                // The draw follows the drag immediately (the value setter
                // flags the knob itself), but the SEND is coalesced: a send
                // is a hardware write whose echo triggers a full-window
                // refresh — one per drag event pixels would stutter. At
                // most ~25 sends/s while dragging; the final value always
                // lands on release below.
                if sendsContinuously, ev.timestamp - lastDragSend >= 0.04 {
                    lastDragSend = ev.timestamp
                    send()
                }
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
    //   optional INVERTED direction via Settings ▸ General ▸ Knob interaction
    //   ("wheel down = more"); trackpad precise deltas accumulate to a
    //   whole step (values are whole numbers), classic mouse wheels one
    //   notch ≈ one step
    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, !isEditing else { super.scrollWheel(with: event); return }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        // Settings ▸ General ▸ Knob interaction: optional inverted direction
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

// MARK: - Grouped source menu (the output strip's SOURCE control)

/// The output strip's SOURCE selector — a popup-style button whose menu
/// carries TWO independent selections, separated by a divider:
///
///     Source                    one checkmark per section
///     Playback 1–2                ✓ marks the routed source
///     Playback 3–4
///     …
///     Silence
///     ─────────────────────
///     Pre-FX                      ✓ marks the tap point on the
///     Post-FX                       SOURCE's chain (mirrors only)
///     Post-Trim
///
/// Picking a source never resets the stage; picking a stage never
/// changes the source.
/// The SHARED dropdown field — the standard container for every dropdown
/// in the app (input mode, output source, Pre/Post-FX stage, plug-in slot,
/// sample rate). One look, built on the "Add Plug-in…" control:
///
///     [ content                       │       ⌄ ]
///       left-aligned, 12 pt pad         divider   30-pt chevron area
///
/// The ENTIRE control opens the menu — the chevron area is not a separate
/// button. Special content (the sample rate's bold tabular readout) rides
/// INSIDE the container; the container itself never varies.
final class SourceMenuButton: NSControl {

    var title: String = "" { didSet { needsDisplay = true } }
    private var hovering = false

    /// THE shared dropdown geometry (logical px) — one spec, every use:
    /// 32-pt height, 10-pt content pad, 26-pt chevron area, 1-pt quiet
    /// divider inset 8 pt. WIDTHS FOLLOW THE ROLE — never equalized
    /// between neighbors (a primary selector flexes; a secondary one is
    /// content-sized).
    static let height: CGFloat = 32
    static let contentPad: CGFloat = 10
    static let chevronArea: CGFloat = 26
    /// The gap between the dropdown and a control beside it (the trim
    /// knob, a secondary selector).
    static let rowGap: CGFloat = 8

    /// Default intrinsic size — callers pin the width per use (the source
    /// selector flexes; the stage popup is content-sized).
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: Self.height) }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        // No width pin here: the caller aligns this control's width with
        // the Audio FX slot below (one shared control width, same left
        // edge); the height comes from intrinsicContentSize.
        toolTip = "Source · tap point on the source's chain"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    // popup buttons open on mouse DOWN and from performClick alike
    override func mouseDown(with event: NSEvent) { _ = sendAction(action, to: target) }
    override func performClick(_ sender: Any?) { _ = sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        // THE shared bezel — the "Add Plug-in…" treatment: flat idle fill
        // (hover lift, subdued when disabled), 1-pt hairline border, r=6.
        let bezel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 6, yRadius: 6)
        let fill: NSColor = !isEnabled ? GGTheme.subduedFill
            : hovering ? GGTheme.hoverFill : GGTheme.idleFill
        fill.setFill()
        bezel.fill()
        GGTheme.idleBorder.setStroke()
        bezel.lineWidth = 1
        bezel.stroke()

        // content — left-aligned, 12-pt pad, vertically centered
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
        ]
        let textRect = NSRect(x: bounds.minX + Self.contentPad,
                              y: bounds.midY - 8,
                              width: bounds.width - Self.contentPad - Self.chevronArea - 6,
                              height: 16)
        NSAttributedString(string: title, attributes: attrs)
            .draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

        // NO vertical divider — the chevron area separates itself by
        // alignment alone (the chevron sits centered in its reserved
        // 26-pt area at the right edge)
        let dx = bounds.maxX - Self.chevronArea

        // the SHARED chevron — one small downward chevron, centered in
        // its reserved area
        let chevronColor = isEnabled ? GGTheme.idleLabel : NSColor.disabledControlTextColor
        chevronColor.setStroke()
        let cx = dx + Self.chevronArea / 2, cy = bounds.midY
        let c = NSBezierPath()
        c.move(to: NSPoint(x: cx - 3, y: cy + 1.6))
        c.line(to: NSPoint(x: cx, y: cy - 1.8))
        c.line(to: NSPoint(x: cx + 3, y: cy + 1.6))
        c.lineWidth = 1.3
        c.lineCapStyle = .round
        c.lineJoinStyle = .round
        c.stroke()
    }
}

// MARK: - Sample-rate selector (one-line digital readout + chevron)

/// The device-wide sample rate — a QUIET footer control: "48 kHz" plus a
/// small chevron, the same type as the footer text (regular weight,
/// secondary color), no permanent fill or border, a subtle hover
/// background. The WHOLE control opens the menu; disabled when the
/// device is away — "— kHz", never a stale value and never an
/// overflowing sentence.
///
///   [ 48 kHz   ⌄ ]
///
final class SampleRateSelector: NSControl {

    /// Fired with the picked rate (the controller's write path).
    var onPick: ((Double) -> Void)?

    /// The advertised rates (menu items), live rate included.
    private(set) var rates: [Double] = []
    /// The CURRENT live hardware rate; nil = unknown (device away).
    private(set) var current: Double?

    private var hovering = false
    private let rateMenu = NSMenu()

    /// The FOOTER control's size — small, with generous invisible click
    /// padding; content-sized width (the short value + chevron inside).
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 22) }
    override var acceptsFirstResponder: Bool { isEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
        // pinned with anchor constraints inside the header — the frame
        // must NOT also drive autoresizing constraints (they conflict and
        // collapse the whole window layout)
        translatesAutoresizingMaskIntoConstraints = false
        rateMenu.autoenablesItems = true
        setAccessibilityLabel("Sample rate")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: state

    /// Update the control: the advertised rates + the live rate (nil =
    /// unknown → placeholder + disabled). Rebuilds the menu only when
    /// the list changes, so an open menu is never disturbed.
    func update(rates: [Double], current: Double?) {
        let old = self.rates
        self.rates = rates
        self.current = current
        if old != rates { rebuildMenu() }
        isEnabled = current != nil
        toolTip = current != nil ? "Sample rate" : "Sample rate — the device is unavailable"
        needsDisplay = true
        setAccessibilityLabel(current.map { "Sample rate, \(Self.menuTitle($0))" } ?? "Sample rate, unknown")
    }

    private func rebuildMenu() {
        rateMenu.removeAllItems()
        for r in rates {
            let item = rateMenu.addItem(withTitle: Self.menuTitle(r), action: #selector(picked(_:)),
                                         keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: r)
            if r == current { item.state = .on }
        }
    }

    /// Open the menu — the WHOLE control is the trigger (mouse + keyboard).
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        rateMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }
    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        rateMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? NSNumber else { return }
        onPick?(r.doubleValue)
    }

    // MARK: hover — a subtle lift only (divider + chevron stay put)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                        options: [.mouseEnteredAndExited, .activeAlways],
                                        owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    // MARK: drawing
    /// Menu titles — kHz, one decimal only when it matters:
    /// "48 kHz", "44.1 kHz", "88.2 kHz", "192 kHz".
    private static func menuTitle(_ r: Double) -> String {
        let k = r / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    /// The FOOTER readout: quiet device information ("48 kHz" — the same
    /// regular weight as the footer text), NO permanent fill or border,
    /// a small muted chevron, and a subtle hover background so it still
    /// reads as clickable. Generous invisible padding for an easy click.
    private static func readout(_ r: Double) -> NSAttributedString {
        let khz = r / 1000
        let text = khz.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        return NSAttributedString(string: "\(text) kHz", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: GGTheme.softGray,
        ])
    }

    /// Disconnected: the SHORT value form — "— kHz" — never a sentence:
    /// the footer's status message on the left already explains WHY the
    /// rate is unavailable, and a long text must never overflow onto the
    /// device name beside it.
    private static func placeholder() -> NSAttributedString {
        NSAttributedString(string: "— kHz", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: GGTheme.muted,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        // QUIET by design: no permanent fill, no border — a footer-level
        // device fact. A subtle rounded background ONLY on hover (live).
        if hovering, isEnabled {
            let hover = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 4, yRadius: 4)
            NSColor(white: 1, alpha: 0.07).setFill()
            hover.fill()
        }

        // the readout — left-padded 10, vertically centered on its ink
        // (CTLine's origin IS the baseline)
        let text = current != nil ? Self.readout(current!) : Self.placeholder()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            ctx.textPosition = CGPoint(x: bounds.minX + 10,
                                       y: bounds.midY - (ascent - descent) / 2)
            CTLineDraw(line, ctx)

            // the small muted chevron — after the text, with its own pad
            let textEnd = bounds.minX + 10 + w
            let chevronColor = isEnabled ? GGTheme.softGray : GGTheme.muted
            chevronColor.setStroke()
            let v = NSBezierPath()
            let cx = textEnd + 7, cy = bounds.midY
            v.move(to: NSPoint(x: cx - 2.5, y: cy + 1.4))
            v.line(to: NSPoint(x: cx, y: cy - 1.5))
            v.line(to: NSPoint(x: cx + 2.5, y: cy + 1.4))
            v.lineWidth = 1.1
            v.lineCapStyle = .round
            v.lineJoinStyle = .round
            v.stroke()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
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

/// The labeled toggle (48V / SL / Ø / Mute / DIM / SUM): OFF =
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

/// The two channel-pair ganging toggles (inputs 1+2 / 3+4 — the
/// touchscreen's linked-fader pairs, the hwinN.group bits): compact
/// chain-link toggles that live ON each pair's divider between the two
/// channels instead of the Inputs header, so the relationship is
/// visible where it matters. The glyph is the bundled chain artwork
/// (assets/app.png), tinted per state — never a pasted black bitmap.
///
/// One state carrier, one color — the channel styling never changes:
///
///   unlinked → muted gray BROKEN chain on a transparent back (a
///              subtle neutral fill on hover only);
///   linked   → connected chain in vivid purple on a subtle
///              purple-tinted bed with a thin purple border — steady,
///              visible without hover (same treatment as the pin's
///              selected state).
///
/// The glyph's footprint and the button's 32-pt box are IDENTICAL in
/// both states (no jump when toggling), and keyboard focus stays a
/// separate system-level exterior ring (see FunctionButton), so the
/// focus ring never reads as the purple linked look.
final class LinkPairButton: FunctionButton {

    /// The ganging state color — vivid purple, deliberately NOT the Ø
    /// polarity or Auto Gain purples: ganging is its own function.
    static let ink = GGTheme.hex("A970FF")

    /// "inputs 1 and 2" / "inputs 3 and 4" — the tooltip's + label part.
    private let pairText: String

    init(pair: Int, target: AnyObject?, action: Selector) {
        pairText = "inputs \(pair * 2 + 1) and \(pair * 2 + 2)"
        super.init(tag: 1400 + pair, accent: Self.ink, target: target, action: action)
        setAccessibilityLabel("Link \(pairText)")
        refreshTooltip()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isLinked: Bool { isEnabled && state == .on }

    override var state: NSControl.StateValue {
        didSet { refreshTooltip() }   // the redraw itself: FunctionButton's didSet
    }

    /// Off: "Link inputs 1 and 2." · On: "Inputs 1 and 2 linked — click to unlink."
    /// (setToggle appends its "— device unavailable" suffix on top when
    /// the pair can't be switched — keep the base short and plain.)
    private func refreshTooltip() {
        toolTip = isLinked
            ? pairText.prefix(1).uppercased() + pairText.dropFirst()
                + " linked — click to unlink."
            : "Link \(pairText)."
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if !isEnabled {
            // device away: receded but READABLE — the state stays visible
            GGTheme.subduedFill.setFill()
            path.fill()
        } else if engaged {
            // LINKED: subtle purple bed + thin purple border — persistent
            Self.ink.withAlphaComponent(0.16).setFill()
            path.fill()
            Self.ink.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            // UNLINKED at rest is fully transparent; hover only lifts
            GGTheme.hoverFill.setFill()
            path.fill()
        }
        let color: NSColor = !isEnabled ? .disabledControlTextColor
            : engaged ? Self.ink : GGTheme.softGray
        drawChain(color: color, linked: engaged)
    }

    /// The chain glyph: the bundled chain artwork (assets/app.png),
    /// tinted to the state ink — the SAME ART in both states with an
    /// identical fitted footprint (the pin toggle's rule: color carries
    /// the state). A linked pair shows the chain whole; an unlinked
    /// pair shows the same chain TORN at the interlock — the art is
    /// drawn twice, each pass clipped to one side of a thin void band
    /// across the center, so the two halves read as a broken link
    /// without any repositioning or rescaling. Fallback (asset
    /// missing): the equivalent two-stadium vector chain.
    private func drawChain(color: NSColor, linked: Bool) {
        if let icon = GGIconAsset.tinted("app", color) {
            let s = icon.size
            guard s.width > 0, s.height > 0 else { return }
            // ~22 × 10 of visible INK, centered: the artwork's canvas is
            // square with slim side margins and fat transparent top /
            // bottom padding (measured: ink 117×53 inside a 128×128
            // canvas), so the CANVAS is aspect-fit into a 22×24 box and
            // its own padding settles the glyph inside it
            let box = bounds.insetBy(dx: 5, dy: 4)
            let scale = min(box.width / s.width, box.height / s.height)
            let fitted = NSRect(x: box.midX - s.width * scale / 2,
                                y: box.midY - s.height * scale / 2,
                                width: s.width * scale, height: s.height * scale)
            if linked {
                icon.draw(in: fitted)
            } else {
                let gap: CGFloat = 1.5
                for (lo, hi) in [(-1000.0, Double(fitted.midX - gap)),
                                 (Double(fitted.midX + gap), 1000.0)] {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: lo, y: 0, width: hi - lo,
                                              height: bounds.height)).addClip()
                    icon.draw(in: fitted)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            return
        }
        // OFFLINE FALLBACK: two stadium links, ~22×12 pt, light 1.5 pt
        // stroke — identical geometry in both states (the doubled
        // footprint matches the artwork's fitted box above)
        let x = bounds.midX - 11, y = bounds.midY - 6
        let left = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 14, height: 12),
                                xRadius: 6, yRadius: 6)
        let right = NSBezierPath(roundedRect: NSRect(x: x + 8, y: y, width: 14, height: 12),
                                 xRadius: 6, yRadius: 6)
        color.setStroke()
        if linked {
            // INTERLOCKED: right link first, then left — left's stroke
            // crosses OVER right's, chaining the two together
            right.lineWidth = 1.5
            right.stroke()
            left.lineWidth = 1.5
            left.stroke()
        } else {
            // BROKEN: identical links, stroke clipped short of the
            // interlock's center line — two flat-torn tube ends
            let gap: CGFloat = 2.5
            strokeTorn(left, xMin: 0, xMax: x + 11 - gap)
            strokeTorn(right, xMin: x + 11 + gap, xMax: bounds.width)
        }
    }

    /// Stroke a link clipped to a horizontal band (the torn edge).
    private func strokeTorn(_ path: NSBezierPath, xMin: CGFloat, xMax: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: xMin, y: 0, width: xMax - xMin,
                                  height: bounds.height)).addClip()
        path.lineWidth = 1.5
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
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
    /// While the strip's TRIM is being adjusted (drag/scroll/typing), the
    /// dropdown's ENTIRE content is temporarily replaced by the trim's dB
    /// number — centered across the full field: no plug-in name, no
    /// "Add Plug-in…", no chevron, nothing else. nil = the normal content,
    /// which returns on its own (800 ms after the last adjustment; a drag
    /// holds the readout until the pointer is released). Display-only: it
    /// never touches the loaded plug-in.
    var overrideText: String? { didSet { namePaint.needsDisplay = true } }
    /// Chip geometry — the SHARED dropdown height (36 pt): the slot and
    /// the small trim knob beside it share ONE height (the knob's whole
    /// diameter), like every other dropdown.
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: SourceMenuButton.height) }
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
        // Clip both paint layers to the container's rounded shape — the
        // hover/selection fills run EDGE TO EDGE (plain rects) and the
        // container's outline rounds only the OUTSIDE ends.
        for p in [namePaint, controlsPaint] {
            p.layer?.cornerRadius = radius
            p.layer?.masksToBounds = true
        }
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
        // enabled = a subtle accent wash; bypassed/empty = the shared idle
        // fill. It does NOT change on hover — the reveal is the hover
        // feedback (except the EMPTY slot, which gets the same restrained
        // hover lift the toolbar tiles use), and the enabled state stays
        // legible while the controls are shown.
        let fill: NSColor
        if hasPlugin && processingEnabled {
            fill = GGTheme.accent.withAlphaComponent(0.14)
        } else if !hasPlugin && hovering {
            fill = GGTheme.hoverFill
        } else {
            fill = GGTheme.idleFill
        }
        fill.setFill()
        path.fill()
        GGTheme.idleBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: the name layer (normal state)

    private func drawName(_ rect: NSRect) {
        // THE TRIM'S TEMPORARY READOUT — while the knob beside the field
        // is adjusted, the field's ENTIRE content is replaced: only the
        // live trim value in dB, centered horizontally + vertically. No
        // plug-in name, no "Add Plug-in…", no chevron, no separator. The
        // field itself (size, fill, border, position) is untouched, so
        // nothing shifts, and the normal content returns when the
        // adjustment ends.
        if let o = overrideText {
            drawCentered(o, in: rect, color: GGTheme.primary)
            return
        }

        // NO vertical divider — the chevron area separates itself by
        // alignment alone
        let dx = rect.maxX - SourceMenuButton.chevronArea
        // the SHARED small downward chevron, centered in its reserved area
        let cx = dx + SourceMenuButton.chevronArea / 2
        drawChevronGlyph(in: NSPoint(x: cx, y: rect.midY), color: GGTheme.muted)

        // the content: the plug-in's name (or the empty slot's
        // "Add Plug-in…" invitation), left-aligned — truncated only when
        // necessary. No permanent trim label: the trim value appears in
        // this field ONLY while it is being adjusted (overrideText).
        let title: String
        let color: NSColor
        if let name = pluginName {
            title = name
            color = processingEnabled ? GGTheme.primary : GGTheme.softGray
        } else {
            title = "Add Plug-in…"
            color = GGTheme.softGray
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byTruncatingTail
        let attr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
        let box = NSRect(x: rect.minX + SourceMenuButton.contentPad, y: 0,
                         width: dx - SourceMenuButton.contentPad, height: rect.height)
        let h = ceil(attr.size().height)
        attr.draw(in: NSRect(x: box.minX, y: box.midY - h / 2,
                             width: max(10, box.width), height: h))
    }

    private func drawCentered(_ s: String, in rect: NSRect, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail   // only when necessary
        let attr = NSAttributedString(string: s, attributes: [
            // tabular numerals — the dB digits don't jitter as they step
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
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
        // The segmented hover state HIDES while the trim's temporary
        // readout occupies the field — the replacement is total. Nothing
        // about this disables the controls; it is purely visual and only
        // lasts for the adjustment.
        if overrideText != nil { return }
        // ONE continuous segmented control — the fills run EDGE TO EDGE
        // (no inset, no per-area rounding); only the container's rounded
        // clip shapes the outside ends, so the three areas read as parts
        // of one control, never as three small buttons inside a frame.
        // the keyboard-picked area — the accent follows the selection
        if focused, hoverArea < 0 {
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            NSBezierPath(rect: areaRect(selectedArea)).fill()
        }
        // the hovered area — a restrained lift
        if hoverArea >= 0 {
            NSColor(white: 1, alpha: 0.08).setFill()
            NSBezierPath(rect: areaRect(hoverArea)).fill()
        }
        // quiet vertical separators BETWEEN the areas — drawn AFTER the
        // highlights so they stay visible above them; THIN + MUTED (never
        // bright white — they must not outshout the surrounding borders)
        GGTheme.idleBorder.withAlphaComponent(0.5).setStroke()
        for x in [sideWidth, bounds.width - SourceMenuButton.chevronArea] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 6))
            line.line(to: NSPoint(x: x, y: bounds.height - 6))
            line.lineWidth = 1
            line.stroke()
        }
        // power — accent while enabled, quiet gray while bypassed (the
        // distinction is visible IN the hover state too)
        drawPowerGlyph(in: areaRect(0).center,
                       color: processingEnabled ? GGTheme.accent : GGTheme.idleLabel)
        // open — the sliders, the widest area
        drawSlidersGlyph(in: areaRect(1).center, color: GGTheme.idleLabel)
        // browse — the chevron
        drawChevronGlyph(in: areaRect(2).center, color: GGTheme.idleLabel)
        // re-stroke the container's hairline LAST so it stays crisp over
        // the fills (the paints sit above the container's own drawing)
        GGTheme.idleBorder.setStroke()
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        frame.lineWidth = 1
        frame.stroke()
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

    /// A STATE-driven fill for the NOT-engaged state (the global mute
    /// tile: green while the outputs are unmuted — the color mirrors the
    /// mute STATE, never hover or focus). nil = the shared neutral idle.
    var idleTint: NSColor? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let engaged = isEngaged
        let enabled = isEnabled
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        // radius 4 — crisper than the chips (6), so these read as small
        // utility controls, not toolbar tiles
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let fill: NSColor
        if !enabled && !engaged && idleTint == nil {
            fill = GGTheme.subduedFill
        } else if engaged {
            // the accent fill SURVIVES a temporary disable — e.g. Auto
            // Gain All stays purple for the whole run while the button
            // is non-interactive (the color reflects STATE, not hit-test)
            fill = hovering ? Self.lift(accent, 0.08) : accent
        } else if let tint = idleTint {
            fill = hovering ? Self.lift(tint, 0.08) : tint
        } else {
            fill = hovering ? GGTheme.hoverFill : GGTheme.idleFill
        }
        fill.setFill()
        path.fill()
        let onColoredTile = engaged || idleTint != nil
        if enabled, !onColoredTile {
            GGTheme.idleBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        // WHITE icons on the colored tiles, quiet label grays otherwise.
        let color: NSColor = !enabled && !onColoredTile ? .disabledControlTextColor
            : onColoredTile ? .white : GGTheme.idleLabel
        drawGlyph(color: color)
    }

    /// Subclasses draw their centered glyph in the given color.
    func drawGlyph(color: NSColor) {}
}

/// Talkback — a LATCH TOGGLE: click once to latch talkback ON (the tile
/// stays lit orange while it's on), click again to stop. Latching via the
/// hotkey/MIDI still works; the chip mirrors the live state either way
/// (refresh reads talkbackState back), so the light always tells the truth.
final class TalkbackIconButton: IconButton {

    // DEFAULT mouseDown (FunctionButton): press-and-release inside flips
    // state and fires the action — a latch, not hold-to-talk.

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
    var onWriteString: (([UInt8], String) -> Void)?
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

    // MARK: quick-control panel plumbing (see QuickControlPanel.swift)

    /// Which of a monitor output's toggles the quick panel flips.
    enum QuickMonitorToggle { case mute, dim, sum }
    /// Fired at the end of every refresh() — the quick panel re-syncs its
    /// knobs, chips and markers from the live state.
    var onRefreshed: (() -> Void)?
    /// The monitor outputs' live state (gain/mute/dim/sum ×2) — read by
    /// the quick panel; the bar's own knobs keep their state privately.
    func monitorStates() -> [MonitorState] { monitors }
    /// A quick-panel monitor toggle (mute / dim / sum) — the same write
    /// path the bar's chips use, with the same guards.
    func quickSetMonitor(_ o: Int, _ which: QuickMonitorToggle, _ on: Bool) {
        guard !isLearning else { return }
        let t = PathIds.active
        let id: [UInt8]?
        switch which {
        case .mute: id = o == 0 ? t.hwout0Mute : t.hwout1Mute
        case .dim:  id = o == 0 ? t.hwout0Dim : t.hwout1Dim
        case .sum:  id = o == 0 ? t.hwout0Sum : t.hwout1Sum
        }
        guard let id, !id.isEmpty else { return }
        onWriteBool?(id, on)
        if case .mute = which { monitors[o].mute = on }
        if case .dim = which { monitors[o].dim = on }
        if case .sum = which { monitors[o].sum = on }
        refresh()
    }
    /// The quick panel's mute-all — same semantics as the bar's tile:
    /// not all-muted → mute both; all-muted → unmute both.
    func quickToggleMuteAll() {
        guard !isLearning else { return }
        let t = PathIds.active
        let bothMuted = (monitors[0].mute ?? false) && (monitors[1].mute ?? false)
        let target = !bothMuted
        for o in 0..<2 {
            let id = o == 0 ? t.hwout0Mute : t.hwout1Mute
            guard !id.isEmpty else { continue }
            onWriteBool?(id, target)
            monitors[o].mute = target
        }
        refresh()
    }
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
        /// The input's ganging bit (hwin<i>.group — the touchscreen's linked
        /// faders). Hardware does NOT mirror externally written gains when
        /// ganged (verified: hwin0 → 30.5, ganged partner hwin1 stayed put),
        /// so the app mirrors the ACTIVE gain write itself.
        var group: Bool?
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

    /// Input ganging bits — `hwin<i>.group` ids, same refresh cadence.
    private var inputGroupIds: [[UInt8]] = Array(repeating: [], count: 4)

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
        // the metering hub knows the window is watching (live meters)
        AdatGainEngine.shared.windowVisible = true
        AdatGainEngine.shared.refreshChannelCount()
        refreshSampleRatePopup()
        if let tree = onSeedTree?() {
            interfaceName = Self.interfaceName(from: tree)
            updateTree(tree)
        } else { refresh() }
        applyPinState()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPoll()
        onRequestTree?()
    }

    // MARK: pin (the panel's temporary ⇄ pinned behavior)

    /// The pin state — PERSISTED (UserDefaults), so hiding and reopening
    /// the panel (by logo click or hotkey) restores the same behavior.
    static let pinnedDefaultsKey = "controlPanelPinned"
    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pinnedDefaultsKey)
            applyPinState()
        }
    }

    /// ⌘P (app-only, while the panel is focused) — toggle the pin. The
    /// state persists; unpinning does NOT hide the panel — the next
    /// outside click does.
    func togglePinned() {
        // not immediately hidden on unpin — the flag alone changes
        pinned = !pinned
    }

    /// Apply the current pin state to the window + toggle:
    ///   pinned   → floats above ordinary app windows (no forced focus)
    ///   unpinned → normal level; the window hides on outside focus loss
    private func applyPinState() {
        window?.level = pinned ? .floating : .normal
        pinButton?.isPinned = pinned
    }

    /// TEMPORARY-panel behavior: an UNPINNED panel hides when the focus
    /// leaves it — but the app's own workflow surfaces (the settings
    /// window, popovers, dropdown menu tracking, plug-in editors) never
    /// dismiss it, and a PINNED panel never auto-hides at all. Hiding is
    /// orderOut only — nothing quits and audio processing is untouched.
    func windowDidResignKey(_ notification: Notification) {
        guard !pinned, window?.isVisible == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // focus came BACK (menu tracking closed, popover dismissed
            // back to us) — keep the panel up
            guard self.window?.isKeyWindow != true else { return }
            // ANOTHER of our own windows took the key (settings, popover,
            // a plug-in editor) — that's the app workflow, not an
            // outside click: stay visible
            if let key = NSApp.keyWindow, key !== self.window { return }
            // nothing of ours holds the key → the click (or app switch)
            // went outside: quietly hide
            self.window?.orderOut(nil)
            self.AdatVisibility(false)
        }
    }

    /// The interface's display name — the device node's `name` (a
    /// hardware property, renameable), falling back to the model string.
    private static func interfaceName(from tree: [String: Any]) -> String {
        guard let serial = GlueClient.quartetSerial(in: tree),
              let dev = GlueClient.findNode(in: tree, type: serial),
              let props = dev["props"] as? [String: Any],
              let name = props["name"] as? String,
              !name.isEmpty else { return "Apogee Quartet" }
        return name
    }

    /// The connected unit's serial, when the tree carries one — shown at
    /// the footer's BOTTOM RIGHT (not in the title bar anymore).
    private static func serial(from tree: [String: Any]) -> String? {
        GlueClient.quartetSerial(in: tree)
    }

    /// Coalesced entry point: a drag (write → echo) and any burst of
    /// device events can call this MANY times per frame, and the body
    /// touches every control in the window — running it per event is what
    /// makes knob drags stutter. The actual reconcile runs at most every
    /// ~50 ms; the last pending call always lands.
    private var refreshScheduled = false
    func refresh() {
        guard window != nil, feedbackLabel != nil else { return }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
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
                levelPopups[i].title = Self.levelLabels[rl] ?? "—"
            } else {
                levelPopups[i].title = "—"
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
        }

        // Ganging link toggles — engaged when the pair's hwinN.group bits
        // are set (whoever set them: this app, the touchscreen, or Apogee
        // Control 2). Enabled once both group ids are known (a serial).
        for (a, l) in linkToggles.enumerated() {
            let b1 = a * 2, b2 = b1 + 1
            setToggle(l, (inputs[b1].group ?? false) && (inputs[b2].group ?? false),
                      enabled: connected && !learning
                          && !inputGroupIds[b1].isEmpty && !inputGroupIds[b2].isEmpty)
        }

        // INPUT BANK — Analog 1–4 / ADAT 1–8: the selector is a pair of
        // mutually-exclusive toggles; the grid + header controls swap.
        let adatBankActive = inputsBank == 1
        bankAnalogButton?.state = adatBankActive ? .off : .on
        bankAdatButton?.state = adatBankActive ? .on : .off
        bankAnalogButton?.isEnabled = connected && !learning
        bankAdatButton?.isEnabled = connected && !learning
        applyInputBankVisibility(adatBankActive)

        // ADAT TILES — focus markers + availability. Assistance is a
        // Core-Audio measurement: it needs the stream, not the glue
        // tree, so tiles stay active whenever the channel exists.
        let adatEngine = AdatGainEngine.shared
        for i in 0..<adatTiles.count {
            adatTiles[i].update(status: adatEngine.statuses[i],
                                focus: adatEngine.focusedChannel == i,
                                available: adatEngine.channelAvailable(i))
        }

        for i in 0..<4 {
            inputHeaders[i]?.stringValue = inputs[i].name ?? "Analog In \(i + 1)"

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

            // SOURCE — SPLIT into two compact popups, so the full source
            // never truncates: "[ Playback 1–2 ▾ ]  [ Pre-FX ▾ ]". The
            // stage popup exists only for MIRRORED sources (own playback
            // and Off have no separate chain to tap).
            let srcBtn = sourceMenus[i]
            srcBtn.title = InsertServer.sourceLabel(server.source(i), for: i)
            // The stage popup is ALWAYS present ("[ Pre-FX ▾ ]") — for
            // non-mirrored sources (own playback / Off — no separate chain
            // to tap) it stays visible but GRAYED OUT with a dash, so the
            // row never reflows when the source changes.
            let stBtn = stageMenus[i]
            if server.source(i).copyIndex != nil {
                stBtn.isEnabled = true
                stBtn.alphaValue = 1
                stBtn.toolTip = "Tap point on the source's chain"
                let label = server.stage(i).label
                if stBtn.title != label { stBtn.title = label }
            } else {
                stBtn.isEnabled = false
                stBtn.alphaValue = 0.45
                stBtn.title = "—"
                stBtn.toolTip = "No tap point — this source has no separate processing chain"
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
            // value, but not a hardware reading (the arc stays neutral)
            trimKnobs[i].valueKind = .saved
            // The ARC carries the level: gray at unity (0 dB), green
            // below it (attenuation — the safe direction), red above it
            // (boost — it can clip). The dial's center is EMPTY and the
            // field beside it shows NO permanent number — the value only
            // appears there while the trim is being adjusted.
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
        // the footer's quiet identity line: model + connection state
        if let sf = serialField {
            let text = connected ? "Apogee Quartet · Connected" : "Apogee Quartet"
            if sf.stringValue != text { sf.stringValue = text }
            sf.isHidden = false
        }
        // Utility pair mirrors the live state: the mic shows Talkback
        // (hotkeys/MIDI/menu can all change it), the speaker is ON while
        // BOTH monitor outputs are muted. Tooltips follow the states.
        let tbActive = talkbackState?() ?? false
        let bothMuted = (monitors[0].mute ?? false) && (monitors[1].mute ?? false)
        // the top-bar Auto Gain chip is a plain action: it calibrates
        // EVERY Mic/Instrument input at once. The animation lives on each
        // input's own button, and the footer owns the Cancel.
        let agRunning = !autoRunning.isEmpty
        // Auto Gain All: purple for the WHOLE run (measure + apply). The
        // tint rides the tile's idle state — it survives the temporary
        // disable while the run is in flight (the color mirrors the
        // ENGINE's state, not clicks or hover), and the footer's Cancel
        // owns the abort. Back to neutral gray the moment it ends.
        autoGainTopButton?.state = .off
        autoGainTopButton?.idleTint = agRunning ? GGTheme.autoGainRun : nil
        autoGainTopButton?.isEnabled = connected && !learning && !agRunning
        autoGainTopButton?.setAccessibilityLabel(agRunning
            ? "Auto Gain All — running" : "Auto Gain All — calibrate every input")
        autoGainTopButton?.toolTip = agRunning
            ? "Auto Gain All — a calibration is running"
            : Self.autoGainConfigTooltip()
        talkbackButton?.state = tbActive ? .on : .off
        talkbackButton?.isEnabled = connected && !learning
        talkbackButton?.toolTip = tbActive ? "Talkback active" : "Talkback"
        // The global mute tile is STATE-colored: green while the outputs
        // are unmuted, red + slashed speaker while Mute All is engaged.
        muteAllButton?.state = bothMuted ? .on : .off
        muteAllButton?.isEnabled = connected && !learning
        muteAllButton?.idleTint = connected && !bothMuted ? GGTheme.muteIdle : nil
        muteAllButton?.toolTip = bothMuted ? "Unmute all outputs" : "Mute all outputs"

        updateFeedback(connected: connected, insertLive: live)
        // NOTE: no geometry work here — resizing during a refresh cancels
        // slider drags mid-flight. The window's size is the user's.
        // The quick panel re-syncs from the same state (it re-reads).
        onRefreshed?()
    }

    /// The footer's feedback strip: [dot] [message] — progress/time only
    /// when the engine actually reports it — with Cancel while Auto Gain
    /// runs, Dismiss on lingering results. Priority: learn → auto gain →
    /// connection → insert
    /// hint → Ready. The strip's height is reserved, so messages never
    /// move the monitor controls.
    private func updateFeedback(connected: Bool, insertLive: Bool) {
        let kind: FeedbackKind
        let message: String
        var action: FeedbackAction = .none
        showDeviceDiagnostics = false

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
            // The device is not there: say so plainly — the STATUS TEXT
            // ITSELF opens the diagnostic popover (no Details button; the
            // message carries that role).
            kind = .warning
            message = "Device unavailable — waiting for Apogee Control 2."
            showDeviceDiagnostics = true
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
        case .none:
            feedbackAction?.isHidden = true
        }
    }

    /// What the footer's action button does.
    private enum FeedbackAction {
        case none
        case cancel      // Auto Gain is running
        case dismiss     // a lingering Auto Gain result
    }

    /// Cancel (Auto Gain running) / Dismiss (lingering result).
    @objc private func feedbackActionClicked(_ sender: NSButton) {
        switch feedbackActionKind {
        case .cancel:
            AutoGainEngine.shared.cancelAll(reason: "cancelled")
        case .dismiss:
            autoGainStatus = nil
            autoGainStatusTimer?.invalidate()
            autoGainStatusTimer = nil
        case .none:
            break
        }
        refresh()
    }

    /// Why the device is not there — the details behind the footer's
    /// Why the device is not there — the details behind the footer's
    /// "Device unavailable" message. Set while the device is away; the
    /// status message's click opens the diagnostic popover.
    private var showDeviceDiagnostics = false

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
        if showDeviceDiagnostics {
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
        // the unit's identity at the footer's bottom right — QUIET:
        // the model + connection state; the serial ID lives in the
        // tooltip (Settings ▸ About carries it too), never as a long
        // line across the strip
        if let serial = Self.serial(from: tree) {
            serialField?.isHidden = false
            serialField?.toolTip = "Apogee Quartet · \(serial)"
        }
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
                st.group = (GlueClient.intProp(node, "group") ?? 0) == 1
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
        // input ganging ids (hwinN.group) — for echo matching + writes
        if let serial = Self.serial(from: tree) {
            for i in 0..<4 { inputGroupIds[i] = PathIds.hash("/dev/\(serial)/hwin/hwin\(i)/group") }
        } else {
            for i in 0..<4 { inputGroupIds[i] = [] }
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
        // ganging echoes (hwin<i>.group) — anyone can toggle a link
        if event.tag == 3, !inputGroupIds.isEmpty,
           let idx = inputGroupIds.firstIndex(of: event.id) {
            if inputs[idx].group != (event.value.first == 1) {
                inputs[idx].group = event.value.first == 1
                refresh()
            }
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
    private var levelPopups: [SourceMenuButton] = []
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
    private var sourceMenus: [SourceMenuButton] = []
    /// The SPLIT source row's tap-point popup (mirrors only) —
    /// "[ Pre-FX ▾ ]" beside the source selector.
    private var stageMenus: [SourceMenuButton] = []
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
    /// The unit's serial ID — quiet, at the footer's BOTTOM RIGHT.
    private var serialField: NSTextField?
    /// The two ganging chain-link toggles — one ON each pair's divider
    /// between its two channels (Link 1+2 / Link 3+4 — the hwinN.group
    /// bits), aligned with the gain knobs' centerline.
    private var linkToggles: [NSButton] = []
    /// The Inputs section's BANK selector — [ Analog 1–4 | ADAT 1–8 ].
    /// The analog layout is untouched; the ADAT bank swaps the grid.
    private var bankAnalogButton: FunctionToggle?
    private var bankAdatButton: FunctionToggle?
    /// The ADAT bank: eight channel strips (4 × 2) carrying their own
    /// Gain Assist actions — no section-level assistant button.
    /// (internal so the QB_AUTO_ASSIST harness can probe milestones.)
    var adatTiles: [AdatTile] = []
    private var adatGrid: NSView?
    /// the analog four-strip grid — hidden while the ADAT bank is
    /// pinned; refresh() applies BOTH banks' visibility so switching
    /// there and back actually swaps the grids
    private var inputGridRef: NSView?
    /// The central workspace scroll area — the fallback when the
    /// fitted window exceeds the screen's usable space.
    private var scrollArea: NSScrollView?
    private var monitorStrip: NSView?
    /// The top monitor bar (volume/mute row) — its measured height is
    /// part of the window's content-height arithmetic.
    private var monitorBarRef: NSView?
    /// What the footer's action button does right now.
    private var feedbackActionKind: FeedbackAction = .none

    private var subtitleField: NSTextField!
    /// Compact sample-rate READOUT at the far right of the title bar —
    /// a flat dark container ("48 000Hz") + chevron section; the whole
    /// control opens the rate menu. A device-wide setting, kept apart
    /// from monitoring / Auto Gain.
    private var sampleRateSelector: SampleRateSelector!
    /// True while the readout shows the "Sample rate —" placeholder
    /// (the device is unreachable, so the active rate is unknown).
    private var sampleRateUnknown = false
    /// The scroll area's document view (top-scroll on open).
    private var scrollDoc: NSView?
    /// The monitor bar's pin indicator (the panel's pinned state).
    private var pinButton: PinIconButton?

    // MARK: keyboard-shortcut selection state (see extension at file end)

    /// Selection markers (index 0…3) — a thin accent bar beside each
    /// strip's header, visible only on the selected strip.
    private var inputMarkers: [NSView] = []
    private var outputMarkers: [NSView] = []
    /// The same thin accent bar before "Speakers"/"Headphones" — marks
    /// which output the macOS volume keys control (0 = speakers, 1 = HP).
    private var monitorMarkers: [NSView] = []
    /// The OS volume-target state, read back for the monitor markers:
    /// 0 = Main Out (Speakers), 1 = Headphones. Wired by AppDelegate.
    var volumeTarget: (() -> Int)?
    /// The strip each "selected…" shortcut acts on (gain, trim, processing).
    var selectedInputIndex = 0
    var selectedOutputIndex = 0

    private static let nameKey: (Int) -> String = { "insertPair.\($0).name" }
    /// Current custom name for a pair ("" when unset).
    static func savedName(_ i: Int) -> String {
        UserDefaults.standard.string(forKey: nameKey(i)) ?? ""
    }

    /// Settings ▸ Quartet ▸ Channel Names: rename a stereo pair ("stay empty/physical to
    /// revert" is handled by the caller — see nameKey).
    static func setSavedName(_ i: Int, _ name: String) {
        if name.isEmpty || name == InsertServer.pairNames[i] {
            UserDefaults.standard.removeObject(forKey: nameKey(i))
        } else {
            UserDefaults.standard.set(name, forKey: nameKey(i))
        }
    }

    // tag namespaces (kept well apart so `tag - base` never collides):
    //   inputs:  100/200/250/300/400/500/1200/600 + i
    //   ganging: 1400 + a (chain-link toggles ON the pair dividers —
    //             inputs 1–2 and 3–4; ADAT bank hides them)
    //   renaming: (NONE inline) — Settings ▸ Quartet ▸ Channel Names owns renames
    //             (hardware hwin/hwout names + the app-side pair names)
    //   stage menus (pre-existing): 2300 + i (tap-point menus)
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

        // --- assemble: three regions pinned with autolayout — the MONITOR
        // BAR (monitoring + global controls) at the TOP (the title-bar row
        // is GONE: no traffic lights, no app title, no device subtitle),
        // then the scrolling inputs/outputs, then the feedback strip.
        let monitorBar = makeMonitorBar()
        let scroll = makeScrollArea()
        let monitor = makeMonitorStrip()
        scrollArea = scroll
        monitorStrip = monitor
        monitorBarRef = monitorBar
        content.addSubview(monitorBar)
        content.addSubview(scroll)
        content.addSubview(monitor)

        NSLayoutConstraint.activate([
            monitorBar.topAnchor.constraint(equalTo: content.topAnchor),
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

        let w = QuartetWindow(contentRect: content.bounds,
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
        // NO title-bar furniture: the standard close / minimize / zoom
        // traffic lights are hidden (the app opens from the menubar logo
        // or the hotkey; Quit lives in the menubar, and the window still
        // closes on ⌘W through the standard responder chain).
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.standardWindowButton(.documentIconButton)?.isHidden = true
        // minimum: all four 240-pt strips + rules + margins must fit —
        // the pinned strip widths are hard requirements, not wishes
        w.minSize = NSSize(width: 1060, height: 420)
        window = w
        // The window HUGS its content: every control stays content-sized
        // vertically, so when the layout changes the window gets shorter
        // (or taller) instead of the rows growing to fill it. The height
        // is MEASURED from the real layout: monitor bar + sections + status
        // strip — no hard-coded sums.
        content.layoutSubtreeIfNeeded()
        let needed = contentNeededHeight()
        w.setContentSize(NSSize(width: 1060,
                                height: max(w.minSize.height, needed.rounded(.up))))
        w.center()
        // open at the TOP of the sections: the doc is NOT flipped, so its
        // origin is the bottom — scrolling to 0 shows the bottom (status
        // line) and leaves the Inputs header clipped at the top.
        content.layoutSubtreeIfNeeded()
        if let d = scrollDoc {
            d.scroll(NSPoint(x: 0, y: d.bounds.maxY))
        }
        // ADAT metering hub — the 10 Hz engine tick feeds every meter
        // fast-path (the control window decides what redraws).
        AdatGainEngine.shared.onUpdate = { [weak self] in self?.adatUpdateTick() }
        AdatGainEngine.shared.refreshChannelCount()
    }

    /// "48000" → "48 kHz" (one decimal when needed, e.g. 44.1 / 88.2).
    private static func rateLabel(_ r: Double) -> String {
        let khz = r / 1000
        let text = khz.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
        return "\(text) kHz"
    }

    /// (Re)build the sample-rate readout from the rates the device
    /// advertises, showing the ACTUAL live hardware rate — never just
    /// the last requested one. The menu rebuilds only when the list
    /// changes so an open menu is never disturbed.
    ///
    /// When the device is unreachable the ACTIVE rate is unknown, so the
    /// readout says "Sample rate —" instead of showing a default that
    /// reads as live; the control is disabled, because a rate cannot be
    /// written to a device that is not there.
    private func refreshSampleRatePopup() {
        guard let selector = sampleRateSelector else { return }
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
                sampleRateUnknown = true
            }
            selector.update(rates: [], current: nil)
            return
        }
        sampleRateUnknown = false

        var rates = InsertServer.availableSampleRates()
        if !rates.contains(live) { rates = ([live] + rates).sorted() }
        selector.update(rates: rates, current: live)
    }

    /// A rate was picked in the readout's menu — write it to the device.
    private func requestSampleRate(_ requested: Double) {
        QBLog.log("control: sampleRateChanged fired")
        guard !suppressActions, requested != InsertServer.deviceSampleRate() else {
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
            guard let self = self else { return }
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

    /// The MONITOR BAR — one row, THREE groups:
    ///
    ///     [compact Speakers + Headphones]   [large sample-rate
    ///     readout, centered in the open space]   [utility tiles in a
    ///     subtle dark translucent tray]
    ///
    /// The title bar above carries ONLY the window controls, the app
    /// title and the device subtitle — the sample rate lives HERE, in
    /// the open space between the monitors and the utility tiles, so it
    /// reads like a prominent instrument display beside the controls it
    /// belongs to.
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
        // sides.
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

        // flexible slack — the sample-rate readout centers in the open
        // space BETWEEN the monitors and the utility tiles (equal-priority
        // spacers on both sides)
        let slack1 = NSView()
        slack1.setContentHuggingPriority(.init(1), for: .horizontal)
        slack1.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        row.addArrangedSubview(slack1)

        // (the sample rate lives in the FOOTER now — a quiet device fact,
        // not a monitor control; nothing fills this gap)

        // breathing room before the utility tray
        let trayGap = NSView()
        trayGap.translatesAutoresizingMaskIntoConstraints = false
        trayGap.widthAnchor.constraint(equalToConstant: 16).isActive = true
        row.addArrangedSubview(trayGap)

        // RIGHT — the utility tiles grouped in a subtle dark translucent
        // tray (Auto Gain All · Talkback · Mute-All · Settings)
        let ag = AutoGainIconButton(tag: 0, accent: GGTheme.autoGainRun,
                                     target: self, action: #selector(autoGainTopClicked(_:)))
        ag.toolTip = "Auto Gain — all inputs"
        ag.setAccessibilityLabel("Auto Gain all inputs")
        autoGainTopButton = ag

        let mic = TalkbackIconButton(tag: 0, accent: GGTheme.talkbackActive,
                                      target: self, action: #selector(talkbackToggled(_:)))
        mic.toolTip = "Talkback"
        mic.setAccessibilityLabel("Talkback")
        talkbackButton = mic

        let mute = MuteAllIconButton(tag: 0, accent: GGTheme.muteEngaged,
                                      target: self, action: #selector(muteAllToggled(_:)))
        mute.toolTip = "Mute all outputs"
        mute.setAccessibilityLabel("Mute all outputs")
        muteAllButton = mute

        // the pin sits BETWEEN its toolbar neighbors — Mute All and
        // Settings — one of the tile row, not an appendix after the tray;
        // click (or ⌘P) flips the window's floating behavior
        let pin = PinIconButton(tag: 0, target: self,
                                action: #selector(pinClicked(_:)))

        let settings = SettingsIconButton(tag: 0, accent: GGTheme.accent,
                                          target: self, action: #selector(settingsClicked(_:)))
        settings.toolTip = "Settings…"
        settings.setAccessibilityLabel("Settings")

        let tiles = NSStackView(views: [ag, mic, mute, pin, settings])
        tiles.spacing = 6
        tiles.translatesAutoresizingMaskIntoConstraints = false

        // the TRAY — equal-sized tiles inside a subtle dark translucent
        // rounded bed (the shared surface that groups the five)
        let tray = NSView()
        tray.translatesAutoresizingMaskIntoConstraints = false
        tray.wantsLayer = true
        tray.layer?.backgroundColor = NSColor(white: 0, alpha: 0.18).cgColor
        tray.layer?.cornerRadius = 9
        tray.addSubview(tiles)
        NSLayoutConstraint.activate([
            tiles.topAnchor.constraint(equalTo: tray.topAnchor, constant: 5),
            tiles.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 5),
            tiles.trailingAnchor.constraint(equalTo: tray.trailingAnchor, constant: -5),
            tiles.bottomAnchor.constraint(equalTo: tray.bottomAnchor, constant: -5),
        ])
        row.addArrangedSubview(tray)
        pinButton = pin

        bar.addSubview(row)
        let divider = Hairline()
        bar.addSubview(divider)

        NSLayoutConstraint.activate([
            // the monitor row breathes: ~22 pt against the window sides,
            // and the groups stay vertically centered in the bar
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -22),
            row.topAnchor.constraint(greaterThanOrEqualTo: bar.topAnchor, constant: 12),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bar.bottomAnchor, constant: -12),
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
        // END MARGIN: the routing section's last row gets real clearance
        // above the monitor bar — the same outer-section padding the
        // Inputs section enjoys at its own boundaries (the old 6 pt left
        // the strips glued to the bottom strip's edge).
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: GGSpace.section, right: 0)
        doc.addSubview(stack)

        // INPUTS section header: title + the BANK selector
        // [ Analog 1–4 | ADAT 1–8 ] ONLY — the ganging toggles are GONE
        // from the header: each pair's chain-link button lives ON the
        // divider between its two channels (addLinkDivider, built with
        // the grid below), so the pairing is visible where it happens.
        // The ADAT bank's Gain Assist actions live on the tile
        // themselves. The Auto Gain Target / Duration configuration
        // moved to Settings ▸ Processing (the Gain Assistance settings
        // live beside it — see SettingsWindow.buildProcessing).
        let bankAnalog = FunctionToggle(title: "Analog 1–4", tag: 1500,
                                        accent: GGTheme.accent,
                                        target: self, action: #selector(bankClicked(_:)))
        bankAnalog.toolTip = "The four analog preamp inputs"
        bankAnalog.setAccessibilityLabel("Analog inputs 1 to 4")
        let bankAdat = FunctionToggle(title: "ADAT 1–8", tag: 1501,
                                      accent: GGTheme.accent,
                                      target: self, action: #selector(bankClicked(_:)))
        bankAdat.toolTip = "The eight optical ADAT inputs (the count follows the sample rate)"
        bankAdat.setAccessibilityLabel("ADAT inputs 1 to 8")
        bankAnalogButton = bankAnalog
        bankAdatButton = bankAdat

        // NO section-level "Gain Assistant…" button — each ADAT tile
        // carries its own Gain Assist action, which makes the
        // destination explicit for one-input-at-a-time operation.

        // linkToggles populate DURING the grid build — one per pair
        // divider (inputs 1–2 then 3–4)
        let inputsHeader = sectionHeader(title: "Inputs",
                                         trailingViews: [bankAnalog, bankAdat])
        stack.addArrangedSubview(inputsHeader)

        let inputGrid = makeInputGrid()
        inputGridRef = inputGrid
        stack.addArrangedSubview(inputGrid)

        // ADAT bank — same four-column geometry, eight compact tiles
        // (one meter row per channel, no preamp knobs). Hidden while
        // the analog bank is selected.
        let adatBank = makeAdatGrid()
        adatGrid = adatBank
        stack.addArrangedSubview(adatBank)
        // the persisted bank applies BEFORE the first layout so the
        // window never opens at the wrong height
        inputGrid.isHidden = inputsBank == 1
        adatBank.isHidden = inputsBank != 1

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
        // the spacing scale — measured from the VISIBLE controls, never
        // from an oversized container: 20–24 pt from the input knobs and
        // stacks down to the section rule, then 16–20 pt rule → heading,
        // and 16–20 pt heading → strips.
        stack.setCustomSpacing(GGSpace.sectionHead, after: inputsHeader)
        stack.setCustomSpacing(22, after: inputGrid)
        stack.setCustomSpacing(22, after: adatBank)
        stack.setCustomSpacing(18, after: sectionRule)
        stack.setCustomSpacing(18, after: outHeader)

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
        return pair
    }

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

        // per pair divider: the interrupted rule + its two rule segments
        // (the BACK half of the toggle mount — wiring happens after the
        // cards)
        var linkMounts: [(rule: NSView, upper: NSView, lower: NSView)] = []

        for i in 0..<4 {
            // PAIR DIVIDERS carry their own toggle: each ganging pair's
            // chain-link button is centered ON the divider between its
            // two channels, aligned with the gain knobs' centerline —
            // the relationship is visible in place. The central divider
            // (between Inputs 2 and 3) stays an uninterrupted rule.
            var parts: (rule: NSView, upper: NSView, lower: NSView)?
            if i == 1 || i == 3 {
                parts = addLinkRule(to: strip)
            } else if i > 0 {
                addRule(to: strip)
            }

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
                // the card HUGS its content (equality, not ≤): the card is
                // NEVER taller than its last control — no stretched blank
                // band inside the input container. Visible spacing to the
                // section rule is measured from the CONTROLS instead.
                col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: 0),
            ])

            // HEADER — the channel NAME is the selector: clicking it
            // selects this strip (a thin accent marker beside the title
            // shows the selection; the panel itself never changes). The
            // chevron beside the name opens the strip's MENU — the home
            // of the Learn action. The compact type dropdown sits at
            // the right.
            // SelectLabel: renaming lives in Settings ▸ Quartet ▸ Channel Names (inline
            // double-click editing was flaky and needed room) — click
            // here is pure strip selection.
            let head = SelectLabel(frame: .zero)
            head.stringValue = "Analog In \(i + 1)"
            head.font = GGTheme.nameFont
            head.textColor = GGTheme.primary
            head.lineBreakMode = .byTruncatingTail
            head.toolTip = "Analog In \(i + 1) — rename in Settings ▸ Quartet ▸ Channel Names"
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

            // INPUT MODE — the SHARED dropdown (Mic / +4 dBu / −10 dBV /
            // Instrument), standard container: divider + chevron.
            // COMPACT (96 pt): the channel NAME beside it keeps enough
            // width to show "Analog In 1…4" in FULL.
            let p = SourceMenuButton(target: self,
                                     action: #selector(levelMenuOpened(_:)))
            p.tag = 100 + i
            p.toolTip = "Analog level (Mic / Instrument / +4 / −10)"
            // FALLBACK width 96 (250 — optional): the qualifying width is
            // the Auto Gain block's width ("ONE aligned right column"),
            // so the fallback only matters before that constraint can
            // choose a size.
            let widthFallback = p.widthAnchor.constraint(equalToConstant: 96)
            widthFallback.priority = NSLayoutConstraint.Priority(250)
            widthFallback.isActive = true
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
            // The channel NAME never compresses — "Analog In 1…4" stays
            // FULL (the distinguishing part); the mode dropdown takes
            // what remains.
            head.setContentCompressionResistancePriority(.init(1000), for: .horizontal)
            head.setContentHuggingPriority(.init(1000), for: .horizontal)
            // join the hierarchy BEFORE constraining against col — a
            // constraint between views with no common ancestor throws
            // NSGenericException and aborts the whole window build
            col.addArrangedSubview(headerRow)
            headerRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

            // SIGNAL LEVEL bargraph between the header and the controls
            // — a 6-pt continuous peak meter (zones + peak-hold + clip
            // lamp; read-only, the knob above/below shows GAIN, this
            // shows LEVEL) spanning the whole channel width.
            let meter = GGLevelMeter()
            meter.heightAnchor.constraint(equalToConstant: 6).isActive = true
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
            // ONE aligned right column: the MODE dropdown in the header
            // and the Auto Gain block below share the SAME width — the
            // header's dropdown ends flush with the chips row. Activated
            // AFTER both sides sit in the hierarchy (common-ancestor rule).
            levelPopups[i].widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

            strip.addArrangedSubview(card)
            if let parts { linkMounts.append(parts) }
        }
        // Mount the toggles AFTER the cards: as the strip's LAST subviews
        // they sit on top in BOTH draw and hit-test order. NSStackView hit-
        // tests its later subviews first — mounted any earlier, a channel
        // card would swallow the half of the toggle's 32-pt box that
        // overhangs it, leaving only the narrow central gutter clickable.
        for (a, m) in linkMounts.enumerated() {
            mountLinkToggle(on: strip, rule: m.rule, upper: m.upper, lower: m.lower, pair: a)
        }
        return strip
    }

    // MARK: ADAT bank

    /// The ADAT bank: eight compact channel tiles in the app's
    /// four-column geometry (two rows). Each tile: channel number +
    /// optional name, live meter with peak/target markers, assistance
    /// status, and an Assist action — no gain knob, no 48V: the
    /// external converter owns the preamp, and the interface must not
    /// suggest control the app does not have.
    private func makeAdatGrid() -> NSView {
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.spacing = GGSpace.related
        wrap.translatesAutoresizingMaskIntoConstraints = false
        for row in 0..<2 {
            let strip = NSStackView()
            strip.orientation = .horizontal
            strip.spacing = GGSpace.related
            strip.translatesAutoresizingMaskIntoConstraints = false
            for col in 0..<4 {
                let i = row * 4 + col
                // the analog section's divided-column structure: thin
                // rules BETWEEN the four channels, open strips otherwise
                if col > 0 { addRule(to: strip) }
                let tile = AdatTile(index: i)
                tile.translatesAutoresizingMaskIntoConstraints = false
                tile.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
                tile.assistAction = { [weak self] in self?.assistChannel(i) }
                tile.doneAction = { [weak self] in self?.dismissAssistant(i) }
                adatTiles.append(tile)
                strip.addArrangedSubview(tile)
            }
            wrap.addArrangedSubview(strip)
        }
        return wrap
    }

    /// Debug helper for the AUTO triggers: snapshot the whole window
    /// content so a headless session can see what actually renders.
    func dumpWindowSnapshot(_ path: String) {        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            QBLog.log("control: window snapshot written to \(path)")
        }
    }

    /// The window's natural content height, measured from the REAL
    /// layout — the monitor bar, the sections document (which hugs its
    /// content) and the status footer. Nothing hard-coded.
    private func contentNeededHeight() -> CGFloat {
        (monitorBarRef?.frame.height ?? 0)
            + (scrollDoc?.frame.height ?? 0)
            + (monitorStrip?.frame.height ?? 0)
    }

    /// The window FOLLOWS its content: whenever the layout meaningfully
    /// changes (bank switch, build, routing rows) the height is
    /// re-measured and applied —
    ///   - the TOP EDGE stays put: the window grows downward, so the
    ///     monitor toolbar never jumps
    ///   - the height is capped by the screen's usable space; beyond
    ///     that the central scroll view stays the fallback (the monitor
    ///     bar and the status footer remain pinned outside it)
    ///   - meter values, texts and other live updates never call this —
    ///     only real layout changes do
    func resizeWindowToFitContent() {
        guard let window, let scrollArea, let doc = scrollArea.documentView
        else { return }
        doc.layoutSubtreeIfNeeded()
        let needed = contentNeededHeight()
        let usable = window.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
        var target = max(window.minSize.height, needed.rounded(.up))
        if let usable, usable >= window.minSize.height {
            target = min(target, usable.rounded(.up))
        }
        let current = window.frame
        guard abs(target - current.height) >= 1 else { return }
        // keep the top edge: move the ORIGIN down by the height change
        window.setFrame(NSRect(x: current.origin.x,
                               y: current.maxY - target,
                               width: current.width,
                               height: target),
                        display: true)
    }

    // MARK: - the per-channel inline Gain Assistant

    /// The tile's Gain Assist action — ONE assistant session at a
    /// time, inline on the tile itself (no overlay). The button is the
    /// SAME control in every state, so the action follows it:
    ///   Stop      this channel is listening → abort (a stopped
    ///             recheck falls back to the previous recommendation)
    ///   Recheck   this channel's frozen guidance is open → fresh
    ///             measurement, previous peak cleared
    ///   Gain Assist… otherwise → stop anything else running, dismiss
    ///             the other channel's guidance, start THIS one
    func assistChannel(_ index: Int) {
        let engine = AdatGainEngine.shared
        let wasOpen = engine.focusedChannel == index
            && engine.statuses[index] != .idle

        if engine.isMeasuringChannel(index) {
            engine.stopMeasuring()
            QBLog.log("adatgain: assist stopped on ADAT \(index + 1)")
            refresh()
            return
        }
        if engine.isMeasuring {
            engine.stopMeasuring()
        }
        if let prior = engine.focusedChannel, prior != index {
            engine.clearResult(prior)
        }
        engine.focusedChannel = index
        if wasOpen {
            // [Recheck] — a fresh measurement, previous peak cleared
            engine.recheck([index])
            QBLog.log("adatgain: assist recheck on ADAT \(index + 1)")
        } else {
            if engine.statuses[index] != .idle {
                engine.clearResult(index)   // stale, unopened guidance
            }
            if let error = engine.startMeasurement([index]) {
                QBLog.log("adatgain: assist failed on ADAT \(index + 1): \(error)")
                engine.focusedChannel = nil
            } else {
                QBLog.log("adatgain: assist opened on ADAT \(index + 1) — Target \(Int(AdatGainEngine.targetDBFS.rounded())) dBFS peak · Measurement \(Int(AdatGainEngine.durationSeconds.rounded())) s")
            }
        }
        refresh()
    }

    /// Done: close this channel's guidance and clear its
    /// recommendation — the button returns to "Gain Assist…".
    func dismissAssistant(_ index: Int) {
        let engine = AdatGainEngine.shared
        engine.clearResult(index)
        if engine.focusedChannel == index {
            engine.focusedChannel = nil
        }
        refresh()
    }

    /// The 10 Hz engine tick: meters fast-path here (never a full
    /// refresh); tile statuses/countdowns refresh only while something
    /// is measuring; an engine transition triggers exactly one refresh.
    private var adatWasMeasuring = false
    func adatUpdateTick() {
        let engine = AdatGainEngine.shared
        guard window?.isVisible == true || engine.isMeasuring else { return }
        // BOTH banks' meters live: the analog strips were built with
        // meters that previously never received a feed — now the same
        // shared tap powers them. One consolidated feed per strip:
        // level + held peak + (while this channel is being calibrated)
        // the Auto Gain target marker + the full-scale flag, whose lamp
        // latch the METER owns (click to reset).
        let autoGain = AutoGainEngine.shared
        for i in 0..<meters.count {
            meters[i].update(
                level: engine.levelFraction(i),
                peakFraction: engine.heldPeakDBFS(i)
                    .map { AdatGainEngine.levelFraction(dbfs: $0) },
                targetFraction: autoGain.runningInputs.contains(i)
                    ? AdatGainEngine.levelFraction(dbfs: AutoGainEngine.targetDBFS)
                    : nil,
                clip: engine.liveClipActive(i))
        }
        for i in 0..<adatTiles.count {
            let ch = AdatGainEngine.analogChannels + i
            let available = engine.channelAvailable(i)
            adatTiles[i].setLevels(
                live: engine.levelFraction(ch),
                holdText: engine.heldPeakText(ch, unavailable: !available),
                clipped: engine.liveClipActive(ch),
                unavailable: !available)
        }
        if engine.isMeasuring {
            adatWasMeasuring = true
        } else if adatWasMeasuring {
            // measurement finished → frozen results: one full refresh
            adatWasMeasuring = false
            refresh()
        }
    }

    // MARK: bank actions

    /// Inputs bank selector — Analog 1–4 (tag 1500) / ADAT 1–8
    /// (tag 1501). Persisted; the selection only swaps the input
    /// section's grid. The swap is THE meaningful layout change, so the
    /// window is RE-MEASURED here: it grows for the ADAT bank's two
    /// rows and shrinks back for the analog bank — top edge pinned
    /// (the window grows downward), capped by the usable screen. With
    /// the sections anchored from the top, the viewport returns to the
    /// top (a no-op once the window fits its content — scrolling is
    /// only the fallback on small screens).
    @objc private func bankClicked(_ sender: NSButton) {
        guard !suppressActions, !isLearning else { return refresh() }
        let bank = sender.tag - 1500
        inputsBank = bank
        QBLog.log("control: inputs bank → \(bank == 1 ? "ADAT 1–8" : "Analog 1–4")")
        // The GRID SWAP must happen synchronously: refresh() defers its
        // work by 50 ms, which would leave the resize-and-scroll below
        // measuring the PREVIOUS bank's layout — the window height and
        // the scroll position then lag one click behind (the layout
        // glitch on switching banks). The scheduled refresh keeps the
        // remaining UI consistent a tick later.
        bankAnalogButton?.state = bank == 1 ? .off : .on
        bankAdatButton?.state = bank == 1 ? .on : .off
        applyInputBankVisibility(bank == 1)
        resizeWindowToFitContent()
        if let doc = scrollArea?.documentView {
            doc.layoutSubtreeIfNeeded()
            doc.scroll(NSPoint(x: 0, y: doc.bounds.maxY))
        }
    }

    /// The input-bank grids' visibility — extracted from refreshNow so
    /// the bank switch can apply it synchronously (the scheduled
    /// refresh keeps it consistent afterwards).
    private func applyInputBankVisibility(_ adatBankActive: Bool) {
        linkToggles.forEach { $0.isHidden = adatBankActive }
        adatGrid?.isHidden = !adatBankActive
        inputGridRef?.isHidden = adatBankActive
    }

    /// ADAT bank header — the assistant opens with the channel picker.
    /// (Removed: each tile carries its own Gain Assist action.)

    /// The persisted bank selection (0 = analog, 1 = ADAT).
    private var inputsBank: Int {
        get { UserDefaults.standard.integer(forKey: "inputsBankPinned") == 1 ? 1 : 0 }
        set { UserDefaults.standard.set(newValue, forKey: "inputsBankPinned") }
    }

    /// QB_AUTO_ASSIST harness: press the REAL bank button, exactly like
    /// a user click (bankClicked's full path: refresh → resize → scroll).
    func debugClickBank(_ bank: Int) {
        guard let button = bank == 1 ? bankAdatButton : bankAnalogButton else {
            QBLog.log("debug: bank button \(bank) unavailable")
            return
        }
        let sel = button.action
        let tgt = button.target
        tgt?.perform(sel ?? #selector(bankClicked(_:)), with: button)
        QBLog.log("debug: bank \(bank) clicked")
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

    /// A pair divider that carries its OWN ganging toggle (inputs 1–2 /
    /// 3–4): the thin vertical rule is interrupted with clearance around
    /// a 32-pt chain-link button, centered on the divider line AND on
    /// the gain knobs' centerline — the toggle reads as integrated into
    /// the boundary between the two channels it gangs.
    ///
    /// The button is an OVERLAY, not an arranged column: it rides over
    /// the spacing around the rule (and ≤7.5 pt of each card's invisible
    /// padding — every card's controls start ≥12 pt inside), so every
    /// strip width and channel alignment the window is built around
    /// stays identical to a plain full-height rule. Added to the strip
    /// BEFORE its edge constraints activate (common-ancestor rule — the
    /// toggle is constrained against the knobs later).
    private func addLinkRule(to strip: NSStackView) -> (rule: NSView, upper: NSView, lower: NSView) {
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        strip.addArrangedSubview(rule)
        NSLayoutConstraint.activate([
            rule.widthAnchor.constraint(equalToConstant: 1),
            rule.topAnchor.constraint(equalTo: strip.topAnchor),
            rule.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
        ])
        // the INTERRUPTED divider: upper + lower rule segments, stopped
        // 3 pt short of the future button's box — the button will sit in
        // the gap it opened (mountLinkToggle activates the breaks).
        let upper = ruleSegment(in: rule)
        let lower = ruleSegment(in: rule)
        NSLayoutConstraint.activate([
            upper.topAnchor.constraint(equalTo: rule.topAnchor),
            lower.bottomAnchor.constraint(equalTo: rule.bottomAnchor),
        ])
        return (rule, upper, lower)
    }

    /// Wire up ONE pair's chain-link toggle (addLinkRule's back half).
    /// Runs AFTER all four cards exist: the button is mounted as the
    /// strip's LAST subview, so it is topmost in hit-test order and its
    /// whole 32-pt box is clickable — mounted earlier, the neighboring
    /// cards' own hit-test would swallow its overhanging halves.
    private func mountLinkToggle(on strip: NSStackView, rule: NSView,
                                 upper: NSView, lower: NSView, pair: Int) {
        let button = LinkPairButton(pair: pair, target: self,
                                    action: #selector(linkClicked(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
            button.centerXAnchor.constraint(equalTo: rule.centerXAnchor),
            // aligned with the pair's first knob — all four knobs share
            // the centerline (the cards are homogeneous)
            button.centerYAnchor.constraint(equalTo: gainKnobs[pair * 2].centerYAnchor),
        ])
        let upperBreak = upper.bottomAnchor
            .constraint(equalTo: button.topAnchor, constant: -3)
        let lowerBreak = lower.topAnchor
            .constraint(equalTo: button.bottomAnchor, constant: 3)
        // both break constraints ride below the required priority so the
        // window's first, zero-size layout pass cannot fight them
        upperBreak.priority = NSLayoutConstraint.Priority(999)
        lowerBreak.priority = NSLayoutConstraint.Priority(999)
        upperBreak.isActive = true
        lowerBreak.isActive = true
        linkToggles.append(button)
    }

    /// One hairline piece of an interrupted pair rule.
    private func ruleSegment(in rule: NSView) -> NSView {
        let seg = NSView()
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.wantsLayer = true
        seg.layer?.backgroundColor = NSColor.separatorColor.cgColor
        rule.addSubview(seg)
        seg.widthAnchor.constraint(equalToConstant: 1).isActive = true
        seg.centerXAnchor.constraint(equalTo: rule.centerXAnchor).isActive = true
        return seg
    }

    // MARK: routing cards

    /// Four aligned output strips separated by the same thin vertical
    /// rules as the inputs. Each strip reads as the actual SIGNAL PATH,
    /// top to bottom, with thin quiet connectors between the stages:
    ///
    ///     [ Playback 3–4 · Pre-FX ▾ ]    SOURCe + tap point (one menu,
    ///                                    two sections with one
    ///                                    checkmark each)
    ///           ↓
    ///     Audio FX          Trim  the two processing stages
    ///     [ Add Plug-in… ] → ( 0 dB )
    ///                    ↓
    ///                Out 1–2      the HARDWARE destination, last
    ///
    /// The grouped source menu replaces the old source dropdown +
    /// "Include source processing" checkbox — the checkbox row is gone,
    /// so the source and the Audio FX stages sit closer together. For
    /// mirrored sources the menu's second section picks the tap point
    /// on the SOURCE's chain (Pre-FX / Post-FX / Post-Trim); own
    /// sources have no separate chain to tap, so the section is absent.
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
                // the card HUGS its content (equality, not ≤) — the same
                // rule as the input cards: stretch is impossible, and the
                // gap to the footer is real spacing
                col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            ])

            // HEADER — the output NAME as a title. A SINGLE click selects
            // this strip (the accent marker beside the title shows the
            // selection). Renaming lives in Settings ▸ Quartet ▸ Channel Names.
            let nf = SelectLabel(frame: .zero)
            nf.font = GGTheme.nameFont
            nf.textColor = GGTheme.primary
            nf.lineBreakMode = .byTruncatingTail
            nf.toolTip = "Destination name — rename in Settings ▸ Quartet ▸ Channel Names"
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
            // the HARDWARE DESTINATION sits at the strip's TOP RIGHT — the
            // end of the path, stated once, up front (no drop arrows, no
            // repeated caption at the bottom)
            let dest = NSTextField(labelWithString: InsertServer.pairNames[i])
            dest.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            dest.textColor = GGTheme.softGray
            dest.alignment = .right
            dest.lineBreakMode = .byTruncatingTail
            dest.toolTip = "Hardware output pair \(InsertServer.pairNames[i])"
            dest.setContentHuggingPriority(.init(251), for: .horizontal)
            dest.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let headerGap = NSView()
            headerGap.setContentHuggingPriority(.init(1), for: .horizontal)
            headerRow.addArrangedSubview(headerGap)
            headerRow.addArrangedSubview(dest)
            col.addArrangedSubview(headerRow)
            headerRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            nf.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor).isActive = true

            // SOURCE — the head of the path, SPLIT into two compact
            // popups so the full source never truncates:
            //
            //     [ Playback 1–2 ▾ ]   [ Pre-FX ▾ ]
            //
            // The stage popup appears only for MIRRORED sources (an own
            // playback stream has no separate chain to tap).
            let sp = SourceMenuButton(target: self,
                                      action: #selector(showSourceMenu(_:)))
            sp.tag = 2100 + i
            let stp = SourceMenuButton(target: self,
                                       action: #selector(showStageMenu(_:)))
            stp.tag = 2300 + i
            stp.toolTip = "Tap point on the source's chain"
            // COMPACT + STABLE (fixed 76 pt): the longer label ("Post-Trim")
            // + content pad + chevron area — never close to the SOURCE's
            // width, never shifting when its value is a dash. Same width
            // in all four strips; disabled treatment retains the geometry.
            stp.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let srcRow = NSStackView()
            srcRow.orientation = .horizontal
            srcRow.alignment = .centerY
            srcRow.spacing = GGSpace.tight
            srcRow.translatesAutoresizingMaskIntoConstraints = false
            srcRow.addArrangedSubview(sp)
            srcRow.addArrangedSubview(stp)
            // the SOURCE dropdown FILLS the remaining row width (the stage
            // popup beside it is fixed) — never a fixed/equal column
            sp.setContentHuggingPriority(.init(1), for: .horizontal)
            sp.setContentCompressionResistancePriority(.init(750), for: .horizontal)
            col.addArrangedSubview(srcRow)
            srcRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            sourceMenus.append(sp)
            stageMenus.append(stp)

            // BODY — the COMPACT control pair:
            //
            //     [ plug-in slot ▾ ]  ◉ (small empty knob)
            //
            // ONE horizontal row: the slot and the knob share ONE height
            // (30 pt — the knob's whole diameter, arc included) and one
            // vertical centerline, 8 pt apart. No arrow, no caption. The
            // knob is silent until touched: while the trim is adjusted
            // the slot's content is TEMPORARILY replaced by the dB value
            // (centered), then the plug-in section returns.
            let tsl = GainKnob()
            tsl.minValue = -64
            tsl.maxValue = 6
            tsl.doubleValue = 0
            tsl.target = self
            tsl.action = #selector(trimSlid(_:))
            tsl.tag = 2600 + i
            tsl.sendsContinuously = true
            tsl.controlName = "Trim"
            tsl.showsCenterValue = false   // the readout lives in the slot
            // DRAG lifecycle for the field readout: while the pointer
            // holds the knob, the readout stays up; on release the
            // restore timer gives it 800 ms more before the normal
            // plug-in content returns
            tsl.onDragChange = { [weak self] knob, dragging in
                guard let self, knob.tag >= 2600, knob.tag < 2604 else { return }
                let i = knob.tag - 2600
                if dragging {
                    self.trimDisplayTimers[i]?.invalidate()
                    self.trimDisplayTimers[i] = nil
                } else {
                    self.restartTrimRestore(i)
                }
            }
            tsl.widthAnchor.constraint(equalToConstant: SourceMenuButton.height).isActive = true
            tsl.heightAnchor.constraint(equalToConstant: SourceMenuButton.height).isActive = true
            trimKnobs.append(tsl)

            // precise entry — the old trim field's tag + delegate
            tsl.valueField.tag = 2650 + i
            tsl.valueField.delegate = self

            let knobCol = NSStackView()
            knobCol.orientation = .vertical
            knobCol.alignment = .centerX
            knobCol.spacing = 0
            knobCol.translatesAutoresizingMaskIntoConstraints = false
            knobCol.addArrangedSubview(tsl)
            knobCol.widthAnchor.constraint(equalToConstant: SourceMenuButton.height).isActive = true

            // processing column — ONE hover-reveal plug-in slot carrying
            // the trim readout too. Loaded and empty slots are exactly
            // the same size.
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

            // The compact pair, ONE row — the slot FILLS the available
            // width beside the knob (its own row: its right edge is NOT
            // aligned to the source dropdown above — different rows,
            // different controls, independent width allocation).
            let body = NSStackView()
            body.orientation = .horizontal
            body.spacing = SourceMenuButton.rowGap
            body.alignment = .centerY
            body.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(procCol)
            body.addArrangedSubview(knobCol)
            // join the hierarchy BEFORE cross-view constraints (common
            // ancestor required at activation time)
            col.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            // the slot takes the rest of the row: the row is the slot +
            // the 8-pt gap + the knob column (the knob's diameter matches
            // the dropdown's height)
            procCol.widthAnchor.constraint(equalTo: body.widthAnchor,
                                            constant: -(SourceMenuButton.height + SourceMenuButton.rowGap)).isActive = true
            slot.widthAnchor.constraint(equalTo: procCol.widthAnchor).isActive = true

            // NO width link between the source dropdown and the slot —
            // the source/stage row and the slot/knob row allocate their
            // widths independently.
            col.setCustomSpacing(GGSpace.related, after: srcRow)

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

        // the ACTION button — Cancel / Dismiss for the Auto Gain flow.
        // The "Details…" case is GONE: while the device is unavailable
        // there is NO button — the status message itself is clickable
        // and opens the diagnostic popover (showFeedbackPopover).
        feedbackAction = NSButton(title: "Cancel", target: self,
                                  action: #selector(feedbackActionClicked(_:)))
        feedbackAction?.bezelStyle = .recessed
        feedbackAction?.controlSize = .small
        feedbackAction?.font = NSFont.systemFont(ofSize: 11)
        feedbackAction?.isHidden = true

        // the unit's serial ID — quiet, at the row's BOTTOM RIGHT (moved
        // out of the title bar); hidden until a tree carries one
        let serial = NSTextField(labelWithString: "")
        serial.font = NSFont.systemFont(ofSize: 11)
        serial.textColor = GGTheme.muted
        serial.alignment = .right
        serial.lineBreakMode = .byTruncatingHead
        serial.toolTip = "Connected Apogee Quartet (serial)"
        serial.isHidden = true
        serial.translatesAutoresizingMaskIntoConstraints = false
        serialField = serial

        let feedbackRow = NSStackView()
        feedbackRow.orientation = .horizontal
        feedbackRow.alignment = .centerY
        // ONE horizontal layout with explicit gaps: [status] <flex>
        // [Cancel/Dismiss…] [48 kHz ⌄] [Apogee Quartet] — 16 pt between
        // the right-side items, ONE flexible spacer, everything centered.
        feedbackRow.spacing = 16
        feedbackRow.translatesAutoresizingMaskIntoConstraints = false
        if let dot = feedbackDot { feedbackRow.addArrangedSubview(dot) }
        if let label = feedbackLabel { feedbackRow.addArrangedSubview(label) }
        let feedbackSpacer = NSView()
        feedbackSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        feedbackRow.addArrangedSubview(feedbackSpacer)
        if let time = feedbackTime { feedbackRow.addArrangedSubview(time) }
        if let action = feedbackAction { feedbackRow.addArrangedSubview(action) }

        // the SAMPLE RATE — quiet device information beside the status:
        // "Ready        48 kHz ⌄  Apogee Quartet". Small, regular
        // weight, no fill; click opens the rate menu.
        let rate = SampleRateSelector(frame: .zero)
        rate.onPick = { [weak self] requested in self?.requestSampleRate(requested) }
        rate.toolTip = "Sample rate"
        rate.setAccessibilityLabel("Sample rate")
        feedbackRow.addArrangedSubview(rate)
        sampleRateSelector = rate

        feedbackRow.addArrangedSubview(serial)

        // NARROW-WIDTH ORDER (deliberate, text never draws over text):
        // 1. the device name collapses to zero width FIRST — the unit
        //    is redundant while its name is in the tooltip;
        // 2. THEN the status message truncates with an ellipsis;
        // 3. the Cancel/Dismiss button + the rate value keep their
        //    natural width — they are the actionable items and must
        //    never be pushed.
        serial.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(200), for: .horizontal)
        feedbackLabel?.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(250), for: .horizontal)
        feedbackTime?.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(750), for: .horizontal)
        feedbackAction?.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(750), for: .horizontal)
        rate.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(750), for: .horizontal)

        footer.addArrangedSubview(feedbackRow)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            // START-height 36–40: a compact footer that still reads as a
            // footer — the row's fixed height keeps messages from ever
            // moving anything
            feedbackRow.heightAnchor.constraint(equalToConstant: 32),
            feedbackRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            feedbackRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            feedbackRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -5),
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
        // ~20% smaller than before (50→40): the monitor row is COMPACT —
        // the type scales with the dial (min 78%), so the value stays
        // readable
        sl.widthAnchor.constraint(equalToConstant: 40).isActive = true
        sl.heightAnchor.constraint(equalToConstant: 40).isActive = true
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
        // wide enough for the FULL "Headphones" title at name size — the
        // label is never constrained to the three M/D/∑ buttons below it,
        // and it never truncates
        textCol.widthAnchor.constraint(equalToConstant: 94).isActive = true

        let name = SelectLabel(frame: .zero)
        name.stringValue = o == 0 ? "Speakers" : "Headphones"
        name.font = GGTheme.nameFont
        name.textColor = GGTheme.primary
        name.onClick = { [weak self] in self?.showLearnMenu(for: o, from: name) }
        // OS volume-target marker — the SAME thin blue marker the input
        // and output sections use. Space is RESERVED in both groups (the
        // marker is always present, just clear), so nothing shifts when
        // the target changes.
        let marker = makeMarker()
        monitorMarkers.append(marker)
        let titleRow = NSStackView(views: [marker, name])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        textCol.addArrangedSubview(titleRow)

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
        // ONE equal chip width — the three glyph buttons are identical
        // tiles, never letter-dependent sizes (they join the hierarchy
        // together, so the cross-views activate after)
        mute.widthAnchor.constraint(equalTo: dim.widthAnchor).isActive = true
        dim.widthAnchor.constraint(equalTo: mono.widthAnchor).isActive = true
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

    /// The pin toggle: flips the window's floating state in place — the
    /// window neither hides nor moves, and the button's selected state
    /// paints from the SAME `pinned` flag ⌘P drives.
    @objc private func pinClicked(_ sender: NSButton) {
        togglePinned()
    }

    /// The input-mode menu items (refLevel values → labels).
    private static let levelLabels: [Int: String] = [
        1: "Mic", 2: "+4 dBu", 3: "−10 dBV", 4: "Instrument",
    ]

    /// The input-mode dropdown opens its menu (the shared dropdown's
    /// action — the menu's items route to levelItemChosen).
    @objc private func levelMenuOpened(_ sender: SourceMenuButton) {
        let i = sender.tag - 100
        let menu = NSMenu()
        for (v, label) in Self.levelLabels.sorted(by: { $0.key < $1.key }) {
            let item = NSMenuItem(title: label, action: #selector(levelItemChosen(_:)),
                                   keyEquivalent: "")
            item.target = self
            item.tag = 100 + i
            item.representedObject = NSNumber(value: v)
            item.state = inputs[i].refLevel == v ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    /// An input-mode choice from the menu (tag = 100 + i, representedObject
    /// = the refLevel value).
    @objc private func levelItemChosen(_ item: NSMenuItem) {
        let i = item.tag - 100
        guard !suppressActions, !isLearning, !AutoGainEngine.shared.isRunning,
              let v = (item.representedObject as? NSNumber)?.intValue,
              let id = PathIds.active.hwinRefLevel[i] else { return refresh() }
        guard (1...4).contains(v) else { return refresh() }
        inputs[i].refLevel = v
        onWriteInt?(id, Int32(v))
        refresh()
    }

    /// Preamp gain: writes the ACTIVE mode's gain only — mic and instrument
    /// keep their own values, so switching modes doesn't carry the gain over.
    /// Ganged inputs mirror the write (see writeInputGain).
    @objc private func gainSlid(_ sender: NSControl) {
        let i = sender.tag - 200
        guard !suppressActions, !isLearning, !AutoGainEngine.shared.isRunning else { return }
        if let rl = inputs[i].refLevel, rl == 2 || rl == 3 { return }
        let v = min(max(sender.doubleValue, 0), 75)
        writeInputGain(i, v)
        refresh()
    }

    /// Ganging link toggle — writes BOTH pair members' `hwinN.group` bit
    /// (verified live: toggling on the touchscreen sets both hwin0/hwin1
    /// group bits; unsetting clears both). Any client may write these.
    @objc private func linkClicked(_ sender: NSButton) {
        let a = sender.tag - 1400
        guard !suppressActions, !isLearning, a >= 0, a <= 1 else { return }
        let b1 = a * 2, b2 = b1 + 1
        let on = !(inputs[b1].group ?? false)        // toggle intent
        let id1 = inputGroupIds[b1], id2 = inputGroupIds[b2]
        guard !id1.isEmpty, !id2.isEmpty else { return }
        QBLog.log("control: link pair \(b1 + 1)+\(b2 + 1) → \(on ? "on" : "off")")
        onWriteBool?(id1, on)
        onWriteBool?(id2, on)
        inputs[b1].group = on
        inputs[b2].group = on
        refresh()
    }

    /// THE input-gain write: the active mode's `PreModelQuartet.gain` for
    /// this channel, mirrored onto the ganged partner when both ganging
    /// bits are set AND both inputs sit in the same analog level (a Mic
    /// input and an Instrument input can be flagged ganged without their
    /// gain transports sharing a rail — mirror only matching pairs).
    /// Hardware does NOT mirror externally written gains even for ganged
    /// inputs (verified live: hwin0 → 30.5 dB with hwin1 ganged at 0.5 dB),
    /// so the mirror is the app's job. Auto Gain deliberately does NOT
    /// route through this (its engine orchestrates individual channels).
    private func writeInputGain(_ i: Int, _ v: Double) {
        let t = PathIds.active
        let rl = inputs[i].refLevel
        let activeId = rl == 4 ? t.hwinInstGain[i] : t.hwinMicGain[i]
        guard let id = activeId else { return }
        onWriteDouble?(id, v)
        if rl == 4 { inputs[i].instGain = v } else { inputs[i].micGain = v }
        let p = (i % 2 == 0) ? i + 1 : i - 1
        guard p >= 0, p < 4, inputs[i].group == true, inputs[p].group == true,
              inputs[p].refLevel == rl else { return }
        let partnerId = (rl == 4 ? t.hwinInstGain[p] : t.hwinMicGain[p])
        if let pid = partnerId {
            onWriteDouble?(pid, v)
            if rl == 4 { inputs[p].instGain = v } else { inputs[p].micGain = v }
        }
        QBLog.log("control: ganged write \(i % 2) pair input \(i + 1) & \(p + 1) \(v) dB")
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

    private func startAutoGain(for indices: [Int]) {
        guard (isGlueConnected?() ?? false) else { return }
        // the ADAT metering tap yields the device's one IOProc first
        AdatGainEngine.shared.pauseForAutoGain()
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

    @objc private func showSourceMenu(_ sender: SourceMenuButton) {
        let i = sender.tag - 2100
        let server = InsertServer.shared
        let menu = NSMenu()
        // the source only — the tap point lives in its OWN popup beside
        // this one (showStageMenu)
        for src in InsertServer.sourceOptions(i) {
            let item = NSMenuItem(title: InsertServer.sourceLabel(src, for: i),
                                  action: #selector(sourceMenuItemChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = i                    // the menu item carries the
            item.representedObject = src.rawValue
            item.state = server.source(i) == src ? .on : .off
            menu.addItem(item)
        }
        // below the button (the view is NOT flipped — "below" is negative y)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    /// The SPLIT stage popup's menu — just the tap point on the selected
    /// (mirrored) source's chain. Picking a stage never touches the source.
    @objc private func showStageMenu(_ sender: SourceMenuButton) {
        let i = sender.tag - 2300
        let server = InsertServer.shared
        let menu = NSMenu()
        for stage in [InsertServer.MirrorStage.pre, .postFX, .postTrim] {
            let item = NSMenuItem(title: stage.label,
                                  action: #selector(stageMenuItemChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = i
            item.representedObject = stage.rawValue
            item.state = server.stage(i) == stage ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    /// A choice from the source menu's SOURCE section (tag = the output
    /// pair, representedObject = the PairSource raw value).
    @objc private func sourceMenuItemChosen(_ item: NSMenuItem) {
        let i = item.tag
        guard !suppressActions,
              let raw = item.representedObject as? String,
              let src = InsertServer.PairSource(rawValue: raw) else { return refresh() }
        InsertServer.shared.setSource(i, src)
        ensureInsertRunning()
        refresh()
    }

    /// A choice from the source menu's STAGE section (tag = the output
    /// pair, representedObject = the MirrorStage raw value). Selecting
    /// a stage never touches the source.
    @objc private func stageMenuItemChosen(_ item: NSMenuItem) {
        let i = item.tag
        guard !suppressActions,
              let raw = item.representedObject as? String,
              let stage = InsertServer.MirrorStage(rawValue: raw) else { return refresh() }
        InsertServer.shared.setStage(i, stage)
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
    /// The strip's plug-in section is TEMPORARILY replaced by the live
    /// trim value (see PluginSlotView.overrideText). The normal content
    /// returns 800 ms after the last adjustment — the timer restarts on
    /// every step — and a DRAG holds the readout until the pointer is
    /// released (the knob's drag-end hook schedules the restore here).
    private var trimDisplayTimers: [Timer?] = [nil, nil, nil, nil]

    @objc private func trimSlid(_ sender: NSControl) {
        let i = sender.tag - 2600
        let v = sender.doubleValue   // already whole (knob rounds)
        InsertServer.shared.setTrim(i, v, notify: false)
        // the ARC follows the drag live; the field beside it shows the
        // trim value ONLY while it is being adjusted — appearance and
        // disappearance of the readout never touch the plug-in itself
        trimKnobs[i].arcColor = Self.trimArcColor(v)
        pluginSlots[i].overrideText = String(format: "%+.1f dB", v)
        // A drag keeps the readout up until release — the drag-end hook
        // schedules the restore. Scroll/keyboard steps restore 800 ms
        // after the last one (scheduledTimer restarts the delay).
        if !trimKnobs[i].isDragging { restartTrimRestore(i) }
    }

    /// Puts the strip's normal plug-in content back 800 ms after the
    /// last trim adjustment.
    private func restartTrimRestore(_ i: Int) {
        trimDisplayTimers[i]?.invalidate()
        let slot = pluginSlots[i]
        trimDisplayTimers[i] = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) {
            [weak self, weak slot] _ in
            slot?.overrideText = nil
            self?.trimDisplayTimers[i] = nil
        }
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

    /// Talkback chip — a LATCH toggle: one click latches it on (stays lit
    /// orange while talkback runs), another click stops it. The light
    /// mirrors the LIVE state (hotkeys/MIDI/menu all flow through
    /// setTalkback, and refresh reads talkbackState back).
    @objc private func talkbackToggled(_ sender: NSButton) {
        guard !suppressActions else { return }
        onTalkback?(sender.state == .on)
    }

    /// The Auto Gain All tile's tooltip: unmistakable action + the current
    /// configuration (set in Settings ▸ Processing ▸ Auto Gain):
    /// "Auto Gain All — calibrate every Mic/Instrument input · Target −18 dBFS peak · 5 s".
    private static func autoGainConfigTooltip() -> String {
        "Auto Gain All — calibrate every Mic/Instrument input · Target \(String(format: "−%.0f", abs(AutoGainEngine.targetDBFS))) dBFS peak · \(Int(AutoGainEngine.listenSeconds)) s"
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

    /// Esc in the inline knob editor cancels — nothing is committed.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        // the field editor's cancel (Esc) — either selector form,
        // depending on SDK and first-responder chain
        if commandSelector == Selector(("cancelOperation:"))
            || commandSelector == Selector(("cancel:")) {
            (control.superview as? GainKnob)?.cancelEditing()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, !suppressActions, !isLearning else { return }
        // an edit that ended by CANCELLING (Esc) keeps the old value
        if let knob = field.superview as? GainKnob, knob.editCancelled { return }
        switch field.tag {
        case 250..<254:
            // input gain (dB) — the knob's inline editor, active mode only
            let i = field.tag - 250
            defer { gainKnobs[i].endEditing() }
            guard let db = parseDB(field.stringValue) else { return refresh() }
            let v = min(max(db, 0), 75)
            let t = PathIds.active
            if inputs[i].refLevel == nil || (inputs[i].refLevel ?? 1 == 0) {
                // no live ref level yet — nothing sane to write
                return refresh()
            }
            writeInputGain(i, v)
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
    /// control's own). The ACCESSIBLE state rides along — the engaged
    /// color is never the only carrier of the state.
    private func setToggle(_ b: NSButton, _ value: Bool?, enabled: Bool) {
        b.isEnabled = enabled
        b.state = (value ?? false) ? .on : .off
        b.setAccessibilityValue((value ?? false) ? "on" : "off")
        if !enabled, let tip = b.toolTip, !tip.isEmpty, !tip.hasSuffix("— device unavailable") {
            // keep the control's own tooltip; add the WHY when unavailable
            b.toolTip = "\(tip)\n— device unavailable"
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
        AdatVisibility(false)
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
        AdatVisibility(false)
    }

    /// The metering hub's visibility flag (the live meters idle when
    /// the window is gone; a running measurement keeps it alive).
    private func AdatVisibility(_ visible: Bool) {
        AdatGainEngine.shared.windowVisible = visible
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
            // the marker's meaning, on the title it sits beside
            inputHeaders[i]?.toolTip = i == selectedInputIndex
                ? "Selected input — gain & Auto Gain shortcuts act here"
                : "Click to select this input"
        }
        for (i, m) in outputMarkers.enumerated() {
            m.layer?.backgroundColor = (i == selectedOutputIndex
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor)
            nameFields[i].toolTip = i == selectedOutputIndex
                ? "Selected output — trim & source shortcuts act here · double-click to rename"
                : "Click to select · double-click to rename this output"
        }
        // the OS volume-target marker on the monitor groups — driven from
        // the ACTUAL binding target (never hover, focus or last-knob-used);
        // the mute state stays completely independent of it
        let target = volumeTarget?()
        for (i, m) in monitorMarkers.enumerated() {
            let selected = (i == target)
            m.layer?.backgroundColor = (selected
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor)
            // the tooltip rides on the LABEL beside the marker
            if let title = m.superview?.subviews.compactMap({ $0 as? SelectLabel }).first {
                title.toolTip = selected ? "Controlled by system volume keys" : nil
            }
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
        sourceMenus[selectedOutputIndex].performClick(nil)
    }

    /// Cycle the selected strip's tap point Pre-FX → Post-FX →
    /// Post-Trim → Pre-FX (mirrors only — own sources have no separate
    /// chain to tap).
    func shortcutCycleStage() {
        let i = selectedOutputIndex
        let server = InsertServer.shared
        guard server.source(i).copyIndex != nil else { return }
        let all: [InsertServer.MirrorStage] = [.pre, .postFX, .postTrim]
        let next = all[(all.firstIndex(of: server.stage(i)).getOrElse { 0 } + 1) % all.count]
        server.setStage(i, next)
        ensureInsertRunning()
        refresh()
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