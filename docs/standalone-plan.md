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

### Next attack (11.5b): interposer status + the decisive insight
**In-process shim works mechanically** (`/tmp/usbsniff.c` → `usbsniff.dylib`):
* same-name `IOCreatePlugInInterfaceForService` definition + DYLD_FORCE_FLAT_NAMESPACE
  (the `__interpose` table also engages, but flat+definition is cleaner;
  note dyld4 interposes the interposer's own imports — recursion — so the
  shim calls IOKit via its own two-level import, which is NOT interposed),
* learns the static IOUSBLib vtables by QI-ing its own objects, then a
  malloc/VM scanner swaps the daemon's object vptrs to logging copies,
* **confirmed hooked objects are the Quartet's**: the `"Woohoo you have a
  cool audio interface"` string lives *inside* the USBDeviceMacOS ctor
  (0x100038884) — the Quartet uses the LEGACY/simple path ("fancy" =
  the modern one, 0x100261f73).

**Yet zero calls through the hooked vptrs during probe writes.** Working
theories, in order:
1. the debug daemon's device open fails (earlier runs printed "Failed to
   open device" once, silently retrying in others — objects created and
   destroyed in a loop, which matches the re-hook spam of the same slots),
2. and/or the actual byte traffic flows through `IOConnectCall*` on the
   modern `AppleUSBHostDeviceUserClient` (the daemon imports these directly),
   with the IOUSBLib objects used only for setup.

**Next steps, in order:**
1. Add open-path hooks (`USBDeviceOpen` 0x40 / `USBInterfaceOpen` 0x40, log
   the IOReturn) to the shim to settle (1).
2. Have the shim walk `USBDeviceMacOS → +0x90 (interface obj) → backpointer →
   GlueServerDevice → +0x428 (messenger) → vptr` and dump the Messenger's
   slot-3 framer address; disassemble it statically. This recovers the wire
   format without any further capture.
3. Alternative once open-path is settled: interpose `IOConnectCallStructMethod`
   (+Async variants) — real-address resolution is the known wall (dlsym is
   poisoned by the interpose map; binary pages immutable so GOT patch fails);
   the vtable-learn trick does not apply (plain functions).
4. Fallback: empirical probing from our own client (bootout the daemon, open
   the device as root, send candidate frames built from the known setter
   encoding + cmdIds, watch monitor-mute state).

**System state hygiene**: every worker run restores the launchd daemon
(`launchctl bootstrap`) — verify with `launchctl print
system/com.apogeedigital.apogeeglue` and `pgrep -f ApogeeGlue` after manual
experiments. Verbose-XML backup: `/tmp/glue-verbose-backup.xml`.

Then (11.6) implement `.directUSB` with the recovered framing, (11.7) verify
OS volume semantics without Apogee software, then the uninstall guide.
