import AppKit

// Probe: corner colors, the tile's bounding box, its corner radius.
guard let img = NSImage(contentsOfFile: "/Users/soufiane/Downloads/apogee-maestro-logo-png_seeklogo-299969.png"),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else { fatalError("load failed") }
let w = rep.pixelsWide, h = rep.pixelsHigh
print("size \(w)x\(h) alpha:\(rep.hasAlpha)")

func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    guard let c = rep.colorAt(x: x, y: y) else { return (-1, -1, -1, -1) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
}
print("corners TL \(px(0, 0)) TR \(px(w-1, 0)) BL \(px(0, h-1)) BR \(px(w-1, h-1))")
print("center \(px(w/2, h/2))")

// scan the top row: where does the dark tile begin/end?
func isWhite(_ p: (Int, Int, Int, Int)) -> Bool { p.0 > 240 && p.1 > 240 && p.2 > 240 }
var firstDarkX = -1, lastDarkX = -1
for x in 0..<w where !isWhite(px(x, 2)) { if firstDarkX < 0 { firstDarkX = x }; lastDarkX = x }
print("top row (y=2): dark from \(firstDarkX) to \(lastDarkX)")
// scan the middle row: full span?
var mFirst = -1, mLast = -1
for x in 0..<w where !isWhite(px(x, h/2)) { if mFirst < 0 { mFirst = x }; mLast = x }
print("mid row: dark from \(mFirst) to \(mLast)")
// scan the left column: vertical span at full width
var tFirst = -1, tLast = -1
for y in 0..<h where !isWhite(px(2, y)) { if tFirst < 0 { tFirst = y }; tLast = y }
print("left col (x=2): dark from \(tFirst) to \(tLast)")
// radius estimate: on the top row, the inset where the tile starts ≈ how
// much the corner arc cuts in; walk down the left edge to find where the
// tile first reaches x=0..2
var yFull = -1
for y in 0..<h where !isWhite(px(0, y)) { yFull = y; break }
print("left edge first dark at x=0: y=\(yFull)")
