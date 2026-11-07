// direct_probe4.swift — audible test on the HEADPHONE output (ch1 = "HP"):
// swing the gain, mute/unmute. The user listens.
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

func send(_ bm: UInt8, _ bReq: UInt8, wIndex: UInt16 = 0, payload: [UInt8] = [], rxLen: Int = 0) -> [UInt8] {
    var req = IOUSBDeviceRequest()
    req.bmRequestType = bm
    req.bRequest = bReq
    req.wIndex = wIndex
    req.wLength = UInt16(rxLen > 0 ? rxLen : payload.count)
    let d = NSMutableData(data: Data(payload))
    if rxLen > payload.count { d.append(Data(repeating: 0, count: rxLen - payload.count)) }
    var t: Int = 0
    do { try dev.__send(req, data: d, bytesTransferred: &t, completionTimeout: 0.5) }
    catch { print("  (0x\(String(bReq, radix: 16)) failed: \(error.localizedDescription))"); return [] }
    return (d as Data).map { $0 }
}

let HP: UInt16 = 1   // hwout1 = "HP"

print("── baseline: HP gain =", send(0xC0, 0x33, wIndex: HP, rxLen: 1).first ?? 0)

print(">>> PLAY SOMETHING ON THE HEADPHONES NOW — gain going LOUD in 5 s <<<")
sleep(5)
print("── HP gain → −10 (loud!):", send(0x40, 0x33, wIndex: HP, payload: [10]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x33, wIndex: HP, rxLen: 1).first ?? 0)
sleep(4)

print("── HP gain → −44 (restore):", send(0x40, 0x33, wIndex: HP, payload: [44]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x33, wIndex: HP, rxLen: 1).first ?? 0)
sleep(3)

print("── HP mute ON:", send(0x40, 0x35, wIndex: HP, payload: [1]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x35, wIndex: HP, rxLen: 1).first ?? 0)
sleep(3)
print("── HP mute OFF (restore):", send(0x40, 0x35, wIndex: HP, payload: [0]).isEmpty ? "FAIL" : "sent")
print("   read-back:", send(0xC0, 0x35, wIndex: HP, rxLen: 1).first ?? 0)
