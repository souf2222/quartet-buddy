// direct_probe10.swift — is 0x36 the MIC/INSTRUMENT preamp selector?
// (0=Mic, 1=Instrument per the setter decode: two property-ids map to
// values 0/1, everything else is IGNORED — matching the app's dead
// "mode 4 → 0x36=2" writes). Write 1 on input 4, read back, restore.
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
print("── baseline in\(IN): 0x36 =", String(format: "%02x", send(0xC0, 0x36, wIndex: IN, rxLen: 1).first ?? 0xff),
      " 0x34 =", String(format: "%02x", send(0xC0, 0x34, wIndex: IN, rxLen: 1).first ?? 0xff))
print("── write 0x36 = 1 (Instrument?):", send(0x40, 0x36, wIndex: IN, payload: [0x01]).isEmpty ? "FAIL" : "sent")
print("   read-back 0x36:", String(format: "%02x", send(0xC0, 0x36, wIndex: IN, rxLen: 1).first ?? 0xff))
sleep(2)
print("── leave it 2 s; now restore 0:")
print("── restore 0x36 = 0:", send(0x40, 0x36, wIndex: IN, payload: [0x00]).isEmpty ? "FAIL" : "sent")
print("   read-back 0x36:", String(format: "%02x", send(0xC0, 0x36, wIndex: IN, rxLen: 1).first ?? 0xff))
print("── also: 0x0F write test on in\(IN) (the 0x0F/0x10 toggle setter's register):")
let base0f = send(0xC0, 0x0F, wIndex: IN, rxLen: 1).first ?? 0xff
print("   baseline 0x0F:", String(format: "%02x", base0f))
send(0x40, 0x0F, wIndex: IN, payload: [0x01])
print("   after write 1:", String(format: "%02x", send(0xC0, 0x0F, wIndex: IN, rxLen: 1).first ?? 0xff))
send(0x40, 0x0F, wIndex: IN, payload: [base0f == 0xff ? 0 : base0f])
print("   restored:", String(format: "%02x", send(0xC0, 0x0F, wIndex: IN, rxLen: 1).first ?? 0xff))
print("done")
