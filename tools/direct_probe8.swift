// direct_probe8.swift — is 0x34 the writable per-INPUT gain register (the
// sibling of the output gain 0x33)? Write test on input 3 (unused), with
// restore. Also a 0x36 write probe (type candidate) with restore.
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
    catch { print("   (0x\(String(bReq, radix: 16)) failed: \(error.localizedDescription))"); return [] }
    return (d as Data).map { $0 }
}

let IN: UInt16 = 3   // input 4 — the unused one

print("── 0x34 baseline in\(IN):", String(format: "%02x", send(0xC0, 0x34, wIndex: IN, rxLen: 1).first ?? 0xff))
print("── write 0x34 = 0x30 (0 dB):", send(0x40, 0x34, wIndex: IN, payload: [0x30]).isEmpty ? "FAIL" : "sent")
print("   read-back:", String(format: "%02x", send(0xC0, 0x34, wIndex: IN, rxLen: 1).first ?? 0xff))
sleep(1)
print("── write 0x34 = 0x40 (−8 dB):", send(0x40, 0x34, wIndex: IN, payload: [0x40]).isEmpty ? "FAIL" : "sent")
print("   read-back:", String(format: "%02x", send(0xC0, 0x34, wIndex: IN, rxLen: 1).first ?? 0xff))
print("── restore 0x34 = 0x00:", send(0x40, 0x34, wIndex: IN, payload: [0x00]).isEmpty ? "FAIL" : "sent")
print("   read-back:", String(format: "%02x", send(0xC0, 0x34, wIndex: IN, rxLen: 1).first ?? 0xff))

print("\n── 0x36 baseline in\(IN):", String(format: "%02x", send(0xC0, 0x36, wIndex: IN, rxLen: 1).first ?? 0xff))
print("── write 0x36 = 1:", send(0x40, 0x36, wIndex: IN, payload: [0x01]).isEmpty ? "FAIL" : "sent")
print("   read-back:", String(format: "%02x", send(0xC0, 0x36, wIndex: IN, rxLen: 1).first ?? 0xff))
print("── restore 0x36 = 0:", send(0x40, 0x36, wIndex: IN, payload: [0x00]).isEmpty ? "FAIL" : "sent")
print("   read-back:", String(format: "%02x", send(0xC0, 0x36, wIndex: IN, rxLen: 1).first ?? 0xff))

print("\n── sanity: in0/in1 unchanged:")
for i: UInt16 in 0...1 {
    print("   in\(i) 0x34:", String(format: "%02x", send(0xC0, 0x34, wIndex: i, rxLen: 1).first ?? 0xff),
          " 0x36:", String(format: "%02x", send(0xC0, 0x36, wIndex: i, rxLen: 1).first ?? 0xff))
}
print("done")
