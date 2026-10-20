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

Each pair picks a **Source** (Outputs & Plug-ins window):

- **Playback i–2** (default) — the pair passes through **its own**
  playback channels.
- **Mirror Out X–Y** — that pair's signal. Mirror point, per pair:
  **Before Source Plug-in** (raw playback channels — independent
  correction per destination) or **After Source Plug-in** (the source's
  processed output — the destination inherits its processing, then may
  apply its own plug-in).
- **Silence**.

Routing cycles resolve to silence, detected and logged main-side —
never in the audio thread. `resolveRoutes` computes each pair's route
(source pair + pre/post) and the render order (post-mirrors render
after their source); in the IO cycle every pair's input is a slice of
the deinterleaved tap or another pair's rendered output.

## Menu & windows

- **Menubar** (quick actions only): Control Volume target, live
  speaker/headphone levels, Mute Speakers/Headphones, Dim Speakers,
  Start/Stop Talkback, **Bypass All Plug-ins**, Outputs & Plug-ins…,
  Settings…, Quit.
- **Outputs & Plug-ins window**: one row per pair
  (Audio Source / Plug-in / Enabled) with a details pane —
  route summary, mirror point, Open Editor…, signal flow
  ("Playback 1–2 → ARC X → Out 3‑4" — double processing is visible).
- **Settings window**: General (launch at login), Talkback (momentary),
  Shortcuts & MIDI (hotkey recording, MIDI learn), Audio (latency).

Per-pair persistence: `insertPair.N.source` (`mix`/`copy:j`/`off`),
`.plugin`, `.enabled`, `.mirror` (`before`/`after`), plus per-plug-in
ClassInfo state. Global: `insertBypassAll`.

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