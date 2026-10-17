import AppKit

/// Menubar icon: the Apogee logo PNG bundled in Resources
/// (assets/apogee-icon-small.png) with optional state overlays:
///  - muted: red slash
///  - talkback: red dot (top-right)
///  - volume keys target Headphones: small headphone badge (bottom-right)
/// Composed variants are cached — the menu icon is regenerated only when
/// state actually changes.
enum LogoIcon {

    static let menuBarHeight: CGFloat = 18

    private static var baseCache: NSImage?
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(muted: Bool, talkback: Bool, headphonesSelected: Bool) -> NSImage {
        let key = "\(muted)-\(talkback)-\(headphonesSelected)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let img = compose(muted: muted, talkback: talkback, headphonesSelected: headphonesSelected)
        lock.lock()
        cache[key] = img
        lock.unlock()
        return img
    }

    private static func compose(muted: Bool, talkback: Bool, headphonesSelected: Bool) -> NSImage {
        guard let base = loadAsset() ?? drawFallbackA(size: menuBarHeight) else {
            return NSImage()
        }

        if !muted && !talkback && !headphonesSelected {
            return scaledToFit(base)
        }

        let size = menuBarHeight
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        base.draw(in: aspectFit(base, in: NSRect(x: 0, y: 0, width: size, height: size)))
        if talkback {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: size - 6, y: size - 6, width: 5, height: 5)).fill()
        }
        if muted {
            let slash = NSBezierPath()
            slash.lineWidth = 1.6
            slash.move(to: NSPoint(x: 1.5, y: 1.5))
            slash.line(to: NSPoint(x: size - 1.5, y: size - 1.5))
            NSColor.systemRed.setStroke()
            slash.stroke()
        }
        if headphonesSelected {
            if let hp = headphoneSymbol() {
                let r = NSRect(x: size - 8, y: -0.5, width: 8, height: 8)
                hp.draw(in: r)
            } else {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: size - 6, y: 1, width: 5, height: 5)).fill()
            }
        }
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    private static func headphoneSymbol() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        return NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private static func scaledToFit(_ image: NSImage) -> NSImage {
        let h = menuBarHeight
        let scale = h / max(image.size.height, 1)
        let w = image.size.width * scale
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        out.unlockFocus()
        out.isTemplate = false
        return out
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
