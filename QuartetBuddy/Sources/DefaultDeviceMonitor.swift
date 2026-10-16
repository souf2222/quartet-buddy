import Foundation
import CoreAudio

/// Tracks whether the Quartet is the current default output device
/// (we only intercept the volume keys when it is).
final class DefaultDeviceMonitor {

    var quartetIsDefault: (() -> Void)?
    var quartetIsNotDefault: (() -> Void)?

    private var lastState: Bool?
    private var listener: AudioObjectPropertyListenerProc?
    private var listenersInstalled = false

    private static let sysObject = AudioObjectID(kAudioObjectSystemObject)

    func start() {
        installListeners()
        poll()
    }

    /// True if the default output device is the Quartet.
    static func quartetIsDefaultOutput() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(Self.sysObject, &addr, 0, nil, &size, &dev) == noErr else {
            return false
        }
        return deviceName(dev) == "Quartet"
    }

    static func deviceName(_ dev: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr else {
            return ""
        }
        return name as String
    }

    func poll() {
        let isDefault = Self.quartetIsDefaultOutput()
        if isDefault != lastState {
            lastState = isDefault
            if isDefault {
                quartetIsDefault?()
            } else {
                quartetIsNotDefault?()
            }
        }
    }

    private func installListeners() {
        guard !listenersInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let proc: AudioObjectPropertyListenerProc = { _, _, _, refCon in
            let myself = Unmanaged<DefaultDeviceMonitor>.fromOpaque(refCon!).takeUnretainedValue()
            DispatchQueue.main.async { myself.poll() }
            return noErr
        }
        listener = proc
        if AudioObjectAddPropertyListener(Self.sysObject, &addr, proc,
                                          Unmanaged.passUnretained(self).toOpaque()) == noErr {
            listenersInstalled = true
        }
    }
}
