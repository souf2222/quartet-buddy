import AppKit

/// Menubar icon, drawn on a FIXED-SIZE canvas so the menubar item never
/// changes width when state changes:
///  - Quartet unplugged     → always the Apogee logo, greyed out (30%), no talkback dot
///  - Main Out selected     → Apogee logo PNG (full color)
///  - Headphones selected   → native macOS headphones glyph, tinted to the menubar
///                            label color (so the talkback dot can be red)
///  - talkback on           → small red dot (top-right), on any connected variant
enum LogoIcon {

    /// Fixed canvas: matches the logo's aspect ratio at iconHeight.
    static let iconHeight: CGFloat = 16
    static let canvasSize = NSSize(width: 20, height: 16)

    private static var baseCache: NSImage?
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(talkback: Bool, headphonesSelected: Bool, active: Bool) -> NSImage {
        // include the appearance in the key: the tinted headphones variant
        // resolves its colors for the current light/dark mode
        let appearance = NSApp?.effectiveAppearance.name.rawValue ?? "none"
        let key = "hp-\(headphonesSelected)-tb-\(talkback)-ac-\(active)-\(appearance)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let img = compose(talkback: talkback, headphonesSelected: headphonesSelected, active: active)
        lock.lock()
        cache[key] = img
        lock.unlock()
        return img
    }

    private static func compose(talkback: Bool, headphonesSelected: Bool, active: Bool) -> NSImage {
        let useHeadphones = active && headphonesSelected   // greyed state always shows the logo
        let out = NSImage(size: canvasSize)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: canvasSize)
        // NOTE: CGContext.setAlpha is ignored by NSImage.draw — the
        // `fraction:` argument is the reliable way to dim an NSImage.
        let fraction: CGFloat = active ? 1.0 : 0.3

        if useHeadphones, let hp = headphoneSymbol() {
            // Tint the template glyph to the menubar text color so the image
            // can stay non-template — required for a red talkback dot.
            let r = aspectFit(hp, in: rect)
            let appearance = NSApp?.effectiveAppearance
                ?? NSAppearance.current
                ?? NSAppearance(named: .aqua)!
            let tint = NSImage(size: canvasSize)
            tint.lockFocus()
            hp.draw(in: r)
            glyphColor(for: appearance).set()
            NSRect(origin: .zero, size: canvasSize).fill(using: .sourceIn)
            tint.unlockFocus()
            tint.draw(in: rect)
        } else if let logo = loadAsset() ?? drawFallbackA(size: iconHeight) {
            logo.draw(in: aspectFit(logo, in: rect), from: .zero, operation: .sourceOver,
                      fraction: fraction, respectFlipped: false, hints: nil)
        }

        if talkback, active {   // unplugged ⇒ assume talkback is off: no dot
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: canvasSize.width - 5.5, y: canvasSize.height - 5.5,
                                        width: 4.5, height: 4.5)).fill()
        }
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    private static func headphoneSymbol() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        return NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones")?
            .withSymbolConfiguration(cfg)
    }

    /// Menubar text color for the current appearance (white on dark, black on light).
    private static func glyphColor(for appearance: NSAppearance) -> NSColor {
        if let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]),
           match == .darkAqua || match == .vibrantDark {
            return .white
        }
        return .black
    }

    private static func loadAsset() -> NSImage? {
        if let base = baseCache { return base }
        if let img = Bundle.main.image(forResource: "apogee-icon-small")
                    ?? Bundle.main.image(forResource: "apogee-icon") {
            baseCache = img
            return img
        }
        return nil
    }

    private static func aspectFit(_ image: NSImage, in rect: NSRect) -> NSRect {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return rect }
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: fallback (hand-drawn A, template)

    private static func drawFallbackA(size: CGFloat) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size * 3), pixelsHigh: Int(size * 3),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = size
        let path = NSBezierPath()
        path.lineWidth = s * 0.20
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: s * 0.20, y: s * 0.86))
        path.line(to: NSPoint(x: s * 0.50, y: s * 0.12))
        path.move(to: NSPoint(x: s * 0.80, y: s * 0.86))
        path.line(to: NSPoint(x: s * 0.50, y: s * 0.12))
        path.move(to: NSPoint(x: s * 0.335, y: s * 0.575))
        path.line(to: NSPoint(x: s * 0.665, y: s * 0.575))
        NSColor.black.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        img.isTemplate = true
        return img
    }
}
