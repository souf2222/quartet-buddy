# Quartet Buddy

A tiny menubar companion for the **Apogee Quartet** audio interface that
restores the system **volume keys** and adds **MIDI/hotkey Talkback triggers** —
working *with* Apogee Control 2 (which you keep for routing), not against it.

Built by reverse-engineering Apogee Control 2's IPC protocol
(see [`docs/protocol-notes.md`](docs/protocol-notes.md)).

## What it does

| Feature | How |
|---|---|
| **Volume keys work again** | macOS gives the Quartet no volume control (that's why the keys were dead). Quartet Buddy intercepts the media keys and drives the Quartet's real analog fader through ApogeeGlue — exactly what the fader in Apogee Control 2 does. |
| **Choose the output** | Menu → *Output for volume keys*: **Main Out** or **Headphones**. |
| **Mute key** | Toggles mute on the selected output. |
| **Talkback hotkey** | Menu → *Talkback hotkey* → press any ⌘/⌥/⌃ + key combo. System-wide. |
| **Talkback MIDI button** | Menu → *Talkback MIDI* → **Learn**, then press a button/note/CC on the keyboard plugged into the Quartet's MIDI port. Toggle or momentary mode. |
| **Live status** | The menubar icon shows the selected output's fader (16 segments) + mute + talkback state, synced in real time — turn the knob on the Quartet's touchscreen and the bar follows. |

The keys only intercept while the **Quartet is the selected output device**;
otherwise events pass through untouched (your MacBook speakers keep working
normally).

## Install & run

```bash
cd quartet-buddy/QuartetBuddy
./build.sh
open build/QuartetBuddy.app
```

On first volume-key press, macOS will ask to enable **Input Monitoring** for
Quartet Buddy — allow it (the menu also has a shortcut to the setting).
Because the app is ad-hoc signed, rebuilding it may re-trigger the prompt
once.

Requirements:
- Apogee Control 2 installed and running (ApogeeGlue daemon is what we talk to)
- Quartet connected (USB)

## How it works

```
volume keys ──► CGEventTap ──┐
hotkey ──────► RegisterEventHotKey ─┤
MIDI keyboard ─► CoreMIDI ("Quartet" source) ─┴─► Glue IPC ──► ApogeeGlue ──► Quartet
```

Glue IPC = TCP `localhost` + JUCE framing + Apogee ValueTreeSyncProtocol
(magic `F2B49E2C`, checksum-fold codec, `setProperty` records with 4-byte
path-ids — all documented in `docs/protocol-notes.md` and reimplemented in
`Sources/GlueProtocol.swift`). Verified read/write against the live daemon.

## Repo layout

```
docs/protocol-notes.md     complete wire protocol spec
docs/captures/             sample tree dump from the live device
tools/                     RE toolchain (capture analyzer, probes, id watchers)
QuartetBuddy/Sources/      the Swift app
```

## Notes & limitations

- The path-ids in `PathIds` were captured from live traffic for this device
  (`quartet1528B15CEE547FA`). They are deterministic (a path hash) — if you use
  a different Quartet, run `tools/watch_ids.py` and update the table.
- Apogee software updates could change the protocol; the app shows a red
  offline status if Glue disappears or changes ports.
- This is an independent interoperability tool; it contains no Apogee code.
