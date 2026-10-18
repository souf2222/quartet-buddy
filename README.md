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
| **macOS slider binding** | The slider macOS shows for the Quartet is a pure display (verified: writing it changes no audio) — Quartet Buddy is the bridge that makes it real. Drag it in System Settings → Sound and the Quartet follows. Toggle in *Advanced → Bind to macOS Volume Slider*; off = classic mode (keys step the fader directly, 4 dB per block, ⌥ = 1 dB). |
| **Mute key** | F10 toggles mute on the selected output. |
| **macOS slider sync** | The volume slider macOS shows for the Quartet (System Settings → Sound, Control Center) always displays the real fader level — 100% ⇔ 0 dB, 0% ⇔ −64 dB. It's a pure display (verified: writing it changes no audio), so the app owns it: it re-writes the level on every volume change and snaps the slider back when macOS or a stray drag moves it. Toggle in *Advanced → Sync macOS Volume Slider*. |
| **Output selector** | Choose **Main Out** or **Headphones** for the volume keys — via the menu, or a **system-wide switch hotkey**. The menubar icon shows which one is active (Apogee logo = Main Out, headphones glyph = HP). |
| **Talkback hotkey** | Any ⌘/⌥/⌃-combo, recorded in-app. |
| **Talkback MIDI button** | Press a note/CC on the keyboard plugged into the Quartet's MIDI port — MIDI-learn captures it. Toggle or momentary mode. |
| **Live status** | Menubar tooltip + menu show both output levels in dB, mute, and talkback state — synced in real time with the hardware touchscreen, Apogee Control 2, and the app. |
| **Connection awareness** | The menubar icon greys out when the Quartet isn't connected (USB-level detection, instant plug/unplug) — and the menu header tells you why ("Quartet Not Connected" / "Glue Offline"). |

In bound mode the volume keys are never intercepted — macOS handles them
natively (whatever device is the current output). In classic mode the keys
only take over while the **Quartet is the selected output device**; otherwise
events pass through untouched (your MacBook speakers keep behaving normally).

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

**First launch only — grant Input Monitoring (required for the volume keys):**

1. The menu shows a warning: **"⚠️ Volume Keys Need Input Monitoring…"** — click it
2. In **System Settings → Privacy & Security → Input Monitoring**, enable **Quartet Buddy**
3. Within ~5 seconds the warning disappears — the keys are live. No relaunch needed.

> The build script signs the app with the **QuartetBuddy Developer**
> certificate (created in your keychain during setup). The grant is bound to
> that certificate, so it **survives every rebuild**. If the identity is
> missing, it falls back to ad-hoc signing and you'd need to re-grant after
> each rebuild.

**Launch at Login** is a menu toggle. Your choice is remembered, and if the
registration ever goes missing (app moved/renamed), the app re-registers
itself automatically on the next launch.

### Setup

- **Output target:** *Volume Keys Target →* Main Out / Headphones (or record a switch hotkey)
- **Talkback:** *Turn Talkback On* to test, then record the *Talkback Hotkey*
  and/or *MIDI Button → Learn…* (press a button on your keyboard)
- **MIDI mode:** *Toggle* (press = on/off) or *Momentary* (hold to talk)

## How it works

```
volume keys ──► macOS (native, untouched) ──► OS "Quartet" volume slider
                                                    ▲            │
           fader changes (echoes from Control 2, ───┘            │ slider moves
           the touchscreen) — enforce onto slider                ▼
                              ApogeeGlue IPC  ──►  ApogeeGlue daemon ──► Quartet
                              (TCP localhost)         ▲
switch/talkback hotkey ──► RegisterEventHotKey ──────┤
MIDI keyboard ──► CoreMIDI ("Quartet" source) ────────┘
```

The OS "Quartet" volume slider is display-only (the driver never applies it
to the audio), so `OSVolumeMirror` bridges it: slider moves are written to
the real fader through ApogeeGlue, and fader moves are copied back onto the
slider.

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
- **Volume keys do nothing** — check the menu icon: if the ⌨️ warning is back,
  Input Monitoring got switched off, or the app was rebuilt ad-hoc.
  Everything logs to `~/Library/Logs/QuartetBuddy.log` (menu: *Advanced →
  Open Debug Log…*) — every key event and write is recorded there.
- **Menu header shows "Glue Offline"** — ApogeeGlue isn't running (Apogee
  Control 2 not installed/running). The app auto-reconnects every 3 s; there's
  also a *Reconnect* menu item.
- **MIDI learn finds nothing** — the keyboard must be plugged into the
  Quartet's MIDI port (CoreMIDI source named "Quartet"); it won't see USB
  keyboards connected directly to the Mac.
- **Talkback does nothing audible** — the TalkbackHelper needs a valid
  source/destination configured in Apogee Control 2's Talkback settings.

## Notes & limitations

- The path-ids in `PathIds` were captured from live traffic for this device
  (`quartet1528B15CEE547FA`). They are deterministic, but if you use a
  *different* Quartet, run `tools/watch_ids.py` and update the table.
- An Apogee software update could change the protocol; the app shows the
  offline state and the debug log tells you where it broke. The protocol
  notes contain everything needed to re-crack it.
- This is an independent interoperability tool for your own hardware; it
  contains no Apogee code.
