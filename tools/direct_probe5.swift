// direct_probe5.swift — map the monitor-mixer channel space: read-backs over
// the (w2, w3) address range for bRequests 0x4C (gain) / 0x4E (mute).
// Valid addresses respond kr=0; the map = the mixer's structure.
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

// The monitor mixer's setters take (value, w2, w3) and compose the address
// w4 = w2 | w3<<16. As an IN read-back: bmReq 0xC0, wValue = the address?
// The static setter stored the payload byte then called the sender with
// (cmdId, payloadPtr, 1, w2|w3<<16...) — try the read as sel=7 with the
// same scalars the write used: (0, 0xC0, cmdId, wValue=addr, ...).
func tryRead(_ bReq: UInt8, wValue: UInt16, wIndex: UInt16, rxLen: UInt16) -> (kr: Int32, data: [UInt8]) {
    var req = IOUSBDeviceRequest()
    req.bmRequestType = 0xC0
    req.bRequest = bReq
    req.wValue = wValue
    req.wIndex = wIndex
    req.wLength = rxLen
    let d = NSMutableData(data: Data(repeating: 0, count: Int(rxLen)))
    var t: Int = 0
    do { try dev.__send(req, data: d, bytesTransferred: &t, completionTimeout: 0.3) }
    catch { return (-1, []) }
    return (0, (d as Data).map { $0 })
}

// the setter composition: w4 = w2 | w3<<16 — for the monitor mixer the
// addresses came as w2 = the channel, w3 = the page/output.
// Scan wValue/wIndex combinations: (channel 0-11, output 0-5).
print("── scanning the mixer space (0x4C gain read-back):")
var valid: [(UInt16, UInt16, UInt8)] = []
for out: UInt16 in 0...5 {
    for ch: UInt16 in 0...13 {
        // the setter's w4 = w2 | w3<<16: try (wValue = the address hi/lo, wIndex = the rest)
        let addr = UInt32(ch) | (UInt32(out) << 16)
        let lo = UInt16(addr & 0xFFFF), hi = UInt16(addr >> 16)
        // variant A: wValue = lo, wIndex = hi
        let (kr, data) = tryRead(0x4C, wValue: lo, wIndex: hi, rxLen: 1)
        if kr == 0 && !data.isEmpty {
            valid.append((ch, out, data[0]))
            print("  ch=\(ch) out=\(out): kr=0 value=0x\(String(data[0], radix: 16)) (\(data[0]))")
        }
    }
}
print("── valid mixer addresses: \(valid.count)")
