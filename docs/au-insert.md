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

The Quartet presents **one 8-channel stream** to macOS = 4 stereo pairs.
The tap captures the **full 8 channels**; each pair i's *own* system
audio is channels (2i, 2i+1) — i.e. whatever apps send to that pair
(a DAW addressing "Out 3‑4" lands exactly there).

Each pair picks a **Source**:

- **No routing** (default) — the pair passes through *its own* system
  channels (pair i ← channels 2i, 2i+1). A DAW outputting to Out 3‑4
  comes out of Out 3‑4, plugin and all.
- **Out X‑Y** — that pair's channels **pre-plugin** (the raw system
  audio of pair X‑Y). Cross-pair copies resolve to the *raw* channels,
  never another pair's processed output.
- **Off (silent)** — the pair outputs silence.

Routing cycles (A copies B, B copies A) resolve to Off, detected and
logged on the main thread — never in the audio thread. Resolution
(`resolveInputs`) runs main-side; in the IO cycle every pair's input is
just a slice of the deinterleaved tap, so the 4 plugin engines render
fully independently.

Routing cycles (A copies B, B copies A) resolve to Off, detected and
logged on the main thread — never in the audio thread. Chains are
resolved main-side (`resolveInputs`); in the IO cycle every pair's
input is simply the dry mix or silence, so the 4 plugin engines render
fully independently.

## Menu

`AU Insert` section:

- **Insert On/Off** — master toggle (persisted; `insertEnabled`)
- **Latency ▸** — IO buffer size 32…512 frames (32 = 0.67 ms @ 48 kHz;
  persisted)
- **⚠️ Tap silent** — warning + link to System Settings when macOS
  denies the System Audio Recording permission (it silences taps
  instead of failing them)
- **One submenu per stereo pair**, e.g.
  `Out 1‑2 · Main — System mix → ARC X`:
  - live status line
  - **Source ▸** (pairs 2‑4 only — Out 1‑2 is fixed)
  - **Plugin ▸** — None (dry) + every installed AU effect
  - **Bypass Plugin** / **Open Plugin UI…** (when a plugin is set)

Per-pair persistence: `insertPair.N.source`, `.plugin`, `.bypass`,
and the plugin's ClassInfo state per pair.

## Plugin hosting

- The plugin chain runs on `AVAudioEngine` in **manual rendering mode**,
  driven from the insert IOProc: `AVAudioSourceNode` (reads the tapped
  mix) → `AVAudioUnitEffect` → mixer → `renderOffline`.
- The Quartet's IO cycle is large (4096 frames at time of writing); the
  engine renders in 512-frame chunks and the chunks are assembled back
  into the 8-channel output stream.
- Plugin choice, bypass and plugin state (ClassInfo) persist in
  `UserDefaults` (`insertPluginDesc`, `insertPluginBypass`,
  `insertPluginState.*`).

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