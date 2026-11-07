// tools/hid_probe.swift — Quartet HID probe (standalone-mode research, phase 2)
//
// The ApogeeGlue daemon talks to the Quartet purely over CoreHID
// (IOHIDDeviceOpen / IOHIDDeviceSetReport / InputReportCallback — see
// docs/standalone-plan.md). This tool does the same thing passively:
//
//   swift tools/hid_probe.swift list
//       enumerate the Quartet's HID devices, dump properties + interface
//       descriptors (usage pages, report sizes, registry props)
//
//   swift tools/hid_probe.swift monitor [seconds]
//       passive input-report tap (non-seize open, coexists with ApogeeGlue),
//       timestamped hex lines written to tools/captures/hid-*.jsonl
//
//   swift tools/hid_probe.swift send <reportID> <hex>
//       DANGER: writes an output report to the matched HID device (manual
//       Phase-2 experiments only — never send firmware/DFU traffic)
//
// Requires only a local compile:  swiftc tools/hid_probe.swift -o /tmp/hid_probe
// No entitlements, no TCC grant — same access the daemon itself has.

import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

let kQuartetVendorID: Int = 0x0C60
let kQuartetProductID: Int = 0x0014

// MARK: - helpers

func hexString(_ bytes: UnsafeMutablePointer<UInt8>?, _ length: Int, maxBytes: Int? = nil) -> String {
    guard let bytes = bytes, length > 0 else { return "(none)" }
    let count = min(length, maxBytes ?? length)
    let parts = (0..<count).map { String(format: "%02x", bytes[$0]) }
    var out = parts.joined(separator: " ")
    if count < length { out += " … (+\(length - count))" }
    return out
}

func hexString(_ buffer: [UInt8]) -> String { buffer.map { String(format: "%02x", $0) }.joined(separator: " ") }

func cfString(_ value: CFTypeRef?) -> String {
    guard let value = value else { return "?" }
    if let s = value as? String { return s }
    if let n = value as? Int { return n > 0xFF ? String(format: "0x%04X (%d)", n, n) : "\(n)" }
    return "\(value)"
}

func isoStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f.string(from: Date())
}

func jsonString(_ obj: Any) -> String {
    let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return d.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

// MARK: - matching

func quartetMatchingDict() -> CFDictionary {
    let dict: [String: Any] = [
        kIOHIDVendorIDKey as String: NSNumber(value: kQuartetVendorID),
        kIOHIDProductIDKey as String: NSNumber(value: kQuartetProductID),
    ]
    return dict as CFDictionary
}

func makeManager() -> IOHIDManager {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, quartetMatchingDict())
    return manager
}

func quartetDevices(_ manager: IOHIDManager) -> [IOHIDDevice] {
    guard let cf = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return Array(cf)
}

// MARK: - descriptor dump

let interestingServicePropKeys = [
    "USB Interface Name", "USB Product Name", "USBVendorID", "USBProductID",
    "USBSerialNumber", "USB Address", "bInterfaceClass", "bInterfaceSubClass",
    "bInterfaceProtocol", "bInterfaceNumber", "bAlternateSetting",
    "bcdDevice", "bEndpointAddress", "Transport", "Path", "ParserType",
]

func dumpDevice(_ device: IOHIDDevice) {
    print("――――――――――――――――――――――――――――――――――――――――")
    let simpleKeys = [
        kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDSerialNumberKey,
        kIOHIDVendorIDKey, kIOHIDProductIDKey, kIOHIDVersionNumberKey,
        kIOHIDTransportKey, kIOHIDLocationIDKey,
        kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey,
        kIOHIDMaxInputReportSizeKey, kIOHIDMaxOutputReportSizeKey,
        kIOHIDMaxFeatureReportSizeKey,
    ]
    for key in simpleKeys {
        if let v = IOHIDDeviceGetProperty(device, key as CFString) {
            print("  \(key): \(cfString(v))")
        }
    }

    // Registry (interface-level) properties — endpoint/class info lives here.
    let service = IOHIDDeviceGetService(device)
    var props: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, IOOptionBits(0)) == KERN_SUCCESS,
       let dict = props?.takeRetainedValue() as? [String: Any] {
        print("  ── registry")
        let keys = dict.keys.filter { k in
            interestingServicePropKeys.contains { k.range(of: $0, options: .caseInsensitive) != nil }
        }.sorted()
        for k in keys {
            print("    \(k) = \(cfString(dict[k] as CFTypeRef))")
        }
    }
}

func cmdList() {
    let manager = makeManager()
    let devices = quartetDevices(manager)
    if devices.isEmpty {
        print("No Quartet (VID 0x0C60, PID 0x0014) found.")
        print("Plug it in over USB and run again.")
        return
    }
    print("Found \(devices.count) HID device(s):")
    for d in devices { dumpDevice(d) }
}

// MARK: - report monitor

// Capture file for the monitor tap (global so the C callback closure
// doesn't capture local context — C function pointers can't capture).
var probeCaptureFile: FileHandle?

func reportCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                    type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: Int) {
    let direction = (type == kIOHIDReportTypeOutput) ? "TX" : (type == kIOHIDReportTypeFeature ? "FEAT" : "RX")
    print("[\(direction)] id=\(reportID) len=\(reportLength)  \(hexString(report, reportLength, maxBytes: 64))")
    let record: [String: Any] = [
        "t": isoStamp(),
        "dir": direction,
        "reportID": Int(reportID),
        "len": reportLength,
        "bytes": hexString(report, reportLength),
    ]
    probeCaptureFile?.write((jsonString(record) + "\n").data(using: .utf8)!)
}

func cmdMonitor(withSeconds seconds: Double?) {
    let dir = "tools/captures"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/hid-\(Int(Date().timeIntervalSince1970)).jsonl"
    FileManager.default.createFile(atPath: path, contents: nil)
    probeCaptureFile = FileHandle(forWritingAtPath: path)

    let manager = makeManager()
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode!.rawValue)

    let open = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if open != kIOReturnSuccess {
        print("IOHIDManagerOpen failed: \(open)")
        exit(1)
    }

    IOHIDManagerRegisterInputReportCallback(manager, reportCallback, nil)

    print("Monitoring (passive, non-exclusive) → \(path)")
    print("Move faders / knobs / mutes on the unit's touchscreen; ^C to stop.")
    if let seconds = seconds {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { CFRunLoopStop(CFRunLoopGetMain()) }
    }
    CFRunLoopRun()
    print("Done. Capture: \(path)")
}

// MARK: - manual send

func cmdSend(_ args: [String]) {
    guard args.count >= 2, let reportID = UInt8(args[0]) else {
        print("usage: hid_probe send <reportID> <hex-bytes>")
        return
    }
    let bytes = args[1].split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { UInt8($0, radix: 16) }
    guard !bytes.isEmpty else { print("no bytes"); return }
    let manager = makeManager()
    let open = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard open == kIOReturnSuccess else { print("open failed: \(open)"); return }
    let devices = quartetDevices(manager)
    guard let device = devices.first else { print("no device"); return }
    var payload = bytes
    var ret: IOReturn = kIOReturnSuccess
    payload.withUnsafeMutableBufferPointer { buf in
        if let base = buf.baseAddress {
            ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, buf.count)
        }
    }
    print("SetReport(\(reportID)) → \(ret), sent \(payload.count) bytes: \(hexString(payload))")
}

// MARK: - main

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "list", nil: cmdList()
case "monitor": cmdMonitor(withSeconds: args.dropFirst().first.flatMap(Double.init))
case "send": cmdSend(Array(args.dropFirst()))
default:
    print("usage: hid_probe.swift [list | monitor [seconds] | send <reportID> <hex>]")
}
