// probe_health.swift — independent one-shot probe of the Quartet's control
// plane, OUTSIDE the app: is the "Unable to send device request" refusal a
// device-side wedge (any client fails) or an app-side session problem?
// Three attempts, 2 s apart, read-only (0x33 fader, wIndex 0).
import Foundation
import IOKit
import IOUSBHost

func findQuartet() -> io_service_t? {
    guard let dict = IOServiceMatching("IOUSBHostDevice") else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var found: io_service_t = 0
    repeat {
        let s = IOIteratorNext(iterator)
        if s == 0 { break }
        var prop: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(s, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let props = prop?.takeRetainedValue() as? [String: Any] {
            if (props["USB Product Name"] as? String ?? "") == "Quartet" {
                print("  found: \(props["USB Product Name"] ?? "?")  locationID=\(props["locationID"] ?? "?")  bcdDevice=\(props["bcdDevice"] ?? "?")")
                found = s
                break
            }
            IOObjectRelease(s)
        }
    } while true
    return found == 0 ? nil : found
}

func attempt(_ n: Int) {
    print("attempt \(n):")
    guard let s = findQuartet() else { print("  Quartet NOT on the bus"); return }
    defer { IOObjectRelease(s) }
    let dev: IOUSBHostDevice
    do { dev = try IOUSBHostDevice(__ioService: s, options: [], queue: DispatchQueue(label: "usb")) }
    catch { print("  open FAILED: \(error.localizedDescription)"); return }
    defer { dev.destroy() }
    var req = IOUSBDeviceRequest()
    req.bmRequestType = 0xC0
    req.bRequest = 0x33
    req.wValue = 0
    req.wIndex = 0
    req.wLength = 1
    let d = NSMutableData(data: Data(repeating: 0, count: 1))
    do {
        try dev.__send(req, data: d, bytesTransferred: nil, completionTimeout: 0.5)
        print("  read 0x33 OK -> byte 0x\(String(format: "%02x", (d as Data).first ?? 0)) (\(-(Int((d as Data).first ?? 0))) dB)")
    } catch {
        print("  read 0x33 FAILED: \(error.localizedDescription)")
    }
}

for n in 1...3 {
    attempt(n)
    if n < 3 { Thread.sleep(forTimeInterval: 2) }
}
