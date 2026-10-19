import Foundation
import CoreAudio
import AudioToolbox
import AudioUnit
import AVFAudio
import CoreAudioKit
import ObjectiveC
import AppKit

/// The AU insert engine: real-time plugin processing on the Quartet's 4
/// stereo output pairs, with per-pair routing.
///
/// Architecture:
///
///   all system audio (bound for the Quartet — default output unchanged)
///      ↓  CATap — stereo tap on Quartet stream 0, EXCLUDES this process,
///         muteBehavior = .muted (true insert, no feedback loop)
///   private aggregate device (master: Quartet, taps: [tap])
///      ↓  one IOProc
///         4 stereo chains, one per output pair (1‑2 / 3‑4 / 5‑6 / 7‑8):
///            source (system mix / copy of another pair / off)
///            → AU plugin chain (or dry when bypassed / absent)
///            → that pair's hardware channels
///
/// The system default output stays "Quartet", so the volume-keys / fader /
/// mute bindings in OSVolumeMirror are unaffected.
final class InsertServer: NSObject {

    static let shared = InsertServer()

    /// Fired on the main thread whenever state changed (menu refresh).
    var onStateChange: (() -> Void)?

    private(set) var running = false

    /// True until the tap delivers a non-silent cycle while running —
    /// the signature of macOS denying the System Audio Recording
    /// permission (it silences taps instead of failing them).
    private(set) var tapSilent = true

    // MARK: - The 4 stereo pairs

    static let pairNames = [
        "Out 1‑2",
        "Out 3‑4",
        "Out 5‑6",
        "Out 7‑8",
    ]

    enum PairSource: String {
        case systemMix = "mix"
        case off = "off"
        case copy0 = "copy:0"
        case copy1 = "copy:1"
        case copy2 = "copy:2"
        case copy3 = "copy:3"

        var label: String {
            switch self {
            case .systemMix: return "No routing"
            case .off: return "Off (silent)"
            case .copy0: return "Out 1‑2"
            case .copy1: return "Out 3‑4"
            case .copy2: return "Out 5‑6"
            case .copy3: return "Out 7‑8"
            }
        }

        /// The pair this source copies from (nil = not a copy).
        var copyIndex: Int? {
            switch self {
            case .copy0: return 0
            case .copy1: return 1
            case .copy2: return 2
            case .copy3: return 3
            default: return nil
            }
        }

        static func copy(_ i: Int) -> PairSource {
            PairSource(rawValue: "copy:\(i)")!
        }
    }

    struct Pair {
        var source: PairSource = .systemMix
        /// Plugin processing enabled for this pair (bypass = raw passthrough).
        var enabled = true
        /// For mirrored sources: copy BEFORE the source pair's plug-in
        /// (raw playback channels) or AFTER (its processed output).
        var mirrorPre = true
        /// Input trim in dB (−64…+6, 0 = unity) — applied to the pair's
        /// input before its plug-in chain. Routing-level: unaffected by
        /// bypassAll.
        var trim: Float = 0
        // runtime (main thread only)
        var engine: AVAudioEngine?
        var srcNode: AVAudioSourceNode?
        var effect: AVAudioUnitEffect?
        var renderBuffer: AVAudioPCMBuffer?
        /// this pair's rendered output storage (audio thread reads)
        var proc: StereoABL?
        /// scaled input storage when trim != 0 dB (audio thread reads)
        var level: StereoABL?
        var pluginName: String?
        var desc: AudioComponentDescription?
        var viewInfo: (bundleURL: URL, classNames: [String])?
        var viewPrefetchState: Int = 0   // 0 idle, 1 running, 2 done
    }

    private(set) var pairs: [Pair] = [Pair(), Pair(), Pair(), Pair()]

    // MARK: - Core Audio plumbing

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48000
    /// The tapped system stream, deinterleaved: 8 mono channels =
    /// 4 stereo pairs (pair i = channels 2i, 2i+1).
    private var sys: StereoABL!


    // MARK: - Audio-thread state

    private var cycleCount = 0
    private var sourcePulls = 0
    private var lastLoggedPulls = 0
    private var lastLogTime: UInt64 = 0
    private let logIntervalTicks: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 5_000_000_000 * UInt64(info.numer) / UInt64(info.denom)   // ~5 s
    }()
    /// The chain currently rendering (its source pointers, chunk state).
    private var chainSrcL: UnsafeMutablePointer<Float>?
    private var chainSrcR: UnsafeMutablePointer<Float>?
    private var chainOffset = 0
    private var chainFrames = 0

    // MARK: - Buffer size (latency)

    /// Supported IO slice sizes (frames @ 48 kHz → ms).
    static let bufferChoices: [(frames: Int, label: String)] = [
        (32, "32 — 0.7 ms"),
        (64, "64 — 1.3 ms"),
        (128, "128 — 2.7 ms"),
        (256, "256 — 5.3 ms"),
        (512, "512 — 10.7 ms"),
    ]
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

    // MARK: - Persistence

    private static func sourceKey(_ i: Int) -> String { "insertPair.\(i).source" }
    private static func pluginKey(_ i: Int) -> String { "insertPair.\(i).plugin" }
    private static func enabledKey(_ i: Int) -> String { "insertPair.\(i).enabled" }
    private static func mirrorKey(_ i: Int) -> String { "insertPair.\(i).mirror" }
    private static let bypassAllKey = "insertBypassAll"
    private static func trimKey(_ i: Int) -> String { "insertPair.\(i).trim" }
    /// Linear gain factors per pair (10^(dB/20)), main-side writes.
    private var trimFactors: [Float] = [1, 1, 1, 1]
    /// Global override: all plug-ins bypassed (per-pair state untouched).
    private(set) var bypassAll = UserDefaults.standard.bool(forKey: "insertBypassAll")
    private static func pluginStateKey(_ d: AudioComponentDescription, _ i: Int) -> String {
        "insertPluginState.\(descKey(d)).\(i)"
    }

    private func loadPairs() {
        pairs = (0..<4).map { i in
            var p = Pair()
            // Default (v5): "No routing" everywhere — every pair just gets
            // the dry mix (copies are pre-plugin, so all inputs are the
            // same mix anyway; routing only matters cross-pair).
            p.source = .systemMix
            if let s = UserDefaults.standard.string(forKey: Self.sourceKey(i)),
               let src = PairSource(rawValue: s) {
                // v4 self-copies ("copy:i" on pair i) mean the same as no
                // routing — normalize them away
                p.source = (src.copyIndex == i) ? .systemMix : src
            }
            // one-time migration to v5 defaults ("insertRouting.v4" is the
            // v4 flag; self-copies above already normalize). Written
            // directly — `pairs` is mid-rebuild.
            if !UserDefaults.standard.bool(forKey: "insertRouting.v5") {
                UserDefaults.standard.set(true, forKey: "insertRouting.v5")
                if i > 0 { p.source = .systemMix }
                UserDefaults.standard.set(p.source.rawValue, forKey: Self.sourceKey(i))
            }
            // enabled (v6): migrate old "bypass" (true = no processing)
            if UserDefaults.standard.object(forKey: Self.enabledKey(i)) != nil {
                p.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey(i))
            } else if UserDefaults.standard.object(forKey: "insertPair.\(i).bypass") != nil {
                p.enabled = !UserDefaults.standard.bool(forKey: "insertPair.\(i).bypass")
            }
            // mirror point: before (default) / after the source plug-in
            if let m = UserDefaults.standard.string(forKey: Self.mirrorKey(i)) {
                p.mirrorPre = (m == "before")
            }
            // input trim (Level) — clamp to −64…+6 dB
            let savedTrim = UserDefaults.standard.double(forKey: Self.trimKey(i))
            if savedTrim != 0 {
                p.trim = Float(min(6, max(-64, savedTrim)))
            }
            // migrate the v1 single-plugin settings to pair 0
            if i == 0, UserDefaults.standard.string(forKey: Self.pluginKey(0)) == nil,
               let old = UserDefaults.standard.string(forKey: "insertPluginDesc") {
                UserDefaults.standard.set(old, forKey: Self.pluginKey(0))
                if UserDefaults.standard.bool(forKey: "insertPluginBypass") {
                    UserDefaults.standard.set(false, forKey: Self.enabledKey(0))
                }
            }
            return p
        }
        trimFactors = pairs.map { pow(10, $0.trim / 20) }
    }

    private func saveSource(_ i: Int) {
        UserDefaults.standard.set(pairs[i].source.rawValue, forKey: Self.sourceKey(i))
    }

    // MARK: - Lifecycle

    func setRunning(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private var startRetries = 0
    private var lastStartAttempt: TimeInterval = 0

    func start() {
        guard !running else { return }
        // a fresh burst of retries whenever a new event (wake, replug)
        // triggers a start more than 5 s after the previous attempt
        let now = Date().timeIntervalSince1970
        if now - lastStartAttempt > 5 { startRetries = 0 }
        lastStartAttempt = now
        do {
            try build()
            startRetries = 0
            running = true
            QBLog.log("insert: running (\((0..<4).map { routeSummaryInner($0) }.joined(separator: " · ")), \(Int(sampleRate)) Hz, buffer \(Self.savedBufferFrames()) frames)")
        } catch {
            QBLog.log("insert: start failed — \(error.localizedDescription)")
            teardown()
            running = false
            // races at relaunch (previous instance still releasing the
            // device) — retry briefly, then give up until replug
            if startRetries < 6 {
                startRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.start()
                }
            }
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
        loadPairs()
        resolveRoutes()

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

        // 2) the aggregate: tap as input, Quartet (master) as output.
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

        // Latency: 32 frames default (see bufferChoices).
        var bufAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        let requested = UInt32(Self.savedBufferFrames())
        var bufFrames = requested
        let bufErr = AudioObjectSetPropertyData(agg, &bufAddr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &bufFrames)
        var granted = UInt32(0)
        var gSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(agg, &bufAddr, 0, nil, &gSize, &granted) == noErr, granted != requested {
            QBLog.log("insert: buffer \(requested) not granted — HAL gave \(granted)")
        } else if bufErr != noErr {
            QBLog.log("insert: buffer size set err \(bufErr)")
        }

        // 3) system buffer, per-pair level buffers + one engine per pair
        sys = StereoABL(frames: 4096, channels: 8)
        for i in 0..<4 { pairs[i].level = StereoABL(frames: 4096) }
        for i in 0..<4 {
            if let key = UserDefaults.standard.string(forKey: Self.pluginKey(i)),
               let d = Self.listPlugins().first(where: { Self.descKey($0.desc) == key })?.desc {
                do { try instantiatePlugin(i, d) } catch {
                    QBLog.log("insert: pair \(i) plugin failed to load (\(key)) — dry. \(error)")
                }
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
        for i in 0..<4 {
            if let d = pairs[i].desc, let effect = pairs[i].effect {
                Self.savePluginState(i: i, desc: d, effect: effect)
            }
            pairs[i].engine?.stop()
            pairs[i].engine = nil
            pairs[i].srcNode = nil
            pairs[i].effect = nil
            pairs[i].renderBuffer = nil
            pairs[i].proc = nil
            pairs[i].level = nil
            pairs[i].desc = nil
            pairs[i].pluginName = nil
            pairs[i].viewInfo = nil
        }
        // editor windows hold views owned by the (now disposed) AUs — close
        viewWindow.values.forEach { $0.close() }
        viewWindow = [:]
        hiddenViews = [:]
        sys = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    // MARK: - Route resolution (main-side)

    /// A pair's resolved input: pair `src`'s raw playback channels
    /// (pre) or rendered output (post — mirror AFTER the source's
    /// plug-in). `nil` = silence (Off or a routing cycle).
    struct Route {
        var src: Int?
        var post = false
    }

    /// The tap captures the Quartet's FULL 8-channel stream — 4 stereo
    /// pairs. Pair i's own channels = (2i, 2i+1): whatever apps send to
    /// pair i. Mirrors copy a source pair's raw channels (before) or
    /// its processed output (after). Cycles resolve to silence, never
    /// in the audio thread.
    private(set) var routes: [Route] = [Route(src: 0), Route(src: 1), Route(src: 2), Route(src: 3)]

    /// Render order (post-mirrors render after their source).
    private var renderOrder: [Int] = [0, 1, 2, 3]

    private func resolveRoutes() {
        var routes = [Route?](repeating: nil, count: 4)
        var order: [Int] = []
        var state = [Int](repeating: 0, count: 4)   // 0 new, 1 in-stack, 2 done
        func resolve(_ i: Int, _ stack: Set<Int>) -> Route {
            if let r = routes[i] { return r }
            var r = Route(src: nil)
            switch pairs[i].source {
            case .off:
                break
            case .systemMix:
                r = Route(src: i)                       // own playback channels
            default:
                guard let j = pairs[i].source.copyIndex else { break }
                if j == i {
                    r = Route(src: i)                   // self == own channels
                } else if pairs[i].mirrorPre {
                    r = Route(src: j)                    // source's raw channels
                } else {
                    // AFTER the source's plug-in: the source's rendered
                    // output — source renders first (order), silence flows
                    if state[j] == 1 {
                        QBLog.log("insert: routing cycle at pair \(i) — silence")
                        routes[i] = Route(src: nil)
                        return routes[i]!
                    }
                    let rj = resolve(j, stack.union([i]))
                    r = Route(src: rj.src, post: rj.src != nil)
                }
            }
            routes[i] = r
            return r
        }
        func orderVisit(_ i: Int) -> Bool {   // false = cycle
            switch state[i] {
            case 2: return true
            case 1: return false
            default: break
            }
            state[i] = 1
            var ok = true
            if pairs[i].source != .off, let j = pairs[i].source.copyIndex,
               j != i, !pairs[i].mirrorPre, j != i {
                ok = orderVisit(j)
            }
            state[i] = 2
            order.append(i)
            return ok
        }
        for i in 0..<4 { _ = resolve(i, [i]) }
        for i in 0..<4 where order.firstIndex(of: i) == nil { order.append(i) }
        // stable, dependency-first order:
        var ordered: [Int] = []
        var seen = Set<Int>()
        func add(_ i: Int) {
            if seen.contains(i) { return }
            seen.insert(i)
            if pairs[i].source != .off, let j = pairs[i].source.copyIndex,
               j != i, !pairs[i].mirrorPre { add(j) }
            ordered.append(i)
        }
        for i in 0..<4 { add(i) }
        self.routes = routes.map { $0 ?? Route(src: nil) }
        renderOrder = ordered
    }

    /// Label for a source option in pair i's picker.
    static func sourceLabel(_ src: PairSource, for i: Int) -> String {
        if src == .off { return "Silence" }
        if src == .systemMix { return "Playback \(2 * i + 1)–\(2 * i + 2)" }
        if let j = src.copyIndex { return "Mirror Out \(2 * j + 1)–\(2 * j + 2)" }
        return "Silence"
    }

    /// Source options for pair i (own playback + mirrors + silence).
    static func sourceOptions(_ i: Int) -> [PairSource] {
        [.systemMix] + [0, 1, 2, 3].filter { $0 != i }.map { PairSource.copy($0) } + [.off]
    }

    /// Human route summary (mirrors label with before/after).
    func routeSummary(_ i: Int) -> String {
        guard let src = routes[i].src else { return "Silence" }
        if src == i { return "Playback \(2 * i + 1)–\(2 * i + 2)" }
        let srcName = "Out \(2 * src + 1)–\(2 * src + 2)"
        let point = pairs[i].mirrorPre ? "before" : "after"
        return "Mirror \(srcName) (\(point) its plug-in)"
    }

    /// Signal-flow line for the Outputs window, e.g.
    /// "Playback 1–2 → ARC X → Out 1–2" /
    /// "Playback 1–2 → Out 1–2 plug-in → Out 3–4".
    func flowLine(_ i: Int) -> String {
        guard let src = routes[i].src else { return "Silence → Out \(2 * i + 1)–\(2 * i + 2)" }
        var parts: [String] = []
        if routes[i].post {
            let srcPlugin = pairs[src].pluginName.map(Self.shortName) ?? "no plug-in"
            parts.append("Playback \(2 * src + 1)–\(2 * src + 2)")
            parts.append("\(srcPlugin) (Out \(2 * src + 1)–\(2 * src + 2))")
        } else {
            parts.append("Playback \(2 * src + 1)–\(2 * src + 2)")
        }
        if let pl = pairs[i].pluginName, pairs[i].enabled, !bypassAll {
            parts.append(Self.shortName(pl))
        }
        parts.append("Out \(2 * i + 1)–\(2 * i + 2)")
        return parts.joined(separator: " → ")
    }

    /// "IK Multimedia: ARC X" → "ARC X" (unchanged when no company).
    static func shortName(_ name: String) -> String {
        if let r = name.range(of: ": ") { return String(name[r.upperBound...]) }
        return name
    }

    private func routeSummaryInner(_ i: Int) -> String {
        "\(Self.pairNames[i]): \(routeSummary(i))"
    }

    func mirrorPre(_ i: Int) -> Bool { pairs[i].mirrorPre }
    func enabled(_ i: Int) -> Bool { pairs[i].enabled }
    /// Current device sample rate (48000 by default before start).
    func currentRate() -> Double { sampleRate }

    // MARK: - The IO cycle

    /// One IO cycle on the aggregate: tap input (stereo) → 4 chains →
    /// the Quartet's 8 output channels. Audio thread: no allocation.
    private func cycle(_ inInputData: UnsafePointer<AudioBufferList>?,
                       _ outOutputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let out = outOutputData, sys != nil else { return noErr }
        let frames = Self.frames(of: out)
        guard frames > 0, frames <= 4096 else { return noErr }

        // 1) the tapped FULL 8-channel system stream → 4 stereo pairs.
        //    Pair i's own channels = (2i, 2i+1): whatever apps send to
        //    pair i (DAW addressing Out 3‑4, etc.) lives here.
        if let inp = inInputData {
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
            var tap: AudioBuffer?
            if inList.count == 1, inList[0].mNumberChannels == 2 {
                tap = inList[0]
            } else {
                for b in inList where b.mNumberChannels == 8 || b.mNumberChannels == 2 {
                    tap = b; break
                }
            }
            if let tap, let d = tap.mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(tap.mNumberChannels))
                let n = min(frames, Int(tap.mDataByteSize) / 4 / ch)
                if ch == 2 {
                    // stereo mixdown tap: pairs 1‑3 have no own channels —
                    // all pairs hear the mix (legacy behavior)
                    sys.buffers[0].update(from: d, count: n)
                    sys.buffers[1].update(from: d + 1, count: n)
                    for c in 2..<8 { sys.buffers[c].update(from: d + (c % 2), count: n) }
                } else {
                    for f in 0..<n {
                        for c in 0..<8 { sys.buffers[c][f] = d[f * ch + c] }
                    }
                }
                if n < frames {
                    for c in 0..<8 { for f in n..<frames { sys.buffers[c][f] = 0 } }
                }
            } else {
                for c in 0..<8 { for f in 0..<frames { sys.buffers[c][f] = 0 } }
            }
        } else {
            for c in 0..<8 { for f in 0..<frames { sys.buffers[c][f] = 0 } }
        }

        // tap health (cheap check)
        if tapSilent, sys.buffers[0][0] != 0 || sys.buffers[1][0] != 0 {
            tapSilent = false
            QBLog.log("insert: tap is live (first non-silent cycle)")
            DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
        }

        // 2) render the 4 chains in dependency order — each pair's input
        //    = its route: the source pair's raw playback channels (pre)
        //    or its rendered output (post-mirror), or silence.
        var outL: [UnsafeMutablePointer<Float>?] = [nil, nil, nil, nil]
        var outR: [UnsafeMutablePointer<Float>?] = [nil, nil, nil, nil]
        for i in renderOrder {
            let p = pairs[i]
            let route = routes[i]
            guard let src = route.src else { continue }   // off / cycle → silent
            if route.post, let l = outL[src], let r = outR[src] {
                outL[i] = l; outR[i] = r       // mirror AFTER source's plug-in
            } else {
                outL[i] = sys.buffers[src * 2]  // raw playback channels
                outR[i] = sys.buffers[src * 2 + 1]
            }
            // input trim (Level): scaled copy into the pair's own buffer —
            // never in place (sys/mirror buffers are shared). Unity (0 dB)
            // skips the copy entirely.
            let f = trimFactors[i]
            if f != 1.0, let lab = p.level, let l = outL[i], let r = outR[i] {
                let labL = lab.buffers[0], labR = lab.buffers[1]
                for fr in 0..<frames {
                    labL[fr] = l[fr] * f
                    labR[fr] = r[fr] * f
                }
                outL[i] = labL
                outR[i] = labR
            }
            // plugin chain (in 512-frame chunks — the renderOffline path;
            // see instantiatePlugin for why manual mode at all)
            if let effect = p.effect, p.enabled, !bypassAll,
               let engine = p.engine, let renderBuffer = p.renderBuffer, let proc = p.proc {
                var offset = 0
                var ok = true
                while offset < frames {
                    let n = min(512, frames - offset)
                    chainSrcL = outL[i]; chainSrcR = outR[i]
                    chainOffset = offset; chainFrames = n
                    if let st = try? engine.renderOffline(AVAudioFrameCount(n), to: renderBuffer),
                       st == .success, renderBuffer.frameLength == AVAudioFrameCount(n),
                       let cl = renderBuffer.floatChannelData?[0],
                       let cr = renderBuffer.floatChannelData?[1] {
                        memcpy(proc.buffers[0] + offset, cl, n * 4)
                        memcpy(proc.buffers[1] + offset, cr, n * 4)
                    } else {
                        ok = false
                        break
                    }
                    offset += n
                }
                if ok {
                    outL[i] = proc.buffers[0]
                    outR[i] = proc.buffers[1]
                } else {
                    sourceRenderErr += 1
                    if sourceRenderErr <= 3 || sourceRenderErr % 512 == 0 {
                        QBLog.log("insert: pair \(i) render failed — bypassed this cycle")
                    }
                }
            }
        }

        // 3) write the Quartet's channels: pair i → channels 2i, 2i+1
        let outList = UnsafeMutableAudioBufferListPointer(out)
        if outList.count >= 8 {
            for i in 0..<4 {
                if let l = outL[i], let r = outR[i] {
                    Self.copyMono(into: outList, at: i * 2, from: l, frames)
                    Self.copyMono(into: outList, at: i * 2 + 1, from: r, frames)
                } else {
                    Self.clear(outList[i * 2], frames)
                    Self.clear(outList[i * 2 + 1], frames)
                }
            }
        } else if outList.count == 1, let interleaved = outList[0].mData?.assumingMemoryBound(to: Float.self) {
            for f in 0..<frames {
                for i in 0..<4 {
                    interleaved[f * 8 + i * 2] = outL[i]?[f] ?? 0
                    interleaved[f * 8 + i * 2 + 1] = outR[i]?[f] ?? 0
                }
            }
        }

        // 4) throttled diagnostics
        cycleCount += 1
        let now = mach_absolute_time()
        if lastLogTime == 0 { lastLogTime = now }
        if cycleCount < 3 || now - lastLogTime > logIntervalTicks {
            lastLogTime = now
            var dryPeak: Float = 0
            for f in 0..<frames { let v = abs(sys.buffers[0][f]); if v > dryPeak { dryPeak = v } }
            QBLog.log("insert: cycle #\(cycleCount) frames=\(frames) dryPeak=\(dryPeak) pulls=\(sourcePulls - lastLoggedPulls)")
            lastLoggedPulls = sourcePulls
        }
        return noErr
    }

    private var sourceRenderErr = 0

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

    /// Four-char-code from a 4-character string ("aufx").
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

    static func name(for desc: AudioComponentDescription) -> String {
        let key = descKey(desc)
        return listPlugins().first { descKey($0.desc) == key }?.name ?? "AU Effect"
    }

    /// Set a pair's plugin (nil = dry). Rebuilds that pair's chain.
    func setPlugin(_ i: Int, _ desc: AudioComponentDescription?) {
        if let d = pairs[i].desc, let e = pairs[i].effect {
            Self.savePluginState(i: i, desc: d, effect: e)
        }
        pairs[i].engine?.stop()
        pairs[i].engine = nil; pairs[i].srcNode = nil
        pairs[i].effect = nil; pairs[i].renderBuffer = nil; pairs[i].proc = nil
        pairs[i].pluginName = nil; pairs[i].desc = nil; pairs[i].viewInfo = nil
        // the old view belongs to the disposed AU — drop the window
        viewWindow[i]?.close()
        viewWindow[i] = nil

        if let desc {
            do {
                try instantiatePlugin(i, desc)
                UserDefaults.standard.set(Self.descKey(desc), forKey: Self.pluginKey(i))
                QBLog.log("insert: pair \(i) plugin set to \(pairs[i].pluginName ?? "?")")
            } catch {
                QBLog.log("insert: pair \(i) plugin instantiate failed — \(error.localizedDescription)")
                UserDefaults.standard.removeObject(forKey: Self.pluginKey(i))
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pluginKey(i))
        }
        onStateChange?()
    }

    /// Set a pair's routing source (any pair; default = its own
    /// playback channels).
    func setSource(_ i: Int, _ source: PairSource) {
        pairs[i].source = source
        saveSource(i)
        resolveRoutes()
        QBLog.log("insert: pair \(i) source → \(source.label)")
        onStateChange?()
    }

    /// Enable/disable pair i's plug-in processing (raw passthrough
    /// when disabled — the plug-in stays loaded).
    func setEnabled(_ i: Int, _ on: Bool) {
        pairs[i].enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey(i))
        pairs[i].effect?.bypass = !on || bypassAll
        QBLog.log("insert: pair \(i) processing \(on ? "on" : "off")")
        onStateChange?()
    }

    /// Global override: bypass every plug-in (per-pair state untouched).
    func setBypassAll(_ on: Bool) {
        bypassAll = on
        UserDefaults.standard.set(on, forKey: Self.bypassAllKey)
        for i in 0..<4 { pairs[i].effect?.bypass = on || !pairs[i].enabled }
        QBLog.log("insert: bypass all plug-ins \(on ? "on" : "off")")
        onStateChange?()
    }

    /// Mirror point for pair i: before/after the source pair's plug-in.
    func setMirrorPre(_ i: Int, _ pre: Bool) {
        pairs[i].mirrorPre = pre
        UserDefaults.standard.set(pre ? "before" : "after", forKey: Self.mirrorKey(i))
        resolveRoutes()
        QBLog.log("insert: pair \(i) mirror \(pre ? "before" : "after") source plug-in")
        onStateChange?()
    }

    /// Input trim (Level) for pair i, dB in −64…+6. Applied to the
    /// pair's input before its plug-in; routing-level (unaffected by
    /// Bypass All Plug-ins). Minimum = effective silence.
    func setTrim(_ i: Int, _ db: Double, notify: Bool = true) {
        let clamped = min(6.0, max(-64.0, db))
        pairs[i].trim = Float(clamped)
        UserDefaults.standard.set(clamped, forKey: Self.trimKey(i))
        trimFactors[i] = pow(10, pairs[i].trim / 20)
        if notify { onStateChange?() }
    }

    func trim(_ i: Int) -> Double { Double(pairs[i].trim) }

    func pluginName(_ i: Int) -> String? { pairs[i].pluginName }
    func source(_ i: Int) -> PairSource { pairs[i].source }
    func bypass(_ i: Int) -> Bool { !pairs[i].enabled }

    private func instantiatePlugin(_ i: Int, _ desc: AudioComponentDescription) throws {
        let effect = AVAudioUnitEffect(audioComponentDescription: desc)

        let engine = AVAudioEngine()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 2, interleaved: false)!
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            guard let self, let l = self.chainSrcL, let r = self.chainSrcR else {
                Self.fillZero(abl, Int(frames))
                return noErr
            }
            self.sourcePulls += 1
            let n = min(Int(frames), self.chainFrames)
            let off = self.chainOffset
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if list.count >= 2 {
                if let bl = list[0].mData?.assumingMemoryBound(to: Float.self) {
                    bl.update(from: l + off, count: n)
                }
                if let br = list[1].mData?.assumingMemoryBound(to: Float.self) {
                    br.update(from: r + off, count: n)
                }
            } else if list.count == 1, let il = list[0].mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<n {
                    il[f * 2] = l[off + f]
                    il[f * 2 + 1] = r[off + f]
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

        effect.bypass = !pairs[i].enabled || bypassAll

        let proc = StereoABL(frames: 4096)
        pairs[i].engine = engine
        pairs[i].srcNode = src
        pairs[i].effect = effect
        pairs[i].desc = desc
        pairs[i].pluginName = Self.name(for: desc)
        pairs[i].proc = proc
        pairs[i].renderBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)

        // sanity render (main thread, before IO)
        if let rb = pairs[i].renderBuffer, let st = try? engine.renderOffline(512, to: rb) {
            QBLog.log("insert: pair \(i) sanity render \(st == .success ? "ok" : "failed")")
        }

        // prefetch the custom-view info asynchronously (see showPluginUI)
        prefetchViewInfo(i, unit: effect.audioUnit)
    }

    private static func savePluginState(i: Int, desc: AudioComponentDescription, effect: AVAudioUnitEffect) {
        let unit = effect.audioUnit
        var state: CFMutableDictionary?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo,
                                   kAudioUnitScope_Global, 0, &state, &size) == noErr,
              let state else { return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: state as NSDictionary,
                                                        requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: pluginStateKey(desc, i))
        }
    }

    // MARK: - Plugin UI

    /// Prefetched plugin view info per pair. The CocoaUI property get must
    /// NEVER run from the menu action while our IO cycle renders the AU
    /// (it deadlocks/blocks on some plugins), so we fetch it once async at
    /// plugin load and cache it.
    private func prefetchViewInfo(_ i: Int, unit: AudioUnit) {
        pairs[i].viewPrefetchState = 1
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            self.pairs[i].viewInfo = Self.readCocoaUIInfo(unit: unit)
            self.pairs[i].viewPrefetchState = 2
            DispatchQueue.main.async { self.onStateChange?() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.pairs[i].viewPrefetchState == 1 {
                QBLog.log("insert: pair \(i) view prefetch still stuck after 4 s — generic UI if used")
            }
        }
    }

    /// Read kAudioUnitProperty_CocoaUI (raw: Swift mis-imports the struct).
    /// Returns (bundle URL, view class names) or nil.
    /// NOTE: the class field is usually a CFArray — but some plugins (IK
    /// Multimedia, ARC X) return a single CFString. Type-check first:
    /// CFArray calls on a CFString throw an ObjC exception Swift can't
    /// catch → crash (live-tested).
    static func readCocoaUIInfo(unit: AudioUnit) -> (bundleURL: URL, classNames: [String])? {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
        raw.initializeMemory(as: UInt64.self, repeating: 0, count: 2)
        defer { raw.deallocate() }
        var size = UInt32(16)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI,
                                   kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let bundlePtr = raw.assumingMemoryBound(to: UnsafeRawPointer?.self)[0]
        let classFieldPtr = (raw + 8).assumingMemoryBound(to: UnsafeRawPointer?.self)[0]
        guard let bundlePtr, let classFieldPtr else { return nil }
        let bundleURL = Unmanaged<CFURL>.fromOpaque(bundlePtr).takeUnretainedValue() as URL
        let classObj: AnyObject = Unmanaged<AnyObject>.fromOpaque(classFieldPtr).takeUnretainedValue()
        var classNames: [String] = []
        if CFGetTypeID(classObj) == CFArrayGetTypeID() {
            let classArray = classObj as! CFArray
            for i in 0..<CFArrayGetCount(classArray) {
                if let p = CFArrayGetValueAtIndex(classArray, i) {
                    classNames.append(Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
                }
            }
        } else if CFGetTypeID(classObj) == CFStringGetTypeID() {
            classNames.append(classObj as! String)
        } else {
            return nil
        }
        guard !classNames.isEmpty else { return nil }
        return (bundleURL, classNames)
    }

    /// Show pair i's plugin editor: its custom JUCE/AUv2 view via the
    /// prefetched info, else the generic parameter view.
    ///
    /// The view is created exactly once per plugin instance (plugins'
    /// `uiViewForAudioUnit:` isn't safe to call repeatedly — SIGSEGV,
    /// live-tested). Re-front the existing window instead. NOTE:
    /// NSWindow.close() releases the window (isReleasedWhenClosed), so
    /// we must drop the reference on close or hold a zombie → SIGSEGV.
    func showPluginUI(_ i: Int) {
        if let w = viewWindow[i] {
            // existing editor: reattach the view if it was detached on
            // close (halts the plugin's render loop), then bring it back
            if let v = hiddenViews.removeValue(forKey: w) {
                w.contentView = v
                QBLog.log("insert: pair \(i) editor view reattached")
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let effect = pairs[i].effect else { return }
        let unit = effect.audioUnit

        var view: NSView?
        view = Self.makeCustomView(unit: unit, info: pairs[i].viewInfo, log: { QBLog.log($0) })
        if view == nil {
            view = Self.makeGenericView(i: i, effect: effect, log: { QBLog.log($0) })
        }
        guard let view else {
            let alert = NSAlert()
            alert.messageText = "\(pairs[i].pluginName ?? "The plugin") exposes no editable view."
            alert.runModal()
            return
        }
        var frame = view.bounds
        if frame.isEmpty { frame = NSRect(x: 0, y: 0, width: 900, height: 620) }
        let window = NSWindow(contentRect: frame,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it; close() must not release under us
        window.title = "\(Self.pairNames[i]) — \(pairs[i].pluginName.map(Self.shortName) ?? "AU Plugin")"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewWindow[i] = window
        QBLog.log("insert: pair \(i) editor window created")
    }

    private var viewWindow: [Int: NSWindow] = [:]

    /// Hide instead of destroy on close: the window owns the plugin view
    /// (created exactly once per plugin instance — re-requesting it from
    /// the AU crashes, see showPluginUI). orderOut keeps it alive; a
    /// later "Open" re-fronts it.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        guard viewWindow.values.contains(where: { $0 === w }) else { return }
        // Keep the view alive (re-requesting it from the AU crashes — see
        // showPluginUI) but halt its rendering: JUCE editors run an
        // OpenGL render loop at ~60 fps that burns real CPU while the
        // window is merely hidden (~20-40% live-measured). Detaching the
        // view stops the loop; reattach on the next Open.
        if let view = w.contentView {
            view.removeFromSuperview()
            hiddenViews[w] = view
        }
        w.contentView = nil
        QBLog.log("insert: editor window hidden (view detached, rendering halted)")
    }

    /// Windows whose editor views were detached on close (kept alive —
    /// re-requesting a view from the AU crashes; see showPluginUI).
    private var hiddenViews: [NSWindow: NSView] = [:]

    /// The plugin's custom Cocoa UI from PREFETCHED info (no property
    /// gets here — they deadlock under active rendering), driving the
    /// AUv2 uiViewForAudioUnit:withSize: protocol.
    private static func makeCustomView(unit: AudioUnit,
                                        info: (bundleURL: URL, classNames: [String])?,
                                        log: (String) -> Void) -> NSView? {
        guard let info, let className = info.classNames.first else { return nil }
        log("insert: CocoaUI class=\(className) bundle=\(info.bundleURL.lastPathComponent)")

        var cls: AnyClass? = NSClassFromString(className)
        if cls == nil, let c = className.cString(using: .utf8),
           let o = objc_getClass(c) as? AnyClass {
            cls = o
        }
        if cls == nil, let bundle = Bundle(url: info.bundleURL) {
            _ = bundle.load()
            cls = NSClassFromString(className)
            if cls == nil, let c = className.cString(using: .utf8),
               let o = objc_getClass(c) as? AnyClass {
                cls = o
            }
        }
        guard let cls else {
            log("insert: custom view class unresolvable — generic UI")
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
                log("insert: custom view via uiViewForAudioUnit ok")
                return v
            }
        }
        if let v = instance as? NSView, !v.subviews.isEmpty {
            log("insert: custom view direct")
            return v
        }
        return nil
    }

    /// Generic parameter UI from the AU's parameter tree (always works).
    private static func makeGenericView(i: Int, effect: AVAudioUnitEffect,
                                       log: (String) -> Void) -> NSView? {
        let au = effect.auAudioUnit
        guard let tree = au.parameterTree else { return nil }
        let params = tree.allParameters
        log("insert: pair \(i) generic view, \(params.count) parameters")
        genericParams[i] = params

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 24 + params.count * 48))
        for (n, param) in params.enumerated() {
            let y = CGFloat(params.count - 1 - n) * 48
            let label = NSTextField(labelWithString: param.identifier ?? "param")
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.frame = NSRect(x: 16, y: y + 26, width: 428, height: 14)
            let slider = NSSlider(value: Double(param.value), minValue: Double(param.minValue),
                                  maxValue: Double(param.maxValue), target: nil, action: nil)
            slider.frame = NSRect(x: 16, y: y, width: 428, height: 20)
            slider.target = InsertServer.shared
            slider.action = #selector(InsertServer.shared.sliderChanged(_:))
            slider.identifier = NSUserInterfaceItemIdentifier("pair:\(i):param:\(n)")
            content.addSubview(label)
            content.addSubview(slider)
        }
        content.autoresizingMask = [.width, .height]
        return content
    }

    private static var genericParams: [Int: [AUParameter]] = [:]

    /// Generic-view slider action: apply the new value to the parameter.
    @objc func sliderChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "pair",
              let i = Int(parts[1]), let n = Int(parts[3]),
              let params = Self.genericParams[i], params.indices.contains(n) else { return }
        params[n].value = Float(sender.doubleValue)
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

    /// Our own process object id — the tap excludes it.
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

    /// Frames in the first buffer of a list (float32, interleaved-aware).
    static func frames(of abl: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let b = list.first else { return 0 }
        let ch = max(1, Int(b.mNumberChannels))
        return Int(b.mDataByteSize) / 4 / ch
    }

    private static func fillZero(_ abl: UnsafeMutablePointer<AudioBufferList>, _ frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for b in 0..<list.count {
            if let d = list[b].mData { memset(d, 0, frames * 4) }
        }
    }

    private static func copyMono(into list: UnsafeMutableAudioBufferListPointer, at index: Int,
                                 from src: UnsafeMutablePointer<Float>, _ frames: Int) {
        guard list.count > index,
              let dst = list[index].mData?.assumingMemoryBound(to: Float.self) else { return }
        dst.update(from: src, count: frames)
    }

    private static func clear(_ b: AudioBuffer, _ frames: Int) {
        if let d = b.mData { memset(d, 0, frames * 4) }
    }
}

/// A non-interleaved AudioBufferList with its own storage.
final class StereoABL {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    var buffers: [UnsafeMutablePointer<Float>] = []
    let channels: Int

    init(frames: Int, channels: Int = 2) {
        self.channels = channels
        let size = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)! + channels * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        pointer = raw.assumingMemoryBound(to: AudioBufferList.self)
        pointer.pointee.mNumberBuffers = UInt32(channels)
        for c in 0..<channels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: 0, count: frames)
            buffers.append(p)
            let bp = raw + MemoryLayout<AudioBuffer>.stride * c
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
extension InsertServer: NSWindowDelegate {}
