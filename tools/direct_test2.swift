// direct_test.swift — standalone .directUSB proof via the public IOUSBHost
// framework (the modern Obj-C API — no legacy nubs, no user-client types).
// build+run: swiftc -O tools/direct_test.swift -o /tmp/direct_test -framework IOKit -framework IOUSBHost && /tmp/direct_test
import Foundation
import IOKit
import IOUSBHost

guard let dict = IOServiceMatching("IOUSBHostDevice") else { fatalError("no matching dict") }

var iterator: io_iterator_t = 0
let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator)
guard kr == KERN_SUCCESS else { fatalError("matching failed: \(kr)") }
defer { IOObjectRelease(iterator) }

var found: io_service_t = 0
repeat {
    let s = IOIteratorNext(iterator)
    if s == 0 { print("(iterator exhausted)"); break }
    var name = "", sn = ""
    var prop: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(s, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let props = prop?.takeRetainedValue() as? [String: Any] {
        sn = props["USB Serial Number"] as? String ?? "(serial via vendor protocol)"
        name = props["USB Product Name"] as? String ?? ""
    }
    print("found: \(name) serial=\(sn)")
    if name == "Quartet" { found = s; break }
    IOObjectRelease(s)
} while true
guard found != 0 else { fatalError("Quartet not found") }

let queue = DispatchQueue(label: "usb")
let dev: IOUSBHostDevice
do {
    dev = try IOUSBHostDevice(__ioService: found, options: [], queue: queue)
} catch {
    fatalError("IOUSBHostDevice init failed: \(error)")
}

// the vendor state poll: bRequest 0x29, 7-byte IN response
var req = IOUSBDeviceRequest()
req.bmRequestType = 0xC0            // IN | vendor | device
req.bRequest = 0x29
req.wValue = 0
req.wIndex = 0
req.wLength = 7
let data = NSMutableData(capacity: 7)!
var transferred: Int = 0
do {
    try dev.__send(req, data: data, bytesTransferred: &transferred, completionTimeout: 0.5)
transferred = data.count
print("✅ poll: bytes=\(transferred) data=\((data as Data).map { String(format: "%02x", $0) }.joined())")
} catch {
    print("poll threw: \(error)")
}

// identify blink: bRequest 0xB6, 1-byte payload 1 then 0
func identify(_ v: UInt8) throws {
    var r = IOUSBDeviceRequest()
    r.bmRequestType = 0x40
    r.bRequest = 0xB6
    r.wValue = 0
    r.wIndex = 0
    r.wLength = 1
    let d = NSMutableData(bytes: [v], length: 1)
    _ = try dev.__send(r, data: d, bytesTransferred: nil, completionTimeout: 0.5)
}
do {
    try identify(1)
    print("✅ identify ON sent (front panel should blink!)")
} catch { print("identify ON failed: \(error)") }
sleep(3)
do {
    try identify(0)
    print("✅ identify OFF sent")
} catch { print("identify OFF failed: \(error)") }
