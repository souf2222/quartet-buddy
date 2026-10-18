import Foundation
import CoreAudio

/// The bridge between the macOS volume slider and the Quartet's real fader.
///
/// The Quartet's driver exposes a CoreAudio "volume" control with the
/// fader's exact range (−64…0 dB) — but it is a pure display: writing it
/// changes nothing audible (verified with a live −64 dB dip test). macOS
/// steps it natively with the volume keys (the media key tap is listen-only
/// on this macOS and cannot swallow NX_SYSDEFINED anyway).
///
/// Quartet Buddy turns that dead display into a real control, bound both
/// ways:
///  • enforce(_:) — Quartet → macOS: copy the fader level onto the slider
///    whenever the volume changes (glue tree + echoes).
///  • onSliderMoved — macOS → Quartet: fired on the main thread whenever the
///    slider moves for any reason (volume key press, a hand-dragged slider
///    in Sound settings, our own enforce writes). The delegate applies the
///    level to the real fader and filters out our own writes by value.
final class OSVolumeMirror {

    /// Fired on the main thread with the slider's new level in dB.
    var onSliderMoved: ((Double) -> Void)?

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

    // MARK: - macOS → Quartet

    private func sliderChanged() {
        guard let dev = device(),
              let db = Self.readDecibels(from: dev) else { return }
        onSliderMoved?(db)
    }

    private func armListener(on dev: AudioDeviceID) {
        guard dev != listenedDevice else { return }
        if let old = listenedDevice, let proc = listenerProc {
            var addr = Self.volumeAddress()
            AudioObjectRemovePropertyListener(old, &addr, proc,
                                              Unmanaged.passUnretained(self).toOpaque())
        }
        var addr = Self.volumeAddress()
        let proc: AudioObjectPropertyListenerProc = { _, _, _, refCon in
            let myself = Unmanaged<OSVolumeMirror>.fromOpaque(refCon!).takeUnretainedValue()
            DispatchQueue.main.async { myself.sliderChanged() }
            return noErr
        }
        listenerProc = proc
        if AudioObjectAddPropertyListener(dev, &addr, proc,
                                           Unmanaged.passUnretained(self).toOpaque()) == noErr {
            listenedDevice = dev
        }
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
