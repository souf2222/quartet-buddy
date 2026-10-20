import AppKit
import CoreAudio

/// Auto Gain — ONE-TIME hardware preamp calibration, not continuous AGC.
///
/// The user plays/sings at their loudest expected level while the engine
/// ADAPTIVELY tracks the CONVERTED input (the ADC stream — the only signal
/// the Mac can see; analog Soft Limit is already applied to it, and
/// lowering anything digital could never undo input clipping anyway).
/// Every second it re-aims the preamp at the target peak (setting,
/// default −12 dBFS), converging within ~5 s, then verifies reduce-only
/// for 2 s and STOPS — the gain stays fixed afterwards, exactly like
/// Focusrite's / UA's Auto Gain (UA's default peak target is −8 dBFS;
/// −12 is a more conservative choice with more headroom).
///
/// One or ALL inputs at once: the single device IOProc (the HAL allows
/// only one per process) already carries every analog input, so one InputTap
/// reduces all four channels and each session nudges its own preamp.
///
/// Per-session sequence:
///   track 5 s     → nudge every 1 s (±18 dB max), clip → −6 dB instantly
///                   (4 recoveries), silence → bold climb to find signal
///   verify 2 s    → reduce-only correction, then done
///
/// Any failure, manual gain/mode change, or cancel RESTORES that input's
/// original gain — other inputs keep their calibration. Phantom power is
/// NEVER touched automatically.
///
/// Threading: the audio callback reduces windows per channel into a
/// pre-allocated ring (no allocation, no ObjC on the audio thread); a
/// 10 Hz main-thread timer drains the ring and drives the sessions.
final class AutoGainEngine {

    static let shared = AutoGainEngine()

    // MARK: - configuration

    struct Config {
        var listenSeconds: Double = 5           // total live tracking time
        var verifySeconds: Double = 2           // reduce-only check afterwards
        var nudgeInterval: Double = 1            // gain adjustment cadence
        var nudgeMaxDB: Double = 18              // max correction per nudge
        var windowMilliseconds: Double = 20     // peak/RMS statistics window
        var activityThresholdDBFS: Double = -55 // "user is performing" heuristic
        var minActiveSeconds: Double = 1.5      // don't calibrate off a click
        var minVerifyActiveSeconds: Double = 0.5 // verification must hear them
        var toleranceDB: Double = 1             // skip sub-1 dB corrections
        var clipThresholdDBFS: Double = -0.2    // near-full-scale = clipped
        var clipBackoffDB: Double = 6           // recovery step on clipping
        var settleSeconds: Double = 0.35          // discard audio after a write
        var maxAttempts: Int = 4                 // clip-recovery retry budget
    }

    /// Preamp hardware range (matches the console's GAIN SAFETY clamps).
    static let minGainDB: Double = 0
    static let maxGainDB: Double = 75

    /// Target peak — a persisted SETTING (menubar/console popup).
    /// The labels say dBFS (what we measure); the console menu calls it
    /// "level" so nobody has to care about the units.
    static var targetDBFS: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "autoGainTargetDBFS")
            return targetOptions.contains(v) ? v : -12
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoGainTargetDBFS")
        }
    }
    static let targetOptions: [Double] = [-18, -15, -12, -9, -6]

    /// Calibration (tracking) time — a persisted SETTING too. Shorter =
    /// faster but rougher; verify is always a fixed 2 s afterwards.
    static var listenSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "autoGainListenSeconds")
            return listenOptions.contains(v) ? v : 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoGainListenSeconds")
        }
    }
    static let listenOptions: [Double] = [5, 8, 10, 15]

    struct StartParams {
        var input: Int               // 0…3 (analog IN 1…4)
        var activeGainId: [UInt8]    // mic or instrument path-id (active mode)
        var refLevelId: [UInt8]?     // mode-change watchdog
        var currentGain: Double      // the preamp value when starting
    }

    // MARK: - per-input session

    private final class Session {
        var params: StartParams
        var phase: Phase = .listening
        var listenStart = Date()
        var lastNudge = Date()
        var verifyStart = Date()
        var originalGain: Double
        var appliedGain: Double
        var lastWrittenGain: Double
        var activeSeconds: Double = 0
        var winPeakDBFS: Double?
        var winRmsDBFS: Double?
        var sawClip = false
        var attempts = 0
        init(params: StartParams) {
            self.params = params
            self.originalGain = params.currentGain
            self.appliedGain = params.currentGain
            self.lastWrittenGain = params.currentGain
        }
        func resetWindow() {
            winPeakDBFS = nil
            winRmsDBFS = nil
            sawClip = false
        }
    }

    enum Phase: Equatable {
        case idle
        case listening         // adaptive tracking — nudges every second
        case verifying
    }

    // MARK: - plumbing (wired by AppDelegate.setupConsoleWindow)

    /// Engine → hardware: write an input's ACTIVE mode preamp gain (glue).
    var writeGain: ((Int, Double) -> Void)?
    /// Live status line (input index, "… 3 s · preamp 21 dB").
    var onStatus: ((Int, String) -> Void)?
    /// Terminal state: input index, human line, success.
    var onFinished: ((Int, String, Bool) -> Void)?

    /// Inputs currently calibrating (empty = none).
    private(set) var runningInputs: [Int] = []
    var isRunning: Bool { !runningInputs.isEmpty }

    // MARK: - state (main thread only)

    private let cfg = Config()
    private var sessions: [Int: Session] = [:]
    private var tap: InputTap?
    private var timer: Timer?
    /// Windows ending before this uptime are settling noise — dropped.
    private var discardBefore: UInt64 = 0
    /// End time of the last window seen — stream must keep flowing.
    private var lastStatUptime: UInt64 = 0

    // MARK: - lifecycle

    /// Start calibrating ONE input or ALL at once. `params` may hold any
    /// subset (the console passes one, or all four analog inputs).
    func start(_ paramsList: [StartParams]) {
        guard sessions.isEmpty else { return }        // one calibration batch
        guard writeGain != nil else {
            onFinished?(paramsList.first?.input ?? 0, "Auto Gain not wired", false)
            return
        }
        guard let dev = Self.findQuartetDevice() else {
            for p in paramsList {
                onFinished?(p.input, "Quartet not found in Core Audio", false)
            }
            return
        }
        // one tap for ALL sessions (the HAL allows a single IOProc per
        // device per process — and it already carries every channel)
        let tap = InputTap()
        do {
            try tap.start(device: dev,
                          channels: paramsList.map { $0.input })
        } catch {
            for p in paramsList {
                onFinished?(p.input, "can't open the input — \(error.localizedDescription)", false)
            }
            return
        }
        self.tap = tap
        discardBefore = 0
        lastStatUptime = DispatchTime.now().uptimeNanoseconds
        for p in paramsList {
            let s = Session(params: p)
            s.listenStart = Date()
            s.lastNudge = s.listenStart
            sessions[p.input] = s
            QBLog.log(String(format: "autogain: IN %d start — preamp %.1f dB, target %.0f dBFS",
                             p.input + 1, p.currentGain, Self.targetDBFS))
        }
        runningInputs = Array(sessions.keys)
        tap.sink.reset()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Convenience for a single input.
    func start(_ params: StartParams) {
        start([params])
    }

    /// Cancel every running session (user cancel / stream stall).
    func cancelAll(reason: String) {
        for i in sessions.keys.sorted() {
            cancel(input: i, reason: reason)
        }
    }

    /// Cancel one input's session — restores just that preamp.
    private func cancel(input i: Int, reason: String) {
        guard let s = sessions[i] else { return }
        QBLog.log("autogain: IN \(i + 1) cancelled — \(reason)")
        finish(session: s,
               line: "IN \(i + 1) Auto Gain — \(reason); original gain restored",
               success: false, restore: true)
    }

    /// Every glue setProperty event while a calibration runs (forwarded by
    /// the console): our own writes echo with the value we just wrote —
    /// anything else on a session's gain or mode cancels THAT session.
    func noteGlueEvent(id: [UInt8], tag: UInt8, value: Data) {
        for (i, s) in sessions {
            if let refId = s.params.refLevelId, id == refId {
                cancel(input: i, reason: "input mode changed")
                continue
            }
            if id == s.params.activeGainId, tag == 4, let v = Self.readDouble(value) {
                if abs(v - s.lastWrittenGain) <= 0.05 { continue }   // our echo
                cancel(input: i, reason: "gain changed by hand")
            }
        }
        if sessions.isEmpty { teardown() }
    }

    // MARK: - state machine (10 Hz, main thread)

    private func tick() {
        guard let tap, !sessions.isEmpty else { teardown(); return }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        if nowNanos - lastStatUptime > 2_000_000_000 {
            cancelAll(reason: "input stream stalled")
            return
        }

        // consume the audio thread's per-channel window statistics
        for s in tap.sink.drain() {
            lastStatUptime = s.endUptime
            guard s.endUptime >= discardBefore, let sess = sessions[s.channel] else { continue }
            let peakDB = Self.db20(s.peak)
            sess.winPeakDBFS = max(sess.winPeakDBFS ?? -.infinity, peakDB)
            let rmsDB = Self.db20(s.rms)
            sess.winRmsDBFS = max(sess.winRmsDBFS ?? -.infinity, rmsDB)
            if rmsDB > cfg.activityThresholdDBFS {
                sess.activeSeconds += cfg.windowMilliseconds / 1000
            }
            if peakDB >= cfg.clipThresholdDBFS { sess.sawClip = true }
        }

        let now = Date()
        let target = Self.targetDBFS
        for (i, s) in sessions {
            switch s.phase {
            case .listening:
                if s.sawClip {
                    s.sawClip = false
                    clipRecovery(s, i)
                    if s.phase != .listening { continue }
                }
                if now.timeIntervalSince(s.lastNudge) >= cfg.nudgeInterval {
                    s.lastNudge = now
                    nudge(s, i, target: target)
                }
                if now.timeIntervalSince(s.listenStart) >= Self.listenSeconds {
                    finishListening(s, i)
                } else {
                    onStatus?(i, String(
                        format: "IN %d Auto Gain — play/sing your loudest: %.0f s · preamp %.1f dB",
                        i + 1, Self.listenSeconds - now.timeIntervalSince(s.listenStart),
                        s.lastWrittenGain))
                }
            case .verifying:
                if s.sawClip {
                    s.sawClip = false
                    clipRecovery(s, i)
                    continue
                }
                if now.timeIntervalSince(s.verifyStart) >= cfg.verifySeconds {
                    finishVerifying(s, i, target: target)
                } else {
                    onStatus?(i, String(
                        format: "IN %d Auto Gain — keep it up, verifying: %.0f s left",
                        i + 1, cfg.verifySeconds - now.timeIntervalSince(s.verifyStart)))
                }
            case .idle:
                break
            }
        }
        if sessions.isEmpty { teardown() }
    }

    /// One adaptive correction: aim the measured peak at the target,
    /// clamped ±nudgeMaxDB, applied immediately. A silent window climbs
    /// boldly to find signal (handles near-zero starting gains inline).
    private func nudge(_ s: Session, _ i: Int, target: Double) {
        guard let peak = s.winPeakDBFS else {
            guard s.lastWrittenGain < Self.maxGainDB - 0.05 else { s.resetWindow(); return }
            let up = Self.floorStep(min(s.lastWrittenGain + cfg.nudgeMaxDB, Self.maxGainDB))
            QBLog.log(String(format: "autogain: IN %d silent → climb %.1f → %.1f dB",
                             i + 1, s.lastWrittenGain, up))
            write(i, up, s)
            return
        }
        let desired = s.lastWrittenGain + target - peak
        let delta = min(max(desired - s.lastWrittenGain, -cfg.nudgeMaxDB), cfg.nudgeMaxDB)
        let newGain = Self.floorStep(min(max(s.lastWrittenGain + delta, Self.minGainDB), Self.maxGainDB))
        defer { s.resetWindow() }
        guard abs(newGain - s.lastWrittenGain) > 0.05 else { return }
        QBLog.log(String(format: "autogain: IN %d peak %.1f dBFS → preamp %.1f → %.1f dB",
                         i + 1, peak, s.lastWrittenGain, newGain))
        write(i, newGain, s)
    }

    /// Clipping: −6 dB, restart the track. ≤ 4 attempts per session.
    private func clipRecovery(_ s: Session, _ i: Int) {
        s.attempts += 1
        guard s.attempts <= cfg.maxAttempts else {
            finish(session: s,
                   line: "IN \(i + 1) Auto Gain — still clipping after \(cfg.maxAttempts) attempts; original gain restored",
                   success: false, restore: true)
            return
        }
        let lower = Self.floorStep(max(Self.minGainDB, s.lastWrittenGain - cfg.clipBackoffDB))
        guard lower < s.lastWrittenGain - 0.001 else {
            finish(session: s,
                   line: "IN \(i + 1) Auto Gain — input overload at minimum gain; original gain restored",
                   success: false, restore: true)
            return
        }
        QBLog.log(String(format: "autogain: IN %d CLIPPING → %.1f dB, restarting (attempt %d/%d)",
                         i + 1, lower, s.attempts, cfg.maxAttempts))
        write(i, lower, s)
        s.phase = .listening
        s.listenStart = Date()
        s.lastNudge = s.listenStart
        s.activeSeconds = 0
        s.resetWindow()
    }

    /// End of the 5 s track: verify what we landed on.
    private func finishListening(_ s: Session, _ i: Int) {
        guard s.activeSeconds >= cfg.minActiveSeconds else {
            finish(session: s,
                   line: "IN \(i + 1) Auto Gain — not enough signal; original gain restored",
                   success: false, restore: true)
            return
        }
        s.phase = .verifying
        s.verifyStart = Date()
        s.appliedGain = s.lastWrittenGain
        s.activeSeconds = 0
        s.resetWindow()
        onStatus?(i, String(format: "IN %d Auto Gain — hold your level, verifying…", i + 1))
    }

    /// End of the 2 s verify: reduce-only correction, then done.
    private func finishVerifying(_ s: Session, _ i: Int, target: Double) {
        guard s.activeSeconds >= cfg.minVerifyActiveSeconds else {
            finish(session: s,
                   line: "IN \(i + 1) Auto Gain — went quiet while verifying; original gain restored",
                   success: false, restore: true)
            return
        }
        let peak = s.winPeakDBFS ?? target
        let excess = peak - target
        if excess > cfg.toleranceDB {
            let corrected = Self.floorStep(max(Self.minGainDB, s.appliedGain - excess))
            if corrected < s.appliedGain - 0.04 {
                QBLog.log(String(format: "autogain: IN %d verify peak %.1f dBFS → reduce %.1f → %.1f dB",
                                 i + 1, peak, excess, corrected))
                write(i, corrected, s)
                s.appliedGain = corrected
            }
        } else {
            QBLog.log(String(format: "autogain: IN %d verify peak %.1f dBFS — within tolerance",
                             i + 1, peak))
        }
        var line = String(format: "IN %d Auto Gain — preamp %.1f dB (%+.1f), peak %.1f dBFS",
                          i + 1, s.appliedGain, s.appliedGain - s.originalGain, peak)
        if s.appliedGain >= Self.maxGainDB - 0.05, peak < target - cfg.toleranceDB {
            line += " — maximum gain reached, target not met"
        } else if s.appliedGain <= Self.minGainDB + 0.05, peak > target + cfg.toleranceDB {
            line += " — minimum gain reached, input too hot"
        }
        finish(session: s, line: line, success: true, restore: false)
    }

    // MARK: - write + teardown

    /// Central write: clamp, floor to 0.1 dB, drop settling audio, record.
    private func write(_ i: Int, _ value: Double, _ s: Session) {
        let v = Self.floorStep(min(max(value, Self.minGainDB), Self.maxGainDB))
        discardBefore = DispatchTime.now().uptimeNanoseconds
            + UInt64(cfg.settleSeconds * 1_000_000_000)
        writeGain?(i, v)
        s.lastWrittenGain = v
    }

    /// Terminal for one session: restore if asked, report, drop it.
    private func finish(session s: Session, line: String, success: Bool, restore: Bool) {
        let i = s.params.input
        if restore {
            let original = Self.floorStep(min(max(s.originalGain, Self.minGainDB), Self.maxGainDB))
            if abs(s.lastWrittenGain - original) > 0.05 {
                writeGain?(i, original)
                QBLog.log(String(format: "autogain: IN %d restored %.1f dB", i + 1, original))
            }
        }
        sessions[i] = nil
        runningInputs = Array(sessions.keys)
        onFinished?(i, line, success)
        QBLog.log("autogain: IN \(i + 1) done — \(success ? "ok" : "restored")")
        if sessions.isEmpty { teardown() }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        tap?.stop()
        tap = nil
        sessions.removeAll()
        runningInputs = []
    }

    // MARK: - helpers

    private static func db20(_ x: Double) -> Double {
        20 * log10(max(x, 1e-12))
    }

    /// Round DOWN to 0.1 dB steps — headroom first.
    private static func floorStep(_ x: Double) -> Double {
        (x * 10).rounded(.down) / 10
    }

    private static func readDouble(_ data: Data) -> Double? {
        guard data.count >= 8 else { return nil }
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(data[data.startIndex + i])
        }
        return Double(bitPattern: v)
    }

    /// The Quartet's CoreAudio device id, by name (self-contained).
    static func findQuartetDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        return ids.first { deviceName($0) == "Quartet" }
    }

    static func deviceName(_ dev: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr else {
            return ""
        }
        return name as String
    }
}

// MARK: - input capture (device-level IOProc)

/// Reads the Quartet's input stream through a device-level HAL IOProc and
/// reduces ANY SET of channels to 20 ms per-channel peak/RMS windows — one
/// tap serves any number of concurrent Auto Gain sessions (the HAL allows
/// only one IOProc per device per process).
///
/// Why not AUHAL: the Quartet is already running (default output + the
/// insert's aggregate), and in that state AudioUnitRender on the input
/// element fails with paramErr — verified live against every pull recipe
/// and buffer layout. The old device-level API hands the input data to the
/// callback directly (no render call) and works fine. It's marked
/// deprecated → unavailable in Swift, so the two entry points are reached
/// through dlsym (the symbols are still in CoreAudio).
///
/// The IOProc contributes silence on the output side: the HAL hands each
/// IOProc its own PRE-ZEROED scratch buffers (verified live), so writing
/// zeros mixes silence into the device — it can never disturb other
/// clients' audio.
///
/// Audio-thread rules: no allocation, no ObjC — statistics go into a
/// pre-allocated ring drained by the engine's main-thread timer.
final class InputTap {

    struct WindowStat {
        var channel: Int
        var endUptime: UInt64
        var peak: Double
        var rms: Double
    }

    /// Fixed-size ring: push from the audio thread, drain from main.
    final class Sink {
        private static let capacity = 16384
        private var slots = [WindowStat?](repeating: nil, count: capacity)
        private var writeIndex = 0
        private var readIndex = 0
        private let lock = NSLock()

        func push(_ s: WindowStat) {                 // audio thread
            lock.lock()
            slots[writeIndex % Sink.capacity] = s
            writeIndex &+= 1
            lock.unlock()
        }

        func drain() -> [WindowStat] {               // main thread
            lock.lock()
            defer { lock.unlock() }
            var out: [WindowStat] = []
            out.reserveCapacity(writeIndex - readIndex)
            while readIndex < writeIndex {
                out.append(slots[readIndex % Sink.capacity]!)
                readIndex &+= 1
            }
            return out
        }

        func reset() {
            lock.lock()
            writeIndex = 0
            readIndex = 0
            lock.unlock()
        }
    }

    let sink = Sink()

    private(set) var isRunning = false
    /// Channels tracked (sorted; empty = nothing pushed).
    private var channels: [Int] = []
    private var channelSet: Set<Int> = []

    private var device: AudioDeviceID = 0
    private var windowFrames = 960                       // 20 ms @ 48 kHz

    // per-channel 20 ms accumulators (audio thread only)
    private var accFrames: [Int] = []
    private var accSumSq: [Double] = []
    private var accPeak: [Double] = []
    private var accIndex: [Int] = []                    // channel index per slot

    func start(device: AudioDeviceID, channels: [Int]) throws {
        guard !channels.isEmpty else {
            throw NSError(domain: "AutoGain", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no channels to track"])
        }
        let available = Self.inputChannelCount(device)
        guard channels.allSatisfy({ $0 < available }) else {
            throw NSError(domain: "AutoGain", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "input channel not available (\(available) seen)"])
        }
        self.device = device
        self.channels = channels.sorted()
        channelSet = Set(self.channels)
        windowFrames = max(16, Int((Self.deviceSampleRate(device) * 0.02).rounded()))
        accFrames = [Int](repeating: 0, count: self.channels.count)
        accSumSq = [Double](repeating: 0, count: self.channels.count)
        accPeak = [Double](repeating: 0, count: self.channels.count)
        accIndex = self.channels
        let status = Self.addIOProc(device, ioProc, Unmanaged.passUnretained(self).toOpaque())
        guard status == noErr else {
            throw NSError(domain: "AutoGain", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                            "can't attach the input listener (\(status))"])
        }
        let startStatus = AudioDeviceStart(device, ioProc)
        guard startStatus == noErr else {
            Self.removeIOProc(device, ioProc)
            // 0x7065726d = 'perm' — the HAL's microphone-TCC denial
            let denied = startStatus == 0x7065726d
            throw NSError(domain: "AutoGain", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: denied
                            ? "microphone access denied — allow Quartet Buddy in System Settings → Privacy → Microphone"
                            : "can't start the input listener (\(startStatus))"])
        }
        sink.reset()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        AudioDeviceStop(device, ioProc)
        Self.removeIOProc(device, ioProc)
    }

    /// C function pointer: the HAL calls this on its IO thread with the
    /// device's native input data. Params follow AudioDeviceIOProc's
    /// positional order.
    private let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, clientData in
        let tap = Unmanaged<InputTap>.fromOpaque(clientData!).takeUnretainedValue()
        return tap.ioCallback(inInputData: inInputData, outOutputData: outOutputData)
    }

    private func ioCallback(inInputData: UnsafePointer<AudioBufferList>?,
                            outOutputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        let inp: UnsafePointer<AudioBufferList>? = inInputData
        if let inp {
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
            if abl.count >= 1, abl[0].mNumberChannels >= 1, let d = abl[0].mData {
                let s = d.assumingMemoryBound(to: Float32.self)
                let ch = Int(abl[0].mNumberChannels)
                let frames = Int(abl[0].mDataByteSize / 4 / UInt32(ch))
                if frames > 0 {
                    if ch > 1 {
                        // interleaved: frame-major, target channels strided
                        accumulateInterleaved(s, frames: frames, stride: ch)
                    } else {
                        // de-interleaved-ish: buffer per channel (not the
                        // Quartet's case, kept for completeness)
                        for (slot, c) in accIndex.enumerated() where c < abl.count {
                            guard let data = abl[c].mData else { continue }
                            let n = Int(abl[c].mDataByteSize / 4)
                            if n > 0 {
                                accumulateOne(slot: slot, channel: c,
                                              data.assumingMemoryBound(to: Float32.self), frames: n)
                            }
                        }
                    }
                }
            }
        }

        // output contribution: silence (scratch arrives pre-zeroed; keep it zero)
        let out: UnsafeMutablePointer<AudioBufferList>? = outOutputData
        if let out {
            let abl = UnsafeMutableAudioBufferListPointer(out)
            for b in 0..<abl.count {
                if let d = abl[b].mData { memset(d, 0, Int(abl[b].mDataByteSize)) }
            }
        }
        return noErr
    }

    /// Interleaved reduction: per tracked channel, walk frame-by-frame and
    /// fold into that channel's 20 ms window accumulator.
    private func accumulateInterleaved(_ samples: UnsafePointer<Float32>, frames: Int,
                                        stride: Int) {
        for (slot, c) in accIndex.enumerated() where c < stride {
            var f = 0
            while f < frames {
                let take = min(windowFrames - accFrames[slot], frames - f)
                var sumSq = 0.0
                var peak = 0.0
                var i = f * stride + c
                for _ in 0..<take {
                    let v = Double(samples[i])
                    let a = Swift.abs(v)
                    if a > peak { peak = a }
                    sumSq += v * v
                    i += stride
                }
                accSumSq[slot] += sumSq
                if peak > accPeak[slot] { accPeak[slot] = peak }
                accFrames[slot] += take
                f += take
                if accFrames[slot] >= windowFrames {
                    let n = Double(accFrames[slot])
                    sink.push(WindowStat(channel: c,
                                         endUptime: DispatchTime.now().uptimeNanoseconds,
                                         peak: accPeak[slot],
                                         rms: (accSumSq[slot] / n).squareRoot()))
                    accFrames[slot] = 0
                    accSumSq[slot] = 0
                    accPeak[slot] = 0
                }
            }
        }
    }

    /// De-interleaved reduction (one 1-channel buffer per tracked channel).
    private func accumulateOne(slot: Int, channel: Int,
                                _ samples: UnsafePointer<Float32>, frames: Int) {
        var f = 0
        while f < frames {
            let take = min(windowFrames - accFrames[slot], frames - f)
            var sumSq = 0.0
            var peak = 0.0
            for i in f..<(f + take) {
                let v = Double(samples[i])
                let a = Swift.abs(v)
                if a > peak { peak = a }
                sumSq += v * v
            }
            accSumSq[slot] += sumSq
            if peak > accPeak[slot] { accPeak[slot] = peak }
            accFrames[slot] += take
            f += take
            if accFrames[slot] >= windowFrames {
                let n = Double(accFrames[slot])
                sink.push(WindowStat(channel: channel,
                                     endUptime: DispatchTime.now().uptimeNanoseconds,
                                     peak: accPeak[slot],
                                     rms: (accSumSq[slot] / n).squareRoot()))
                accFrames[slot] = 0
                accSumSq[slot] = 0
                accPeak[slot] = 0
            }
        }
    }

    // MARK: HAL plumbing

    private typealias AddIOProcFn = @convention(c) (AudioDeviceID, AudioDeviceIOProc,
                                                   UnsafeMutableRawPointer?) -> OSStatus
    private typealias RemoveIOProcFn = @convention(c) (AudioDeviceID, AudioDeviceIOProc) -> OSStatus

    private static let coreAudio = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW)

    private static let addIOProc: AddIOProcFn = {
        guard let sym = dlsym(coreAudio, "AudioDeviceAddIOProc") else {
            fatalError("CoreAudio: AudioDeviceAddIOProc not found")
        }
        return unsafeBitCast(sym, to: AddIOProcFn.self)
    }()

    private static let removeIOProc: RemoveIOProcFn = {
        guard let sym = dlsym(coreAudio, "AudioDeviceRemoveIOProc") else {
            fatalError("CoreAudio: AudioDeviceRemoveIOProc not found")
        }
        return unsafeBitCast(sym, to: RemoveIOProcFn.self)
    }()

    private static func inputChannelCount(_ dev: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { mem.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, mem) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(mem.assumingMemoryBound(to: AudioBufferList.self))
        var total = 0
        for i in 0..<list.count {
            total += Int(list[i].mNumberChannels)
        }
        return total
    }

    private static func deviceSampleRate(_ dev: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(48000)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate) == noErr else {
            return 48000
        }
        return rate > 0 ? rate : 48000
    }
}