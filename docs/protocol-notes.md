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

## Notes

* Record size field = data length (excludes keybyte and chk).
* Meter records: keybyte + serial string + `00 00 00 00 00` + repeated
  float32 pairs (L/R per output; 0.0 = silent).
* Glue keeps per-connection state; multiple clients are fine (we ran as a 5th).
* writes are accepted from any connected client (flag=0).
