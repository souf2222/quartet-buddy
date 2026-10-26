# AU Insert

Real-time AU plugin processing on the Quartet's 4 stereo output pairs,
with per-pair routing.

## Architecture

```
all system audio (bound for the Quartet — default output unchanged)
   ↓  CATap — stereo tap on Quartet stream 0, EXCLUDES this process,
      muteBehavior = .muted
      → captured audio never reaches the Quartet's DAC (true insert);
        our own output passes through untouched (no feedback loop)
private aggregate device (master: Quartet, taps: [tap])
   ↓  one IOProc (InsertServer.cycle)
      4 stereo chains, one per output pair (1‑2 / 3‑4 / 5‑6 / 7‑8):
         source → AU plugin chain (or dry) → that pair's channels
```

- No virtual loopback driver, no default-device switching, no kexts.
  Uses the public Core Audio **process taps** API (macOS 14.2+).
- The macOS default output stays "Quartet", so the volume-keys/fader/mute
  bindings (`OSVolumeMirror`) are untouched.
- The tap excludes our own process (via
  `kAudioHardwarePropertyTranslatePIDToProcessObject`), so the processed
  output is not re-captured.

## Routing model

The Quartet presents macOS **one 8-channel stream** = 4 stereo pairs.
The tap captures the **full 8 channels**; pair i's *own* playback audio
is channels (2i, 2i+1) — a DAW addressing "Out 3‑4" lands exactly there.

Each pair picks a **Source** (control window):

- **Playback i–2** (default) — the pair passes through **its own**
  playback channels.
- **Playback X–Y** (mirror) — another pair's signal. For mirrors, a
  second menu section picks the **tap point on the SOURCE's chain**:
  - **Pre-FX** — the source's raw playback channels, before its
    processing and trim (independent correction per destination).
  - **Post-FX** — after the source's plug-in, but with its input trim
    divided back out (the source's FX without its level trim).
  - **Post-Trim** — the source's full rendered output, trim included
    (the destination inherits the processing, then may apply its own).
- **Silence**.

The stages refer to the selected source's chain — never the
destination's own FX and trim, which stay downstream of the tap.

### Trim (hardware on the line-out pairs)

The routing cards' **trim knobs write the QUARTET's firmware trim** —
`/dev/<serial>/hwout/hwoutN/trim`, live-verified Oct 26 2026
(protocol-notes.md, "Line-out trim"). `hwout2…7` are mono strips, so:

    Out 3‑4 → hwout2 + hwout3 · Out 5‑6 → hwout4 + hwout5 ·
    Out 7‑8 → hwout6 + hwout7

The firmware applies it at the DAC — **downstream of everything macOS
sends**, including the insert's own re-injection and the mirror taps.
Live-mapped card ↔ strip ↔ jack labels (Oct 26 2026):

| macOS card | Quartet strips | jacks |
|---|---|---|
| Out 1‑2 | `hwout0` "Main Out" (no trim — software) | main monitor pair |
| Out 3‑4 | "Analog Out 1/2" = `hwout2`+`hwout3` | line pair 1 |
| Out 5‑6 | "Analog Out 3/4" = `hwout4`+`hwout5` | line pair 2 |
| Out 7‑8 | "Analog Out 5/6" = `hwout6`+`hwout7` | line pair 3 |

(LABEL TRAP: the strips are named "Analog Out 1…6", offset from the macOS
card numbers by one pair. User-verified: monitoring there starts on
Out 7‑8 and never hears "Out 5‑6".)

Consequences:

- the tap stages never see (or need to work around) the destination's
  trim: on those pairs `trimFactors` stays 1, so Post-FX and Post-Trim
  are numerically identical and the written value rides the hardware;
- saved knob values are re-pushed to the unit on every glue reconnect
  (a power cycle may come back at 0);
- **Out 1‑2 is Main Out** — `hwout0` has no trim property (the main bus
  rides `gain`, owned by the OS fader binding), so pair 0's knob is
  still the old software trim applied in the capture chain.

Routing cycles resolve to silence, detected and logged main-side —
never in the audio thread. `resolveRoutes` computes each pair's route
(source pair + tap stage) and the render order (post-stage mirrors
render after their source); in the IO cycle every pair's input is a
slice of the deinterleaved tap or another pair's rendered output.

## Menu & windows

- **Menubar** (quick actions only): Control Volume target, live
  speaker/headphone levels, Mute Speakers/Headphones, Dim Speakers,
  Start/Stop Talkback, **Bypass All Plug-ins**, Outputs & Plug-ins…,
  Settings…, Quit.
- **Outputs window**: the routing cards in the control window — one
  strip per pair with the grouped source menu, the plug-in slot and the
  trim knob.
- **Settings window**: General (launch at login), Talkback (momentary),
  Shortcuts & MIDI (hotkey recording, MIDI learn), Audio (latency).

Per-pair persistence: `insertPair.N.source` (`mix`/`copy:j`/`off`),
`.plugin`, `.enabled`, `.stage` (`pre`/`post-fx`/`post-trim`; the old
`.mirror` `before`/`after` value migrates: before→pre, after→post-trim),
plus per-plug-in ClassInfo state. Global: `insertBypassAll`.

## Plugin hosting

- The plugin chain runs on `AVAudioEngine` in **manual rendering mode**,
  driven from the insert IOProc: `AVAudioSourceNode` (reads the tapped
  mix) → `AVAudioUnitEffect` → mixer → `renderOffline`.
- The Quartet's IO cycle is large (4096 frames at time of writing); the
  engine renders in 512-frame chunks and the chunks are assembled back
  into the 8-channel output stream.
- Plugin choice, bypass and plugin state (ClassInfo) persist in
  `UserDefaults` (`insertPair.N.plugin`, `.enabled`,
  `insertPluginState.*`). The ClassInfo is saved on stop, plugin swap,
  editor close and app quit, and restored when the plugin is
  instantiated — so a relaunch picks up exactly where it left off.

### macOS 27.0.1 quirks (live-tested Oct 2026)

- The classic C `AudioUnitRender` hosting path (formats +
  `kAudioUnitProperty_SetRenderCallback` on global scope) fails with
  `paramErr` (-50) for every AU — including Apple's own.
- `AVAudioEngine`'s `manualRenderingBlock` also returns -50 in both
  `.realtime` and `.offline` modes.
- Only `.offline` mode + the `renderOffline` ObjC path renders
  correctly. Hence the engine runs in offline manual mode, pulled from
  the IOProc. Not textbook-realtime-safe, but it works and v1 accepts
  it; re-evaluate on macOS updates.
- Bare CLI binaries can't enumerate third-party AUs (only bundled
  apps); the insert must be tested in-app.

## Latency

Insert overhead = one IO buffer (32 frames = 0.67 ms @ 48 kHz by
default, see Latency ▸). Plugins add their own processing latency
(ARC X's correction filter, a reverb's tail, etc.). For
input-monitoring with true zero latency, use the Quartet's hardware
mixer direct path — it never touches macOS or the insert.