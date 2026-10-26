import AppKit
import CoreAudio

// MARK: - ADAT Assisted Gain (measurement + guidance engine)

/// ADAT ASSISTED GAIN — a measurement-and-guidance loop for the eight
/// optical inputs, NOT automatic gain control and NOT digital
/// normalization. The Quartet's ADAT preamps live on the EXTERNAL
/// converter, so the app can never write their gain — what it CAN do
/// is measure what arrives and tell the user how far to turn the
/// external knob.
///
/// One short, repeatable calibration instead of a moving
/// recommendation:
///
///   listen  `durationSeconds` (default 5 s) to the selected channels
///           → the HIGHEST SAMPLE PEAK of the whole window is the
///             reference (peaks matter here — they sit closest to the
///             digital ceiling; RMS/LUFS describe different aspects of
///             average energy and perceived loudness)
///   →       recommendation = target peak − measured peak, FROZEN
///           ("Increase external gain by ~8 dB" — a RELATIVE
///           instruction; the app does not know the external preamp's
///           absolute gain setting)
///   recheck  → a FRESH measurement, previous peak cleared first, so
///           the guidance never recalculates from the original take
///           while the user turns the knob
///
///   Listen → Recommend → Manual adjustment → Recheck → Verified
///
/// The measurement reads the device stream BEFORE app trim, plug-ins
/// or routing (the same device-level IOProc Auto Gain uses), so a
/// software level can never appear to fix an input-gain problem.
/// Channel mapping is read from the LIVE stream configuration (analog
/// 1–4 first, then however many ADAT channels the current sample rate
/// actually exposes — two lightpipes worth at 88.2/96 kHz) — never
/// assumed.
///
/// Unreliable measurements get explicit treatment, never a confident
/// number: no meaningful signal → "No signal during measurement"
/// (never a huge gain recommendation out of silence — and worded about
/// the TAKE, so signal arriving later still shows on the live meter);
/// a peak at the ceiling → "Input clipped · Reduce external gain" (the
/// level above full scale is unknowable). A result says "verified
/// during the last check", never "permanently safe".
///
/// Threading mirrors AutoGain: the audio callback folds the stream
/// into pre-allocated 20 ms windows, a 10 Hz main-thread timer drains
/// them. The SAME tap also feeds the live level meters (analog + ADAT)
/// while the control window is open, and it yields AT ONCE when an
/// Auto Gain calibration takes the device IOProc.

final class AdatGainEngine {

    static let shared = AdatGainEngine()

    // MARK: configuration (persisted; Settings ▸ Processing ▸ Gain Assistance)

    static let targetOptions: [Double] = [-18, -15, -12, -9, -6]
    static let durationOptions: [Double] = [3, 5, 8, 10]
    static let toleranceOptions: [Double] = [1, 2, 3]

    /// Target peak (dBFS) — the proposed default is −12.
    static var targetDBFS: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "adatAssistTargetDBFS")
            return targetOptions.contains(v) ? v : -12
        }
        set { UserDefaults.standard.set(newValue, forKey: "adatAssistTargetDBFS") }
    }
    /// Measurement duration (s) — default 5.
    static var durationSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "adatAssistDurationSeconds")
            return durationOptions.contains(v) ? v : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: "adatAssistDurationSeconds") }
    }
    /// Acceptable range around the target (±dB) — default 2.
    static var toleranceDB: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "adatAssistToleranceDB")
            return toleranceOptions.contains(v) ? v : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: "adatAssistToleranceDB") }
    }

    /// The overlay's quiet settings summary (settings live in Settings,
    /// never as prominent dropdowns in the assistant).
    static var configSummary: String {
        String(format: "Target %.0f dBFS peak · Measurement %.0f s · Range ±%.0f dB",
               targetDBFS, durationSeconds, toleranceDB)
    }

    /// Per-ADAT-channel assistance status. Results are FROZEN until
    /// that channel is remeasured.
    enum Status: Equatable {
        case idle                 // no measurement yet
        case measuring
        case increase(Double)     // frozen: raise the external preamp by X dB
        case reduce(Double)       // frozen: lower it by X dB
        case withinTarget(Double) // frozen: measured peak, inside tolerance
        case clipped(Double)      // frozen: the ceiling was hit — guidance stays qualitative
        case noSignal             // frozen: not enough signal to base anything on
    }

    static let analogChannels = 4
    static let maxAdatChannels = 8

    // MARK: state (main thread only)

    private(set) var statuses: [Status] = Array(repeating: .idle, count: maxAdatChannels)
    /// Highest sample peak of the last valid measurement (dBFS) — the
    /// frozen reference behind the recommendation and peak marker.
    private var measuredPeak = [Double?](repeating: nil, count: maxAdatChannels)
    /// Status snapshot to restore when a channel's recheck is torn
    /// down without a result — the old frozen recommendation stays
    /// truthful until a fresh one lands.
    private var pendingRestore = [Int: Status]()

    /// How many ADAT channels the CURRENT stream exposes (a live Core
    /// Audio read — it reflects the sample rate's SMUX channel layout).
    private(set) var adatChannelCount = 0
    /// The metering tap's last error (device gone, permission…).
    private(set) var tapError: String?

    // MARK: plumbing (wired by the control window)

    /// 10 Hz tick on the main thread while anything is active — the
    /// window fast-paths the meters out of this (no full refresh).
    var onUpdate: (() -> Void)?
    /// The Quartet Control window is visible (keeps the meters alive).
    var windowVisible = false {
        didSet { if windowVisible != oldValue { wake() } }
    }

    // MARK: measurement internals

    private var since = [Int: Date]()
    private var calPeak = [Double?](repeating: nil, count: maxAdatChannels) // linear
    private var calClip = [Bool](repeating: false, count: maxAdatChannels)
    private var calActive = [Double](repeating: 0, count: maxAdatChannels)

    private var livePeak = [Double](repeating: 0,
                                    count: analogChannels + maxAdatChannels)
    /// Display PEAK HOLD for the ADAT meter readout (device channels,
    /// linear):
    /// a sample peak catches the hold instantly; it holds still for
    /// `holdSeconds`, then decays slowly so the readout stays readable
    /// after the gain knob was turned. Started over only by a new peak.
    private var holdPeak = [Double](repeating: 0,
                                    count: analogChannels + maxAdatChannels)
    private var holdStamp = [Date?](repeating: nil,
                                    count: analogChannels + maxAdatChannels)
    /// Recent-clipping latch (device channels): a clipped
    /// sample paints the meter red for 1 s (word: the meter is a live
    /// instrument, not a calibration result).
    private var clipLatch = [Date?](repeating: nil,
                                    count: analogChannels + maxAdatChannels)
    /// The ADAT channel the Gain Assistant currently belongs to
    /// (single-channel entry); the tile's purple selection marker
    /// mirrors it while the overlay is open.
    var focusedChannel: Int?
    private var tap: InputTap?
    private var tapChannels: [Int] = []
    private var lastStatUptime: UInt64 = 0
    private var timer: Timer?
    private var slowTick = 0

    private let activityThresholdDBFS: Double = -55
    private let clipThresholdDBFS: Double = -0.2
    private let minActiveSeconds: Double = 0.5
    /// Peak-hold freeze time before the decay starts.
    private var holdSeconds: Double = 2.0

    var isMeasuring: Bool { !since.isEmpty }
    private var measuringChannels: [Int] { since.keys.sorted() }

    /// True when at least one channel carries a presentable result.
    var hasAnyResult: Bool {
        statuses.contains { s in
            if case .idle = s { return false }
            if case .measuring = s { return false }
            return true
        }
    }

    // MARK: per-channel names (app-side only; Settings ▸ Channel Names)

    static func adatName(_ i: Int) -> String {
        UserDefaults.standard.string(forKey: "adatName.\(i)") ?? ""
    }
    static func setAdatName(_ i: Int, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: "adatName.\(i)") }
        else { UserDefaults.standard.set(trimmed, forKey: "adatName.\(i)") }
    }

    // MARK: level model for the UI

    /// −60…0 dBFS → 0…1 (the display scale of every ADAT meter).
    static func levelFraction(dbfs: Double) -> Double {
        min(max((dbfs + 60) / 60, 0), 1)
    }

    /// Live smoothed display fraction for a device channel (0-based:
    /// analog 0–3, then ADAT 4–11).
    func levelFraction(_ deviceChannel: Int) -> Double {
        guard deviceChannel >= 0,
              deviceChannel < Self.analogChannels + Self.maxAdatChannels else { return 0 }
        let linear = livePeak[deviceChannel]
        guard linear > 1e-12 else { return 0 }
        return Self.levelFraction(dbfs: 20 * log10(linear))
    }

    // MARK: the ADAT meter's held-peak readout

    /// The held peak in dBFS (nil = below the display floor — the
    /// inline readout shows "−∞"). The meter's number + marker use it.
    func heldPeakDBFS(_ deviceChannel: Int) -> Double? {
        guard deviceChannel >= 0,
              deviceChannel < Self.analogChannels + Self.maxAdatChannels else { return nil }
        let p = holdPeak[deviceChannel]
        return p > 1e-10 ? 20 * log10(p) : nil
    }

    /// True within 1 s of a clipped sample on this device channel —
    /// the arc's red indication.
    func liveClipActive(_ deviceChannel: Int) -> Bool {
        guard let t = clipLatch[deviceChannel] else { return false }
        return Date().timeIntervalSince(t) < 1.0
    }

    /// The meter's peak marker: the running calibration peak while a
    /// measurement runs, else the frozen reference peak.
    func peakFraction(_ channel: Int) -> Double? {
        let db: Double?
        if since[channel] != nil, let p = calPeak[channel] {
            db = 20 * log10(max(p, 1e-12))
        } else {
            db = measuredPeak[channel]
        }
        return db.map { Self.levelFraction(dbfs: $0) }
    }

    func measuredPeakDB(_ ch: Int) -> Double? { measuredPeak[ch] }

    func isMeasuringChannel(_ ch: Int) -> Bool { since[ch] != nil }

    func remaining(_ channel: Int) -> Double? {
        guard let start = since[channel] else { return nil }
        return max(0, Self.durationSeconds - Date().timeIntervalSince(start))
    }

    func overallRemaining() -> Double? {
        since.values.map {
            max(0, Self.durationSeconds - Date().timeIntervalSince($0))
        }.min()
    }

    func channelAvailable(_ i: Int) -> Bool { i < adatChannelCount }

    // MARK: - measurement lifecycle

    /// Start a fresh measurement of the given ADAT channels (0-based).
    /// Channels already carrying results have their peak cleared — a
    /// new measurement supersedes the frozen one.
    @discardableResult
    func startMeasurement(_ channels: [Int]) -> String? {
        guard !AutoGainEngine.shared.isRunning else {
            return "Auto Gain is calibrating the analog inputs — wait for it to finish."
        }
        refreshChannelCount()
        let requested = channels.filter { $0 >= 0 && $0 < Self.maxAdatChannels && $0 < adatChannelCount }
        guard !requested.isEmpty else {
            return tapError ?? "No ADAT channels are present on the current stream — check the optical connection or the sample rate."
        }
        for ch in requested { beginMeasurement(ch) }
        QBLog.log("adatgain: measuring ADAT \(requested.map { $0 + 1 }) — \(Self.configSummary)")
        wake()
        return nil
    }

    /// Recheck: clear the previous measurement peak, run a fresh
    /// measurement, recalculate. Everything else stays frozen.
    @discardableResult
    func recheck(_ channels: [Int]) -> String? {
        guard !AutoGainEngine.shared.isRunning else {
            return "Auto Gain is calibrating the analog inputs — wait for it to finish."
        }
        refreshChannelCount()
        let requested = channels.filter { $0 >= 0 && $0 < Self.maxAdatChannels && $0 < adatChannelCount }
        guard !requested.isEmpty else {
            return tapError ?? "No ADAT channels are present on the current stream."
        }
        for ch in requested {
            pendingRestore[ch] = statuses[ch]   // a cancelled recheck falls back
            beginMeasurement(ch)
        }
        QBLog.log("adatgain: recheck ADAT \(requested.map { $0 + 1 })")
        wake()
        return nil
    }

    /// Done on an inline assistant: clear this channel's frozen
    /// recommendation and return it to idle (the button becomes
    /// "Gain Assist…" again).
    func clearResult(_ ch: Int) {
        statuses[ch] = .idle
        measuredPeak[ch] = nil
        pendingRestore[ch] = nil
        QBLog.log("adatgain: guidance cleared on ADAT \(ch + 1)")
        wake()
    }

    /// DEBUG-ONLY (guarded by the QB_AUTO_ASSIST harness env): freeze
    /// a synthetic result so headless snapshots can exercise the
    /// guidance compositions ("Increase…", "Clipped") without real
    /// hardware signal. Production never calls this.
    func debugForceStatus(_ ch: Int, _ status: Status) {
        guard ProcessInfo.processInfo.environment["QB_AUTO_ASSIST"] != nil else { return }
        statuses[ch] = status
        switch status {
        case .increase(let d): measuredPeak[ch] = Self.targetDBFS - d
        case .reduce(let d):   measuredPeak[ch] = Self.targetDBFS + d
        case .withinTarget(let p), .clipped(let p): measuredPeak[ch] = p
        default: measuredPeak[ch] = nil
        }
        wake()
    }

    /// Stop the running measurement(s). Frozen results are KEPT — a
    /// stopped recheck falls back to the previous recommendation.
    func stopMeasuring() {
        guard !since.isEmpty else { return }
        let channels = measuringChannels
        cancelMeasurements(reason: "stopped")
        QBLog.log("adatgain: stopped ADAT \(channels.map { $0 + 1 })")
    }

    private func beginMeasurement(_ ch: Int) {
        since[ch] = Date()
        calPeak[ch] = nil
        calClip[ch] = false
        calActive[ch] = 0
        measuredPeak[ch] = nil
        statuses[ch] = .measuring
        if measurementSampleRate == nil {
            measurementSampleRate = InsertServer.deviceSampleRate()
        }
        if measurementDevice == 0 {
            measurementDevice = AutoGainEngine.findQuartetDevice() ?? 0
        }
    }

    /// Measurement torn down without a result (user stop / stream
    /// lost / Auto Gain took over): restore the pre-recheck snapshot.
    private func cancelMeasurements(reason: String) {
        guard !since.isEmpty else { return }
        for ch in since.keys {
            statuses[ch] = pendingRestore[ch] ?? .idle
            pendingRestore[ch] = nil
        }
        since.removeAll()
        QBLog.log("adatgain: measurements cancelled — \(reason)")
        wake()   // nothing may need the tap anymore
    }

    /// Clear one channel's everything (invalidation).
    private func invalidate(channel ch: Int) {
        since[ch] = nil
        pendingRestore[ch] = nil
        measuredPeak[ch] = nil
        statuses[ch] = .idle
    }

    // MARK: - the 10 Hz tick (main thread)

    private func wake() {
        let needed = windowVisible || isMeasuring
        if needed {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.tick()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            stopTap()
            for i in 0..<livePeak.count { livePeak[i] = 0 }
            holdPeak = [Double](repeating: 0, count: livePeak.count)
            holdStamp = [Date?](repeating: nil, count: livePeak.count)
            clipLatch = [Date?](repeating: nil, count: livePeak.count)
            onUpdate?()
        }
    }

    private func tick() {
        // ONE device IOProc per process — while an analog Auto Gain
        // calibration runs, ADAT metering steps aside, and a
        // measurement in flight is cancelled (never run half a
        // calibration against a moving stream).
        if AutoGainEngine.shared.isRunning {
            if !since.isEmpty { cancelMeasurements(reason: "Auto Gain started") }
            stopTap()
            onUpdate?()
            return
        }

        let needed = windowVisible || isMeasuring
        guard needed else {
            wake()   // everything ended — retire the tap + timer
            return
        }

        ensureTap()
        guard tap?.isRunning == true else {
            onUpdate?()
            return
        }

        // ~1 Hz housekeeping: re-read the LIVE stream layout. A sample
        // rate or lightpipe change cancels the measurement and
        // invalidates its results — data from another configuration is
        // meaningless.
        slowTick += 1
        if slowTick >= 10 {
            slowTick = 0
            housekeeping()
        }
        stabilityWatchdog()

        // consume the audio thread's windows
        for s in tap!.sink.drain() {
            lastStatUptime = s.endUptime
            let ch = s.channel
            guard ch >= 0, ch < livePeak.count else { continue }
            // live meter: fast attack, gentle decay
            livePeak[ch] = s.peak >= livePeak[ch] ? s.peak : livePeak[ch] * 0.80
            // display peak hold: instant catch, frozen until the hold
            // expires (the decay runs in the tick below)
            if s.peak >= holdPeak[ch] {
                holdPeak[ch] = s.peak
                holdStamp[ch] = Date()
            }
            if s.peak >= pow(10, clipThresholdDBFS / 20) { clipLatch[ch] = Date() }
            guard ch >= Self.analogChannels,
                  ch < Self.analogChannels + Self.maxAdatChannels, since[ch - Self.analogChannels] != nil
            else { continue }
            let i = ch - Self.analogChannels
            // calibration peak = highest SAMPLE peak of this measurement
            calPeak[i] = max(calPeak[i] ?? 0, s.peak)
            if s.peak >= pow(10, clipThresholdDBFS / 20) { calClip[i] = true }
            if 20 * log10(max(s.rms, 1e-12)) > activityThresholdDBFS {
                calActive[i] += 0.020   // the tap's 20 ms window
            }
        }

        // stall watchdog: the stream must keep flowing while measuring
        if isMeasuring, lastStatUptime != 0 {
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if nowNanos - lastStatUptime > 2_000_000_000 {
                cancelMeasurements(reason: "input stream stalled")
                tapError = "the input stream stalled — try again"
                onUpdate?()
                return
            }
        }

        // peak-hold decay: after the 2 s hold the readout falls toward
        // the CURRENT level until the next peak catches it — exactly
        // one precision: the linear hold, the rounding happens only in
        // heldPeakText
        let holdNow = Date()
        for i in 0..<holdPeak.count where holdPeak[i] > 0 {
            if let t = holdStamp[i], holdNow.timeIntervalSince(t) > holdSeconds {
                let target = livePeak[i]
                let moved = holdPeak[i] + (target - holdPeak[i]) * 0.25
                holdPeak[i] = max(moved, target)
                if holdPeak[i] <= 1e-10 {
                    holdPeak[i] = 0
                    holdStamp[i] = nil
                }
            }
        }

        // measurement close-outs
        let now = Date()
        let finished = Array(since)
            .filter { now.timeIntervalSince($0.value) >= Self.durationSeconds }
            .map { $0.key }
            .sorted()
        for ch in finished { finishMeasurement(ch) }

        onUpdate?()
        wake()   // measurements may have all ended — retire if idle
    }

    /// One measurement closes: validate the signal, then FREEZE the
    /// result until this channel is remeasured.
    private func finishMeasurement(_ ch: Int) {
        since[ch] = nil
        pendingRestore[ch] = nil
        let linear = calPeak[ch]
        calPeak[ch] = nil
        let peakDB = linear.map { 20 * log10(max($0, 1e-12)) }
        measuredPeak[ch] = peakDB
        let target = Self.targetDBFS
        let tol = Self.toleranceDB
        var status: Status
        if calClip[ch] {
            // A clipped waveform says nothing about how far past the
            // ceiling it went — an exact correction would be a lie.
            status = .clipped(peakDB ?? 0)
            QBLog.log(String(format: "adatgain: ch %d CLIPPED", ch + 1))
        } else if let peak = peakDB, calActive[ch] >= minActiveSeconds {
            let delta = target - peak
            if abs(delta) <= tol { status = .withinTarget(peak) }
            else if delta > 0 { status = .increase(delta) }
            else { status = .reduce(-delta) }
            QBLog.log(String(format: "adatgain: ch %d peak %.1f dBFS → %.1f dB adjustment",
                             ch + 1, peak, delta))
        } else {
            // Silence is its own result — never recommend a gain
            // increase off an empty take.
            measuredPeak[ch] = nil
            status = .noSignal
            QBLog.log("adatgain: ch \(ch + 1) not enough signal")
        }
        statuses[ch] = status
        wake()   // the last measurement may have ended
    }

    // sample-rate / device watchdog — armed while measuring
    private var measurementSampleRate: Double?
    private var measurementDevice: AudioDeviceID = 0

    private func stabilityWatchdog() {
        guard isMeasuring else { return }
        let live = InsertServer.deviceSampleRate()
        if let baseline = measurementSampleRate, let live,
           abs(live - baseline) > 0.5 {
            cancelMeasurements(reason: "sample rate changed")
            measurementSampleRate = nil
            measurementDevice = 0
            return
        }
        let dev = AutoGainEngine.findQuartetDevice() ?? 0
        if measurementDevice != 0, dev != measurementDevice {
            cancelMeasurements(reason: "device changed")
            stopTap()
            measurementSampleRate = nil
            measurementDevice = 0
        }
    }

    /// Live stream re-read: the ADAT channel count grows and shrinks
    /// with the sample rate/SMUX and the lightpipe. Results on a
    /// channel that left the stream are invalidated.
    func refreshChannelCount() {
        guard let dev = AutoGainEngine.findQuartetDevice(),
              let rate = InsertServer.deviceSampleRate(), rate > 0 else {
            if adatChannelCount != 0 {
                adatChannelCount = 0
                for ch in 0..<Self.maxAdatChannels { invalidate(channel: ch) }
                QBLog.log("adatgain: no Quartet device — ADAT channels invalidated")
            }
            return
        }
        let total = InputTap.inputChannelCount(dev)
        let count = max(0, min(Self.maxAdatChannels, total - Self.analogChannels))
        if count != adatChannelCount {
            adatChannelCount = count
            for ch in 0..<Self.maxAdatChannels where ch >= count { invalidate(channel: ch) }
            QBLog.log("adatgain: stream now exposes \(count) ADAT channels")
        }
    }

    private func housekeeping() {
        refreshChannelCount()
    }

    // MARK: tap management (the SHARED metering IOProc)

    private func ensureTap() {
        guard let dev = AutoGainEngine.findQuartetDevice() else {
            tapError = "the Quartet is not available in Core Audio"
            if isMeasuring { cancelMeasurements(reason: "device unavailable") }
            stopTap()
            return
        }
        refreshChannelCount()
        let wanted = Array(0..<(Self.analogChannels + adatChannelCount))
        guard !wanted.isEmpty else { stopTap(); return }
        if tap?.isRunning == true, tapChannels == wanted { return }
        tap?.stop()
        tap = nil
        tapChannels = []
        let newTap = InputTap()
        do {
            try newTap.start(device: dev, channels: wanted)
            tap = newTap
            tapChannels = wanted
            tapError = nil
            lastStatUptime = DispatchTime.now().uptimeNanoseconds
            for i in 0..<livePeak.count { livePeak[i] = 0 }
            holdPeak = [Double](repeating: 0, count: livePeak.count)
            holdStamp = [Date?](repeating: nil, count: livePeak.count)
            clipLatch = [Date?](repeating: nil, count: livePeak.count)
            QBLog.log("adatgain: metering tap started on \(wanted.count) input channels")
        } catch {
            tapError = error.localizedDescription
            QBLog.log("adatgain: metering tap failed — \(error.localizedDescription)")
        }
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        tapChannels = []
    }

    /// Auto Gain needs the device's one IOProc — step aside now (a
    /// running measurement is cancelled; existing results stay frozen).
    func pauseForAutoGain() {
        if !since.isEmpty { cancelMeasurements(reason: "Auto Gain started") }
        stopTap()
        wake()
    }
}


/// One ADAT channel strip — COMPACT by design: the analog bank's
/// horizontal meter carries it, the circular readout is gone. The old
/// circle repeated the level the meter already shows and consumed most
/// of each strip's height, pushing the second ADAT row and the Outputs
/// section far down. Now:
///
///     ADAT 1                     [ Assist… ]
///     [━━━━━━━━━━ 4-pt meter ━━━━━━━━━━━ ▪ −24.1]
///
///     ↑ Increase external gain by 12 dB      ← only while the
///                                        Done   session runs
///
///   - ONE control row to every strip: the channel heading left, the
///     session button right — the SAME control in every state
///     (Assist… → Stop while listening → Recheck when frozen)
///   - the shared horizontal input meter beneath, full width, with the
///     inline held-peak readout at its right end (one decimal, colored
///     by the held value's own band — never the live level's)
///   - a TRANSIENT two-line guidance under the meter: inserted only
///     while THIS strip hosts the assistant session (measuring or a
///     frozen verdict), collapsed on Done — the idle strip carries NO
///     reserved space, so all eight strips stay compact and the second
///     row sits close; the host strip's row grows just the two lines'
///     height while it runs, its neighbours staying top-aligned
///   - Done sits TRAILING on the second guidance line, never attached
///     to the instruction's tail ("Play the source" and Done stay two
///     separate things)
///   - no card, no border, no extra numeric readout: the meter's
///     inline number IS the readout
///
/// Purple is the measuring color, amber the adjustment, green success,
/// red a clip — always with words beside the color. No 48V/Soft-Limit/
/// polarity, no hardware gain: the strip measures and guides, the
/// external converter owns the preamp. One assistant runs at a time;
/// the controller owns the transitions, the tile mirrors them.

final class AdatTile: NSView {

    let index: Int
    var assistAction: (() -> Void)?
    /// The quiet "Done" action that closes the assistant's guidance.
    var doneAction: (() -> Void)?

    private let marker = NSView()             // the assistant's focus marker
    private let numberLabel = NSTextField(labelWithString: "ADAT 1")
    private let nameLabel = NSTextField(labelWithString: "")
    /// The shared horizontal input meter with its inline held-peak
    /// readout — the analog bank's own meter occupies the strip's body.
    private let levelMeter = GGLevelMeter()
    private let assistButton: NSButton
    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")
    private let doneButton: NSButton
    /// The transient two-line guidance block — collapsed while idle.
    private let guideCol = NSStackView()

    init(index: Int) {
        self.index = index
        assistButton = NSButton(title: "Assist…", target: nil, action: nil)
        doneButton = NSButton(title: "Done", target: nil, action: nil)
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        // HEADER — number + custom name (Settings ▸ Channel Names) left,
        // the compact session button right. One control-sized row: no
        // 32-pt header, no reserved dropdown space — the analog bank's
        // mode dropdown has no ADAT counterpart, and nothing in a
        // compact strip should take an empty row. Same name typography
        // as the analog strips (13-pt medium): one name treatment.
        numberLabel.stringValue = "ADAT \(index + 1)"
        numberLabel.font = GGTheme.nameFont
        numberLabel.textColor = GGTheme.primary
        numberLabel.lineBreakMode = .byTruncatingTail
        numberLabel.setContentCompressionResistancePriority(.init(1000), for: .horizontal)
        numberLabel.setContentHuggingPriority(.init(1000), for: .horizontal)
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = GGSpace.related
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // CONTENT-SIZED idle strip: 8 top + 24 header + 8 gap +
            // 12 meter + 14 bottom ≈ 66 pt. The bottom pad is the
            // strip's ONLY idle air below the meter — no reserved
            // instruction space (the guidance inserts itself while a
            // session runs and collapses on Done).
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        // the purple focus marker — an edge remnant that lights up while
        // THIS strip hosts the assistant session (the analog strips'
        // 2×14 selection marker geometry)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.widthAnchor.constraint(equalToConstant: 2).isActive = true
        marker.heightAnchor.constraint(equalToConstant: 14).isActive = true

        assistButton.bezelStyle = .recessed
        assistButton.controlSize = .small
        assistButton.font = NSFont.systemFont(ofSize: 11)
        assistButton.toolTip = "Gain Assist — measure this ADAT input's loudest level and get an external-gain recommendation"
        assistButton.target = self
        assistButton.action = #selector(assistClicked)
        assistButton.translatesAutoresizingMaskIntoConstraints = false
        assistButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        // compact: the button hugs its label ("Assist…" / "Stop" /
        // "Recheck") — no Auto Gain width to share, no other button
        // beside it to align with

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [marker, numberLabel, nameLabel,
                                            headerSpacer, assistButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = GGSpace.tight
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        col.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        // BODY — the analog bank's own meter: a 4-pt continuous peak
        // track with the inline held-peak readout ("−24.1", one decimal,
        // band-colored) riding the row's right end — the same fixed
        // line in every state, so no reflow. Zones + held-peak marker +
        // transient target + clip lamp (click to reset) all inside.
        levelMeter.heightAnchor.constraint(equalToConstant: 12).isActive = true
        levelMeter.toolTip = "ADAT input level · Adjust gain on the external preamp"
        col.addArrangedSubview(levelMeter)
        levelMeter.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        // FEEDBACK — the guidance's two lines, built once and toggled
        // visible by the session state: line1 the instruction (colored
        // by meaning), line2 the secondary cue with the TRAILING Done
        // action. Collapsed while idle — the strip returns to its
        // compact height and nothing here is ever a placeholder.
        line1.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        line1.lineBreakMode = .byTruncatingTail
        line1.usesSingleLineMode = true
        line1.textColor = GGTheme.primary
        line1.translatesAutoresizingMaskIntoConstraints = false
        line1.heightAnchor.constraint(equalToConstant: 16).isActive = true

        line2.font = NSFont.systemFont(ofSize: 10.5)
        line2.lineBreakMode = .byTruncatingTail
        line2.usesSingleLineMode = true
        line2.textColor = GGTheme.muted
        line2.translatesAutoresizingMaskIntoConstraints = false
        line2.heightAnchor.constraint(equalToConstant: 16).isActive = true
        // the instruction keeps the line's left edge; Done keeps the
        // right edge and never touches the instruction's tail
        line2.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // the QUIET dismissal — a dedicated plain text action, trailing
        doneButton.isBordered = false
        doneButton.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: GGTheme.softGray,
        ])
        doneButton.toolTip = "Done — closes this channel's guidance"
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.isHidden = true

        let guideSpacer = NSView()
        guideSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line2Row = NSStackView(views: [line2, guideSpacer, doneButton])
        line2Row.orientation = .horizontal
        line2Row.alignment = .centerY
        line2Row.spacing = 2
        line2Row.translatesAutoresizingMaskIntoConstraints = false

        guideCol.addArrangedSubview(line1)
        guideCol.addArrangedSubview(line2Row)
        guideCol.orientation = .vertical
        guideCol.alignment = .leading
        guideCol.spacing = 3
        guideCol.translatesAutoresizingMaskIntoConstraints = false
        // TRANSIENT, not reserved: the guidance exists in the stack but
        // is COLLAPSED while idle (NSStackView drops hidden arranged
        // views from layout — the same pattern as the optional channel
        // name in the header). Only the strip hosting a session grows;
        // the other seven stay compact and top-aligned.
        guideCol.isHidden = true
        col.addArrangedSubview(guideCol)
        guideCol.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        // common ancestor holds — the row spans the guidance area
        line2Row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
    }

    @objc private func assistClicked() { assistAction?() }
    @objc private func doneClicked() { doneAction?() }

    /// The 10 Hz fast path: the meter row's feed, nothing else. The
    /// horizontal meter takes the same consolidated feed the analog
    /// strips get — live level, held-peak marker + inline readout,
    /// transient target while THIS channel is being measured, and the
    /// clip flag (the LATCH is the meter's; click to reset). Off-stream
    /// channels read "—".
    func setLevels(live: Double, peakFraction: Double?, targetFraction: Double?,
                   clipped: Bool, unavailable: Bool) {
        levelMeter.update(level: live, peakFraction: peakFraction,
                          targetFraction: targetFraction, clip: clipped,
                          holdText: unavailable ? "—" : nil)
    }

    /// One full-state application from the controller's tick. The
    /// button is the SAME control in every state — only its label
    /// changes; the feedback lines are ALWAYS present (empty when
    /// idle) so the strip's geometry is state-independent.
    func update(status: AdatGainEngine.Status, focus: Bool, available: Bool) {
        let name = AdatGainEngine.adatName(index)
        nameLabel.stringValue = name
        nameLabel.isHidden = name.isEmpty

        // purple marker: only the strip hosting the active session
        marker.layer?.backgroundColor = focus ? GGTheme.autoGainRun.cgColor
                                              : NSColor.clear.cgColor
        marker.isHidden = !focus
        assistButton.isEnabled = available
        doneButton.isHidden = true

        var title = "Assist…"
        var line1Text = "", line1Color = GGTheme.primary
        var line2Text = "", line2Color = GGTheme.muted
        var frozen = false          // a measured verdict → Done + Recheck
        switch status {
        case .measuring where focus:
            title = "Stop"
            line1Text = "Play your loudest section"
            line2Text = engineRemainingText
            line2Color = GGTheme.purple
        case .measuring:
            break                    // another channel's session
        case .increase(let d):
            title = "Recheck"
            frozen = true
            line1Text = "↑ Increase external gain by \(Int(d.rounded())) dB"
            line1Color = GGTheme.amber
        case .reduce(let d):
            title = "Recheck"
            frozen = true
            line1Text = "↓ Reduce external gain by \(Int(d.rounded())) dB"
            line1Color = GGTheme.amber
        case .withinTarget:
            title = "Recheck"
            frozen = true
            line1Text = "✓ Within target"
            line1Color = GGTheme.green
        case .clipped:
            title = "Recheck"
            frozen = true
            line1Text = "Input clipped"
            line1Color = GGTheme.red
            line2Text = "Reduce external gain"
        case .noSignal:
            title = "Recheck"
            frozen = true
            // "during measurement" — the failure is about the take, not
            // the input: if signal NOW exists the meter already shows it
            line1Text = "No signal during measurement"
            line1Color = GGTheme.primary
            line2Text = "Play the source"
        case .idle:
            break
        }
        assistButton.title = focus ? title : "Assist…"
        line1.stringValue = focus ? line1Text : ""
        line1.textColor = line1Color
        line2.stringValue = focus ? line2Text : ""
        line2.textColor = line2Color
        doneButton.isHidden = !(focus && frozen)
        // the guidance RIDES the session: visible only while THIS strip
        // hosts one (measuring or a frozen verdict), collapsed the
        // moment it ends — the strip returns to its compact height and
        // the window re-fits once (the controller schedules it)
        guideCol.isHidden = !focus || status == .idle
    }

    /// Live countdown while THIS strip measures — a text-only touch
    /// from the 10 Hz tick ("Listening · 3 s" counts down second by
    /// second without a full refresh; the line's height is fixed, so
    /// no layout and no resize ever follow).
    func updateCountdown() {
        guard !guideCol.isHidden, line2.stringValue.hasPrefix("Listening") else { return }
        line2.stringValue = engineRemainingText
    }

    /// The session's countdown ("Listening · 3 s") from the engine.
    private var engineRemainingText: String {
        if let remaining = AdatGainEngine.shared.remaining(index) {
            return String(format: "Listening · %.0f s", ceil(remaining - 0.001))
        }
        return "Listening…"
    }

    /// DEBUG-ONLY (QB_AUTO_ASSIST harness): the strip's real geometry,
    /// so headless runs can verify what actually laid out instead of
    /// guessing from bitmaps.
    func debugLogGeometry(_ tag: String) {
        guard ProcessInfo.processInfo.environment["QB_AUTO_ASSIST"] != nil else { return }
        layoutSubtreeIfNeeded()
        QBLog.log("geo \(tag): tile \(Int(bounds.width))×\(Int(bounds.height)) meter.y \(Int(levelMeter.frame.minY)) meter.w \(Int(levelMeter.frame.width)) meter.h \(Int(levelMeter.frame.height)) btn.x \(Int(assistButton.frame.minX)) btn.w \(Int(assistButton.frame.width)) btn.h \(Int(assistButton.frame.height)) line1.x \(Int(line1.frame.minX)) line1.w \(Int(line1.frame.width)) line2.x \(Int(line2.frame.minX)) line2.w \(Int(line2.frame.width)) done.x \(Int(doneButton.frame.minX)) done.w \(Int(doneButton.frame.width))")
    }
}
