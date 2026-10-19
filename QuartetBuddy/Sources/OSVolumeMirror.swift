import Foundation
import CoreAudio

/// The bridge between macOS's audio controls and the Quartet's real fader.
///
/// The Quartet's driver exposes CoreAudio volume + mute controls with the
/// fader's exact range (−64…0 dB) — but they are pure display: writing them
/// changes nothing audible (verified with a live −64 dB dip test). macOS
/// drives them natively (volume keys, F10, Control Center — the media key
/// tap is gone entirely).
///
/// Quartet Buddy turns those dead controls into real ones:
///  • volume — bound BOTH ways: enforce(_:) copies the hardware level onto
///    the slider (glue tree + echoes), and onSliderMoved applies OS slider
///    moves to the fader. Volume writes are driver-safe (proven over hours).
///  • mute — ONE way only: onMuteChanged applies OS mute changes (F10,
///    Control Center) to the hardware mute. The app never writes the OS
///    mute: doing so wedged the Apogee driver (CoreAudio 'what' errors on
///    every volume write until the Quartet was power-cycled — live-tested
///    incident, Oct 18 2026). Cosmetic side effect: mutes done in Apogee
///    Control 2 / on the touchscreen don't update the macOS mute display.
final class OSVolumeMirror {

    /// Fired on the main thread with the slider's new level in dB.
    var onSliderMoved: ((Double) -> Void)?

    /// Fired on the main thread with the OS mute's new state.
    var onMuteChanged: ((Bool) -> Void)?

    /// True when the Quartet's macOS volume control is missing entirely
    /// (HAL 'who!' on every volume read/write — driver wedge observed
    /// after the device re-enumerates, e.g. overnight USB churn). The
    /// binding cannot work until the Quartet is power-cycled; reset on
    /// every device-list change (replug gives the control back).
    private(set) static var volumeControlMissing = false

    /// kAudioHardwareUnknownPropertyError — 'who!'
    private static let whoErr: OSStatus = 2003332927

    private var listenedDevice: AudioDeviceID?
    private var listenerProc: AudioObjectPropertyListenerProc?
    private var cachedDeviceID: AudioDeviceID?
    private var lastEnforcedDB: Double?
    /// The last OS mute state delivered upward (nil before the first read).
    /// The listener proc fires on ANY output-property notification — volume
    /// writes included — so without a baseline a stale OS mute would be
    /// re-delivered as a "change" and applied to whatever output is selected
    /// *now* (muting the just-switched-to output — observed Oct 19 2026).
    /// See muteChanged().
    private var lastMute: Bool?
    /// True after a volume-target switch: the OS mute flag is stale — it
    /// still reflects the PREVIOUS target's last F10 state (the app never
    /// writes the OS mute; Oct 18 driver wedge). The next OS mute change
    /// is that stale state being cleared (user's first F10 press, or
    /// macOS auto-unmuting on a volume write), NOT a mute request for the
    /// newly selected output. Absorb it. Observed live Oct 19 2026:
    /// muting Main Out then switching muted the Headphones.
    private var absorbNextMuteChange = false
    private var systemListenerProc: AudioObjectPropertyListenerProc?
    private var retryTimer: Timer?
    private var retryCount = 0

    /// Watch the system device list. When the Quartet is (re)plugged it gets
    /// a fresh CoreAudio device id, and USB presence fires BEFORE CoreAudio
    /// has published the new device — so the mirror re-binds itself here,
    /// from the CoreAudio event, when the device really exists.
    func start() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let proc: AudioObjectPropertyListenerProc = { _, _, _, refCon in
            let myself = Unmanaged<OSVolumeMirror>.fromOpaque(refCon!).takeUnretainedValue()
            DispatchQueue.main.async { myself.rebind() }
            return noErr
        }
        systemListenerProc = proc
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, proc,
                                       Unmanaged.passUnretained(self).toOpaque())
    }

    /// The device list changed: drop the stale id + listener binding and
    /// re-apply the last known level to the (possibly new) Quartet device.
    private func rebind() {
        Self.volumeControlMissing = false
        guard let db = lastEnforcedDB else { return }
        cachedDeviceID = nil
        listenedDevice = nil     // force fresh listener registration
        enforce(db)
    }

    /// The Quartet's CoreAudio device id, by name (nil if not present).
    /// Cached — this runs on every slider event; one name read validates the
    /// cache, a full device scan only happens on a miss (e.g. after replug).
    /// Main-thread only (enforce and the listener callback both run there).
    private func device() -> AudioDeviceID? {
        if let id = cachedDeviceID, DefaultDeviceMonitor.deviceName(id) == "Quartet" {
            return id
        }
        guard let id = Self.scanForQuartet() else {
            cachedDeviceID = nil
            return nil
        }
        cachedDeviceID = id
        return id
    }

    // MARK: - Quartet → macOS

    /// Copy `db` (the real fader level) onto the macOS volume slider.
    /// RANGE-VALIDATED: a wedged driver fed a -255 dB sentinel through here
    /// (Oct 19 2026), which then echoed into the hardware fader and crashed
    /// the whole unit. Nothing outside the fader's -64…0 dB (+ slack) is
    /// ever written to CoreAudio.
    func enforce(_ db: Double) {
        guard db.isFinite, db >= -65, db <= 1 else {
            QBLog.log(String(format: "slider sync: IGNORED bogus level %.1f dB", db))
            return
        }
        lastEnforcedDB = db
        guard let dev = device() else {
            QBLog.log("slider sync: no Quartet in CoreAudio yet — will retry")
            scheduleRetry()
            return
        }
        cancelRetry()
        armListener(on: dev)
        if !Self.volumeControlExists(dev) {
            Self.noteMissingControl()
            return
        }
        if Self.write(decibels: db, to: dev) {
            QBLog.log(String(format: "slider sync: macOS slider -> %.1f dB", db))
        } else if !Self.volumeControlMissing {
            QBLog.log("slider sync: slider write failed")
        }
    }

    /// Does the device expose the output volume control at all?
    private static func volumeControlExists(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(dev, &addr)
    }

    /// The control is gone ('who!' wedge) — the volume-keys binding is
    /// dead until the Quartet is power-cycled. Say it once, clearly.
    private static func noteMissingControl() {
        guard !volumeControlMissing else { return }
        volumeControlMissing = true
        QBLog.log("volume control MISSING on the Quartet (HAL 'who!') — " +
                  "the macOS volume keys binding is dead until the Quartet is power-cycled")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .init("qb.volumeControlMissing"), object: nil)
        }
    }

    // MARK: - retry (device not yet enumerated when presence beat CoreAudio)

    private func scheduleRetry() {
        guard retryCount < 4 else { return }   // the devices listener re-triggers anyway
        let delays: [TimeInterval] = [0.5, 1, 2, 4]
        retryTimer = Timer.scheduledTimer(withTimeInterval: delays[retryCount], repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            guard let self, let db = self.lastEnforcedDB else { return }
            self.retryCount += 1
            self.enforce(db)
        }
    }

    private func cancelRetry() {
        retryCount = 0
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - macOS → Quartet

    private func sliderChanged() {
        guard let dev = device(),
              let db = Self.readDecibels(from: dev) else { return }
        onSliderMoved?(db)
    }

    /// Volume-target switch (Main Out ↔ Headphones): arm the absorb latch.
    /// The OS mute flag still carries the OLD target's state and cannot be
    /// written (driver wedge, Oct 18) — the next OS mute change is stale
    /// cleanup, never a real mute request for the newly selected output.
    func noteTargetSwitch() {
        absorbNextMuteChange = true
    }

    private func muteChanged() {
        guard let dev = device(),
              let m = Self.readMute(from: dev) else { return }
        // Target just switched: this change clears the previous output's
        // stale OS mute (first F10 press, macOS volume-write auto-unmute).
        // Applying it muted/unmuted the just-switched-to output (Oct 19).
        if absorbNextMuteChange {
            absorbNextMuteChange = false
            lastMute = m
            QBLog.log("mute sync: absorbed stale OS mute (\(m ? "on" : "off")) after target switch")
            return
        }
        // Only deliver REAL changes. The listener fires on any output
        // property notification (our own enforce() volume writes included),
        // and the OS mute goes stale whenever the volume target switches:
        // muting output A leaves the OS mute on, and the app never writes
        // the OS mute (driver wedge — see header). Delivering that stale
        // value right after a switch muted the newly selected output.
        guard m != lastMute else { return }
        lastMute = m
        onMuteChanged?(m)
    }

    private static let listenedSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyMute
    ]

    private func armListener(on dev: AudioDeviceID) {
        guard dev != listenedDevice else { return }
        if let old = listenedDevice, let proc = listenerProc {
            for sel in Self.listenedSelectors {
                var addr = AudioObjectPropertyAddress(mSelector: sel,
                                                      mScope: kAudioDevicePropertyScopeOutput,
                                                      mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListener(old, &addr, proc,
                                                  Unmanaged.passUnretained(self).toOpaque())
            }
        }
        let proc: AudioObjectPropertyListenerProc = { _, _, _, refCon in
            let myself = Unmanaged<OSVolumeMirror>.fromOpaque(refCon!).takeUnretainedValue()
            DispatchQueue.main.async {
                myself.sliderChanged()
                myself.muteChanged()
            }
            return noErr
        }
        listenerProc = proc
        var allOK = true
        for sel in Self.listenedSelectors {
            var addr = AudioObjectPropertyAddress(mSelector: sel,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListener(dev, &addr, proc,
                                               Unmanaged.passUnretained(self).toOpaque()) != noErr {
                allOK = false
            }
        }
        listenedDevice = allOK ? dev : nil
        // Seed the dedupe baseline (see lastMute): a stale OS mute at bind
        // time — e.g. the other output was muted before switching targets —
        // must not be delivered as a change by the first spurious
        // notification (any enforce() volume write fires one).
        if allOK { lastMute = Self.readMute(from: dev) }
    }

    // MARK: - CoreAudio helpers

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The Quartet's device id, by name (nil if not present in CoreAudio).
    static func scanForQuartet() -> AudioDeviceID? {
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
        return ids.first { DefaultDeviceMonitor.deviceName($0) == "Quartet" }
    }

    /// The slider's current level in dB (nil if it has no volume control).
    static func readDecibels(from dev: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    /// The OS mute flag (nil if the device has no mute control).
    static func readMute(from dev: AudioDeviceID) -> Bool? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v == 1
    }

    /// Write the level onto the slider. Prefers VolumeDecibels (the HAL then
    /// applies its own taper); falls back to VolumeScalar using the HAL's
    /// square-law taper: scalar = (normalized dB)².
    static func write(decibels db: Double, to dev: AudioDeviceID) -> Bool {
        var dbAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                mScope: kAudioDevicePropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        if AudioObjectHasProperty(dev, &dbAddr),
           AudioObjectIsPropertySettable(dev, &dbAddr, &settable) == noErr,
           settable.boolValue {
            var v = Float32(db)
            if AudioObjectSetPropertyData(dev, &dbAddr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                return true
            }
        }
        // fallback: VolumeScalar, square-law taper
        // (a 'who!' error here means the control is gone entirely — flagged)
        var lo = -64.0, hi = 0.0
        var rAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels,
                                               mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var rSize = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(dev, &rAddr, 0, nil, &rSize, &range) == noErr,
           range.mMaximum > range.mMinimum {
            lo = Double(range.mMinimum)
            hi = Double(range.mMaximum)
        }
        let norm = min(1, max(0, (db - lo) / (hi - lo)))
        var s = Float32(norm * norm)
        var sAddr = volumeAddress()
        return AudioObjectSetPropertyData(dev, &sAddr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &s) == noErr
    }
}
