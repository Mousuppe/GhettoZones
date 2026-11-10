import Foundation

enum SnapDebugLog {
    private static let queue = DispatchQueue(label: "com.mousuppe.GhettoZones.snapdebug")
    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/GhettoZones", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("snap.log")
    }()

    static func clear() {
        queue.sync {
            try? Data().write(to: fileURL)
        }
    }

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        defer { try? handle.close() }
                        try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
        NSLog("[GhettoZones] %@", message)
    }
}
