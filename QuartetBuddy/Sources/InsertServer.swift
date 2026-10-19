import Foundation
import CoreAudio
import ObjectiveC
import AudioToolbox
import AudioUnit
import AVFAudio
import CoreAudioKit
import AppKit

/// The AU insert engine: real-time plugin processing on the Quartet's outputs.
///
/// Architecture:
///
///   all system audio (bound for the Quartet)
///      ↓  CATap — stereo tap on the Quartet's stream 0, EXCLUDES this
///         process, muteBehavior = .muted — captured audio never reaches
///         the Quartet's DAC (true insert), and our own output passes
///         through untouched (no feedback loop).
///   private aggregate device (master: Quartet, taps: [tap])
///      ↓  one IOProc
///      ├─ outs 1‑2 (speakers): AU plugin chain (ARC X…) or dry bypass
///      ├─ outs 3‑4 (HP):       dry passthrough
///      └─ outs 5‑6 / 7‑8:      silence (future plugin slots)
///
/// The system default output stays "Quartet", so the volume-keys / fader /
/// mute bindings in OSVolumeMirror are unaffected.
final class InsertServer: NSObject {

    static let shared = InsertServer()

    /// Fired on the main thread whenever state changed (menu refresh).
    var onStateChange: (() -> Void)?

    /// True when the tap has never delivered a non-silent cycle while the
    /// insert is running — the signature of macOS denying the System Audio
    /// Recording permission (it silences taps instead of failing them).
    private(set) var tapSilent = true

    private(set) var running = false
    private(set) var pluginName: String?
    private(set) var pluginBypass: Bool = UserDefaults.standard.bool(forKey: "insertPluginBypass")

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48000

    // MARK: - Plugin (AVAudioEngine realtime manual rendering)

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var effect: AVAudioUnitEffect?
    /// Render target for the engine (offline renderManual → copy out).
    private var renderBuffer: AVAudioPCMBuffer?
    private var pluginDesc: AudioComponentDescription?
    private var dry: StereoABL?
    /// Processing output buffers (chunks assembled per cycle).
    private var procBufL: UnsafeMutablePointer<Float>?
    private var procBufR: UnsafeMutablePointer<Float>?
    private var viewWindow: NSWindow?
    private var cycleCount = 0
    private var renderOK = 0
    private var renderErr = 0

    /// Current plugin-chain render chunk (the source node pulls it from
    /// `dry`). Audio-thread only — no locking.
    private var chunkOffset = 0
    private var chunkFrames = 0
    /// Source-node pull counter (diagnostics).
    private var sourcePulls = 0
    private var lastLoggedPulls = 0
    /// Time-based log throttle state (audio thread).
    private var lastLogTime: UInt64 = 0
    private let logIntervalTicks: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 5_000_000_000 * UInt64(info.numer) / UInt64(info.denom)   // ~5 s
    }()

    // MARK: - Buffer size (latency)

    /// Supported IO slice sizes (frames @ 48 kHz → ms).
    static let bufferChoices: [(frames: Int, label: String)] = [
        (32, "32 — 0.7 ms"),
        (64, "64 — 1.3 ms"),
        (128, "128 — 2.7 ms"),
        (256, "256 — 5.3 ms"),
        (512, "512 — 10.7 ms"),
    ]

    /// Default when never configured: 32 (lowest latency).
    private static let defaultBufferFrames = 32

    static func savedBufferFrames() -> Int {
        let v = UserDefaults.standard.integer(forKey: "insertBufferFrames")
        return bufferChoices.contains { $0.frames == v } ? v : defaultBufferFrames
    }

    /// Change the IO slice: restarts the insert with the new size.
    func setBufferFrames(_ frames: Int) {
        UserDefaults.standard.set(frames, forKey: "insertBufferFrames")
        if running {
            stop()
            start()
        }
        onStateChange?()
    }

    func setRunning(_ on: Bool) {
        if on { start() } else { stop() }
    }

    func start() {
        guard !running else { return }
        do {
            try build()
            running = true
            QBLog.log("insert: running (\(pluginName ?? "no plugin"), \(Int(sampleRate)) Hz, buffer \(Self.savedBufferFrames()) frames)")
        } catch {
            QBLog.log("insert: start failed — \(error.localizedDescription)")
            teardown()
            running = false
        }
        onStateChange?()
    }

    func stop() {
        guard running else { return }
        teardown()
        running = false
        QBLog.log("insert: stopped")
        onStateChange?()
    }

    private func build() throws {
        guard #available(macOS 14.2, *) else {
            throw InsertError.other("needs macOS 14.2+ for Core Audio taps")
        }
        tapSilent = true
        guard let quartet = OSVolumeMirror.scanForQuartet() else {
            throw InsertError.other("Quartet not found in Core Audio")
        }
        let quartetUID = try Self.deviceUID(quartet)
        sampleRate = Self.deviceRate(quartet)

        // 1) the tap: stereo mix of everything bound for the Quartet's
        //    output stream 0, except this process, muted at the hardware.
        let desc = CATapDescription(excludingProcesses: [try Self.ownProcessObjectID()],
                                    deviceUID: quartetUID,
                                    stream: 0)
        desc.uuid = UUID()
        desc.name = "Quartet Buddy Insert"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        var tap = AudioObjectID(0)
        try Self.check(AudioHardwareCreateProcessTap(desc, &tap), "tap create")
        guard tap != 0 else { throw InsertError.other("tap id 0") }
        tapID = tap

        // 2) the aggregate that exposes the tap as input and the Quartet
        //    (master) as output — all IO happens on this one device.
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.quartetbuddy.insert." + UUID().uuidString,
            kAudioAggregateDeviceNameKey: "Quartet Buddy Insert",
            kAudioAggregateDeviceMainSubDeviceKey: quartetUID,
            kAudioAggregateDeviceSubDeviceListKey: [["uid": quartetUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
            kAudioAggregateDeviceIsPrivateKey: 1,
        ]
        var agg = AudioObjectID(0)
        try Self.check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg), "aggregate create")
        guard agg != 0 else { throw InsertError.other("aggregate id 0") }
        aggregateID = agg

        // Latency: the IO slice drives the insert's round-trip delay
        // (32 frames = 0.67 ms @ 48 kHz). Persisted; defaults to 32.
        let requested = Self.savedBufferFrames()
        var bufAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        var bufFrames = UInt32(requested)
        let bufErr = AudioObjectSetPropertyData(agg, &bufAddr, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &bufFrames)
        // read back what the HAL actually granted (safety offsets may
        // clamp it — the Quartet is USB)
        var granted = UInt32(0)
        var gSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(agg, &bufAddr, 0, nil, &gSize, &granted) == noErr, granted != requested {
            QBLog.log("insert: buffer \(requested) not granted — HAL gave \(granted)")
        } else if bufErr != noErr {
            QBLog.log("insert: buffer size set err \(bufErr)")
        }

        // 3) dry buffer + plugin (if it fails, don't leave the system silent)
        dry = StereoABL(frames: 4096)
        if let key = UserDefaults.standard.string(forKey: "insertPluginDesc"),
           let d = Self.listPlugins().first(where: { Self.descKey($0.desc) == key })?.desc {
            do { try instantiatePlugin(d) } catch {
                QBLog.log("insert: plugin failed to load (\(key)) — running dry. \(error)")
            }
        }

        // 4) the IO cycle.
        let proc: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, refCon in
            let myself = Unmanaged<InsertServer>.fromOpaque(refCon!).takeUnretainedValue()
            return myself.cycle(inInputData, outOutputData)
        }
        try Self.check(AudioDeviceCreateIOProcID(aggregateID, proc,
                                                Unmanaged.passUnretained(self).toOpaque(), &ioProcID),
                      "IOProc create")
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "device start")
    }

    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if let effect, let pluginDesc {
            Self.savePluginState(desc: pluginDesc, effect: effect)
        }
        if let engine { engine.stop() }
        engine = nil
        sourceNode = nil
        effect = nil
        renderBuffer = nil
        procBufL?.deallocate()
        procBufR?.deallocate()
        procBufL = nil
        procBufR = nil
        pluginDesc = nil
        dry = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    // MARK: - The IO cycle

    /// One IO cycle on the aggregate: tap input (stereo) → plugin →
    /// Quartet's 8 output channels. Audio thread: no allocation.
    private func cycle(_ inInputData: UnsafePointer<AudioBufferList>?,
                       _ outOutputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let out = outOutputData else { return noErr }
        let frames = Self.frames(of: out)
        guard frames > 0, frames <= 4096, let dry else { return noErr }

        // 1) the tapped system mix → dry stereo.
        //    The aggregate input carries TWO streams: the Quartet's own
        //    12ch input stream + our 8ch tap (copy of Quartet stream 0).
        //    Find the 8ch tap buffer; the system's stereo mix sits on its
        //    channels 1‑2 (device stereo pair [1,2] → stream ch 0,1).
        if let inp = inInputData {
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
            var tap: AudioBuffer?
            if inList.count == 1, inList[0].mNumberChannels == 2 {
                tap = inList[0]   // future stereo-mixdown tap: interleaved stereo
            } else {
                for b in inList where b.mNumberChannels == 8 || b.mNumberChannels == 2 {
                    tap = b; break
                }
            }
            if let tap, let d = tap.mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(tap.mNumberChannels))
                let n = min(frames, Int(tap.mDataByteSize) / 4 / ch)
                if ch == 2 {
                    dry.buffers[0].update(from: d, count: n)
                    dry.buffers[1].update(from: d + 1, count: n)
                } else {
                    for f in 0..<n {
                        dry.buffers[0][f] = d[f * ch]
                        dry.buffers[1][f] = d[f * ch + 1]
                    }
                }
                if n < frames {
                    for c in 0..<2 { for f in n..<frames { dry.buffers[c][f] = 0 } }
                }
            } else {
                for c in 0..<2 { for f in 0..<frames { dry.buffers[c][f] = 0 } }
            }
        } else {
            for c in 0..<2 { for f in 0..<frames { dry.buffers[c][f] = 0 } }
        }
        cycleCount += 1
        let now = mach_absolute_time()
        if lastLogTime == 0 { lastLogTime = now }

        // 2) outs 1‑2: plugin chain via AVAudioEngine manual rendering
        //    (offline + renderOffline — the block API returns -50 on
        //    macOS 27.0.1), in 512-frame chunks.
        var procL = dry.buffers[0], procR = dry.buffers[1]
        if let engine, !pluginBypass, let renderBuffer {
            var offset = 0
            var ok = true
            while offset < frames {
                let n = min(512, frames - offset)
                chunkOffset = offset
                chunkFrames = n
                if let st = try? engine.renderOffline(AVAudioFrameCount(n), to: renderBuffer),
                   st == .success, renderBuffer.frameLength == AVAudioFrameCount(n),
                   let cl = renderBuffer.floatChannelData?[0],
                   let cr = renderBuffer.floatChannelData?[1],
                   let pl = procBufL, let pr = procBufR {
                    memcpy(pl + offset, cl, n * 4)
                    memcpy(pr + offset, cr, n * 4)
                } else {
                    ok = false
                    break
                }
                offset += n
            }
            if ok, let pl = procBufL, let pr = procBufR {
                renderOK += 1
                procL = pl
                procR = pr
            } else {
                renderErr += 1
                if renderErr <= 3 || renderErr % 512 == 0 {
                    QBLog.log("insert: plugin render failed (frames=\(frames), ok=\(renderOK)) — falling back dry")
                }
                procL = dry.buffers[0]   // graceful dry fallback
                procR = dry.buffers[1]
            }
        }

        // tap health: sustained exact silence = capture denied/muted.
        // Cheap check every cycle; the full log only on the throttle.
        if !tapSilent { /* already known-live */ }
        else if dry.buffers[0][0] != 0 || dry.buffers[1][0] != 0 {
            tapSilent = false
            QBLog.log("insert: tap is live (first non-silent cycle)")
            DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
        }

        if cycleCount < 3 || now - lastLogTime > logIntervalTicks {
            lastLogTime = now
            var dryPeak: Float = 0
            for f in 0..<frames { let v = abs(dry.buffers[0][f]); if v > dryPeak { dryPeak = v } }
            var procPeak: Float = 0
            for f in 0..<frames { let v = abs(procL[f]); if v > procPeak { procPeak = v } }
            QBLog.log("insert: cycle #\(cycleCount) frames=\(frames) dryPeak=\(dryPeak) procPeak=\(procPeak) pulls=\(sourcePulls - lastLoggedPulls) \(pluginBypass ? "[bypassed]" : "")")
            lastLoggedPulls = sourcePulls
        }
        // 3) write the Quartet's output channels:
        //    1‑2 = processed, 3‑4 = dry, 5‑8 = silence
        let outList = UnsafeMutableAudioBufferListPointer(out)
        if outList.count >= 8 {
            // non-interleaved: one buffer per channel
            Self.copyStereo(into: outList, base: 0, l: procL, r: procR, frames: frames)
            Self.copyStereo(into: outList, base: 2, l: dry.buffers[0], r: dry.buffers[1], frames: frames)
            Self.clear(outList[4], frames); Self.clear(outList[5], frames)
            Self.clear(outList[6], frames); Self.clear(outList[7], frames)
        } else if outList.count == 1, let interleaved = outList[0].mData?.assumingMemoryBound(to: Float.self) {
            // interleaved 8ch fallback
            for f in 0..<frames {
                interleaved[f * 8 + 0] = procL[f]
                interleaved[f * 8 + 1] = procR[f]
                interleaved[f * 8 + 2] = dry.buffers[0][f]
                interleaved[f * 8 + 3] = dry.buffers[1][f]
                interleaved[f * 8 + 4] = 0; interleaved[f * 8 + 5] = 0
                interleaved[f * 8 + 6] = 0; interleaved[f * 8 + 7] = 0
            }
        }
        return noErr
    }

    // MARK: - Plugin management

    /// All installed effect AU components ('aufx').
    static func listPlugins() -> [(name: String, desc: AudioComponentDescription)] {
        var cd = AudioComponentDescription(componentType: fourCC("aufx"), componentSubType: 0,
                                           componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        var out: [(String, AudioComponentDescription)] = []
        var comp = AudioComponentFindNext(nil, &cd)
        while let c = comp {
            var name: Unmanaged<CFString>?
            var d = AudioComponentDescription()
            if AudioComponentCopyName(c, &name) == noErr,
               AudioComponentGetDescription(c, &d) == noErr {
                out.append((name?.takeUnretainedValue() as String? ?? "AU Effect", d))
            }
            comp = AudioComponentFindNext(c, &cd)
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Pick the outs 1‑2 plugin (nil = dry).
    func setPlugin(_ desc: AudioComponentDescription?) {
        let wasRunning = running
        if running { stop() }
        if let desc {
            do {
                try instantiatePlugin(desc)
                pluginName = Self.name(for: desc)
                UserDefaults.standard.set(Self.descKey(desc), forKey: "insertPluginDesc")
                QBLog.log("insert: plugin set to \(pluginName ?? "?")")
            } catch {
                QBLog.log("insert: plugin instantiate failed — \(error.localizedDescription)")
                pluginName = nil
                UserDefaults.standard.removeObject(forKey: "insertPluginDesc")
            }
        } else {
            pluginName = nil
            UserDefaults.standard.removeObject(forKey: "insertPluginDesc")
        }
        if wasRunning { start() }
        onStateChange?()
    }

    func setBypass(_ on: Bool) {
        pluginBypass = on
        UserDefaults.standard.set(on, forKey: "insertPluginBypass")
        effect?.bypass = on
        QBLog.log("insert: bypass \(on ? "on" : "off")")
        onStateChange?()
    }

    static func name(for desc: AudioComponentDescription) -> String {
        let key = descKey(desc)
        return listPlugins().first { descKey($0.desc) == key }?.name ?? "AU Effect"
    }

    /// Four-char-code from a 4-character string ("aufx" → 'aufx').
    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Stable "type.subtype.manufacturer" key for persistence.
    static func descKey(_ d: AudioComponentDescription) -> String {
        func s(_ v: UInt32) -> String {
            withUnsafeBytes(of: v.bigEndian) { String(decoding: $0, as: UTF8.self) }
        }
        return "\(s(d.componentType)).\(s(d.componentSubType)).\(s(d.componentManufacturer))"
    }

    private func instantiatePlugin(_ desc: AudioComponentDescription) throws {
        if let old = effect, let oldDesc = pluginDesc {
            Self.savePluginState(desc: oldDesc, effect: old)
        }
        if let engine { engine.stop() }
        engine = nil
        sourceNode = nil
        effect = nil

        let effect = AVAudioUnitEffect(audioComponentDescription: desc)

        let engine = AVAudioEngine()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 2, interleaved: false)!
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            guard let self, let dry = self.dry else {
                Self.fillZero(abl, Int(frames))
                return noErr
            }
            self.sourcePulls += 1
            let n = min(Int(frames), self.chunkFrames)
            let off = self.chunkOffset
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if list.count >= 2 {
                if let l = list[0].mData?.assumingMemoryBound(to: Float.self) {
                    l.update(from: dry.buffers[0] + off, count: n)
                }
                if let r = list[1].mData?.assumingMemoryBound(to: Float.self) {
                    r.update(from: dry.buffers[1] + off, count: n)
                }
            } else if list.count == 1, let il = list[0].mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<n {
                    il[f * 2] = dry.buffers[0][off + f]
                    il[f * 2 + 1] = dry.buffers[1][off + f]
                }
            }
            return noErr
        }
        engine.attach(src)
        engine.attach(effect)
        engine.connect(src, to: effect, format: fmt)
        engine.connect(effect, to: engine.mainMixerNode, format: fmt)
        // NOTE: offline manual mode + renderOffline — macOS 27.0.1's
        // manualRenderingBlock returns paramErr (-50) in both modes,
        // while the renderOffline path renders fine (verified live).
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
        engine.prepare()
        try engine.start()

        effect.bypass = pluginBypass

        procBufL = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        procBufR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        procBufL?.initialize(repeating: 0, count: 4096)
        procBufR?.initialize(repeating: 0, count: 4096)

        self.engine = engine
        self.sourceNode = src
        self.effect = effect
        self.pluginDesc = desc
        self.pluginName = Self.name(for: desc)
        self.renderBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)

        // quick sanity render (main thread, before IO starts)
        if let renderBuffer, let st = try? engine.renderOffline(512, to: renderBuffer) {
            QBLog.log("insert: plugin sanity render \(st == .success ? "ok (\(renderBuffer.frameLength) frames)" : "failed")")
        }
    }

    private static func fillZero(_ abl: UnsafeMutablePointer<AudioBufferList>, _ frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for b in 0..<list.count {
            if let d = list[b].mData { memset(d, 0, frames * 4) }
        }
    }

    private static func pluginStateKey(_ d: AudioComponentDescription) -> String {
        "insertPluginState." + descKey(d)
    }

    private static func savePluginState(desc: AudioComponentDescription, effect: AVAudioUnitEffect) {
        let unit = effect.audioUnit
        var state: CFMutableDictionary?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo,
                                   kAudioUnitScope_Global, 0, &state, &size) == noErr,
              let state else { return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: state as NSDictionary,
                                                        requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: pluginStateKey(desc))
        }
    }

    // MARK: - Plugin UI

    func showPluginUI() {
        guard let effect else { return }
        let unit = effect.audioUnit

        var view: NSView?

        // 1) the plugin's custom view (kAudioUnitProperty_CocoaUI).
        //    The struct is read raw (Swift mis-imports the class array),
        //    and JUCE view classes are registered at runtime — try both
        //    NSClassFromString and the ObjC runtime, then the AUv2
        //    uiViewForAudioUnit:withSize: protocol.
        view = Self.makeCustomView(unit: unit, log: { QBLog.log($0) })

        // 2) fallback: generic parameter view (always available)
        if view == nil {
            view = Self.makeGenericView(for: effect, log: { QBLog.log($0) })
        }

        guard let view else {
            let alert = NSAlert()
            alert.messageText = "\(pluginName ?? "The plugin") exposes no editable view."
            alert.runModal()
            return
        }
        viewWindow?.close()
        var frame = view.bounds
        if frame.isEmpty { frame = NSRect(x: 0, y: 0, width: 900, height: 620) }
        let window = NSWindow(contentRect: frame,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = pluginName ?? "AU Plugin"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        // menubar apps need this to bring their windows forward
        NSApp.activate(ignoringOtherApps: true)
        viewWindow = window
    }

    /// The plugin's custom Cocoa UI: resolve the (often dynamically
    /// registered) JUCE view class, then drive the AUv2 view protocol.
    private static func makeCustomView(unit: AudioUnit, log: (String) -> Void) -> NSView? {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
        raw.initializeMemory(as: UInt64.self, repeating: 0, count: 2)
        defer { raw.deallocate() }
        var size = UInt32(16)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI,
                                   kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let bundlePtr = raw.assumingMemoryBound(to: UnsafeRawPointer?.self)[0]
        let classArrayPtr = (raw + 8).assumingMemoryBound(to: UnsafeRawPointer?.self)[0]
        guard let bundlePtr, let classArrayPtr else { return nil }
        let bundleURL = Unmanaged<CFURL>.fromOpaque(bundlePtr).takeUnretainedValue() as URL
        let classArray = Unmanaged<CFArray>.fromOpaque(classArrayPtr).takeUnretainedValue()
        var classNames: [String] = []
        for i in 0..<CFArrayGetCount(classArray) {
            if let p = CFArrayGetValueAtIndex(classArray, i) {
                classNames.append(Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
            }
        }
        guard let className = classNames.first else { return nil }
        log("insert: CocoaUI class=\(className) bundle=\(bundleURL.lastPathComponent)")

        // JUCE registers its view class at runtime in-process; try both lookups
        var cls: AnyClass? = NSClassFromString(className)
        if cls == nil, let c = className.cString(using: .utf8),
           let o = objc_getClass(c) as? AnyClass {
            cls = o
            log("insert: NSClassFromString miss, objc_getClass=\(true)")
        }
        guard let cls else {
            log("insert: custom view class not registered in-process — falling back to generic UI")
            return nil
        }

        let instance: NSObject = (cls as! NSObject.Type).init()
        let sel = sel_registerName("uiViewForAudioUnit:withSize:")
        if class_getInstanceMethod(cls, sel) != nil {
            // -(NSView*)uiViewForAudioUnit:(AudioUnit)withSize:(NSSize)
            typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer, CGSize) -> AnyObject?
            let imp = method_getImplementation(class_getInstanceMethod(cls, sel)!)
            let fn = unsafeBitCast(imp, to: Fn.self)
            if let v = fn(instance, sel, UnsafeMutableRawPointer(unit), CGSize(width: 1000, height: 650)) as? NSView {
                log("insert: custom view via uiViewForAudioUnit ok (\(v))")
                return v
            }
        }
        // plain NSView subclass (non-JUCE AUv2 views)
        if let v = instance as? NSView, !v.subviews.isEmpty {
            log("insert: custom view direct (\(v))")
            return v
        }
        return nil
    }

    /// Generic parameter UI from the AU's parameter tree (always works).
    private static func makeGenericView(for effect: AVAudioUnitEffect, log: (String) -> Void) -> NSView? {
        let au = effect.auAudioUnit
        guard let tree = au.parameterTree else {
            log("insert: generic view unavailable (no parameter tree)")
            return nil
        }
        let params = tree.allParameters
        InsertServer.shared.genericParams = params
        log("insert: generic view, \(params.count) parameters")

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 24 + params.count * 48))
        for (i, param) in params.enumerated() {
            let y = CGFloat(params.count - 1 - i) * 48
            let label = NSTextField(labelWithString: param.identifier ?? "param")
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.frame = NSRect(x: 16, y: y + 26, width: 428, height: 14)
            let value = NSTextField(labelWithString: Self.fmt(param.value, unit: param.unit))
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .right
            value.frame = NSRect(x: 16, y: y + 26, width: 428, height: 14)

            let slider = NSSlider(value: Double(param.value), minValue: Double(param.minValue),
                                  maxValue: Double(param.maxValue), target: nil,
                                  action: nil)
            slider.frame = NSRect(x: 16, y: y, width: 428, height: 20)
            slider.target = InsertServer.shared
            slider.action = #selector(InsertServer.shared.sliderChanged(_:))
            slider.identifier = NSUserInterfaceItemIdentifier("param:\(i)")
            content.addSubview(label)
            content.addSubview(slider)
        }
        content.autoresizingMask = [.width, .height]
        return content
    }

    /// Generic-view parameter list (identifier → AUParameter).
    private var genericParams: [AUParameter] = []

    /// Generic-view slider action: apply the new value to the parameter.
    @objc func sliderChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("param:"),
              let idx = Int(id.dropFirst(6)), genericParams.indices.contains(idx) else { return }
        genericParams[idx].value = Float(sender.doubleValue)
    }

    private static func fmt(_ v: Float, unit: AudioUnitParameterUnit) -> String {
        switch unit {
        case .percent: return String(format: "%.0f%%", v)
        case .decibels: return String(format: "%.1f dB", v)
        case .hertz: return String(format: "%.0f Hz", v)
        case .seconds: return String(format: "%.3f s", v)
        default: return String(format: "%.2f", v)
        }
    }

    // MARK: - CoreAudio helpers

    private enum InsertError: LocalizedError {
        case other(String)

        var errorDescription: String? {
            if case .other(let m) = self { return m }
            return nil
        }
    }

    private static func check(_ err: OSStatus, _ what: String) throws {
        guard err == noErr else { throw InsertError.other("\(what) failed (err \(err))") }
    }

    private static func deviceUID(_ dev: AudioDeviceID) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var uid = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "device UID")
        return uid as String
    }

    private static func deviceRate(_ dev: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var r = 48000.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r) == noErr else { return 48000 }
        return r
    }

    /// Our own process object id — the tap excludes it, so our processed
    /// output isn't re-captured (feedback) and isn't muted.
    private static func ownProcessObjectID() throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = Int32(getpid())
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<Int32>.size), &pid, &size, &obj),
                  "pid→process object")
        return obj
    }

    /// Frames in the first buffer of a list (float32).
    private static func frames(of abl: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let b = list.first else { return 0 }
        let ch = max(1, Int(b.mNumberChannels))
        return Int(b.mDataByteSize) / 4 / ch
    }

    /// Detailed layout + peak logging (throttled) for debugging.
    private static func describe(_ abl: UnsafeMutablePointer<AudioBufferList>) -> String {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        return list.map { b in
            let ch = b.mNumberChannels
            let frames = b.mDataByteSize / 4 / max(1, ch)
            var peak: Float = 0
            if let d = b.mData?.assumingMemoryBound(to: Float.self) {
                for i in stride(from: 0, to: Int(b.mDataByteSize) / 4, by: max(1, Int(ch))) {
                    let v = abs(d[i])
                    if v > peak { peak = v }
                }
            }
            return "\(ch)ch/\(frames)f peak=\(peak)"
        }.joined(separator: " | ")
    }

    private static func copyStereo(into list: UnsafeMutableAudioBufferListPointer, base: Int,
                                    l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>,
                                    frames: Int) {
        guard list.count > base + 1,
              let dl = list[base].mData?.assumingMemoryBound(to: Float.self),
              let dr = list[base + 1].mData?.assumingMemoryBound(to: Float.self) else { return }
        dl.update(from: l, count: frames)
        dr.update(from: r, count: frames)
    }

    private static func clear(_ b: AudioBuffer, _ frames: Int) {
        if let d = b.mData { memset(d, 0, frames * 4) }
    }
}

/// A non-interleaved stereo AudioBufferList with its own storage.
private final class StereoABL {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    var buffers: [UnsafeMutablePointer<Float>] = []

    var list: UnsafeMutablePointer<AudioBufferList> { pointer }

    init(frames: Int) {
        let size = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)! + 2 * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        pointer = raw.assumingMemoryBound(to: AudioBufferList.self)
        pointer.pointee.mNumberBuffers = 2
        for c in 0..<2 {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: 0, count: frames)
            buffers.append(p)
            let bp = UnsafeMutableRawPointer(pointer) + MemoryLayout<AudioBuffer>.stride * c
            let ab = bp.assumingMemoryBound(to: AudioBuffer.self)
            ab.pointee.mNumberChannels = 1
            ab.pointee.mDataByteSize = UInt32(frames * 4)
            ab.pointee.mData = UnsafeMutableRawPointer(p)
        }
    }

    deinit {
        for b in buffers { b.deallocate() }
        pointer.deallocate()
    }
}