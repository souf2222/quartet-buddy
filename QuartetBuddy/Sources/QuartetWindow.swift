import AppKit

// MARK: - Windows with a working ⌘Q

/// Quartet Buddy is a STATUS-ITEM (accessory) app: there is no menu bar,
/// so the standard Quit accelerator (⌘Q, shown next to "Quit Quartet
/// Buddy" in the status menu) never actually fires — the accelerator
/// lives in the app menu that an accessory app never shows. While a
/// window is frontmost the key equivalent goes down the responder chain
/// anyway, so these subclasses CONSUME ⌘Q themselves and terminate the
/// app (which button of focus: the control window, Settings, or the
/// floating quick panel behave the same).
final class QuartetWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The floating quick panel — a PANEL, so it needs the same ⌘Q handler.
final class QuartetPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
