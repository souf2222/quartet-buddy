// direct_probe6.swift — write a monitor-mixer gain and hear it: the address
// = (input | output<<16) as (wValue, wIndex); the value = the clamp(dB+48) byte.
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
    do { try dev.__send(req, data: d, bytesTransferred: &t, completionTimeout: 0.3) }
    catch { print("  (0x\(String(bReq, radix: 16)) failed: \(error.localizedDescription))"); return [] }
    return (d as Data).map { $0 }
}

let INPUT: UInt16 = 0
let OUTPUT: UInt16 = 0
let addr = UInt16(INPUT)

print("── mixer (in \(INPUT), out \(OUTPUT)): baseline =", send(0xC0, 0x4C, wValue: addr, wIndex: OUTPUT, rxLen: 1).first ?? 0)
print(">>> MONITOR YOUR INPUT 1 ON THE HEADPHONES — level drops in 5 s <<<")
sleep(5)
print("── write 0x14 (=−28 dB):", send(0x40, 0x4C, wValue: addr, wIndex: OUTPUT, payload: [0x14]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x4C, wValue: addr, wIndex: OUTPUT, rxLen: 1).first ?? 0)
sleep(4)
print("── write 0x30 (=0 dB, restore):", send(0x40, 0x4C, wValue: addr, wIndex: OUTPUT, payload: [0x30]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x4C, wValue: addr, wIndex: OUTPUT, rxLen: 1).first ?? 0)
sleep(3)
print("── mute ON (0x4E):", send(0x40, 0x4E, wValue: addr, wIndex: OUTPUT, payload: [1]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x4E, wValue: addr, wIndex: OUTPUT, rxLen: 1).first ?? 0)
sleep(3)
print("── mute OFF (0x4E, restore):", send(0x40, 0x4E, wValue: addr, wIndex: OUTPUT, payload: [0]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x4E, wValue: addr, wIndex: OUTPUT, rxLen: 1).first ?? 0)
