import AppKit

// Builds assets/AppIcon.iconset/* from the downloaded Apogee logo:
// 1. finds the tile's bounding box (the PNG has a white margin),
// 2. measures the tile's corner radius,
// 3. crops + masks the corners transparent (the source has no alpha),
// 4. writes every iconset size for iconutil.
let src = NSImage(contentsOfFile: "/Users/soufiane/Downloads/apogee-maestro-logo-png_seeklogo-299969.png")!
let tiff = src.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let w = rep.pixelsWide, h = rep.pixelsHigh
func isWhite(_ p: NSColor) -> Bool {
    p.redComponent > 0.94 && p.greenComponent > 0.94 && p.blueComponent > 0.94
}
var minX = w, maxX = -1, minY = h, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        if let c = rep.colorAt(x: x, y: y), !isWhite(c) {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
let tw = maxX - minX + 1, th = maxY - minY + 1
print("tile: (\(minX),\(minY)) \(tw)x\(th)")
// radius: top-left corner — walk down until the tile reaches its own left edge
var radius = 0
for dy in 0..<th {
    var firstX = -1
    for x in minX...maxX {
        if let c = rep.colorAt(x: x, y: minY + dy), !isWhite(c) { firstX = x; break }
    }
    if firstX <= minX + 1 { radius = dy; break }
}
print("corner radius ≈ \(radius) px")
// mask radius with a 2 px safety inset so no white sliver survives
let maskRadius = CGFloat(radius - 2)

let master = NSImage(size: NSSize(width: tw, height: th))
master.lockFocus()
let rect = NSRect(x: 0, y: 0, width: tw, height: th)
let clip = NSBezierPath(roundedRect: rect, xRadius: maskRadius, yRadius: maskRadius)
clip.addClip()
// high-quality draw of the crop (rep is bottom-left origin like the draw)
let crop = NSRect(x: minX, y: minY, width: tw, height: th)
rep.draw(in: crop)

// white-bleed check is unnecessary — the clip kills the corners
master.unlockFocus()

let fm = FileManager.default
let dir = "QuartetBuddy/assets/AppIcon.iconset"
try? fm.removeItem(atPath: dir)
try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
for spec in [(16, "1x"), (32, "2x"), (32, "1x"), (64, "2x"), (128, "1x"), (256, "2x"),
             (256, "1x"), (512, "2x"), (512, "1x"), (1024, "2x")] {
    let (size, scale) = spec
    let pxSize = CGFloat(size)
    let out = NSImage(size: NSSize(width: pxSize, height: pxSize))
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pxSize, height: pxSize))
    out.unlockFocus()
    guard let t = out.tiffRepresentation,
          let r = NSBitmapImageRep(data: t),
          let png = r.representation(using: .png, properties: [:]) else { fatalError("encode") }
    let name = "icon_\(size)x\(size)\(scale == "2x" ? "@2x" : "").png"
    try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
}
print("iconset written: \(dir)")
