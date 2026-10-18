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

    /// Formatters are expensive to create — keep one (thread-safe in use).
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    /// Writers come from several threads (main, CoreMIDI, IOKit, glue queue);
    /// a serial queue + one persistent handle keep lines from interleaving.
    private static let queue = DispatchQueue(label: "quartetbuddy.log")
    private static var handle: FileHandle?

    static func log(_ s: String) {
        let line = "\(formatter.string(from: Date()))  \(s)\n"
        let data = line.data(using: .utf8) ?? Data()
        queue.async {
            // cached handle still valid? (log file may have been deleted)
            if let h = handle, FileManager.default.fileExists(atPath: url.path) {
                h.seekToEndOfFile()
                h.write(data)
                return
            }
            if let h = handle {
                try? h.close()
                handle = nil
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = FileHandle(forWritingAtPath: url.path) else {
                try? data.write(to: url)
                return
            }
            handle = h
            h.seekToEndOfFile()
            h.write(data)
        }
    }
}
