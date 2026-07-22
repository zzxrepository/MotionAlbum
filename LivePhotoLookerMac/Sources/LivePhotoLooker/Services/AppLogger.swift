import Foundation

enum AppLogger {
    private static let queue = DispatchQueue(label: "MotionAlbum.AppLogger")

    static var logDirectory: URL {
        AppDirectories.logRoot
    }

    static var currentLogURL: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return logDirectory.appendingPathComponent("motion-album-\(formatter.string(from: Date())).log")
    }

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func warning(_ message: String, error: Error? = nil) {
        write(level: "WARN", message: message, error: error)
    }

    static func error(_ message: String, error: Error? = nil) {
        write(level: "ERROR", message: message, error: error)
    }

    private static func write(level: String, message: String, error: Error? = nil) {
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: logDirectory,
                    withIntermediateDirectories: true
                )
                let timestamp = ISO8601DateFormatter().string(from: Date())
                var line = "\(timestamp) [\(level)] \(message)"
                if let error {
                    line += "\n\(String(reflecting: error))"
                }
                line += "\n"

                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: currentLogURL.path) {
                    let handle = try FileHandle(forWritingTo: currentLogURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: currentLogURL, options: .atomic)
                }
            } catch {
                // 日志失败不能影响照片浏览。
            }
        }
    }
}
