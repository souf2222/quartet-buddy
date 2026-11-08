# Quartet Buddy 🎛

A menubar companion for the **Apogee Quartet** audio interface — now
**fully standalone**: it talks to the Quartet over USB **directly** and
needs **no Apogee software at all** (no ApogeeGlue daemon, no Apogee
Control 2, no kext). Built by reverse-engineering the Quartet's vendor
protocol — every register decoded and verified
([`docs/standalone-plan.md`](docs/standalone-plan.md)).

It started by fixing what Apogee Control 2 breaks on modern macOS: the
Quartet's driver never lets macOS's volume keys touch the **real fader** —
all the system sees is a display-only volume slider (range −64…0 dB, no
audible effect). Quartet Buddy **binds that slider to the real fader, both
directions** — and then replaced Apogee Control 2 entirely: preamps,
routing, front-panel pads, output trims, touchscreen preferences, and
talkback, all straight to the hardware.

## Screenshots

**Quartet Control** — one window for everything: inputs (level mode, preamp
gain, 48V, soft limit) → outputs & routing (source, plug-in insert, trim) →
the persistent monitor bar (Speakers · Headphones with their M/D/∑ chips),
plus the live sample-rate readout — and clicking the menubar Apogee logo
toggles it.

![Analog inputs](docs/screenshots/control-window.jpg)

**The analog inputs** — level mode (Mic / +4 dBu / −10 dBV / Instrument),
preamp gain, Auto Gain, 48V, soft limit, polarity, ganging — and the
monitor bar (Speakers · Headphones) with their M/D/∑ chips, all live:


**The Digital 1–8 bank** — the optical ADAT inputs as eight compact strips
with the live meter and the Digital Gain Assistant:

![Digital inputs](docs/screenshots/digital-inputs.jpg)

**Settings ▸ Quartet ▸ Output Levels** — the line-out reference levels,
the hardware trims, and the **hardware output routing** (each output pair
plays a USB playback pair or one of the two hardware mixers):

![Settings — Output Levels](docs/screenshots/settings-output-levels.jpg)

**Settings ▸ Quartet ▸ Controls** — the touchscreen preferences and the
front-panel pad assignments:

![Settings — Controls](docs/screenshots/settings-controls.jpg)

## Features

| Feature | Details |
|---|---|
| **Native volume keys** | F11/F12 (and the volume HUD, ⌥-fine steps — everything) behave exactly like any Mac: they drive the macOS volume slider, which is **bound to the Quartet's real analog fader**. Key presses move the fader; fader moves (Apogee Control 2, the touchscreen) move the slider — always in sync, both directions. |
| **macOS slider binding** | The slider macOS shows for the Quartet is a pure display (verified: writing it changes no audio) — Quartet Buddy is the bridge that makes it real. Drag it in System Settings → Sound / Control Center and the Quartet follows; 100% ⇔ 0 dB, 0% ⇔ −64 dB. |
| **Native mute key** | F10 (and the Control Center mute icon) toggle the selected output's hardware mute. One-way by necessity: writing the OS mute control wedges the Apogee driver, so mutes done in Apogee Control 2 / on the touchscreen don't update the macOS mute display. |
| **Volume target** | Choose **Main Out** or **Headphones** for the binding — a **system-wide switch hotkey** (recorded in Settings ▸ Shortcuts) or the next/previous-output shortcuts. The menubar icon shows which one is active (Apogee logo = Main Out, headphones glyph = HP). **Defaults to Main Out** on every launch and Quartet (re)connect. |
| **Talkback hotkey** | Any ⌘/⌥/⌃-combo, recorded in-app. |
| **Talkback MIDI button** | Press a note/CC on the keyboard plugged into the Quartet's MIDI port — MIDI-learn captures it. Toggle or momentary mode. |
| **Talkback (standalone)** | The engine runs in-app — no helper process. Pressing talkback: **opens the selected mic's mixer channel**, **re-routes your headphones to that hardware mixer** (which carries the playback *and* the mic), and **dims the main outputs**. Release/press-again restores everything: the headphones to your saved routing, the mic muted, the dim off. The source = any of the Quartet's **12 inputs** (the 4 analog + the 8 optical), picked in Settings ▸ Talkback. |
| **Live status** | The menubar tooltip and the Quartet Control window show both output levels in dB, mute, and talkback state — synced in real time with the hardware touchscreen, Apogee Control 2, and the app. |
| **AU insert** | Run any AU plugin independently on each of the Quartet's 4 stereo pairs, with per-pair routing (own playback / mirror another pair with a selectable tap point on its chain — Pre-FX / Post-FX / Post-Trim / silence) in the Quartet Control window. No loopback driver, no default-device switch, volume keys unaffected. See [`docs/au-insert.md`](docs/au-insert.md`). |
| **Quartet Control** | One unified audio-control window (the old "Quartet Console" + "Outputs & Plug-ins" merged) with an explicit signal flow: **inputs → outputs & routing → monitor**. Per analog input — analog level (Mic / +4 dBu / −10 dBV / Instrument), preamp gain (mic and instrument keep their own values — the slider edits the active mode's; hidden at the line levels), signal meter, +48V (Mic only), soft limit, polarity, and **ganging** (a chain-link toggle on each channel-pair's divider — inputs 1–2 and 3–4; linked preamps move together, mirrored by the app exactly like the touchscreen's linked faders). Per stereo output pair — destination name, source (a grouped menu whose second section picks where the signal is taken from a mirrored source's chain: Pre-FX / Post-FX / Post-Trim), processing slot (enable / open / replace), output trim. A persistent bottom strip keeps Main Speakers + Headphones monitor level, mute, dim, mono always visible while the rest scrolls, and the window's subtitle shows the device's name. Reads are always live (tree poll); **write ids are computed from the device serial via the cracked descriptor hash** (see [`docs/protocol-notes.md`](docs/protocol-notes.md)) — every control works on any Quartet, no setup, no capture. |
| **Digital inputs (ADAT)** | A single compact **Analog 1–4 \| Digital 1–8** **segmented bank selector** in the Inputs section header (two equal-width segments in one shared dark container — switching banks only changes the displayed input view). The Digital bank shows the optical inputs — digital inputs 1–8 via ADAT — as eight compact channel strips (4 × 2) — channel heading with its **Assist…/Stop/Recheck** button on one row, then the SAME live meter the analog strips use (4-pt track, zones, held-peak marker, clip lamp) with the inline held-peak readout ("−12.4", one decimal, colored by the held value's band) at its right end. No circular readout, no gain knob, no 48V button: the Quartet's ADAT preamps are the external converter's, and the interface doesn't imply hardware control it doesn't have. The channel count follows the LIVE stream configuration (at 88.2/96 kHz each lightpipe carries four channels); off-stream channels read "—". Names are app-side (Settings ▸ Quartet ▸ Channel Names ▸ Digital Inputs). |
| **Digital Gain Assistant** | Assisted Gain for Digital 1–8 (the optical ADAT inputs) — measurement and guidance, not automatic gain control, inline on each channel strip. It measures the selected channels' highest SAMPLE peak for the Settings-defined duration (default 5 s), compares it with the target (default −12 dBFS, ±2 dB) and shows a relative instruction — "↑ Increase external gain by 8 dB" — which stays FROZEN while the user turns the external preamp's knob; **Recheck** runs a fresh measurement and verifies. The loop: Listen → Recommend → Manual adjustment → Recheck → Verified. The button follows the session state (Assist… → Stop while listening → Recheck when frozen); the two-line guidance appears ONLY on the strip hosting the session — "Play your loudest section" / "Listening · 3 s" while measuring, a **trailing Done** text action when frozen (never glued to the instruction's tail) — and collapses on Done; the idle strips carry no reserved space, the row grows just the two lines while the session runs, and the window re-fits once per open/close. A take without usable signal reads "No signal during measurement" (signal arriving later still shows on the active meter), a clipped take "Input clipped" without an exact correction off the ceiling. One assistant runs at a time; it never changes the audio signal, and it cedes the device's IOProc when an analog Auto Gain calibration runs. |
| **Names** | Settings ▸ Names renames the hardware inputs (what the touchscreen and Apogee Control 2 show), the hardware outputs (Main Out / Headphones / Analog Out 1–6), and the app-side stereo-pair display names. |
| **Hardware output routing** | Settings ▸ Quartet ▸ Output Levels ▸ Hardware output routing: each output pair (Out 1-2 Main, Out 3-4, Out 5-6, Headphones) plays a **USB playback pair** (Playback 1-2 / 3-4 / 5-6 / 7-8) or one of the **two hardware mixers** — the DAC's source selection, written straight to the unit's flash. The headphone's default = Playback 7-8. |
| **Line out levels** | Settings ▸ Audio ▸ Line Out Levels gives each of the six ¼" line outputs (Analog Out 1–6) its own hardware reference level (+4 dBu / −10 dBV), the same knob the touchscreen's output settings drive. |
| **Talkback source** | Settings ▸ Talkback picks which input device the talkback helper listens to (Quartet inputs, MacBook mic, a Continuity iPhone mic — whatever is in the tree) and its input channel; talkback then works even when the Mac's default input isn't the Quartet. |
| **Touchscreen prefs** | Settings ▸ Quartet ▸ Controls drives the unit's front-panel touchscreen preferences: meter peak hold, overload hold, and lock home screen — live registers, verified against the touchscreen itself. |
| **Front-panel pads** | Settings ▸ Quartet ▸ Controls remaps the unit's A / B / C touchpads and the encoder push — written **once, straight to the unit's flash** (the assignments survive reboots, power cycles, and moving the unit between computers). The pads' menu = Mute / Dim / Sum to Mono (Speaker/Headphone/All), Clear Meters, Engage Speaker Set 1/2/3; **the toggles are encoder-only** (the device's pad enum doesn't carry them), so the encoder gets its own restricted menu — Mute Speaker/Headphone/All + Toggle Mute Speaker/HP — exactly like Apogee Control 2's. |
| **Device buffer** | Settings ▸ Audio sets the Quartet's CoreAudio IO buffer (32…4096 frames) — the tree's `preferredBufferSize` is a daemon preference that never reaches the HAL (verified), so this writes the device property directly like the sample-rate selector. |
| **Connection awareness** | The menubar icon greys out when the Quartet isn't connected (USB-level detection, instant plug/unplug), and the Quartet Control window flags what's unreachable ("Quartet Not Connected" / "Glue Offline"). |
| **Quick-control panel** | An optional floating, titlebar-free strip with the essentials — monitor knobs with their M/D/∑ chips, talkback and mute-all tiles — toggled by a configurable global hotkey (default ⌥C). Clicking the menubar Apogee logo toggles the full Quartet Control window; ⌘P pins/unpins it while it's focused. All keyboard shortcuts are configurable in Settings ▸ Shortcuts. |

No media keys are ever intercepted — macOS handles the volume keys and F10
natively, on whatever device is the current output (your MacBook speakers
keep behaving normally). The Quartet's binding applies to its own macOS
controls, and the app needs **no permissions at all** — no Input Monitoring,
no prompts.

## Requirements

- macOS 13+ (developed on macOS 27)
- Quartet connected over USB
- **No Apogee software** — Control 2, the daemon, and the helper are not
  needed (uninstall them if you like; the settings live in the unit's own
  flash and survive moving the unit between computers)

## Install & first run

```bash
git clone https://github.com/souf2222/quartet-buddy.git
cd quartet-buddy/QuartetBuddy
./build.sh          # builds "Quartet Buddy.app", signs, restarts the running app
```

The script relaunches the app automatically, so every rebuild goes live
immediately. The app lives in `build/Quartet Buddy.app`.

**No permissions needed.** The app never intercepts media keys and needs no
TCC grants (no Input Monitoring, no prompts, nothing to re-grant after
rebuilds). Volume keys and F10 work through macOS's own controls, bridged
to the Quartet's hardware.

> The build script signs the app with the **QuartetBuddy Developer**
> certificate (created in your keychain during setup) so the Launch-at-Login
> registration survives every rebuild; without it, it falls back to ad-hoc
> signing.

**Launch at Login** is a checkbox in Settings ▸ General. Your choice is
remembered, and if the registration ever goes missing (app moved/renamed),
the app re-registers itself automatically on the next launch.

### Setup

- **Volume target:** record a switch hotkey in Settings ▸ Shortcuts (or use
  the next/previous-output shortcuts) — what the macOS slider binding
  controls. Resets to Main Out whenever the app launches or the Quartet
  (re)connects.
- **AU insert:** Settings ▸ Plug-ins ▸ *Plug-in insert active* turns the
  insert on; routing and the processing slots live in the Quartet Control
  window's **Outputs & Routing** section.
- **New Quartet:** plug it in and the **setup wizard opens by itself**.
  Path-ids are hashed per device serial, so
  each physical Quartet needs its ids captured once: follow 5 steps (move the
  Main Out fader, the HP fader, toggle each mute, toggle dim) — the wizard
  listens to the glue stream, captures each id live and saves it to
  preferences. No code change, no Terminal needed.
- **Talkback:** *Turn Talkback On* to test, then record the *Talkback Hotkey*
  and/or *MIDI Button → Learn…* (press a button on your keyboard)
- **MIDI mode:** *Toggle* (press = on/off) or *Momentary* (hold to talk)

## Talkback

Talkback is the app-side engine (Apogee's helper process reimplemented on
the decoded registers):

1. **Press** (the strip button, the menubar, a hotkey, or MIDI) and Quartet
   Buddy:
   - opens the selected mic channel in the hardware mixer (unmutes it),
   - switches your **headphones' routing to that mixer** — mixer 1 carries
     the USB playback *and* the mic, so you keep hearing your music,
   - **dims the main outputs** so the speakers don't blast the room.
2. **Release** (hold-to-talk) or **press again** (toggle) and everything
   restores: the headphones back to your saved routing, the mic muted again
   (the feedback guard), the dim off.

**Settings ▸ Talkback** picks the source — any of the **12 inputs** (Analog
1–4 = mixer channels 1–4, Optical/Digital 1–8 = 5–12) — the behavior (toggle /
hold-to-talk), and the MIDI trigger.

Ear-verified protocol detail (11/8): the two mixer route bytes on
register 0x53 = **04 (Mixer 1)** and **05 (Mixer 2)** — Apogee's original
source list (Playback 1-2…7-8 = 00-03, Mixer 1 = 04, Mixer 2 = 05). The
talkback engine's mic gate = the route switch: normal listening on a
playback pair (no mic), talkback on the selected mixer (music + mic),
restored on release.

### Hardware mixers (Settings ▸ Quartet ▸ Hardware Mixers)

**VERIFIED MODEL (11/8):** Mixer 1 = route byte 4, Mixer 2 = byte 5
(Apogee's original source list). The mixers' channel gains live in the
**0x10 snapshot blocks — ONE PER STEREO SIDE, 14 slots of (gain, marker)**:
Mixer 1 = block 0 (L) + block 1 (R), Mixer 2 = block 2 (L) + block 3 (R).
Slots 0-11 = the inputs (gain = clamp(dB+48, 0…54) → −48…+6 dB; factory:
Mixer 1 = 0x00 (−48, silent), Mixer 2 = 0x16 (−26 dB) — the "always-on
mic" mystery was Mixer 2's Digital 1 sitting at −26 dB). **Slot 12 = THE
PLAYBACK channel** (the tree's playback.mixerChannel = 12): the stereo
playback spans the side blocks — **L block's slot 12 = playback L, R
block's slot 13 = playback R** (factory 0x20 = −16 dB; the old 0x4C
ch12/13 cells gate nothing on the mixer routes — the playback-gating
matrix v2 proved the bus survives their seals). **PAN = the L/R gain
difference** (verified: writing only block 2 moved the LEFT output
channel). The marker bytes (0xA1 for inputs, 0x00 for the playback
slots) must be preserved when rewriting slots.

The UI: Mixer 1 / Mixer 2 sections, rows = Analog 1-4, Digital 1-8,
Playback (one stereo row — writes L slot 12 + R slot 13), fader
(−48…+6 dB) + Pan (the L/R balance), live read-backs through the blocks.
Route any output pair to Mixer 1/2 via the routing popups.

**Mute/Solo = app-level (11/8):** the mute/solo hunt found no hardware
gate — the 0x4F mute register reads back on every wValue plane (0-3) but
gates nothing on the block-mixer routes, and marker bits 1/2/5 don't
either. So the app implements them like the daemon likely did: a muted
row's both side slots sit at −48 dB while the fader/pan keep the user's
positions (remembered across relaunches in defaults); solo ducks every
unsoloed row the same way. Functionally identical to AC2's mixer.

The front-panel pads can't trigger talkback: the pads execute the unit's
built-in action enum, and talkback is a host-loop feature that lives in the
app. The menubar button, the strip button, the hotkey, and MIDI are the
triggers.

## How it works

```
volume + mute keys ──► macOS (native, untouched) ──► OS "Quartet" volume + mute
                                                          │  ▲
                          OS control changes ─────────────┘  │ hardware state
                          (applied to fader/mute)           │ (copied onto the
                                                           ▼  OS controls)
                              ApogeeGlue IPC  ──►  ApogeeGlue daemon ──► Quartet
                              (TCP localhost)         ▲
switch/talkback hotkey ──► RegisterEventHotKey ──────┤
MIDI keyboard ──► CoreMIDI ("Quartet" source) ────────┘
```

The OS "Quartet" volume + mute controls are display-only (the driver never
applies them to the audio), so `OSVolumeMirror` bridges them: OS control
changes are written to the real hardware through ApogeeGlue, and hardware
changes (from Apogee Control 2, the touchscreen, key presses) are copied
back onto the OS controls.

Quartet Buddy connects to ApogeeGlue like the official apps do and speaks its
protocol: JUCE framing (magic `F2B49E2C`), the custom ValueTreeSyncProtocol
records (checksum-fold codec, `setProperty` messages with 4-byte path-ids),
and the gzip'd JUCE ValueTree binary stream used for full-tree sync. All of
it is documented in [`docs/protocol-notes.md`](docs/protocol-notes.md) and
reimplemented in `QuartetBuddy/Sources/GlueProtocol.swift`. Both read and
write paths were verified against the live daemon.

## Repo layout

```
docs/protocol-notes.md       complete wire protocol spec
docs/captures/               sample tree dump from the live device
tools/                       RE toolchain (capture analyzer, probes, id watcher,
                             write tests — the scripts that cracked the protocol)
QuartetBuddy/Sources/        the Swift app
QuartetBuddy/assets/         Apogee logo
QuartetBuddy/build.sh        build + sign + bundle
```

## Troubleshooting

- **Icon is greyed out** — the Quartet isn't detected over USB. Check the
  cable/port; the icon returns to full color the moment it's seen again.
- **Volume keys do nothing on the Quartet** — the keys drive the macOS
  slider, and the app carries its level to the Quartet, so the bridge must
  be up (Apogee Control 2 / its daemon not running → the app auto-reconnects
  every 3 s). And the Quartet must be the current output device — with any
  other device selected, the keys adjust that device instead (native macOS
  behavior).
- Everything logs to `~/Library/Logs/QuartetBuddy.log` (Settings ▸ General ▸
  *Open Debug Log…*) — every slider move, mute change, and write is recorded.
- **MIDI learn finds nothing** — the keyboard must be plugged into the
  Quartet's MIDI port (CoreMIDI source named "Quartet"); it won't see USB
  keyboards connected directly to the Mac.
- **Talkback does nothing audible** — the TalkbackHelper needs a valid
  source/destination configured in Apogee Control 2's Talkback settings.

## Notes & limitations

- Path-ids in `PathIds` are a hash of the property path **including the
  device serial** — every physical Quartet has its own table. Two units are
  captured in code (`quartet1528B15CEE547FA`, `quartet15819153CE0E077`);
  any **other** Quartet auto-opens the built-in **setup wizard**
  (*Setup New Quartet…*) — 5 guided steps, ids captured from the live glue
  stream and saved to preferences. No rebuild needed.
- An Apogee software update could change the protocol; the app shows the
  offline state and the debug log tells you where it broke. The protocol
  notes contain everything needed to re-crack it.
- This is an independent interoperability tool for your own hardware; it
  contains no Apogee code.
