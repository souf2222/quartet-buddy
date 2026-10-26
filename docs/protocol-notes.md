# Apogee Control 2 — Glue IPC protocol (fully reverse-engineered)

Complete wire protocol, verified end-to-end against the live ApogeeGlue daemon
(Apogee Control 2 v1.21.55, macOS 27). All offsets/formulas verified against
2754 captured frames + live write test.

## Architecture

```
Apogee Control 2.app ─┐
ApogeeTalkbackHelper ─┼── TCP localhost:<port> ──► ApogeeGlue (root LaunchDaemon)
ApogeeMessenger      ─┘   (JUCE InterprocessConnection)      │ USB control transfers ▼
QuartetBuddy (ours)   ─┘                                   Quartet firmware
```

* Audio runs on Apple's class-compliant driver (`usbaudiod`), NOT Apogee's.
* CoreAudio: the Quartet *does* expose master volume + mute controls (volume
  range −64…0 dB, square-law taper, settable) — but they are **display-only**:
  writes change no audio (verified with a live −64 dB dip test). macOS drives
  them natively (volume keys, F10, Control Center — no event tap, no Input
  Monitoring needed). Quartet Buddy binds volume both ways (OS slider →
  `setProperty(hwoutN.gain)` writes; hardware changes → slider writes).
  The OS **mute** is bound ONE way only (OS mute → hardware): writing the OS
  mute wedged the Apogee driver — every volume write started returning
  `kAudioHardwareUnspecifiedError` ('what') until the Quartet was
  power-cycled (live-tested incident, Oct 18 2026). `OSVolumeMirror.swift`
  never writes the OS mute.
* **Out-of-range gain writes crash the unit** (live incident, Oct 19 2026):
  a wedged driver made CoreAudio volume reads return **−255 dB** (a garbage
  sentinel, not a real level). The unvalidated slider-sync path echoed it
  into `setProperty(hwoutN.gain, −255)` → black screens, dead unit; the
  echo then looped −255 back through tree → slider → read every second
  (self-sustaining). Recovery = bootloader factory reset (hold controller
  knob, power-cycle, wait for the A/B/C touchpads to blink). Since then
  **every dB value crossing the OS↔Quartet boundary is range-validated**
  (`AppDelegate.isValidDB`, plus a guard in `OSVolumeMirror.enforce`):
  finite and within −64…0 dB (+1 slack) or it is logged `IGNORED bogus …`
  and dropped. A wedged driver can only produce log noise now.
* ApogeeGlue owns device state as a JUCE ValueTree and applies changes to hardware.

## Transport

TCP to `localhost`, first free port from the shared table
(client scans with `connectToSocket("localhost", table[i++ % 8])`, ~10 ms retry):

```cpp
static const uint32_t ports[8] = { 53435, 61367, 4677, 24110, 36218, 18140, 6414, 0 };
```

## Layer 1 — JUCE InterprocessConnection frame

```
uint32 LE  magic = 0xF2B49E2C          (bytes: 2C 9E B4 F2)
uint32 LE  payload_length
[payload_length bytes]
```

(Apogee vendored JUCE hardcodes the magic in the InterprocessConnection ctor:
`mov x9, #-0x61d4 ; movk x9, #0xf2b4, lsl #16` → LE store `2C 9E B4 F2`.)

## Layer 2 — Apogee::ValueTreeSyncProtocol record (the payload)

```
byte0   = type (bits 0-4) | flag (bit 5) | sizemask (bits 6-7)
size    = uint LE, 1/2/4 bytes per sizemask: 0x00→1B, 0x40→2B, 0x80→4B
keybyte = 1 byte  (fold-state after byte0+sizefield)
data    = `size` bytes  (message content, PLAINTEXT)
chk     = 1 byte  (fold-state after byte0+sizefield+keybyte+data)
```

Message types (from Decoder::pushData dispatch table @ 0x1000e90f0):

| type | name | data content |
|---|---|---|
| 1 | getEntireTree (hello) | empty (size=0, flag=1) |
| 2 | setTree | [string path][gzip'd JUCE ValueTree binary stream] |
| 3 | setProperty | [var-tag][4-byte path-id][raw value] |
| 4 | deleteItem | [string path] |
| 5 | ? | |
| 6 | setEntireTree | [gzip'd JUCE ValueTree binary stream] |
| 7 | Command | [string] |
| 8 | meterData | [string deviceSerial][padding][float32 pairs...] (flag=1) |
| 9 | setIndexedPaths | [string root][zlib'd int→path map] |
| 10 | treeChildOrderChanged | |

### The checksum fold (verified 2754/2754 frames)

```
F(x):  t  = (x << 9) & 0xFFFFFFFF
       if (int8)x < 0:        t ^= 0x700
       repeat 6 times:
           prev = (int16)t
           t = (t << 1) & 0xFFFFFFFF
           if prev < 0:       t ^= 0x700
       u  = t >> 7            (logical)
       if (int16)t < 0:       u ^= 7
       return u & 0xFF

checksum(buf): key = 0; for b in buf: key = F(b ^ key); return key

record layout uses:
  keybyte = fold(byte0 + sizefield)
  chk     = fold(byte0 + sizefield + keybyte + data)
```

### Hello (client → Glue, first message after TCP connect)

```
record: byte0=0x21 (type 1, flag 1, mask 0), size=0x00, keybyte=fold(21 00)=0xBB, chk=0x00
wire:   2C 9E B4 F2 | 04 00 00 00 | 21 00 BB 00
```
Glue responds with: type 6 (setEntireTree), type 9 (setIndexedPaths),
then a type 8 meter stream every ~50 ms.

### setProperty (write a value)

```
data = [var-tag][path-id 4 bytes LE][value]
var-tags: 1=int32(4B) 2=int64(8B) 3=bool(1B) 4=double(8B) 5=string(NUL-term)
flag = 0 for app-originated property writes
```
Verified live: `setProperty(hwout0.gain = -56.5)` → tree + hardware updated.

### setEntireTree / setTree payload

zlib stream (header `78 5E`/`78 DA`) containing a JUCE ValueTree binary stream:

```
tree:   string type; cint numProps; (string name; var value)×numProps;
        cint numChildren; tree×numChildren
var:    cint totalLen; byte marker; data
        markers: 1=int(4B LE) 6=int64(8B LE) 2=true 3=false 4=double(8B LE)
                 5=string(len-1 bytes incl NUL) 8=binary 7=array 9=undefined
cint (JUCE compressed int): byte0 = (nbytes | 0x80 if negative);
                            then nbytes little-endian magnitude
string (writeString): UTF-8 bytes + NUL (no length prefix)
```

## Live tree structure (partial)

```
root
├─ dev/quartet1528B15CEE547FA          (device serial)
│   ├─ hwout/hwout0 "Main Out": gain(dB), dim, mute, sum, mainOutputFormat, activeSpeakerSet
│   ├─ hwout/hwout1 "HP":        gain, dim, mute, sum, routeSource
│   ├─ hwin/hwin0..11, swout/playback0..3, mixers/mixerN/channels/...
├─ Apps
│   ├─ ApogeeGlue/{Logging, ApogeeDevices}
│   ├─ ApogeeMessenger/{Logging, messageButtons}
│   └─ Apogee Talkback helper/Talkback: talkbackOn, selectedTalkbackSourceDevice/Channel,
│        selectedTalkbackDestinationDevice/Channel, talkbackSources/{...}
```

## Path-ids (descriptor hash — CRACKED)

**The path-id is the Java string hash (`h = h·31 + UTF-8 byte`, 32-bit
wrapping) of the property's slash path from the tree root, sent as the
32-bit result little-endian:**

```
device-scoped:  /dev/<serial>/<node>/<node>/…/<property>
app-scoped:     /Apps/Apogee Talkback helper/Talkback/<property>
```

Examples (all verified live):

| path | id (wire bytes) |
|---|---|
| `/dev/quartet1528B15CEE547FA/hwout/hwout0/gain` | `c5 a2 bd b5` |
| `/dev/quartet1528B15CEE547FA/hwin/hwin0/micSettings/PreModelQuartet/gain` | `f1 e0 2c b3` |
| `/dev/quartet1528B15CEE547FA/hwin/hwin1/micSettings/phantom` | `83 ed f9 6c` |
| `/Apps/Apogee Talkback helper/Talkback/talkbackOn` | `8f 0a 6a 00` |

Cracked offline from 22 live-captured pairs across two physical units
(`tools/crack_id_hash.py` — 1008 path templates × 31 hash functions, only
java31 over `/dev/<serial>/…` little-endian matched all 22), then
live-verified by writing a never-captured id
(`/dev/<serial>/hwin/hwin2/softLimit` → `2d 86 37 ce`) and watching the
tree change. Consequences:

* **Every id is computable from the serial** (which the tree gives us) —
  no capture wizard, no per-unit tables, nothing. Any Quartet works
  out of the box (`PathIds.computedTable(serial:)` in the app).
* The ids are independent hashes (no derivable relation between inputs
  1-4 — checked: no constant XOR/sum, no shared bytes), so this formula
  is the ONLY shortcut.
* Curious structure leak that guided the crack: per unit, `hwoutN.gain`
  and `hwoutN.mute` share their last wire byte (unit A: `b5`/`b7`, unit
  B: `1d`/`1f`, differing by exactly 2 per output index), and the
  cross-unit XOR of same-path ids ends in `a8` — weak low-byte mixing of
  the java31 hash over the shared path suffixes.

## analogRefLevel values (Quartet inputs — verified live)

| value | meaning |
|---|---|
| 1 | Mic (XLR, preamp, micSettings.gain + phantom apply) |
| 2 | +4 dBu (line, no preamp gain) |
| 3 | −10 dBV (line, no preamp gain) |
| 4 | Instrument (¼", preamp, instSettings.gain applies) |

Switching a line level (2/3) auto-disables phantom. Mic↔Instrument
selection also swaps which PreModelQuartet gain the hardware applies.

## Device sample rate (WRITABLE via Glue — live-verified Oct 21 2026)

The device node itself carries a `samplerate` property (JUCE double):

```
<quartet1528B15CEE547FA … samplerate="44100.0" …>
```

* path-id: java31 hash of `/dev/<serial>/samplerate`, LE
  (this unit: `32f2cf89`)
* write: `setProperty` (type 3, flag 0), var-tag `4` (double), 8-byte LE value.
* Glue echoes the setProperty back, updates its tree, **and applies the new
  clock to the Quartet hardware** — live test `tools/sample_rate_write.py`:
  wrote 48000 over Glue, tree flipped 44100→48000 and CoreAudio's
  `Current SampleRate` followed to 48000 (verified via system_profiler).
  Restore to the previous rate works identically.
* Supported rates come from CoreAudio
  (`kAudioDevicePropertyAvailableNominalSampleRanges`) — the tree does not
  list them.
* Apogee Control 2 exposes no sample-rate UI, but the property is a fully
  functional device-side write, unlike the display-only CoreAudio master
  volume.

## Notes

* Record size field = data length (excludes keybyte and chk).
* Meter records: keybyte + serial string + `00 00 00 00 00` + repeated
  float32 pairs (L/R per output; 0.0 = silent).
* Glue keeps per-connection state; multiple clients are fine (we ran as a 5th).
* writes are accepted from any connected client (flag=0).

## Verified writes (batch — live-tested Oct 25 2026, Quartet connected)

All go through plain `setProperty` (type 3, flag 0). Serendipity file:
`tools/prop_probe.py` runs each one; `tools/watch_features.py` observes the
stream while the unit's own UI is driven.

### var-tag taxonomy (setProperty value encodings)

| tag | payload | notes |
|---|---|---|
| 1 | int32 LE | **the universally applied numeric write** |
| 4 | double LE | sample rate, preamp gains |
| 5 | NUL-terminated UTF-8 | string props (`name` etc.) |
| 3 | ONE byte, **1 = true / 0 = false** | bool-typed props |

⚠ bool gotcha: tag `3`'s value byte is a raw 1/0 — NOT the JUCE var
bool-markers 2/3. Glue treats any nonzero byte as true (probe initially
sent markers and "false" writes kept properties true). The app's Swift
`setBool` was always correct.

Glue does not echo setProperty back to the WRITER's socket (other clients
get the echo; we see our own writes only via tree re-reads).

### Applied by hardware (verified end-to-end)

| write | path | payload |
|---|---|---|
| line-out reference level | `/dev/<serial>/hwout/hwout2..7/analogRefLevel` | int32 2 (+4 dBu) / 3 (−10 dBV) |
| input rename | `/dev/<serial>/hwin/hwinN/name` | string ("Kick" ↔ "Analog IN 1", round-trip verified) |
| touchscreen lock | `/dev/<serial>/lockHomeScreen` | bool 1/0 — **user-confirmed the touchscreen locks/unlocks** |
| meter peak hold | `/dev/<serial>/peakHold` | bool 1/0 — user-confirmed holds release |
| meter clip hold | `/dev/<serial>/overHold` | bool 1/0 — user-confirmed |
| talkback source | `/Apps/Apogee Talkback helper/Talkback/selectedTalkbackSourceDevice` (+ `…Channel`) | string + int32 |

Accepted but NOT hardware-visible:

* `dev/identify` — consumes every encoding (bool/int/flag1/string), the
  tree's value even follows the tag, but **the front panel never blinks**.
  Type-7 `Command` strings (`"identify"`, `"Identify"`, `"identify=1"`,
  `"blink"`, `"identify 1"`) all inert. Front-panel-only mirror, like the
  OS master volume. QuartetBuddy therefore ships no Identify UI.
* `dev/preferredBufferSize` — tree accepts and persists (int/string),
  but CoreAudio's `kAudioDevicePropertyBufferFrameSize` never follows —
  verified across a USB replug (preference 160 latched, HAL stayed 512).
  DEAD for a buffer selector; a real selector writes CoreAudio directly
  (full 15…4096 range — verified write + read-back).

### Input ganging (hwinN.group)

* Ganging two inputs on the touchscreen sets BOTH members' `group` bit
  (hwin0.group = hwin1.group = True; bool-typed). Anyone can write these
  bits (bool 1/0 verified).
* BUT the firmware does NOT mirror externally written preamp gains even
  when ganged — live test: hwin0 → 30.5 dB while its ganged partner hwin1
  stayed at 0.5 dB. **Ganging is enforced by the touchscreen's UI, not
  the DSP** — an app must mirror the gain write itself (QuartetBuddy's
  Link toggles do: pair members' group bits are set together and the
  ACTIVE-mode gain is written to both, Mic/Instrument matched only).

### Front-panel touchpad assignments (dev/appState/actionButtons) — DECODED Oct 26 2026

* Pad presses themselves produce **no glue traffic** — but assignment
  changes DO: setProperty echo (int32) + tree update on the pad's
  `actionButton` property. Path:
  `/dev/<serial>/appState/actionButtons/<Touchpad_A|Touchpad_B|Touchpad_C|Encoder_Push>/actionButton`
  (ids re-derived with tools/prop_probe.py's java31 hash: c68d9cb1 /
  65577a93 / 04215875 / 1fa7bebf for this unit).
* **Full enum, captured by cycling Apogee Control 2's dropdown while
  recording** (order = AC2's list; `(group << 16) | target` where
  target 2/3/4 = Speaker/Headphone/All Outputs):
  Pads A/B/C accept ALL 15:
  `0x20002 Mute−Speaker · 0x20003 Mute−Headphone · 0x20004 Mute−All ·
   0x30002 Dim−Speaker · 0x30003 Dim−Headphone · 0x30004 Dim−All ·
   0x40002 SumMono−Speaker · 0x40003 SumMono−Headphone · 0x40004 SumMono−All ·
   0x5000B Toggle−Mute Speaker/HP · 0x5000C Toggle−Speaker Set 1/2 ·
   0x60001 Clear Meters · 0x70005/6/7 Engage Speaker Set 1/2/3`
* **Encoder Push has a shorter menu in AC2** (Mute ▸3 + Toggle ▸ Mute
  Speaker/HP). Writing an out-of-menu value to the encoder left its
  action at 0x0 (inert push — verified); a valid value applied and the
  push followed. QuartetBuddy's UI therefore offers the pads all 15 and
  the encoder only its 4.
* External write round-trip: setProperty int32 → the pad performs the
  new action immediately (user-verified: Dim All, Mute Headphone).
  Factory (round-1 baseline): A=0x20002 · B=0x30002 · C=0x40004 ·
  Encoder=0x5000B.

### HP routeSource (hwout1)

* 402653190 while switching the touchscreen's HP source produced no tree
  change and no traffic — semantics unverified; no UI shipped.

### Line-out trim (hwout2..7/trim) — LIVE-VERIFIED Oct 26 2026

* `hwout2..7` each carry a `trim` double (tree baseline `-0.0`; Main Out
  and HP have NO trim property — they ride on `gain` alone).
* **hwout2..7 are MONO channel strips** ("Analog Out 1"…"Analog Out 6",
  mixerChannel 13…18), so a stereo line pair is two separate nodes:
  trimming a pair means writing BOTH nodes (hwout2+hwout3 = Analog 1+2).
* path-id: java31 of `/dev/<serial>/hwout/hwoutN/trim` (this unit:
  hwout2 `00f7bb20`), write type 3 flag 0, var-tag 4 (double).
* **The firmware applies it to the DAC output** — user-confirmed audible
  pulsing at exactly the −12 dB / 5 s write pattern, on the written
  channel only (output 1 pulsed for hwout2; hwout2+hwout3 pulsed
  output 1 AND 2). Not a tree-only cosmetic copy.
* Glue accepts wide values (±24 dB tested, no clamp observed — range
  limit unknown; the win was likely larger ranges, so validation should
  stay conservative until an upper bound is proven).
* Glue does NOT echo trim writes back to other clients (unlike gain /
  analogRefLevel writes) — it's a silent, low-level copy parameter.
* AC2 exposes no trim UI; the touchscreen's output trim never influenced
  audio (user-reported) — the property is only reachable by protocol.
* Probe: `tools/trim_probe.py` (write/read/restore), A/B pulses during
  the session with `trim_ab.py`-style inline writes. Baseline restored
  to 0.0 after every test.

