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
