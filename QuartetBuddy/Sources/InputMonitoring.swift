import Foundation
import IOKit.hid

enum InputMonitoring {
    enum Access { case granted, denied, unknown }

    static func check() -> Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .unknown
        }
    }

    /// Shows the system permission request (System Settings → Input Monitoring).
    /// IOHIDRequestAccess returns a plain Bool in Swift (true = granted).
    @discardableResult
    static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

enum QBLog {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/QuartetBuddy.log")
    }

    static func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "\(stamp)  \(s)\n"
        let data = line.data(using: .utf8) ?? Data()
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
