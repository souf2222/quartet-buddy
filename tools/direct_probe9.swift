// direct_probe9.swift — which per-input registers are writable? For each
// candidate (0x11 0x13 0x15 0x16 0x3e 0x44) on input 4: baseline → write 1 →
// read-back → restore → read-back. The touchscreen shows which does what.
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
    var prop: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(s, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let props = prop?.takeRetainedValue() as? [String: Any] {
        if (props["USB Product Name"] as? String ?? "") == "Quartet" { found = s; break }
    }
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
    do { try dev.__send(req, data: d, bytesTransferred: &t, completionTimeout: 0.3) }
    catch { return [] }
    return (d as Data).map { $0 }
}

let IN: UInt16 = 3
for r: UInt8 in [0x11, 0x13, 0x15, 0x16, 0x3e, 0x44] {
    let base = send(0xC0, r, wIndex: IN, rxLen: 1).first ?? 0xff
    send(0x40, r, wIndex: IN, payload: [0x01])
    let after1 = send(0xC0, r, wIndex: IN, rxLen: 1).first ?? 0xff
    send(0x40, r, wIndex: IN, payload: [base])
    let restored = send(0xC0, r, wIndex: IN, rxLen: 1).first ?? 0xff
    let verdict = (after1 == 0x01) ? "WRITABLE" : ((after1 == base) ? "read-only/ignored" : "changed to \(String(after1, radix: 16))?")
    print(String(format: "0x%02x: base=%02x → write1=%02x → restore=%02x  %@", r, base, after1, restored, verdict))
}
print("done")
