// OFFLINE PREVIEW RENDERER (development tool — not part of the app).
//
// Builds the Quartet Control window WITHOUT the menubar app around it
// and renders its content view straight to a PNG, so the layout can be
// checked on a machine with no Quartet attached (and without screen
// recording permission).
//
//   swiftc -o /tmp/qbpreview tools/preview/main.swift <app sources…>
//   /tmp/qbpreview <out-prefix>          → <prefix>-disconnected.png
//                                           <prefix>-connected.png
//
import AppKit

let outPrefix = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/qb-control"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = QuartetControlController.shared

// MARK: - a fake device tree (so the CONNECTED state can be checked)

func node(_ type: String, _ props: [String: Any], _ children: [[String: Any]] = []) -> [String: Any] {
    ["type": type, "props": props, "children": children]
}

let serial = "quartetPREVIEW01"
var inputs: [[String: Any]] = []
for i in 0..<4 {
    inputs.append(node("hwin\(i)", [
        "name": "Analog In \(i + 1)",
        "analogRefLevel": i == 3 ? 4 : 1,
        "softLimit": i == 1 ? 1 : 0,
        "polarityInvert": i == 2 ? 1 : 0,
    ], [
        node("micSettings", ["phantom": i == 0 ? 1 : 0],
             [node("PreModelQuartet", ["gain": 19.0 - Double(i) * 4])]),
        node("instSettings", [:], [node("PreModelQuartet", ["gain": 12.0])]),
    ]))
}
let outputs = [
    node("hwout0", ["gain": -12.0, "mute": 0, "dim": 0, "sum": 0]),
    node("hwout1", ["gain": -24.0, "mute": 0, "dim": 1, "sum": 0]),
]
let tree = node("root", [:], [node(serial, ["samplerate": 48000.0], inputs + outputs)])

// MARK: - render

func render(_ path: String) {
    guard let window = NSApp.windows.first(where: { $0.title == "Quartet Control" }),
          let view = window.contentView else {
        FileHandle.standardError.write("no Quartet Control window\n".data(using: .utf8)!)
        exit(1)
    }
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(bounds.width),
                                      pixelsHigh: Int(bounds.height),
                                      bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    view.cacheDisplay(in: bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) — \(Int(bounds.width))×\(Int(bounds.height))")
    }
}

// 1 — DISCONNECTED: no device, no glue, nothing known.
controller.show()
RunLoop.main.run(until: Date().addingTimeInterval(1.2))
render(outPrefix + "-disconnected.png")

// 2 — CONNECTED: a live tree, live values, the sample rate known.
PathIds.select(serial: serial)
controller.isGlueConnected = { true }
controller.onSeedTree = { tree }
controller.updateTree(tree)
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
render(outPrefix + "-connected.png")

exit(0)
