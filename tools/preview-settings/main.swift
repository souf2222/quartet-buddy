// OFFLINE PREVIEW HARNESS — the Settings window's Quartet ▸ Outputs pane
// (development tool — not part of the app). Runs with NO device attached
// and prints the pane's control tree (frames, selections, enabled/hidden
// states) for the disconnected and connected states, so layout and state
// rules can be checked without hardware.
//
// (A pixel capture needs either cacheDisplay — which the hosted AppKit
// buttons don't survive — or a Screen Recording TCC grant, which this
// harness must not trigger; hence the structural dump.)
//
//   swiftc -o /tmp/qbsettings tools/preview-settings/main.swift <app sources…>
//   /tmp/qbsettings
//
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = SettingsWindowController()

func findSettingsWindow() -> NSWindow? {
    NSApp.windows.first(where: { $0.title == "Quartet Buddy Settings" })
}

// select the Quartet pane (sidebar button tag 2 — its title is
// "▣  Quartet"), then its "Outputs" sub-tab, by driving the controls'
// actions through the responder chain
func openOutputsTab() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let window = findSettingsWindow(),
          let content = window.contentView else { return }
    var buttons: [NSButton] = []
    var segs: [NSSegmentedControl] = []
    func walk(_ v: NSView) {
        if let b = v as? NSButton { buttons.append(b) }
        if let s = v as? NSSegmentedControl { segs.append(s) }
        v.subviews.forEach(walk)
    }
    walk(content)
    if let quartet = buttons.first(where: { $0.tag == 2 && $0.title.contains("Quartet") }),
       let action = quartet.action {
        _ = NSApp.sendAction(action, to: quartet.target, from: quartet)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    guard let seg = segs.first(where: { $0.segmentCount == 4 && $0.label(forSegment: 2) == "Outputs" }),
          let action = seg.action else {
        FileHandle.standardError.write("Outputs segment not found\n".data(using: .utf8)!)
        exit(1)
    }
    seg.selectedSegment = 2
    _ = NSApp.sendAction(action, to: seg.target, from: seg)
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
}

/// Structural verification: walk the VISIBLE Quartet sub-pane and print
/// every control's frame + state.
func describeOutputs() {
    guard let window = findSettingsWindow(),
          let content = window.contentView else { return }
    var lines: [String] = []
    func describe(_ v: NSView, _ depth: Int) {
        if v.isHidden { return }
        let indent = String(repeating: "  ", count: depth)
        var extra = ""
        if let popup = v as? NSPopUpButton {
            extra = " sel='\(popup.titleOfSelectedItem ?? "none")' enabled=\(popup.isEnabled)"
        } else if let slider = v as? NSSlider {
            extra = String(format: " value=%.1f enabled=%d hidden=%d",
                           slider.doubleValue, slider.isEnabled ? 1 : 0,
                           slider.isHidden ? 1 : 0)
        } else if let label = v as? NSTextField, label.isEditable == false {
            extra = " '\(label.stringValue.prefix(48))'"
        }
        let f = v.frame
        lines.append("\(indent)\(type(of: v)) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))\(extra)")
        if depth < 12 { v.subviews.forEach { describe($0, depth + 1) } }
    }
    describe(content, 0)
    print(lines.joined(separator: "\n"))
}

// 1 — DISCONNECTED: no device, no glue. Last-known values shown (disabled);
// trims with no readable value → a dash with no slider handle.
controller.show()
openOutputsTab()
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
describeOutputs()

// 2 — CONNECTED: fake live values through the page's own callbacks
// (pair 3's trim deliberately unreadable → must show a dash even connected).
controller.readDeviceProps = { [:] }   // non-nil = reachable (direct session)
controller.readLineOutLevels = { (0..<6).map { ("Analog Out \($0 + 1)", 2) } }
controller.readHwoutTrims = { [("Analog Out 1 / 2", -3.5),
                               ("Analog Out 3 / 4", 0.0),
                               ("Analog Out 5 / 6", nil)] }
controller.readHwoutRouting = { [0, 1, 2, 3] }
controller.refresh()
openOutputsTab()
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
describeOutputs()

exit(0)
