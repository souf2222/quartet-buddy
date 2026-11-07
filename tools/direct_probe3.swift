// direct_probe3.swift — map the hwout channels: read back each channel's gain
// (bRequest 0x33 IN, wIndex = channel), then swing the headphone output's
// gain so it's audible.
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
    catch { print("  (0x\(String(bReq, radix: 16)) w\(wIndex) failed: \(error.localizedDescription))"); return [] }
    return (d as Data).map { $0 }
}

// 1. read every channel's gain via the 0x33 read-back
print("── per-channel gain read-backs (bRequest 0x33 IN):")
for ch: UInt16 in 0...7 {
    let r = send(0xC0, 0x33, wIndex: ch, rxLen: 1)
    let v = r.first ?? 0
    print("  ch\(ch): 0x\(String(v, radix: 16)) (\(v)) → dB = \(60 - Int(v))")
}

// 2. the same for the mute (0x35)
print("── per-channel mute read-backs (0x35 IN):")
for ch: UInt16 in 0...7 {
    let r = send(0xC0, 0x35, wIndex: ch, rxLen: 1)
    print("  ch\(ch): \(r.first ?? 0)")
}
