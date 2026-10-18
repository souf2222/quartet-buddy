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
/// Quartet Buddy turns those dead controls into real ones, bound both ways:
///  • enforce(_:) / enforceMute(_:) — Quartet → macOS: copy the hardware
///    state onto the OS controls whenever it changes (glue tree + echoes).
///  • onSliderMoved / onMuteChanged — macOS → Quartet: fired on the main
///    thread whenever the OS controls move for any reason (key press, a
///    hand-dragged slider, our own enforce writes). The delegate applies the
///    state to the hardware and filters out its own writes by value.
final class OSVolumeMirror {

    /// Fired on the main thread with the slider's new level in dB.
    var onSliderMoved: ((Double) -> Void)?

    /// Fired on the main thread with the OS mute's new state.
    var onMuteChanged: ((Bool) -> Void)?

    private var listenedDevice: AudioDeviceID?
    private var listenerProc: AudioObjectPropertyListenerProc?
    private var cachedDeviceID: AudioDeviceID?

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
    func enforce(_ db: Double) {
        guard let dev = device() else {
            QBLog.log("slider sync: no Quartet in CoreAudio")
            return
        }
        armListener(on: dev)
        if Self.write(decibels: db, to: dev) {
            QBLog.log(String(format: "slider sync: macOS slider -> %.1f dB", db))
        } else {
            QBLog.log("slider sync: slider write failed")
        }
    }

    /// Copy the hardware mute state onto the macOS mute display.
    func enforceMute(_ muted: Bool) {
        guard let dev = device() else { return }
        armListener(on: dev)
        if Self.write(mute: muted, to: dev) {
            QBLog.log("mute sync: OS mute -> \(muted ? "on" : "off")")
        } else {
            QBLog.log("mute sync: OS mute write failed")
        }
    }

    // MARK: - macOS → Quartet

    private func sliderChanged() {
        guard let dev = device(),
              let db = Self.readDecibels(from: dev) else { return }
        onSliderMoved?(db)
    }

    private func muteChanged() {
        guard let dev = device(),
              let m = Self.readMute(from: dev) else { return }
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

    /// Mirror the hardware mute state onto the OS mute control.
    static func write(mute: Bool, to dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &v) == noErr
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
