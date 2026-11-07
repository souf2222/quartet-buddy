// direct_probe2.swift — decode the device state via diffs: poll → write → poll.
// Run with the daemon stopped (the exclusive open).
import Foundation
import IOKit
import IOUSBHost

guard let dict = IOServiceMatching("IOUSBHostDevice") else { fatalError("no dict") }
var iterator: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator) == KERN_SUCCESS else { fatalError("match") }
defer { IOObjectRelease(iterator) }

var found: io_service_t = 0
repeat {
    let s = IOIteratorNext(iterator)
    if s == 0 { break }
    var name = ""
    var prop: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(s, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let props = prop?.takeRetainedValue() as? [String: Any] {
        name = props["USB Product Name"] as? String ?? ""
    }
    if name == "Quartet" { found = s; break }
    IOObjectRelease(s)
} while true
guard found != 0 else { fatalError("Quartet not found") }

let dev: IOUSBHostDevice
do { dev = try IOUSBHostDevice(__ioService: found, options: [], queue: DispatchQueue(label: "usb")) }
catch { fatalError("open: \(error)") }
IOObjectRelease(found)

func send(_ bm: UInt8, _ bReq: UInt8, wValue: UInt16 = 0, wIndex: UInt16 = 0, payload: [UInt8] = [], rxLen: Int = 0) -> [UInt8] {
    var req = IOUSBDeviceRequest()
    req.bmRequestType = bm
    req.bRequest = bReq
    req.wValue = wValue
    req.wIndex = wIndex
    req.wLength = UInt16(rxLen > 0 ? rxLen : payload.count)
    let d = NSMutableData(data: Data(payload))
    if rxLen > payload.count { d.append(Data(repeating: 0, count: rxLen - payload.count)) }
    var t: Int = 0
    do { try dev.__send(req, data: d, bytesTransferred: &t, completionTimeout: 0.5) }
    catch { print("  (request 0x\(String(bReq, radix: 16)) failed: \(error.localizedDescription))"); return [] }
    return (d as Data).map { $0 }
}

func poll() -> [UInt8] { send(0xC0, 0x29, rxLen: 7) }

print("── baseline polls:")
for _ in 0..<3 { print("  state:", poll().map { String(format: "%02x", $0) }.joined()); usleep(300_000) }

print("── setGain(hwout0, -40):")
_ = send(0x40, 0x33, wIndex: 0, payload: [40])
print("  state after:", poll().map { String(format: "%02x", $0) }.joined())
usleep(300_000)
print("  state after (2nd):", poll().map { String(format: "%02x", $0) }.joined())

print("── setGain(hwout0, -20):")
_ = send(0x40, 0x33, wIndex: 0, payload: [20])
print("  state after:", poll().map { String(format: "%02x", $0) }.joined())
usleep(300_000)
print("  state after (2nd):", poll().map { String(format: "%02x", $0) }.joined())

print("── setMute(hwout0, on):")
_ = send(0x40, 0x35, wIndex: 0, payload: [1])
print("  state after:", poll().map { String(format: "%02x", $0) }.joined())
usleep(300_000)

print("── setMute(hwout0, off) [restore]:")
_ = send(0x40, 0x35, wIndex: 0, payload: [0])
print("  state after:", poll().map { String(format: "%02x", $0) }.joined())

print("── identify on/off [sanity]:")
_ = send(0x40, 0xB6, payload: [1]); usleep(1_500_000)
_ = send(0x40, 0xB6, payload: [0])
print("  done")
