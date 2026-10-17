import AppKit

/// Menubar icon, drawn on a FIXED-SIZE canvas so the menubar item never
/// changes width when state changes:
///  - Main Out selected  → Apogee logo PNG (color)
///  - Headphones selected → native macOS headphones glyph (template)
///  - talkback on         → small red dot (top-right); black on the template variant
/// The mute state no longer alters the icon — macOS shows its own mute feedback.
enum LogoIcon {

    /// Fixed canvas: matches the logo's aspect ratio at iconHeight.
    static let iconHeight: CGFloat = 17
    static let canvasSize = NSSize(width: 21, height: 17)

    private static var baseCache: NSImage?
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(talkback: Bool, headphonesSelected: Bool) -> NSImage {
        let key = "hp-\(headphonesSelected)-tb-\(talkback)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let img = compose(talkback: talkback, headphonesSelected: headphonesSelected)
        lock.lock()
        cache[key] = img
        lock.unlock()
        return img
    }

    private static func compose(talkback: Bool, headphonesSelected: Bool) -> NSImage {
        let out = NSImage(size: canvasSize)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: canvasSize)

        if headphonesSelected, let hp = headphoneSymbol() {
            // native look: template glyph, macOS inverts it for the menubar
            let r = aspectFit(hp, in: rect)
            hp.draw(in: r)
            if talkback {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: canvasSize.width - 5.5, y: canvasSize.height - 5.5,
                                            width: 4.5, height: 4.5)).fill()
            }
            out.unlockFocus()
            out.isTemplate = true
            return out
        }

        if let logo = loadAsset() ?? drawFallbackA(size: iconHeight) {
            logo.draw(in: aspectFit(logo, in: rect))
        }
        if talkback {
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
