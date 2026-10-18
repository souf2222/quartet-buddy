# Quartet Buddy 🎛

A menubar companion for the **Apogee Quartet** audio interface, built by
reverse-engineering Apogee Control 2's IPC protocol
([`docs/protocol-notes.md`](docs/protocol-notes.md)).

It fixes what Apogee Control 2 breaks on modern macOS: because the Quartet
exposes no CoreAudio volume control, the **system volume keys go dead**.
Quartet Buddy makes them work again — and adds a few things Apogee never
offered. It talks to the ApogeeGlue daemon directly, so you keep Apogee
Control 2 installed (for routing) and everything stays in sync.

## Features

| Feature | Details |
|---|---|
| **Volume keys work again** | F11/F12 (volume up/down) drive the Quartet's real analog fader, exactly like the fader in Apogee Control 2. macOS-proportional: **100% ⇔ 0 dB, 0% ⇔ −64 dB**, 16 blocks, one block per key press (4 dB). |
| **⌥-fine steps** | Hold **⌥** while pressing volume for quarter-block steps (1 dB), just like macOS. |
| **Mute key** | F10 toggles mute on the selected output. |
| **Output selector** | Choose **Main Out** or **Headphones** for the volume keys — via the menu, or a **system-wide switch hotkey**. The menubar icon shows which one is active (Apogee logo = Main Out, headphones glyph = HP). |
| **Talkback hotkey** | Any ⌘/⌥/⌃-combo, recorded in-app. |
| **Talkback MIDI button** | Press a note/CC on the keyboard plugged into the Quartet's MIDI port — MIDI-learn captures it. Toggle or momentary mode. |
| **Live status** | Menubar tooltip + menu show both output levels in dB, mute, and talkback state — synced in real time with the hardware touchscreen, Apogee Control 2, and the app. |
| **Connection awareness** | The menubar icon greys out when the Quartet isn't connected (USB-level detection, instant plug/unplug) — and the menu header tells you why ("Quartet Not Connected" / "Glue Offline"). |

The keys only take over while the **Quartet is the selected output device**;
otherwise events pass through untouched (your MacBook speakers keep behaving
normally).

## Requirements

- macOS 13+ (developed on macOS 27)
- Apogee Control 2 installed (its ApogeeGlue daemon is what we talk to)
- Quartet connected over USB

## Install & first run

```bash
cd quartet-buddy/QuartetBuddy
./build.sh
open build/QuartetBuddy.app
```

**First launch only — grant Input Monitoring (required for the volume keys):**

1. The menu shows a warning: **"⚠️ Volume Keys Need Input Monitoring…"** — click it
2. In **System Settings → Privacy & Security → Input Monitoring**, enable **Quartet Buddy**
3. Within ~5 seconds the warning disappears — the keys are live. No relaunch needed.

> The build script signs the app with the **QuartetBuddy Developer**
> certificate (created in your keychain during setup). The grant is bound to
> that certificate, so it **survives every rebuild**. If the identity is
> missing, it falls back to ad-hoc signing and you'd need to re-grant after
> each rebuild.

### Setup

- **Output target:** *Volume Keys Target →* Main Out / Headphones (or record a switch hotkey)
- **Talkback:** *Turn Talkback On* to test, then record the *Talkback Hotkey*
  and/or *MIDI Button → Learn…* (press a button on your keyboard)
- **MIDI mode:** *Toggle* (press = on/off) or *Momentary* (hold to talk)

## How it works

```
volume keys ──► CGEventTap (NX_SYSDEFINED, listen-only) ─┐
switch/talkback hotkey ──► RegisterEventHotKey ───────────┤
MIDI keyboard ──► CoreMIDI ("Quartet" source) ───────────┤
                                                          ▼
                              ApogeeGlue IPC  ──►  ApogeeGlue daemon ──► Quartet
                              (TCP localhost)
```

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
