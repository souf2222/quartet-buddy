# Standalone Quartet Buddy — direct-USB plan

Goal: Quartet Buddy works with **only itself installed** — no Apogee Control 2,
no ApogeeGlue daemon, no Apogee kext. Bluetooth-style nothing; the app talks to
the Quartet directly over USB from user space.

Status: **research phase** (card currently unplugged). Nothing here is wired
into the app yet.

---

## Intel gathered (2026‑11‑07, from the binaries on this Mac — no card needed)

### The kernel kext is a red herring
`/Library/Extensions/QuartetUSBOverideDriver.kext` contains **no executable at
all** — only `_CodeSignature` + `Info.plist`. Every IOKit personality uses
`IOClass = AppleUSBMergeNub`: Apple's own mechanism. It only injects:

* name strings (`USB Product Name` / `USB Interface Name` → "Quartet"),
* per-sample-rate latency dicts (IOAudioEngine{Input,Output}SampleLatency).

The audio I/O itself runs on **Apple's class-compliant `usbaudiod`** (already
documented in `protocol-notes.md`). When the kext is gone we keep working I/O;
we may lose the custom names/latency polish. Nothing to reverse engineer, and
a DriverKit DEXT would be the wrong tool (can't displace AppleUSBAudio for a
class-compliant device anyway).

### ApogeeGlue talks to the device over CoreHID (user space!)
`nm -u ApogeeGlue` → only `IOHIDDeviceOpen`, `IOHIDDeviceSetReport`,
`IOHIDDeviceRegisterInputReportCallback`, `IOHIDManagerCreate/SetDeviceMatching/CopyDevices`,
plus `IOHIDDeviceGetService/GetProperty` etc.

> **UPDATE Nov 7 2026 (live device connected): the Quartet exposes NO HID
> interface.** `ioreg -r -n "Quartet@01110000"` shows the real interface set:
>
> | # | class/subclass | meaning | endpoints |
> |---|---|---|---|
> | 0 | 1/1 | UAC **Audio Control** (interrupt status EP) | 1 |
> | 1 | 1/2 | UAC **Audio Streaming Out** | 2 |
> | 2 | 1/2 | UAC **Audio Streaming In** | 1 |
> | 3 | 1/1 | UAC Audio Control (second, no EP) | 0 |
> | 4 | 1/3 | UAC **MIDI Streaming** | 2 |
> | 5 | **0xFF/0xF0** | **vendor "iAP Interface"** | 3 |
> | 6 | **0xFE/1** | **DFU** ("DFU Quartet") | 0 |
>
> `ApogeeGlue` holds an **`AppleUSBHostDeviceUserClient` at DEVICE level** (also
> visible: `MIDIServer` user client for the MIDI port). So the control channel
> is (as our protocol notes say) **USB control transfers on endpoint 0
> (device-level user client) and/or the vendor iAP interface's 3 endpoints**
> — none of which needs the HID path. The CoreHID code in the glue binary is
> for OTHER Apogee products (the `apogeeRemotes` HID remotes / One/Duet) — not
> this box.
>
> Consequences: our `hid_probe` (CoreHID matching VID/PID) correctly finds
> nothing for the Quartet. The standalone transport has to speak device-level
> control transfers — achievable user-space, but the access story for an
> unentitled app via `AppleUSBHostDeviceUserClient` needs verification (the
> device matrix advertises `IOServiceDEXTEntitlements =
> com.apple.developer.driverkit.transport.usb` for DEXT providers; a plain app
> opening the device-level user client is the piece to test). Plan-B capture
> = Glue's own `logMessageRX/TX` logging (below) + interface-5 bulk traffic.

That's the best possible outcome:

* plain HID reports (input + output + feature), sniffable and replayable,
* non-seize opens (`kIOHIDOptionsTypeNone`) **coexist with other clients** —
  we can listen passively while Glue is still running,
* CoreHID needs **no entitlement, no TCC grant, no elevated privileges** — an
  unsigned local build can already do exactly what the daemon does.

Symbol map of the device side of Glue (mangled names → meaning):

| Symbol | Meaning |
|---|---|
| `Apogee::USBDevice` / `USBDeviceMacOSE` / `USBDeviceManagerMacOSE` | their USB abstraction (CoreHID on top) |
| `QuartetGlueServerDevice::install{Input,Set,Output,Monitor}Handlers` | the per-property ValueTree→packet write handlers |
| `QuartetGlueServerDevice::update{InputGain,InputType,Monitor{Dim,Sum,Gain,Mute},InputPhantom}` | concrete writes (our expected packet kinds) |
| `SIO2TGlueServerDevice::processPacket(CommandPacket)` | device→host message processor ("SIO2" = the PSoC control channel protocol) |
| `ApogeeRemoteGlueServerDevice::hidMessageArrived` / `processMessageFromDevice(ApogeeRemoteUSBPacket)` | HID message = `ApogeeRemoteUSBPacket` |
| `PSoCInterface` | the Quartet's controller MCU (touchscreen brain) is a Cypress PSoC — this is the far end of our protocol |
| `SideEffectFactory` / `QuartetSideEffects` | glue's translation layer ValueTree change → device packets |

### Glue has a built-in packet logger — our sniffer
The daemon's own logging is a ValueTree child (`Logging`) with entries
`logCommand`, `logGeneric`, **`logMessageRX`**, **`logMessageTX`**, `logLevel`,
`logMethod` … and it writes to
`/Library/Preferences/Apogee/Glue/Apogee_Glue.log`.

**We can flip those flags through the existing Quartet Buddy glue bridge** and
the daemon logs its own USB traffic for us. No hardware USB sniffer, no USBM
VM, no Frida needed. (Verify the log shows report hex rather than just method
names when the card is in; fallback = passive CoreHID listener.)

### State seed exists
Glue persists each device's full ValueTree as XML in
`/Library/Application Support/Apogee/Settings/quartet<serial>.xml`. We can
adopt that format (plus our own preferences) to boot standalone without glue.

### Known hazards to carry over
* OS mute write wedges the driver (`protocol-notes.md`) — keep the one-way rule.
* Out-of-range dB writes crash the unit — keep `isValidDB` guards at the new
  transport boundary too.

---

## Architecture

```
Quartet Buddy (single app)
├── GlueProtocol.swift      unchanged ValueTree/codec layers
├── Transport (new enum)
│     .glueDaemon           today's TCP IPC   (compat mode, still supported)
│     .directUSB            (target mode) CoreHID reports in-process
└── QuartetHIDDevice (new)  io: VID 0x0C60 PID 0x0014 → IOHIDManager
                            read InputReports → parse → ValueTree updates
                            report builder ← same commands glue sends
```

Required when glue is absent (features to re-home):

| Feature | Without glue |
|---|---|
| Device state tree | seed from our preferences / saved XML; live input via HID |
| Talkback helper | already app-side (CoreAudio), fine |
| `ApogeeMessenger` | only used by Control 2 — we already skip it |
| Audio | Apple class driver, untouched |
| `usbaudiod` display volume/mute quirk | **re-verify without Apogee kext/daemon** — behavior of the OS slider may differ when no Apogee stack runs; the bridge adapts via the same two-way binding (it only writes the real fader + mirrors) |

## Phases

1. ✅ Static RE of ApogeeGlue (this doc).
2. **Probe pass (needs the card)** — `tools/hid_probe.swift`:
   * `list` — enumerate VID/PID 0x0C60:0x0014 HID devices, dump properties +
     registry interface descriptors (usage pages, report sizes, endpoints).
   * `monitor` — passive input-report tap with timestamps → JSONL at
     `tools/captures/hid-*.jsonl` for `capture_analyzer.py`.
   * Optional `send <hex>` for controlled write experiments (manual use).
3. **Decode pass** — card connected + Glue running, passive co-listen:
   * touchscreen/encoder actions → inbound packets → action→packet table;
   * flip glue `Logging.logMessageTX/RX` → outbound↔inbound correlation,
     map against known ValueTree paths (we already have write ids).
4. **Transport swap** — implement `QuartetHIDDevice` + `.directUSB`, keep
   `.glueDaemon` fallback; ByteStream of SIO2T CommandPacket framing goes to
   its own file + section in `protocol-notes.md`.
5. **Standalone polish** — boot tree without daemon, remove "Glue Offline"
   states, re-verify OS volume behavior with no Apogee software installed,
   Document install = just Quartet Buddy.

## Risks

* Report traffic alone may not carry the *full* tree; glue might also use
  control transfers/GetReport on open (watch probe/`protocol-notes` updates).
* Firmware update flow (`Firmware/dfu-util`) — never send DFU packets; probe
  stays read-only except explicit `send`.
* Apogee could change protocol/USB endpoints in a Quartet firmware update —
  same mitigation as the glue protocol (re-crack tooling in `tools/`).

---

## Live session intel (Nov 7 2026 — device connected)

### Logging attach — mapped, then ruled out
* The daemon persists its `/Apps/ApogeeGlue` subtree to
  **`/Library/Preferences/com.apogee.glueserver.xml`** (root-owned, rewritten by
  the daemon on its own events; `persisted pid="523" version="70964"`). Backup
  + patch + `pkill -9` (launchd `KeepAlive` restarts) is a working edit path —
  password flow via `osascript -e 'do shell script "… && pkill -9 -f
  ApogeeGlue.app" with administrator privileges'` pops the macOS auth dialog.
  Restored afterwards; snapshot kept at `/tmp/glueserver-backup.xml`.
* The `Logging` subtree is READ-ONLY over glue IPC: setProperty writes (tag 1
  int AND tag 5 string) to `…/logMessage{RX,TX}/{logLevel,logMethod}` are
  accepted then dropped — tree/XML unchanged.
* Patching XML to logLevel 2/3/4 + logMethod 0/1/2 and bouncing the daemon
  (three full passes) produced **zero USB packet hex** in
  `/Library/Preferences/Apogee/Glue/Apogee_Glue.log` and empty
  `/tmp/com.apogeedigital.apogeeglue.err`. `logMessageRX/TX` therefore gates
  other products' traffic (probably the HID ApogeeRemotes) or needs a
  destination this config surface can't change. **Logging attach is parked** —
  not the RX/TX oracle we hoped for on the Quartet.
* What DID work:
  * Vector writes through the normal glue bridge are healthy after daemon
    restart (`preferredBufferSize` 128→256→128 verified; transient "no echo"
    on `identify` right after restart, self-cleared; tag-3 single-byte bool +
    tag-1 int32 both accepted for `identify` afterwards).
  * Daemon stdout (`/tmp/com.apogeedigital.apogeeglue.out`) logs
    `key not found for index: <int32 path-id>` — it maps received property ids
    into internal indexes; useful behavior note for future probing (invalid
    writes are logged, not crashed).
  * Apple unified log carries nothing for the daemon's USB traffic
    (Apple redacts it), and the binary is stripped (nm shows imports only —
    class names exist only as RTTI strings). Disassembly must anchor on those
    RTTI strings + call sites of imported IOKit/CoreFoundation APIs
    (`IOServiceOpen`, `IOConnectCall*…`).

### Post-restart sanity
* SIGKILL + launchd restart is safe and repeatable; Quartet Buddy reconnects
  (3 s cadence), the tree resyncs, writes verify again.
* Full stock restore verified (logGeneric 1/1 · TX/RX/cmd 1/0).

### Next (phase 11.4 revised)
The packet oracle is the binary itself: a focused disassembly pass over
`QuartetGlueServerDevice::update*` / `SIO2TGlueServerDevice::processPacket` /
`USBDeviceMacOSE` (anchored via the RTTI strings near
`"quartet"`/`"ApogeeRemoteUSBPacket"`), ending in:
1. the wire frame for at least ONE small reversible write (`identify`),
2. the transfer mechanism (endpoint-0 control transfer vs interface-5 iAP
   bulk) and the user-client call that performs it,
3. an unentitled-app feasibility check opening `AppleUSBHostDeviceUserClient`
   the same way.
Then live-probe: replicate the `identify` packet from our own client and watch
the front panel blink.

---

## Phase 11.5 results (Nov 7 2026 — disassembly oracle, arm64 slice)

Slice: `/tmp/glue_arm64` (`lipo -thin arm64`). Tool: `tools/gd.py` (otool-based
section map + capstone; `adrp` operands are **absolute**, fixed after much pain).
The binary is stripped but stuffed with C++ RTTI names, which anchor everything.

### Transport solved — plain IOKit USB, no proprietary kernel bits
`USBDeviceMacOS` (RTTI `N6Apogee14USBDeviceMacOSE`, template base
`Apogee::USBDevice<unsigned char*, unsigned long>`) wraps Apple's classic
IOUSBLib COM interface:

* ctor: `IOServiceMatching` → `IOCreatePlugInInterfaceForService(svc,
  kIOUSBDeviceUserClientTypeID = 9DC7B780-9EC0-11D4-A54F-000A27052861,
  kIOCFPlugInInterfaceID)` → enumerate interfaces (`IOIteratorNext`) →
  `IOCreatePlugInInterfaceForService(iface,
  kIOUSBInterfaceUserClientTypeID = 2D9786C6-9EF3-11D4-AD51-000A27052861, …)`
  → `QueryInterface(kIOUSBInterfaceInterfaceID100 =
  73C97AE8-9EF3-11D4-B1D0-000A27052861)` → **stored at USBDeviceMacOS+0x90**
  → `USBInterfaceOpen` (vtbl+0x40) → `GetNumEndpoints` (vtbl+0x98, byte out).
* read helper (vtable slot 4): `[if vtbl+0xf8]` = **ReadPipe(iface, pipeRef,
  buf, &len)** — pipeRef byte at +0x98, len passed by value-in/value-out.
* write helper (vtable slot 5, `0x100036c20`): `[if vtbl+0x140]` =
  **WritePipeTO(iface, pipeRef, buf, len, noDataTO=500 ms, completionTO=800 ms)**
  — pipeRef byte at +0xa4.
* vtable offsets use the **4-slot IUNKNOWN_C_GUTS** (reserved + QI + AddRef +
  Release); with 3 the offsets look shifted — that was the week-long bug.

**Conclusion: Quartet control = ordinary bulk/interrupt pipe writes on the
UAC control interface.** `.directUSB` can use `IOUSBHostInterface` (modern)
or the same IOUSBLib dance — no Apogee kernel help needed. This kills
requirement 11.3's unknown.

### Property → command layer decoded (QuartetGlueServerDevice)
Class chain: `QuartetGlueServerDevice : LegacySimpleUSBGlueServerDevice`;
`SIO2TGlueServerDevice : ThunderboltGlueServerDevice` (separate transport
family — Quartet is the "LegacySimpleUSB" one).

Simple setters (vtable slots 18–28 of the Quartet vtable at 0x1002af890) all
funnel into `sendWithRetry(messenger=[this+0x428], cmdId, payloadPtr,
payloadLen, lo16, hi16)` at **0x100188798**: up to 4 attempts, 16 ms sleep
between, returns bit0 = failure.

Encodings recovered so far:
* `0x100021b14` (slot 18): float dB → `clamp(v+48, 0…54)` → u8 payload,
  cmdId **0x4C**; addr `w4 = w2 | w3<<16`.
* `0x100021b84` (slot 19): same encoding, cmdId **0x4D**.
* `0x100021be8/1c1c` (slots 21/22): bool → u8, cmdId **0x4F/0x4E**.
* `0x100021c50/1cc4`: float variant with fixed sub-index `0x0c | w2<<16`.
* The Quartet's own strings (`identify`, `boardVersion`, `pSoCVersion`,
  `usbConnection`, …) live in a std::string pool at 0x10025f1e0–0x10025f4c4.

### Still missing (the last mile)
The wire **framer** — `Messenger` (`Apogee::Messenger`, log domain
"ApogeeMessenger") vtable slot 3, called by sendWithRetry with
`(cmdId, payload, len, lo16, hi16)`. It assembles the frame and hits the USB
write. Messenger is embedded at GlueServerDevice+0x230 (pointer copy at
+0x428); its concrete vtable hasn't been pinned statically yet.

### Dynamic capture status (lldb attempts — infrastructure works, blocked)
* lldb attach/launch from `do shell script` (background session): refused
  ("non-interactive debug session").
* debugserver: exits silently even on own processes.
* Re-signed copy with `get-task-allow` (`/Library/Application
  Support/Apogee/ApogeeGlueDebug.app`): **launches and runs fine** (serves the
  IPC tree, holds UsbExclusiveOwner), but breakpoint memory-writes fail
  (`error sending the breakpoint request: 9`) — even for lldb's own child.
  Hooks/steering infra: `/tmp/usbhooks.py` + `/tmp/hook_cmd.txt` (working
  design, kept for reference; frames log `/tmp/usb_frames.log`).
* One run hit "Failed to open device" — caused by two daemons racing for the
  exclusive USB open; serialized runs avoid it.

### BREAKTHROUGH: the wire protocol is text-tagged ("ApogeeRemote" family)
Near `SIO2PT`/`HDA`/`ApogeeRemote`/`127.0.0.` constants (0x100263e60–0x100263f10)
live the per-model transport tags:

    Duet3TX          @0x100263ea8
    QuartetTONEv2TX  @0x100263eb0
    DuetIITX         @0x100263ec0
    DuetiOSTSDTX     @0x100263ef0

**The daemon builds packets containing the literal string `QuartetTONEv2TX`**
(the Quartet's transport tag; the tag family covers the other models).
Packet construction observed inline in the GlueServerDevice ctor flow
(0x10017140c–0x100171464):

    buf = new(0x23)                       // 35-byte packet
    *(u32*)buf        = 0                 // stlr wzr
    *(u64*)(buf+8)    = 0xC               // command/length field (12)
    *(u64*)(buf+0x10) = "QuartetT"        // first 8 bytes of the tag
    *(u16*)(buf+0x18) = 0x58              // ('X'?) — more tag bytes stored elsewhere
    … then passed (with the tag const at 0x100263eb0 = "QuartetTONEv2TX") into
    a packet-object constructor at 0x100174ab0 with call args
    (this, x20, shared_ptr(buf), w4=0xC, w5=1, w6=2, x7, stack byte=1)

The tag string `QuartetTONEv2TX` (= "QuartetTONE" + "v2" + "TX"?) is stored
piecewise into the packet. This looks like the **"ApogeeRemote" framing**:
text-tagged per-model, per-direction packets ("TX" = host→device), the same
family as the `ApogeeRemoteUSBPacket` RX struct seen in RTTI.

Remaining decode (mechanical now that the anchor is found):
1. the rest of the 35-byte header (fields at 0x0/0x8/0x18/0x19+),
2. where the payload bytes + the lo16/hi16 address (w4/w5 from the setters)
   land in the packet,
3. the checksum/CRC (the JUCE-style fold from prop_probe? the same family?),
4. the RX-side tag (`…RX`) and `processMessageFromDevice` field offsets.

### CAPTURE SUCCESS (worker13 + replug): the vendor-request wire format decoded
With the serialized worker + **unplug/replug** (device re-enumeration — the
firmware refuses a new master's vendor requests until re-enumerated!), the
shim captured **1103 frames** with the device responding (kr=0):

**Session setup (IOConnectCallScalarMethod on AppleUSBHostDeviceUserClient):**
* `sel=2` (open?) → kr=0, out0=2579/7443
* `sel=8` (get info, 4 scalars 255,255,65535,65535) → out0=70659 (0x11403 = version?)
* `sel=0` (1 scalar, 0)

**The state poll (every ~100–200 ms):**
    IOConnectCallScalarMethod(conn, sel=7, {0, 0xC0, 0x29, 0, 0, 7, pData, 500}, 8)
* s1 = bmRequestType **0xC0** (IN|vendor|device), s2 = **bRequest 0x29**, 
* s5 = wLength 7 (a 7-byte response), s6 = pData, s7 = timeout 500 ms.

**The command write (fired 4× at startup — the 4 analog outputs' gains):**
    IOConnectCallScalarMethod(conn, sel=6, {0, 0x40, 0x10, 0, wIndex, 28, pData, 500}, 8)
* s1 = bmRequestType **0x40** (OUT|vendor|device), s2 = **bRequest 0x10**,
* s3 = wValue 0, s4 = **wIndex = the channel (0/1/2/3)**, s5 = **wLength 28** (payload!),
* the 28-byte payload (live dump, ch0–3): `16 a1` × 12 + `20 00 00 00` —
  12 gain-ish pairs (0x16 = 22 = the clamp(dB+48) encoding? → −26 dB default)
  + a trailing u32 0x20.

**Probe writes (identify/buffer/refLevel) were tree-accepted but did NOT hit
USB this run** — the identify "did not apply" transient + the tree-only echo
path; next session: retry the probes mid-capture after the transient clears,
and add the OUT-request payload dumps at write time.

### ✅ STATE-DIFF PROBE: writes accepted from our own client (kr=0)
`tools/direct_probe2.swift` (with the daemon gracefully stopped):
* setGain(hwout0, −40) → kr=0; setGain(−20) → kr=0; setMute on/off → kr=0;
  identify on/off → kr=0. **Every command accepted by the device.**
* The 7-byte poll block (`02 01 00 00 00 00 00`) = a fixed device-status
  heartbeat — NOT the per-channel state. The per-channel state = the
  same-bRequest read-backs (the daemon pairs a read with every write).
* The UI's state model for `.directUSB` = built from the read-backs
  (write → read-back = the authoritative value) + the polls = the liveness.

### ✅ AUDIBLE CONFIRMATION (direct_probe4, user-verified!)
The headphone output = **ch1** ("HP", the tree names map: hwout0 = Main Out,
hwout1 = HP, hwout2-7 = the fixed-level Analog Outs 1-6 — no per-channel
gains on those, hence the tree's gain=None).

The user-verified audible sequence (the daemon stopped, our client only):
* HP gain −44 → **−10 (LOUD — the user heard it jump!)** → restore −44
* HP mute on → off — heard ✓
* The read-backs return the WRITTEN values (the gain byte = |dB| confirmed:
  write 10 → read 10; write 44 → read 44)

**⇒ The device applies our vendor commands. The protocol is proven end-to-end
for gain, mute, and identify. 11.5 = COMPLETE.**

### ✅ HARDWARE ROUTING (the monitor mixer) — controlled and verified
The monitor mixer = **14 inputs × 6 outputs**, addressed as
`wValue = input`, `wIndex = output`, values in the clamp(dB+48, 0…54) byte:

* **gain**: bRequest 0x4C OUT / read-back 0x4C IN — write 0x14 (−28 dB) →
  the read-back 20 ✓; restore 0x30 (0 dB) → 48 ✓
* **mute**: 0x4E OUT / IN — 1 = on, 0 = off ✓ (read-backs verified)
* the sibling cmdIds: 0x4D (the second gain set?)/0x4F (the second bool set?)
  — the mixer's two planes (per the setter pairs)

All inputs read back 0x30 (0 dB unity) on every output = the default
direct-monitoring matrix. **This IS the "hardware routing of the outputs"
feature**: the monitor mixer = the input→output matrix, fully controllable
from Quartet Buddy's own USB session.

**⇒ The Settings UI (the next step): the routing matrix — the inputs as the
rows, the outputs as the columns, the gain sliders + the mute checkboxes,
backed by the monitor commands via DirectUSBClient.**

### PROTOCOL DECODED (worker13 + replug + 30 s settle): 16332 frames
With the device re-enumerated (unplug/replug) and the settle time extended,
the shim captured the **complete control protocol** (16332 frames,
`captures/usb_vendor_frames.log`):

**1. Session** (AppleUSBHostDeviceUserClient, IOServiceOpen):
    sel=2 → kr=0 out0=2579        (open/session)
    sel=8 → kr=0 out0=70659       (get info; scalars 255,255,65535,65535)
    sel=0 → kr=0                  (1 scalar, 0)

**2. State poll** — `IOConnectCallScalarMethod(conn, 7, {0, 0xC0, 0x29, 0, 0, 7, buf, 500}, 8)`
* bmRequestType 0xC0 (IN|vendor|device), **bRequest 0x29**, wLength 7,
* the 7-byte response = the device state block; the daemon also does
  **single-byte property reads** (the same sel=7, wLength=1 — responses seen:
  01, 21, 00, 02, 2b, 11, c8 — the individual property state!),
* an 8-byte response = `fa47e5ce 158b5201` = the serial-number block
  (matches the serial quartet1528B15CEE547FA).

**3. Gain writes** (4× at startup, the analog outputs 0–3):
    IOConnectCallScalarMethod(conn, 6, {0, 0x40, 0x10, 0, channel, 28, payload, 500}, 8)
* bmRequestType 0x40 (OUT|vendor|device), **bRequest 0x10**, wIndex = the
  channel, wLength 28,
* payload = 12 × (`0x16`, `0xA1`) + u32 `0x20` — 12 gain slots × 2 bytes; the
  gain byte = the clamp(dB+48, 0…54) encoding (0x16 = 22 → −26 dB default?);
  the trailing u32 0x20 = 32.

**4. IDENTIFY — fully decoded and verified twice:**
    IOConnectCallScalarMethod(conn, 6, {0, 0x40, 0xB6, 0, 0, 1, &b, 500}, 8)
* **bRequest 0xB6**, wLength 1, payload **0x01 = identify on**, **0x00 = off**
  — the daemon pairs them (the front-panel blink).

**Remaining for 11.6:** map the other commands (mute/dim/refLevel/bufferSize)
onto bRequest values (the tree-write → vendor-request correlation: fire each
probe mid-capture and diff), then implement `.directUSB` in Quartet Buddy:
IOServiceOpen + the three selector calls above — ~100 lines of Swift.

### ✅ 11.5 MILESTONE: standalone identify blink works (public API only!)
`tools/direct_test2.swift` (the public **IOUSBHost framework**, ~60 lines):
1. `IOServiceMatching("IOUSBHostDevice")` → iterate → the name = "Quartet"
   (no USB Serial Number property on the device — the serial comes via the
   vendor protocol!),
2. `IOUSBHostDevice(ioService:options:queue:) throws` (the Obj-C framework;
   the error when the daemon holds the device: **"Another client likely has
   exclusive access"**),
3. `dev.__send(request:data:bytesTransferred:completionTimeout:)` — the
   `NS_REFINED_FOR_SWIFT` methods = the `__`-prefixed variants in Swift,
4. **identify = vendor request 0xB6, 1-byte payload 1/0 — THE FRONT PANEL
   BLINKED** with zero Apogee software in the loop.

Gotchas recorded the hard way:
* `IOServiceMatching` returns CFMutableDictionary directly (ARC-managed);
  the CFDictionarySetValue needs the passUnretained pointers,
* the IOUSBHostDevice's init = throwing, refined to
  `__ioService:options:queue:` (the `__` prefix!),
* the sendDeviceRequest = `__send(request:data:bytesTransferred:completionTimeout:)`,
* the request's `data` = NSMutableData with **length ≥ wLength** (the
  capacity alone isn't enough — "Data buffer is smaller than request
  wLength"),
* the legacy `IOUSBDevice` nub = created ONLY by the kext's merge-nub
  personalities — the daemon DIES without the kext; Quartet Buddy doesn't
  need it (the modern path is entitlement-free),
* **the device firmware holds session state across daemon restarts** —
  vendor requests return kIOReturnNotResponding until a USB re-enumeration
  (unplug/replug). A graceful (SIGTERM) daemon shutdown avoids this.

**⇒ 11.6 is green-lit: `.directUSB` in-app = this client + the decoded
command table (0x33 gain / 0x35 mute / 0xB6 identify / 0x29 poll).**

### THE COMPLETE COMMAND TABLE (worker15: graceful stop, no replug needed!)
**Graceful bootout (SIGTERM) = no device wedging** — the next session's
vendor requests work immediately. With the probes fired mid-capture:

| bRequest | Dir (bmReq) | Meaning | wIndex | Payload |
|---|---|---|---|---|
| **0x10** | OUT 0x40 | gain block | block# (0-3) | 28 B: 12×(gain,0xA1) + u32 |
| **0x33** | OUT 0x40 / IN 0xC0 | **hwout gain** | **channel (0-3)** | 1 B = \|dB\| (20, 26, 30 verified) |
| **0x35** | OUT 0x40 / IN 0xC0 | **mute** | 0 | 1 B (1=on, 0=off) |
| **0xB6** | OUT 0x40 | **identify** | 0 | 1 B (1=on, 0=off) |
| **0x29** | IN 0xC0 | state poll | 0 | 7 B response |

* Every write = followed by an immediate read-back with the SAME bRequest
  (the sendWithRetry verify step). Reads = bmReq 0xC0; writes = 0x40.
* Verified by payload bytes: gain −20 → `0x14`, −26 → `0x1a`, −30 (hwout1,
  wIndex=1) → the same bRequest with the channel in wIndex ✓.
* **analogRefLevel does NOT use vendor requests** — it is applied via
  CoreAudio properties (`AudioObjectSetPropertyData`, the USBDeviceMacOS
  vtable slots 10/11 wrap kAudioDeviceProperty AVPs) — host-side audio-path
  config, like preferredBufferSize.
* The 7-byte poll response = the device state block; the 8-byte variant =
  the serial (`fa47e5ce…` = quartet1528B15CEE547FA).

**⇒ .directUSB implementation (11.6) needs exactly:**
    IOServiceOpen(device, kIOMainPortDefault, 0, &connect)   // AppleUSBHostDeviceUserClient
    IOConnectCallScalarMethod(connect, 0, {0}, 1, …)          // session
    IOConnectCallScalarMethod(connect, 6, {0,0x40,0x10|0x33|0x35|0xB6, …}, 8, …)  // commands
    IOConnectCallScalarMethod(connect, 7, {0,0xC0,0x29|…, …}, 8, …)               // polls/reads
~100 lines of Swift. No Apogee code, no kext, no daemon.

### Interposer status: infrastructure proven; the blocker was a race

| bRequest | Dir (bmReq) | Meaning | wIndex | Payload |
|---|---|---|---|---|
| **0x10** | OUT 0x40 | gain block | block# (0-3) | 28 B: 12×(gain,0xA1) + u32 |
| **0x33** | OUT 0x40 / IN 0xC0 | **hwout gain** | **channel (0-3)** | 1 B = \|dB\| (20, 26, 30 verified) |
| **0x35** | OUT 0x40 / IN 0xC0 | **mute** | 0 | 1 B (1=on, 0=off) |
| **0xB6** | OUT 0x40 | **identify** | 0 | 1 B (1=on, 0=off) |
| **0x29** | IN 0xC0 | state poll | 0 | 7 B response |

* Every write = followed by an immediate read-back with the SAME bRequest
  (the sendWithRetry verify step). Reads = bmReq 0xC0; writes = 0x40.
* Verified by payload bytes: gain −20 → `0x14`, −26 → `0x1a`, −30 (hwout1,
  wIndex=1) → the same bRequest with the channel in wIndex ✓.
* **analogRefLevel does NOT use vendor requests** — it is applied via
  CoreAudio properties (`AudioObjectSetPropertyData`, the USBDeviceMacOS
  vtable slots 10/11 wrap kAudioDeviceProperty AVPs) — host-side audio-path
  config, like preferredBufferSize.
* The 7-byte poll response = the device state block; the 8-byte variant =
  the serial (`fa47e5ce…` = quartet1528B15CEE547FA).

**⇒ .directUSB implementation (11.6) needs exactly:**
    IOServiceOpen(device, kIOMainPortDefault, 0, &connect)   // AppleUSBHostDeviceUserClient
    IOConnectCallScalarMethod(connect, 0, {0}, 1, …)          // session
    IOConnectCallScalarMethod(connect, 6, {0,0x40,0x10|0x33|0x35|0xB6, …}, 8, …)  // commands
    IOConnectCallScalarMethod(connect, 7, {0,0xC0,0x29|…, …}, 8, …)               // polls/reads
~100 lines of Swift. No Apogee code, no kext, no daemon.

### ✅ 11.6 OFFLINE UI: the control window works with the daemon GONE
**User-verified end-to-end**: ApogeeGlue stopped → the control window's
faders/mutes keep working via the direct-USB vendor requests. The
"Device unavailable — waiting for Apogee Control 2." gating is gone.

The wiring (AppDelegate):
* `writeGain/writeMute(target, …)` = the transport selection: the glue tree
  when connected, the direct vendor requests (0x33 gain / 0x35 mute,
  wIndex = the channel) when the daemon is gone,
* `isGlueConnected` → the glue connected **OR** the direct session openable
  (the control window stays live offline),
* `onWriteDouble/onWriteBool` → the path-id → vendor-command translation for
  the known properties (the hwout gains/mutes + the identify),
* the OS slider/mute sync gates relaxed for the direct session.

### ✅ 11.7 UNINSTALL COMPLETE (Nov 7 2026, user-verified)
Removed (all backed up to `~/apogee-backup-2026-11-07/` first):
* `/Library/LaunchDaemons/com.apogeedigital.apogeeglue.plist` + the messenger
* `/Library/Application Support/Apogee/` (ApogeeGlue.app)
* `/Library/Extensions/QuartetUSBOverideDriver.kext`
* `/Applications/Apogee Control 2.app`
* `/Library/Preferences/com.apogee.*` + the caches

Verification: no launchd jobs, no kext, no support files, no processes, not
loaded in the kernel. **A reboot flushes the last kernel-side merge nubs**
(the legacy IOUSBDevice facade nubs the daemon needed — irrelevant now).

**Post-uninstall behavior (user-verified live):**
* audio keeps playing (Apple's class-compliant `usbaudiod` — no daemon ever
  needed for audio),
* the app's sliders/mutes write via **direct USB** — the log shows
  `transport: directUSB gain Headphones …` streaming while the daemon is
  *gone*,
* the identify blink = direct vendor request 0xB6.

**⇒ The goal reached: only Quartet Buddy installed, fully working.**
A reboot is recommended once to flush the kernel-side merge nubs.

### ⭐ THE COMPLETE REGISTER MAP (11/7 sweep — decoded from the daemon's own USB writes)
The sweep toggled every tree property A→B→A while the shim captured the
wire; the timeline correlation (write ≈ mark−1.5…−3 s, lazy queue flush)
yields the FULL map. Capture: captures/usbsniff_sweep_2026-11-07.log (37 MB)
+ captures/sweep_timeline_2026-11-07.txt. All writes: bmRequestType=0x40,
wValue=0, wIndex=selector, 1 byte, unless noted.

**INPUTS (wIndex = input 0…3):**
* `0x11` softLimit (0/1; default 1 — the tree's softLimit=True ✓)
* `0x13` polarityInvert Ø (0/1)
* `0x15` phantom +48V (0/1)  [touchscreen-verified earlier]
* `0x16` input TYPE: 0=+4dBu, 1=−10dBV, 2=Mic, 3=Instrument  [touchscreen-verified]
* `0x34` MIC preamp gain, |dB| (0…75)
* `0x3e` INSTRUMENT preamp gain, |dB| (the app's separate inst store!)
* `0x44` group/ganging (0/1) — the daemon writes BOTH pair members

**ANALOG OUTS (wIndex = out−2, i.e. hwout2…7 → 0…5):**
* `0x18` output TRIM: |dB|×10, attenuation-only (0…~240)
  (−10→0x64, −20→0xc8, −5→0x32, 0→0x00; the pre-existing c8/c8/0a/0a
  match the tree's −20/−20/−1/−1 EXACTLY)
* `0xb6` output REF LEVEL bit: +4dBu=0, −10dBV=1
  (⚠ 0xB6 was earlier mis-attributed to "identify" — the blink may have
  been the output LEDs reacting to the level change; re-verify identify)

**MONITOR OUTPUTS (hwout0=Main, hwout1=HP; wIndex = the output):**
* `0x33` gain |dB|, `0x35` mute (verified earlier)
* `0x40` dim flag (0/1)   ← NOT 0x4F as guessed
* `0x46` sum-to-mono flag (0/1)  ← NOT 0x4E as guessed
* `0x45` mainOutputFormat bit; `0x47` activeSpeakerSet bit

**MIXER (wIndex = channel 0…12, 14 = MASTER):**
* `0x4C` fader volume, clamp(dB+48, 0…54)  (−10→0x26, −6→0x2a)
* `0x4D` pan, round(pan×128)  (0.25→0x20, 0.5→0x40)  ← NOT the dim level
* `0x4E` solo (0/1)   ← NOT the mute
* `0x4F` mute (0/1)   ← NOT the dim enable
* after EVERY mixer change the daemon also commits two 28-byte `0x10`
  block writes (wIndex=0 and 1; 12×(val,0xA1)-ish + tail) — a state
  snapshot, likely the power-cycle persistence mechanism. Layout TBD;
  the individual registers above suffice for control.
* the matrix cells (wValue=input, wIndex=output) were audibly verified
  earlier with the same 0x4C/0x4E — the cell space and the channel-fader
  space coexist in one register family.

**DEVICE (wIndex=0):**
* `0x1f` peakHold, `0x20` overHold, `0x4a` lockHomeScreen (0/1)
* `0x51` keyboardVolumeControls (0/1)
* `0x49` wIndex=0…2 = the pad A/B/C action (enum byte: 131076→3, 262147→8)
* `0x4b` wIndex=0 = the encoder-push action (enum byte: 327691→4)
* `0x29` 7 B poll; `0x31` 8 B serial; `0x14` 60 B change-event block
* the app's dim/sum guesses (0x4E/0x4F at reg 0x0C) were WRONG — the real
  dim/sum = 0x40/0x46 with wIndex=the output.

### THE GLUE SWEEP (11/7 afternoon): the daemon restored UNDER THE SHIM
The systematic decode: /Library/Apogee restored from the backup (ONLY the
debug glue app — no launchd, no messenger/kext), the device replugged,
the daemon launched under /tmp/usbsniff.dylib, EVERY tree property toggled
A→B→A via prop_probe's TCP set-op with timestamps (tools/sweep_toggle.py),
then the daemon stopped GRACEFULLY (pkill -15) and the files deleted again.

**Lessons + finds from round 1:**
* the tree's var-tags: 1=int32, 3=bool, **4=DOUBLE** — the probe's guessed
  tag 2 (32-bit float) is SILENTLY IGNORED by the daemon (no USB write,
  no error). All float properties need the 8-byte double write.
* `0x44` = the hwin GROUP (ganging) bit: setting hwin0.group writes 0x44
  on wI=0 AND wI=1 — the PAIR partner is written too (2 channels).
* the daemon SKIPS USB writes when its cached model already has the value
  (group=False after True wrote nothing — the model was back to False... or
  the write landed outside the correlation window — the fixed sweep re-decodes).
* the fresh-tree correlation: softLimit=True(default) ↔ 0x11=01 everywhere;
  hwin1 instSettings gain 17.0 ↔ 0x3e=0x11(17) → **0x3e = the INSTRUMENT
  preamp gain** (0x34 = the MIC gain — the app's two gain stores confirmed).
* the tree's analogRefLevel did NOT match the device's 0x16 types after the
  replug — the daemon seeds some properties from its SAVED model, not from
  the device registers (the model also lives in ApogeeSupport/Settings).

### INPUT SECTION DECODED + VERIFIED (11/7, the afternoon session)
The addressing fix that unblocked everything: **per-input registers are
addressed wValue=0, wIndex=input** (NOT wValue=input+2 — my earlier guess
silently failed; reads returned nil → the UI stayed empty).

**The verified input register map (live write/read-back on 11/7):**
* `0x34` wIndex=input, 1 byte = **the per-INPUT preamp GAIN, |dB| (0…75)**
  — NOT the mixer's dB+48 (the preamp goes UP; in0 read 0x21=33 dB,
  in1 0x2b=43 dB — classic mic gains; unused inputs read 0x00 = 0 dB).
  Write 0x30/0x40 → read-back 0x30/0x40 ✓. Sibling of the output's 0x33.
* `0x36` wIndex=input, 1 byte = **the input TYPE**: writable (0↔1 verified);
  all-Mic inputs read 0 → hypothesis: 0=Mic, 1=Line, 2=Instrument
  (app enum 1=Mic 2=+4 3=−10 4=Inst; +4/−10 collapse to Line=1; the sub-ref
  lives in another register). PENDING: touchscreen type-change diff.
* `0x11/0x13/0x15/0x16/0x3e/0x44` per input: read OK, semantics unknown
  (all in0-in3 currently 11:01 13:00 15:00 16:02 3e:00 44:00).
* `0x10` wIndex=block(0-3), 28 bytes = `12×(gain,0xA1) + 4B tail` — READABLE
  (my earlier belief: write-only, wrong). All 4 blocks currently
  `16 a1`×12 + tail `20000000`/`00002000` alternating. 12 slots = the 12
  input channels (4 analog + 8 ADAT)? Semantics TBD — not needed for the
  preamps (0x34 owns those). The tail alternates per block parity.
* `0x14` (60 B, polled ×1994 in the capture) = all zeros in practice —
  a change-event/meter block, not state.
* `0x29` 7 B poll: `02 01 00 41 00 00 00`; `0x31` 8 B = the serial block.
* `0x28` wI=0..2, 3 B; `0x49` wI=0..2 1 B; `0x18` per out 0-5 (2/3 = c8,
  4/5 = 0a) — unknown, likely LED/touchscreen config.
* The full read surface (capture): per-input sweep {0x11,0x13,0x15,0x16,
  0x34,0x3e,0x44} ×4, per-out {0xb6,0x18} ×6, {0x33,0x35} ×2, the mixer
  matrix {0x4c,0x4d,0x4e,0x4f} scan, then 0x51/0x45/0x47/0x46/0x40/0x53×4.

**0x16 TYPE ENUM COMPLETE (11/7):** the user set input 2 = +4dBu and
input 3 = −10dBV on the touchscreen; the diff read in1 0x16=00, in2
0x16=01. Full enum: **0=+4dBu, 1=−10dBV, 2=Mic, 3=Instrument** — the app
reads and writes all four modes now (verified read-side against three
independent hardware switches; write-side uses the identical addressing
as 0x34/0x15 which are write-verified).

**0x16 = the INPUT TYPE — TOUCHSCREEN-VERIFIED (11/7, the decisive diff):**
the user CAN switch the input type on the device's touchscreen (unlike
SL/Ø). After they switched input 4 to Instrument MANUALLY, the diff vs
the known state showed ONE register move: in3's 0x16 02→03. All-Mic
inputs read 0x16=02. So: 02=Mic, 03=Instrument, Line=the pending third
value (the user is switching in4 to Line for the next diff). The app now
reads AND writes 0x16 (map: 1(Mic)→2, 4(Inst)→3, Line→pending-no-write).
Also captured in the same diff: the user's hardware gain changes
(in0/in1 0x34 → 00) flowed into the registers — the device register is
the single source of truth.

**0x36 = NOT the type — writable-but-unknown (parked):** the setter at
0x100009b08 serves two tree properties → 0/1, bails otherwise. My 0x36=1
write on in4 stuck (read-back verified) but the touchscreen's own type
switch overrode/reverted it to 0. Function TBD (hpf/pad candidates).

**0x36 = the MIC/INSTRUMENT preamp selector (11/7, setter decode + live):**
the setter at 0x100009b08 compares the incoming property value against
TWO runtime globals (two tree property-ids) and emits ONLY 0 or 1 —
anything else BAILS (no write). That's why the app's "mode 4 → 0x36=2"
did nothing. 0=Mic (all inputs read 0), 1=Instrument (write sticks,
read-back verified on in4). The Line modes (+4/−10) don't touch 0x36 —
the daemon's line path is a different setter, still pending. The app's
enum map now: 1→0, 4→1, 2/3→no write.

**The setter-table decodes (0x100009a00–0x100009b80, 11/7):**
* TWO 0x10 1-byte setters: (A) w1∈{0,1}, (B) w1+2 → wValue = the input
  0…3, value = clamp(dB, −50…+6) + 48 — the mixer-range encoding on FOUR
  per-channel 0x10 sub-registers (semantic TBD — NOT the preamp: the
  preamp is 0x34 = |dB| 0…75). The 28-byte block writes (wValue=0,
  wIndex=block) are a separate bulk path over the same register space.
* The helper 0x100188918(transport, bRequest, &byte, wValue) → the
  transport's vtable+0x18(bRequest, pData, len=1, wValue, wIndex=0) —
  the per-INPUT channel index lives INSIDE the per-input transport
  object (each input object holds its transport at +0x428).
* A 0x0F/0x10 toggle setter via the SHADOW-QUEUE helper 0x100005f0c
  (self, bRequest, value, channel 0-2, flag) — the queue holds
  (bRequest, |value|, channel, flag) records and per-bRequest shadow
  fields exist for bRequests 0x0A…0x1E. 0x0F ignores direct writes at
  the wIndex addressing — its addressing differs (pending).
* The property NAME REGISTRY (the std::string init at 0x1001c8xxx):
  analogRefLevel, softLimit, polarityInvert, phantom, hpf, pad,
  impedance, gainLink, mixerChannel, channelType … (full list dumped —
  grep "softLimit" in this file's history). These are TREE names, not
  USB registers.
* The capture write surface (both sniff sessions): ONLY 0x10 blocks,
  0x33, 0x35, 0xb6 — the daemon sessions never wrote type/SL/Ø.

**0x15 = +48V phantom — VERIFIED by touchscreen diff (11/7):** the user
toggled 48V on input 1 on the DEVICE's touchscreen and probe7 caught the
only change: in0's 0x15 0x00→0x01. The touchscreen exposes 48V — SL/Ø are
likely there too (candidates: 0x13 writable-unknown, 0x11, 0x16, 0x44).
in1's 0x3e reads 0x11 (pre-existing, unexplained).

**probe9 (11/7): the writable per-input registers:** `0x13` (wIndex=input)
accepts writes and STICKS (write 1 → reads 1; restored 0) — function
unknown, a 48V/SL/Ø candidate. `0x11` reads 1 everywhere (write inconclusive).
After a write to an unusual register, subsequent reads can fail transiently
(0xff) — the device goes briefly busy; probe7 immediately after read
everything fine again. Also: the user's own encoder test changed in0's 0x34
from 0x21 to 0x00 — the DEVICE register is the truth (front-panel writes land
there), so the UI re-poll (2 s cadence in direct mode, added) is the right model.

**Wired into the app (built 12:54):** setInputGain→0x34, setInputType→0x36
(+ the app↔device enum map in DirectUSBClient), readInput addressing fix,
the read sweep = {0x34,0x36}×4, the type popup's offline fallback
(onDirectInputType), the onWriteInt→0x36 translation for captured ids.

### 11.6 status after the uninstall (the honest ledger)
**Working offline (user-verified):**
* the menubar icon (white, no flicker) + "Quartet Connected (direct USB)"
* the app's faders/mutes → the direct vendor requests (the log proves it)
* the hotkeys (⌘⇧S = the output switch), the identify blink
* the eager direct session at boot + on the device arrival
* the offline boot = the saved tree snapshot
  (~/Library/Application Support/QuartetBuddy/lastTree.json)

**Not yet (the input section offline):**
* the input TYPE's path-id is not in the captured DeviceTable (the table has
  no field for it) → its writes log "no direct mapping … dropped"
* the input section's UI state = from the tree snapshot only — the live
  read-backs (0x10/0x33/0x35/0x36 IN) are not wired into the UI refresh yet
* the monitor/dim property name was wrong in the probe (monitor/dim — the
  real path = the hwout0.dim)

**Next session's work list:**
1. the DeviceTable += the input-type id (a new capture step), or the
   reverse-lookup via the tree snapshot's node ids
2. the control window's input section = the read-back-backed refresh
   (0x10/0x33/0x35/0x36 IN reads = the live state without the tree)
3. the same for the dim/sum (the monitor register 0x0C reads)
4. then 11.7's final pass: the README + the uninstall guide for the users

### Interposer status: infrastructure proven; the blocker was a race
**The in-process shim works** (`tools/usbsniff.c` → `usbsniff.dylib`):
* learns the static IOUSBLib vtables by QI-ing its own objects (two-level
  import = the real IOKit, no interpose-map poisoning),
* a VM scanner swaps the daemon's object vptrs to logging copies (confirmed
  hooking the daemon's device+interface objects — 111 hooks in the last run),
* hooks the open path (USBDeviceOpen/USBInterfaceOpen) + all six pipe methods
  + DeviceRequest/DeviceRequestTO,
* plus same-name `IOConnectCall*` definitions (these engage only under
  DYLD_FORCE_FLAT_NAMESPACE, which chained-fixup binaries ignore — never
  fired; kept for reference).

**Why zero frames appeared (complete root cause):**
1. A dozen daemon PIDs fought over the exclusive USB open (2040 kernel
   failures) — early debug daemons lost the race outright.
2. **The device itself holds session state**: after the old daemon dies
   mid-session, the Quartet firmware ignores vendor requests from any new
   session (`sendUSBInVendorRequest: kIOReturnNotResponding` spam every
   second) until the device is **re-enumerated** (unplug/replug). The debug
   daemons were talking to a device wedged on its dead master.
3. Original binary entitlements (`allow-unsigned-executable-memory`,
   `disable-executable-page-protection`) get stripped by the re-sign; the
   binary's `__DATA` is page-immutable on this macOS, so vptr swaps from the
   shim silently never stick (writes to the shared-cache/binary pages).

**The airtight run recipe (next session):**
1. `launchctl bootout` **both** jobs (apogeeglue AND apogeemessenger),
2. `pkill -9 -f ApogeeGlue` + poll until `pgrep -f ApogeeGlue` is empty,
3. **physically unplug + replug the Quartet** (re-enumeration!), poll `ioreg`
   for the fresh device instance,
4. launch the debug daemon (shim inserted) → verify
   `UsbExclusiveOwner = <debug pid>`,
5. fire `identify` / `reflevel` via `prop_probe.py` → frames appear in
   `/tmp/usbsniff.log`,
6. `launchctl bootstrap` both jobs back.

Scripts: `tools/usbworker.sh` (root worker; needs the debug app copy at
`/Library/Application Support/Apogee/ApogeeGlueDebug.app` — re-sign with
`codesign --force --sign - --entitlements <get-task-allow plist>`, see
`/tmp/dbg.ent`), `tools/lldb_usbhooks.py` (lldb steering hooks — worked,
blocked on session permissions).

**System state hygiene**: every worker run restores the launchd daemon
(`launchctl bootstrap`) — verify with `launchctl print
system/com.apogeedigital.apogeeglue` and `pgrep -f ApogeeGlue` after manual
experiments. Verbose-XML backup: `/tmp/glue-verbose-backup.xml`.

Then (11.6) implement `.directUSB` with the recovered framing, (11.7) verify
OS volume semantics without Apogee software, then the uninstall guide.
