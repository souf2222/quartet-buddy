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

## Phase 9 — Small RE batch (implemented + LIVE-VERIFIED Oct 25 2026)- [x] 9.1 `GlueClient.setString` (var-tag 5, NUL-terminated) — transport for all string writes
- [x] 9.2 Identify — **dead end (verified live)**: `dev/identify` consumes writes of every encoding but the front panel never blinks; type-7 Command strings inert. Front-panel-only mirror. UI **removed**; findings in docs/protocol-notes.md ("Verified writes")
- [x] 9.3 Touchscreen prefs — Settings ▸ General: peakHold / overHold / lockHomeScreen — **all three live-verified** (lock + holds user-confirmed on the unit). Note: `intProp` hardened for bool/string-typed tree props; probe gotcha: setProperty tag-3 value byte is 1/0, NOT JUCE var markers 2/3
- [x] 9.4 Line-out levels — Analog Out 1–6 (`hwout2..7.analogRefLevel`): write +4/−10 live-verified (int32), restored — **UI moved to Settings ▸ Audio ▸ Line Out Levels** (Oct 25 2026, user request; the control window's row is gone)
- [x] 9.5 Talkback source picker — Settings ▸ Talkback: `selectedTalkbackSourceDevice`/`Channel` write live-verified (set "Quartet"/0). Oct 25 fix: the sources live UNDER the `talkbackSources` container node — the picker read Talkback's direct children and showed one bogus "source"; now lists Quartet / MacBook Air Microphone / iPhone mic with the channel picker enabled per device
- [x] 9.6 Renaming — hardware `hwinN.name` round-trip verified live ("Analog IN 1" ↔ "Kick"). Oct 25: **inline double-click removed** (never engaged reliably) → Settings ▸ Names pane: Quartet inputs (hwin0..3.name), Quartet outputs (hwout0..7.name — write path same pattern, not separately spot-checked), and the app-side stereo-pair names
- [x] 9.7 LIVE-VERIFY every 9.1–9.6 write with `tools/prop_probe.py` — done Oct 25 2026 (see docs/protocol-notes.md § Verified writes)
- [x] 9.8 Buffer-size selector — probe verdict: `preferredBufferSize` NEVER reaches the HAL (verified across a USB replug) → shipped as a **direct CoreAudio write** (Settings ▸ Audio "Device buffer", 32…4096 frames; CoreAudio write + read-back verified; insert restarts)
- [ ] 9.9 HP routeSource menu — SKIPPED: hwout1.routeSource showed no change/traffic while switching HP source (semantics unverified; revisit if Apogee Control 2's HP routing page can be instrumented)
- [x] 9.10 Input ganging (`hwin.group`) — probe verdict: toggling on the touchscreen sets BOTH pair members' group bits, but hardware does NOT mirror externally written gains (hwin0→30.5, ganged partner stayed 0.5) → app mirrors writes itself; Link 1+2 / Link 3+4 toggles in the Inputs header + ganged active-gain mirroring
- [x] 9.11 Front-panel touchpad actions — **SHIPPED Oct 26 2026**: full action enum captured by cycling AC2's dropdown under `tools/watch_features.py`; external round-trip write verified (Dim All, then Mute Headphone on the encoder push). UI: Settings ▸ General ▸ **Front Panel Pads** — grouped popups (Mute ▸ / Dim ▸ / Sum to Mono ▸ / Toggle ▸ / Clear Meters / Engage Speaker Set ▸); the **encoder gets its own 4-option menu** (out-of-menu values left its action at 0x0 — inert). Footgun documented for future drives: NSPopUpButton can't display a selection inside a submenu — grouped look must use section headers + indented top-level items, and the popup needs BOTH action + target wired or nothing fires.


## Phase 10 — ADAT input bank + Gain Assistant (Oct 26 2026)
- [x] 10.1 `AdatGain.swift` — `AdatGainEngine`: shared CoreAudio metering tap (the InputTap from AutoGain, yielded aside while an Auto Gain calibration owns the device IOProc), live smoothed levels for analog + ADAT, and the ADAT measurement loop (target −12 dBFS peak · 5 s · ±2 dB — all Settings-configurable; frozen results until Recheck)
- [x] 10.2 Inputs bank selector [ Analog 1–4 | ADAT 1–8 ] in the section header; ADAT tiles 4×2: number + name, `AdatLevelMeter` (dB-scale fill, target tick, peak marker), status text, Assist… — no gain knob/48V (the external converter owns the preamp)
- [x] 10.3 `AdatGainOverlay` — in-window focused assistant over a dimmed workspace (monitor bar stays usable): select chips → listening (single big meter / multi rows) → frozen guidance (big instruction / results table with per-row recheck ticks + "Recheck selected") — Close always visible, Escape stops measuring, dimmed area never dismisses
- [x] 10.4 Live stream mapping: ADAT channel count from the device's input stream config (SMUX-aware at 88.2/96 kHz); stale results invalidated on sample-rate/device change or stream stall; no optical-lock claim
- [x] 10.5 Reliability states: "Not enough signal" (silence never suggests a big up), "Clipped — reduce gain" (no exact correction off a clipped wave), result freeze semantics, Auto Gain handshake
- [x] 10.6 Settings ▸ Processing ▸ Gain Assistance (target/duration/±range), Settings ▸ Channel Names ▸ ADAT Inputs (app-side names), analog strip meters now fed by the same tap
- [ ] 10.7 LIVE-VERIFY on hardware: SMUX channel count at 44.1/48 vs 88.2/96, a real measure→adjust→recheck loop, permission grant on first tap, meter sanity — user confirmation pending
