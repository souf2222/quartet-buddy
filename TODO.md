# Quartet Buddy — Overhaul TODO

## Phase 1 — Knob fundamentals
- [x] 1.1 Center the value text inside the knob
- [x] 1.2 Double-click knob to type a value (Enter commits, Esc/click-away cancels)
- [x] 1.3 ⌘-click a knob resets it to zero
- [x] 1.4 Trim knobs half-size + remove the "Trim (dB)" caption

## Phase 2 — Segmented control hover (Plugin slot)
- [x] 2.1 Edge-to-edge flat hover highlights (no inset padding)
- [x] 2.2 Left segment: round only outside (left) corners; center: all square; right: round only right corners
- [x] 2.3 Clip all segment fills to the outer rounded container; separators drawn above highlights

## Phase 3 — Toolbar state palette + unified hover
- [x] 3.1 Talkback: orange #E68A32 active, neutral gray off
- [x] 3.2 Mute All: green #35BA68 unmuted, red #E25560 + slashed speaker when muted (state-driven)
- [x] 3.3 Auto Gain All: purple #9255C8 for the whole run (measure + apply), state-driven
- [x] 3.4 Unify hover effect (brightness shift) on Auto Gain, Add Plugin, all toolbar tiles
- [x] 3.5 Border-scan animation kept on per-input buttons; top chip holds its purple fill

## Phase 4 — Dropdown chevrons
- [x] 4.1 Plugin slot: downward chevron on the right → replace-plugin flow (+ chevron on the empty "Add Plug-in…" slot)
- [x] 4.2 Chevron treatment on the custom dropdowns (sample-rate selector; SourceMenuButton kept; native popups carry their own arrow)

## Phase 5 — Monitor bar refinement
- [x] 5.1 Monitor knobs ~15–20% smaller (60→50), values centered/readable
- [x] 5.2 Row padding: 22 pt sides, ≥12 pt top/bottom; groups vertically centered
- [x] 5.3 Thin blue OS-volume-target marker before Speakers/Headphones (space reserved, tooltip "Controlled by system volume keys", driven from selectedOutput)
- [x] 5.4 Right-hand utility buttons preserved in size/spacing

## Phase 6 — Sample-rate selector
- [x] 6.1 Custom one-line readout "48 000Hz" (nbsp thousands, no comma), bold tabular numerals
- [x] 6.2 Dark flat container #25262C, chevron section + subtle divider, entire control opens the menu
- [x] 6.3 Hover brightens background; fixed width for longest value; "Sample rate —" placeholder when unknown

## Phase 7 — Quick-control panel + hotkey + logo
- [x] 7.1 New titlebar-free quick-control panel (QuickControlPanel.swift) — knobs, M/D/∑, talkback, mute-all, settings
- [x] 7.2 Global hotkey, default ⌥C, re-recordable in Settings ▸ Shortcuts
- [x] 7.3 Logo click opens the Quartet Control window directly (menubar menu removed)

## Phase 8 — Serial number
- [x] 8.1 "Apogee Quartet · <serial>" moved to the footer's bottom-right (muted label, hidden when no serial)