// direct_probe7.swift — full INPUT-state baseline dump: the 0x10 gain blocks
// (28 B each) + every per-input register seen in the capture sweep, so a
// front-panel change can be diffed against this baseline.
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

@discardableResult
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

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

print("── 0x10 gain blocks (read 28 B each, wIndex=block):")
for block: UInt16 in 0...3 {
    let r = send(0xC0, 0x10, wValue: 0, wIndex: block, rxLen: 28)
    print("   block \(block): \(r.isEmpty ? "(read failed)" : hex(r))")
}

print("── per-input registers (wIndex = input 0…3):")
let regs: [UInt8] = [0x11, 0x13, 0x15, 0x16, 0x34, 0x36, 0x3e, 0x44, 0x40, 0x45, 0x46, 0x47]
for input: UInt16 in 0...3 {
    var row = "   in\(input):"
    for r in regs {
        let v = send(0xC0, r, wValue: 0, wIndex: input, rxLen: 1)
        row += String(format: " %02x:%02x", r, v.first ?? 0xff)
    }
    print(row)
}

print("── per-output registers (wIndex = out 0…5):")
for output: UInt16 in 0...5 {
    let g33 = send(0xC0, 0x33, wValue: 0, wIndex: output, rxLen: 1).first ?? 0xff
    let m35 = send(0xC0, 0x35, wValue: 0, wIndex: output, rxLen: 1).first ?? 0xff
    let r18 = send(0xC0, 0x18, wValue: 0, wIndex: output, rxLen: 1).first ?? 0xff
    print(String(format: "   out\(output): 33:%02x 35:%02x 18:%02x", g33, m35, r18))
}

print("── misc blocks:")
print("   0x29 poll(7):", hex(send(0xC0, 0x29, rxLen: 7)))
print("   0x14 block(60):", hex(send(0xC0, 0x14, rxLen: 60)))
for wI: UInt16 in 0...2 {
    print("   0x28 wI=\(wI) (3):", hex(send(0xC0, 0x28, wValue: 0, wIndex: wI, rxLen: 3)))
    print("   0x49 wI=\(wI) (1):", String(format: "%02x", send(0xC0, 0x49, wValue: 0, wIndex: wI, rxLen: 1).first ?? 0xff))
}
print("   0x31 serial(8):", hex(send(0xC0, 0x31, rxLen: 8)))
print("   0x51 (1):", String(format: "%02x", send(0xC0, 0x51, rxLen: 1).first ?? 0xff))
print("done")
