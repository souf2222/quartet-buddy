// direct_test.swift — standalone .directUSB proof: open the Quartet via
// AppleUSBHostDeviceUserClient, poll state, fire the identify blink.
// build+run: swiftc -O tools/direct_test.swift -o /tmp/direct_test -framework IOKit && /tmp/direct_test
import Foundation
import IOKit

// The daemon matches "IOUSBDevice" — the LEGACY nub that only exists because
// the kext's merge-nub personalities create it. Quartet Buddy uses the modern
// per-interface path: IOUSBHostInterface.
guard let dict = IOServiceMatching("IOUSBHostInterface") else { fatalError("no matching dict") }

var iterator: io_iterator_t = 0
let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator)
guard kr == KERN_SUCCESS else { fatalError("matching failed: \(kr)") }
defer { IOObjectRelease(iterator) }

var service: io_service_t = 0
var serial = ""
var found: io_service_t = 0
repeat {
    let s = IOIteratorNext(iterator)
    if s == 0 { print("(iterator exhausted)"); break }
    service = s
    var name = "", sn = "(none — serial via vendor protocol)"
    var prop: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(s, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let props = prop?.takeRetainedValue() as? [String: Any] {
        sn = props["USB Serial Number"] as? String ?? sn
        name = props["USB Product Name"] as? String ?? props["USBInterfaceString"] as? String ?? ""
        if name == "" {
            // interface nubs: walk up to the parent device for the name
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) == KERN_SUCCESS {
                var pprop: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(parent, &pprop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let pp = pprop?.takeRetainedValue() as? [String: Any] {
                    name = pp["USB Product Name"] as? String ?? ""
                }
                IOObjectRelease(parent)
            }
        }
    }
    print("found: \(name) serial=\(sn)")
    if name == "Quartet" {
        found = s   // keep the handle; the serial comes via the vendor protocol
        break
    }
    IOObjectRelease(s)
} while true

// brute-force the user-client type: the daemon uses type 0 on the LEGACY nub;
// the modern IOUSBHostInterface's types are private
var connect: io_connect_t = 0
var openKr: kern_return_t = -1
for t: UInt32 in [0, 1, 2, 3, 4, 5] {
    connect = 0
    openKr = IOServiceOpen(found, kIOMainPortDefault, t, &connect)
    print("type \(t): kr=\(openKr) \(openKr == KERN_SUCCESS ? "✅ OPEN" : String(cString: mach_error_string(openKr)))")
    if openKr == KERN_SUCCESS, connect != 0 { break }
}
guard openKr == KERN_SUCCESS, connect != 0 else { exit(1) }
defer { IOServiceClose(connect) }

func vendorRequest(_ bm: UInt8, _ bRequest: UInt8, wValue: UInt16 = 0, wIndex: UInt16 = 0, data: UnsafeMutableRawPointer? = nil, length: UInt16 = 0, selector: UInt32 = 6) -> IOReturn {
    var scalars: [UInt64] = [0, UInt64(bm), UInt64(bRequest), UInt64(wValue), UInt64(wIndex), UInt64(length),
                             data.map { UInt64(UInt(bitPattern: $0)) } ?? 0, 500]
    var out = [0 as UInt64, 0 as UInt64]
    var outCnt: UInt32 = 2
    return IOConnectCallScalarMethod(connect, selector, &scalars, 8, &out, &outCnt)
}

// 1. three state polls
for _ in 0..<3 {
    var buf = [UInt8](repeating: 0, count: 7)
    let r = buf.withUnsafeMutableBytes { ptr in
        vendorRequest(0xC0, 0x29, data: ptr.baseAddress, length: 7, selector: 7)
    }
    print("poll: kr=\(r) data=\(buf.map { String(format: "%02x", $0) }.joined())")
    usleep(200_000)
}

// 2. identify blink: on … off
var on: UInt8 = 1
let r1 = withUnsafeMutableBytes(of: &on) { ptr in
    vendorRequest(0x40, 0xB6, data: ptr.baseAddress, length: 1)
}
print("identify ON: kr=\(r1) \(r1 == 0 ? "✅ (front panel should be blinking!)" : "❌")")
sleep(3)
var off: UInt8 = 0
let r2 = withUnsafeMutableBytes(of: &off) { ptr in
    vendorRequest(0x40, 0xB6, data: ptr.baseAddress, length: 1)
}
print("identify OFF: kr=\(r2)")
