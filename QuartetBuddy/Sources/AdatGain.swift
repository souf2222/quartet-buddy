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
/// number: no meaningful signal → "Not enough signal" (never a huge
/// gain recommendation out of silence); a peak at the ceiling →
/// "clipped — reduce gain" (the level above full scale is
/// unknowable). A result says "verified during the last check", never
/// "permanently safe".
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
    /// Display PEAK HOLD for the ADAT dial (device channels, linear):
    /// a sample peak catches the hold instantly; it holds still for
    /// `holdSeconds`, then decays slowly so the dial stays readable
    /// after the gain knob was turned. Started over only by a new peak.
    private var holdPeak = [Double](repeating: 0,
                                    count: analogChannels + maxAdatChannels)
    private var holdStamp = [Date?](repeating: nil,
                                    count: analogChannels + maxAdatChannels)
    /// Recent-clipping latch for the dial's red indication: a clipped
    /// sample paints the arc red for 1 s (word: the dial is a live
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

    // MARK: the ADAT dial's peak hold

    /// The held peak in dBFS (nil = below the display floor — the dial
    /// reads "−∞"). The center readout uses it.
    func heldPeakDBFS(_ deviceChannel: Int) -> Double? {
        guard deviceChannel >= 0,
              deviceChannel < Self.analogChannels + Self.maxAdatChannels else { return nil }
        let p = holdPeak[deviceChannel]
        return p > 1e-10 ? 20 * log10(p) : nil
    }

    /// The center readout: the held peak as a WHOLE number ("−18") —
    /// full precision is kept in holdPeak, only the display rounds —
    /// "−∞" while silent, "—" when the channel is not on the stream.
    func heldPeakText(_ deviceChannel: Int, unavailable: Bool) -> String {
        if unavailable { return "—" }
        guard let db = heldPeakDBFS(deviceChannel) else { return "−∞" }
        return String(format: "%d", Int(db.rounded())).replacingOccurrences(of: "-", with: "−")
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

// MARK: - ADAT level meter (flat bar, peak + target markers)

/// A thin horizontal level bar: recessed bed, a flat dB-scale fill, a
/// faint TARGET tick (always visible — the −12 dBFS line), a bright
/// PEAK marker (the measured reference) — and a fill color that
/// carries the assistance state: green normally, purple while a
/// measurement runs, red when the channel clipped.
// MARK: - ADAT circular input-level dial

/// A READ-ONLY instrument display that borrows the analog knob's
/// geometry (60-pt dial, thick 270° track, opening at the bottom) but
/// not its interaction: no dragging, no editing, no hover affordance.
/// Analog is a control; this is a meter. Kept deliberately MINIMAL:
///   - the arc is the live input level, its whole illuminated length
///     one flat color for the current band (Adobe Audition's meter
///     coloring: green below −18 dBFS, amber from −18, red from −6 —
///     an application convention, not a universal standard)
///   - the center shows the held peak as a WHOLE number (full
///     precision is kept internally; only the display rounds)
///   - no unit label, no outer tick, no captions — the channel
///     heading and the Assist button stay the strip's only text
final class AdatLevelDial: NSView {

    /// LIVE input level on the −60…0 dBFS display scale.
    var level: Double = 0 { didSet { needsDisplay = true } }
    /// The center readout — the whole-number held peak ("−18"),
    /// "−∞" while silent, "—" when the channel is not on the stream.
    var valueText: String = "−∞" { didSet { needsDisplay = true } }
    /// No channel on the current stream — "—", no arc.
    var unavailable = false { didSet { needsDisplay = true } }
    /// A sample hit the digital ceiling within the last second (the
    /// UNROUNDED sample peak decides — never the displayed integer).
    var clipped = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 60) }

    // the analog dial's geometry (GainKnob): a 60-pt dial = 5.1-pt stroke
    private var stroke: CGFloat { max(2.2, bounds.width * 0.085) }
    private var trackRadius: CGFloat { bounds.width / 2 - stroke / 2 - 0.75 }
    private static let startAngle: CGFloat = 225
    private static let sweepAngle: CGFloat = 270

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)

        func arc(_ sweep: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: trackRadius,
                        startAngle: Self.startAngle,
                        endAngle: Self.startAngle - sweep, clockwise: true)
            p.lineWidth = stroke
            p.lineCapStyle = .butt
            return p
        }

        // the quiet remainder of the dial + the LIVE level arc in the
        // level band's flat color (on the −60…0 scale: −18 dBFS = 0.7,
        // −6 dBFS = 0.9). The clip latch says "ceiling" in the same
        // red — but it is driven by the unrounded sample peak.
        GGTheme.knobTrack.setStroke()
        arc(Self.sweepAngle).stroke()
        if !unavailable {
            let f = max(0, min(1, level))
            if f > 0.002 {
                (clipped || f >= 0.9 ? GGTheme.red
                    : f >= 0.7 ? GGTheme.amber
                    : GGTheme.knobArc).setStroke()
                arc(CGFloat(f) * Self.sweepAngle).stroke()
            }
        }

        // CENTER readout — the held peak, off-white, straight on the
        // panel (no raised disc: this display never implies a control)
        let valueString = unavailable ? "—" : valueText
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let silent = valueString == "−∞" || valueString == "—"
        let value = NSAttributedString(string: valueString, attributes: [
            .font: valueFont,
            .foregroundColor: silent ? GGTheme.muted : GGTheme.knobValue,
        ])
        if let ctx = NSGraphicsContext.current?.cgContext {
            let line = CTLineCreateWithAttributedString(value)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            // the ink's cap height rides baseline…baseline+capHeight —
            // half of it below the dial's center centers the digits
            ctx.textPosition = CGPoint(x: c.x - width / 2, y: c.y - valueFont.capHeight / 2)
            CTLineDraw(line, ctx)
        } else {
            value.draw(at: NSPoint(x: c.x, y: c.y - valueFont.capHeight / 2))
        }
    }
}
// MARK: - ADAT channel tile (with the inline assistant)

/// One ADAT channel strip in the SAME open, divided-column structure
/// as the analog bank: name + hairline on top; the circular read-only
/// dial LEFT on the knob's spot; and the assist control RIGHT on the
/// Auto Gain spot — ONE button whose label follows the session state
/// (Gain Assist… → Stop while listening → Recheck when frozen), with
/// a RESERVED two-line feedback column beneath it so the row never
/// jumps when a status arrives or leaves:
///
///     ── ADAT 1 ─────────────────────
///     ( −20 )    [ Recheck ]
///     ────────   ↑ Increase by 8 dB
///                On external preamp    Done
///
/// No card, no border, no heading — the assistant is inline text,
/// left-aligned with the button inside the button column. Purple is
/// the measuring color, amber the adjustment, green success, red a
/// clip — always WITH words next to the color.

final class AdatTile: NSView {

    let index: Int
    var assistAction: (() -> Void)?
    /// The quiet "Done" action that closes the assistant's guidance.
    var doneAction: (() -> Void)?

    private let marker = NSView()             // the assistant's focus marker
    private let numberLabel = NSTextField(labelWithString: "ADAT 1")
    private let nameLabel = NSTextField(labelWithString: "")
    private let dial = AdatLevelDial()
    private let assistButton: NSButton
    private let line1 = NSTextField(labelWithString: "")
    private let line2 = NSTextField(labelWithString: "")
    private let doneButton: NSButton

    init(index: Int) {
        self.index = index
        assistButton = NSButton(title: "Gain Assist…", target: nil, action: nil)
        doneButton = NSButton(title: "Done", target: nil, action: nil)
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        numberLabel.stringValue = "ADAT \(index + 1)"
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = GGSpace.related
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        // HEADER — number + custom name (Settings ▸ Channel Names),
        // the purple focus marker is an edge remnant that lights up
        // while THIS tile hosts the assistant session (mirrors the
        // analog strips' selection marker)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1.5
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.widthAnchor.constraint(equalToConstant: 3).isActive = true
        marker.heightAnchor.constraint(equalToConstant: 15).isActive = true
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [marker, numberLabel, nameLabel, headerSpacer])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = GGSpace.tight
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        col.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        // the analog section's separator treatment: one hairline under
        // the name (the analog strips' meter row sits in this slot)
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        col.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        // CONTROL ROW — the circular meter LEFT on the knob's spot;
        // RIGHT the assist column: the session button + the reserved
        // two-line feedback area (both always present — width and
        // heights fixed so no row ever jumps on a status update)
        dial.translatesAutoresizingMaskIntoConstraints = false
        dial.toolTip = "ADAT input level · Adjust gain on the external preamp"
        dial.widthAnchor.constraint(equalToConstant: 60).isActive = true
        dial.heightAnchor.constraint(equalToConstant: 60).isActive = true

        assistButton.bezelStyle = .recessed
        assistButton.controlSize = .small
        assistButton.font = NSFont.systemFont(ofSize: 11)
        assistButton.toolTip = "Gain Assist — measure this ADAT input's loudest level and get an external-gain recommendation"
        assistButton.target = self
        assistButton.action = #selector(assistClicked)
        assistButton.translatesAutoresizingMaskIntoConstraints = false
        assistButton.widthAnchor.constraint(equalToConstant: 108).isActive = true
        assistButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        line1.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        line1.lineBreakMode = .byTruncatingTail
        line1.usesSingleLineMode = true
        line1.textColor = GGTheme.primary
        line1.translatesAutoresizingMaskIntoConstraints = false
        line1.heightAnchor.constraint(equalToConstant: 16).isActive = true
        line1.widthAnchor.constraint(equalToConstant: 148).isActive = true

        line2.font = NSFont.systemFont(ofSize: 10.5)
        line2.lineBreakMode = .byTruncatingTail
        line2.usesSingleLineMode = true
        line2.textColor = GGTheme.muted
        line2.translatesAutoresizingMaskIntoConstraints = false
        line2.heightAnchor.constraint(equalToConstant: 16).isActive = true
        line2.setContentHuggingPriority(.init(1), for: .horizontal)

        // the QUIET dismissal — a plain text action after measurement
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

        let line2Row = NSStackView(views: [line2, doneButton])
        line2Row.orientation = .horizontal
        line2Row.alignment = .centerY
        line2Row.spacing = 2
        line2Row.translatesAutoresizingMaskIntoConstraints = false
        line2Row.widthAnchor.constraint(equalToConstant: 148).isActive = true

        let assistCol = NSStackView(views: [assistButton, line1, line2Row])
        assistCol.orientation = .vertical
        assistCol.alignment = .leading
        assistCol.spacing = 5
        assistCol.translatesAutoresizingMaskIntoConstraints = false

        let midSpacer = NSView()
        midSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let controlRow = NSStackView(views: [dial, midSpacer, assistCol])
        controlRow.orientation = .horizontal
        controlRow.alignment = .top
        controlRow.spacing = GGSpace.related
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        col.addArrangedSubview(controlRow)
        controlRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
    }

    @objc private func assistClicked() { assistAction?() }
    @objc private func doneClicked() { doneAction?() }

    /// The 10 Hz fast path: arc and center readout only.
    func setLevels(live: Double, holdText: String,
                   clipped: Bool, unavailable: Bool) {
        dial.level = live
        dial.valueText = holdText
        dial.clipped = clipped
        dial.unavailable = unavailable
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

        var title = "Gain Assist…"
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
            line1Text = "↑ Increase by \(Int(d.rounded())) dB"
            line1Color = GGTheme.amber
            line2Text = "On external preamp"
        case .reduce(let d):
            title = "Recheck"
            frozen = true
            line1Text = "↓ Reduce by \(Int(d.rounded())) dB"
            line1Color = GGTheme.amber
            line2Text = "On external preamp"
        case .withinTarget(let peak):
            title = "Recheck"
            frozen = true
            line1Text = "✓ Within target"
            line1Color = GGTheme.green
            line2Text = "Target \(Int(peak.rounded())) dBFS"
        case .clipped:
            title = "Recheck"
            frozen = true
            line1Text = "Input clipped"
            line1Color = GGTheme.red
            line2Text = "Reduce external gain"
        case .noSignal:
            title = "Recheck"
            frozen = true
            line1Text = "No signal detected"
            line1Color = GGTheme.primary
            line2Text = "Play the source"
        case .idle:
            break
        }
        assistButton.title = focus ? title : "Gain Assist…"
        line1.stringValue = focus ? line1Text : ""
        line1.textColor = line1Color
        line2.stringValue = focus ? line2Text : ""
        line2.textColor = line2Color
        doneButton.isHidden = !(focus && frozen)
    }

    /// The session's countdown ("Listening · 3 s") from the engine.
    private var engineRemainingText: String {
        if let remaining = AdatGainEngine.shared.remaining(index) {
            return String(format: "Listening · %.0f s", ceil(remaining - 0.001))
        }
        return "Listening…"
    }

    /// DEBUG-ONLY (QB_AUTO_ASSIST harness): the assistant column's
    /// real geometry, so headless runs can verify what actually laid
    /// out instead of guessing from bitmaps.
    func debugLogGeometry(_ tag: String) {
        guard ProcessInfo.processInfo.environment["QB_AUTO_ASSIST"] != nil else { return }
        layoutSubtreeIfNeeded()
        QBLog.log("geo \(tag): tile \(Int(bounds.width))×\(Int(bounds.height)) dial.x \(Int(dial.frame.minX)) dial.w \(Int(dial.frame.width)) line1.x \(Int(line1.frame.minX)) line1.w \(Int(line1.frame.width)) line2.x \(Int(line2.frame.minX)) line2.w \(Int(line2.frame.width)) done.w \(Int(doneButton.frame.width))")
    }
}
