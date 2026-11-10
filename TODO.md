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
- [x] 10.2 Inputs bank selector [ Analog 1–4 | ADAT 1–8 ] in the section header; ADAT strips 4×2, COMPACT: heading + Assist…/Stop/Recheck button on one row, then the SAME `GGLevelMeter` the analog strips use (4-pt track, zones, peak marker, clip lamp) with the inline held-peak readout (one decimal, band-colored) at its right end, and a reserved two-line feedback area beneath (blank when idle; Done trailing on the second line) — the circular dial was REMOVED (it repeated the meter's level and cost the height); no gain knob/48V (the external converter owns the preamp)
- [x] 10.3 Assistant INLINE on each strip (the overlay was replaced): one session at a time, the header button follows the state (Assist… → Stop → Recheck), guidance rides the reserved feedback area — no overlay, no dimming, no extra card
- [x] 10.4 Live stream mapping: ADAT channel count from the device's input stream config (SMUX-aware at 88.2/96 kHz); stale results invalidated on sample-rate/device change or stream stall; no optical-lock claim
- [x] 10.5 Reliability states: "No signal during measurement" (silence never suggests a big up — worded about the take, so later signal still shows on the live meter), "Input clipped · Reduce external gain" (no exact correction off a clipped wave), result freeze semantics, Auto Gain handshake
- [x] 10.6 Settings ▸ Processing ▸ Gain Assistance (target/duration/±range), Settings ▸ Channel Names ▸ ADAT Inputs (app-side names), analog strip meters now fed by the same tap
- [ ] 10.7 LIVE-VERIFY on hardware: SMUX channel count at 44.1/48 vs 88.2/96, a real measure→adjust→recheck loop, permission grant on first tap, meter sanity — user confirmation pending
- [x] 10.8 Bank selector reworked + Digital naming (Oct 26 2026): the pair of separate [Analog 1–4 | ADAT 1–8] toggles → ONE compact segmented control (`BankSegmentedControl` — shared dark container, equal-width segments, no gap, ~28 pt, small radii; graphite selection + off-white label on the selected segment, transparent + muted + hover lift on the unselected one, exterior focus ring; no accent fill — bank switching is a view change, not an audio function); visible bank + channel headings renamed ADAT → "Optical 1–8" / "Optical 1–8" (Settings Channel Names block now "Optical Inputs"), ADAT kept in the tooltips/device details where the connection format matters ("Optical inputs 1–8 via ADAT"); PRESENTATION ONLY — the underlying ADAT channel mapping, metering and gain-assistance behavior untouched (segments stay tags 1500/1501 into `bankClicked`, harness unaffected)


## Phase 11 — Standalone mode: no Apogee Control 2 at all
Goal: Quartet Buddy works with ONLY itself installed (no ApogeeGlue daemon).
Static RE done 2026-11-07 → `docs/standalone-plan.md`.

- [x] 11.1 Static RE of ApogeeGlue's device path — first read said **CoreHID** (IOHIDDeviceOpen / SetReport / InputReportCallback in the imports); **live session Nov 7 corrected it**: the Quartet itself has no HID interface — Glue's HID code serves other Apogee products; for the Quartet it opens a **device-level `AppleUSBHostDeviceUserClient`** (endpoint-0 control transfers / vendor iAP interface 5). Kernel kext is a no-op property-injection stub (AppleUSBMergeNub, no binary); Glue's own log (`Logging`, `logMessageRX/TX` → `/Library/Preferences/Apogee/Glue/Apogee_Glue.log`) turned out NOT to dump Quartet packets (11.4)
- [x] 11.2 `tools/hid_probe.swift` — list / passive monitor / manual send (compiles clean, runs with no card: "No Quartet found")
- [ ] 11.3 Card plugged (2026-11-07): ✅ live descriptor dump done — **no HID interface**: UAC ctrl(0)/stream-out(1)/stream-in(2)/ctrl(3)/MIDI(4), vendor iAP(5, 0xFF:0xF0, 3 EPs), DFU(6); Glue holds a device-level `AppleUSBHostDeviceUserClient`; `hid_probe` (CoreHID) rightly finds nothing → transport = endpoint-0 control transfers / interface-5 bulk; update `hid_probe` accordingly next
- [x] 11.4 Logging-oracle probe — RULED OUT after 3 config passes: `Logging` read-only over IPC; XML mirror (`/Library/Preferences/com.apogee.glueserver.xml`) patch+bounce works but logMessage RX/TX emits no Quartet packet hex at any level/method (gates other products); strip-safe daemon restarted repeatedly; system RESTORED to stock. Findings in `docs/standalone-plan.md` § Live session intel
- [ ] 11.5 Disassembly oracle pass: `otool -tvV` on the stripped binary (no local symbols — anchor via RTTI strings for `ApogeeRemoteUSBPacket` / `QuartetGlueServerDevice` / `USBDeviceMacOSE` + imported `IOServiceOpen`/`IOConnectCall*` sites) → recover ≥1 write frame (start with `identify`), the transfer mechanism, and the unentitled-app feasibility of `AppleUSBHostDeviceUserClient` — then live-probe the front-panel blink from our own client
- [ ] 11.6 Direct-USB transport: `.directUSB` enum case alongside `.glueDaemon`; boot tree from saved XML/preferences without the daemon; "Glue Offline" states become "device, transport-n/a"; talkback helper re-homed app-side
- [ ] 11.7 Re-verify OS volume/mute slider semantics with zero Apogee software installed (pure AppleUSBAudio) and adapt OSVolumeMirror; document "install = just Quartet Buddy"


## Phase 12 — Settings ▸ Quartet ▸ Outputs consolidation (Nov 8 2026)
- [x] 12.1 Tab renamed "Output Levels" → "Outputs"; the three stacked sections (reference levels / trim / routing) → ONE destination table (Output | Source | Hardware trim) + the six reference levels in a 2×3 grid below. MAPPING CORRECTED Nov 8 by the user against the live unit (the Oct 26 "one pair up" LABEL-TRAP note was wrong): jack numbers ARE the macOS pair numbers — Main Out = Out 1-2, strips "Analog Out 1/2, 3/4, 5/6" (hwout2…7) = jack pairs Out 3-4 / 5-6 / 7-8, and the headphone jack plays Out 7-8, so ALL FOUR destinations route (slot 3 = Headphones = Out 7-8) and all but Main carry a trim. Rows lead with the jack identity; touchscreen strip names ride as secondary text. No audio-model change: same 0x53 sources, same trim pairs/registers, same analogRefLevel paths.
- [x] 12.2 Long inline paragraphs → one short task line per section; registers, connector map (the "one pair up" label trap), ⌘-click reset, talkback footgun and reconnect/persistence notes moved behind per-section ⓘ popovers (shared `showInfoPopover` — the mixer ⓘ now uses it too).
- [x] 12.3 Disconnected state made consistent: one notice ("Quartet disconnected. Showing last-known settings…"), routing popups now disable like the rest (they stayed enabled before), trims/levels keep last-known values readable+disabled, and an UNREADABLE trim shows a dash with the slider REMOVED — no handle implying a made-up position.
- [x] 12.4 Layout: table rows + ref grid pin to the pane body width (deferred pin like the mixer bank), shared columns via fixed name/source widths, readouts fixed-width right-aligned monospaced, one subtle rule under the captions.
- [ ] 12.5 LIVE-CHECK on hardware: with the unit plugged in, confirm the table's row↔jack mapping reads as documented and the disabled/last-known states show as intended when unplugged.
