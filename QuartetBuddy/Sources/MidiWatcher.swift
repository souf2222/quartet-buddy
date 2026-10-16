import Foundation
import CoreMIDI

/// Watches a CoreMIDI source (e.g. the "Quartet" endpoint, which carries the
/// keyboard plugged into the Quartet's MIDI port) and reports note/CC events.
final class MidiWatcher {

    struct Trigger: Codable, Equatable {
        var channel: Int      // 0-15
        var kind: Kind        // note or cc
        var number: Int       // note or controller number
        enum Kind: Int, Codable { case note = 0, cc = 1 }
    }

    struct MidiEvent {
        var channel: Int
        var kind: Trigger.Kind
        var number: Int
        var value: Int
        var isDown: Bool
    }

    var onTrigger: ((Trigger, Bool) -> Void)?
    var onAnyEvent: ((MidiEvent) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private(set) var endpointName: String?

    func start(matchingSourceNamed name: String) -> Bool {
        var status = MIDIClientCreate("QuartetBuddy" as CFString, nil, nil, &client)
        guard status == noErr else { return false }

        var found = false
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var nm: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(src, kMIDIPropertyName, &nm) == noErr,
                  let nameCF = nm?.takeUnretainedValue() as String? else { continue }
            if nameCF == name {
                status = MIDIInputPortCreate(client, "in" as CFString, { pktList, refCon, _ in
                    let myself = Unmanaged<MidiWatcher>.fromOpaque(refCon!).takeUnretainedValue()
                    myself.handle(pktList)
                }, Unmanaged.passUnretained(self).toOpaque(), &port)
                guard status == noErr else { return false }
                MIDIPortConnectSource(port, src, nil)
                endpointName = nameCF
                found = true
                break
            }
        }
        return found
    }

    private func handle(_ pktList: UnsafePointer<MIDIPacketList>) {
        let list = pktList.pointee
        var offset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        let base = UnsafeRawPointer(pktList)
        for _ in 0..<list.numPackets {
            let packetPtr = (base + offset).assumingMemoryBound(to: MIDIPacket.self)
            let packet = packetPtr.pointee
            let dataPtr = UnsafeRawPointer(packetPtr)
                + MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
            let bytes = dataPtr.assumingMemoryBound(to: UInt8.self)
            var idx = 0
            while idx < Int(packet.length) {
                let status = bytes[idx]
                let channel = Int(status & 0x0F)
                switch status & 0xF0 {
                case 0x90 where idx + 2 < Int(packet.length):
                    let note = Int(bytes[idx + 1])
                    let vel = Int(bytes[idx + 2])
                    let isDown = vel > 0
                    onAnyEvent?(MidiEvent(channel: channel, kind: .note, number: note, value: vel, isDown: isDown))
                    onTrigger?(Trigger(channel: channel, kind: .note, number: note), isDown)
                    idx += 3
                case 0x80 where idx + 2 < Int(packet.length):
                    let note = Int(bytes[idx + 1])
                    onAnyEvent?(MidiEvent(channel: channel, kind: .note, number: note, value: 0, isDown: false))
                    onTrigger?(Trigger(channel: channel, kind: .note, number: note), false)
                    idx += 3
                case 0xB0 where idx + 2 < Int(packet.length):
                    let cc = Int(bytes[idx + 1])
                    let val = Int(bytes[idx + 2])
                    let isDown = val >= 64
                    onAnyEvent?(MidiEvent(channel: channel, kind: .cc, number: cc, value: val, isDown: isDown))
                    onTrigger?(Trigger(channel: channel, kind: .cc, number: cc), isDown)
                    idx += 3
                default:
                    idx += 1
                }
            }
            offset += MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
                     + Int(packet.length)
        }
    }
}
