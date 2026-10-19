# AU Insert (v1)

Real-time AU plugin processing on the Quartet's outputs.

## Architecture

```
all system audio (bound for the Quartet — default output unchanged)
   ↓  CATap — stereo tap on Quartet stream 0, EXCLUDES this process,
      muteBehavior = .muted
      → captured audio never reaches the Quartet's DAC (true insert);
        our own output passes through untouched (no feedback loop)
private aggregate device (master: Quartet, taps: [tap])
   ↓  one IOProc (InsertServer.cycle)
   ├─ outs 1‑2 (speakers): AU plugin chain (ARC X…) or bypass
   ├─ outs 3‑4 (HP):       dry passthrough
   └─ outs 5‑6 / 7‑8:      silence (future plugin slots)
```

- No virtual loopback driver, no default-device switching, no kexts.
  Uses the public Core Audio **process taps** API (macOS 14.2+).
- The macOS default output stays "Quartet", so the volume-keys/fader/mute
  bindings (`OSVolumeMirror`) are untouched.
- The tap excludes our own process (via
  `kAudioHardwarePropertyTranslatePIDToProcessObject`), so the processed
  output is not re-captured.

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

## Menu

`AU Insert` section: enable/disable, plugin picker (all installed
`aufx` effects), bypass, plugin UI window, and a routing status line.
Enable state persists across launches; the insert stops when the
Quartet unplugs and restarts on reconnect.

## Latency

Tap + aggregate + plugin. ARC X adds its own correction latency; the
dry HP path is offset from the speakers path by that amount (nobody
listens to both at once — fine for listening use).