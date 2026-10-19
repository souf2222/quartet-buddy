# Quartet Buddy 🎛

A menubar companion for the **Apogee Quartet** audio interface, built by
reverse-engineering Apogee Control 2's IPC protocol
([`docs/protocol-notes.md`](docs/protocol-notes.md)).

It fixes what Apogee Control 2 breaks on modern macOS: the Quartet's driver
never lets macOS's volume keys touch the **real fader** — all the system sees
is a display-only volume slider (range −64…0 dB, no audible effect), so the
volume keys are effectively dead. Quartet Buddy **binds that slider to the
real fader, both directions**, giving the Quartet a fully native macOS
volume experience — plus a few things Apogee never offered. It talks to the
ApogeeGlue daemon directly, so you keep Apogee Control 2 installed (for
routing) and everything stays in sync.

## Features

| Feature | Details |
|---|---|
| **Native volume keys** | F11/F12 (and the volume HUD, ⌥-fine steps — everything) behave exactly like any Mac: they drive the macOS volume slider, which is **bound to the Quartet's real analog fader**. Key presses move the fader; fader moves (Apogee Control 2, the touchscreen) move the slider — always in sync, both directions. |
| **macOS slider binding** | The slider macOS shows for the Quartet is a pure display (verified: writing it changes no audio) — Quartet Buddy is the bridge that makes it real. Drag it in System Settings → Sound / Control Center and the Quartet follows; 100% ⇔ 0 dB, 0% ⇔ −64 dB. |
| **Native mute key** | F10 (and the Control Center mute icon) toggle the selected output's hardware mute. One-way by necessity: writing the OS mute control wedges the Apogee driver, so mutes done in Apogee Control 2 / on the touchscreen don't update the macOS mute display. |
| **Volume target** | Choose **Main Out** or **Headphones** for the binding — via the menu, or a **system-wide switch hotkey**. The menubar icon shows which one is active (Apogee logo = Main Out, headphones glyph = HP). **Defaults to Main Out** on every launch and Quartet (re)connect. |
| **Talkback hotkey** | Any ⌘/⌥/⌃-combo, recorded in-app. |
| **Talkback MIDI button** | Press a note/CC on the keyboard plugged into the Quartet's MIDI port — MIDI-learn captures it. Toggle or momentary mode. |
| **Live status** | Menubar tooltip + menu show both output levels in dB, mute, and talkback state — synced in real time with the hardware touchscreen, Apogee Control 2, and the app. |
| **AU insert** | Run any AU plugin independently on each of the Quartet's 4 stereo pairs, with per-pair routing (own playback / mirror another pair before or after its plug-in / silence) in the Outputs & Plug-ins window. No loopback driver, no default-device switch, volume keys unaffected. See [`docs/au-insert.md`](docs/au-insert.md). |
| **Connection awareness** | The menubar icon greys out when the Quartet isn't connected (USB-level detection, instant plug/unplug) — and the menu header tells you why ("Quartet Not Connected" / "Glue Offline"). |

No media keys are ever intercepted — macOS handles the volume keys and F10
natively, on whatever device is the current output (your MacBook speakers
keep behaving normally). The Quartet's binding applies to its own macOS
controls, and the app needs **no permissions at all** — no Input Monitoring,
no prompts.

## Requirements

- macOS 13+ (developed on macOS 27)
- Apogee Control 2 installed (its ApogeeGlue daemon is what we talk to)
- Quartet connected over USB

## Install & first run

```bash
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

**Launch at Login** is a menu toggle. Your choice is remembered, and if the
registration ever goes missing (app moved/renamed), the app re-registers
itself automatically on the next launch.

### Setup

- **Volume target:** *Volume Target →* Main Out / Headphones (or record a
  switch hotkey) — what the macOS slider binding controls. Resets to Main Out
  whenever the app launches or the Quartet (re)connects.
- **AU insert:** *Start Plug-in Insert* in the menubar menu turns the insert
  (and its routing window) on and is remembered across launches.
- **New Quartet:** plug it in and the **Setup wizard opens by itself** (or
  menubar → *Setup New Quartet…*). Path-ids are hashed per device serial, so
  each physical Quartet needs its ids captured once: follow 5 steps (move the
  Main Out fader, the HP fader, toggle each mute, toggle dim) — the wizard
  listens to the glue stream, captures each id live and saves it to
  preferences. No code change, no Terminal needed.
- **Talkback:** *Turn Talkback On* to test, then record the *Talkback Hotkey*
  and/or *MIDI Button → Learn…* (press a button on your keyboard)
- **MIDI mode:** *Toggle* (press = on/off) or *Momentary* (hold to talk)

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
  be up: check the menu header — "Glue Offline" means the app can't reach
  the Quartet (Apogee Control 2 / its daemon not running; it auto-reconnects
  every 3 s). And the Quartet must be the current output device — with any
  other device selected, the keys adjust that device instead (native macOS
  behavior).
- **Menu header shows "Glue Offline"** — ApogeeGlue isn't running (Apogee
  Control 2 not installed/running). The app auto-reconnects every 3 s; there's
  also a *Reconnect* menu item.
- Everything logs to `~/Library/Logs/QuartetBuddy.log` (menu: *Advanced →
  Open Debug Log…*) — every slider move, mute change, and write is recorded.
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
