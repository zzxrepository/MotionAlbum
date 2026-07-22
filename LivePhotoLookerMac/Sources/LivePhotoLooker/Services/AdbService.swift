import Foundation

enum AdbServiceError: LocalizedError {
    case adbNotInstalled
    case noAuthorizedDevice
    case multipleDevices
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .adbNotInstalled:
            return "未找到 adb。请先在终端运行：brew install android-platform-tools"
        case .noAuthorizedDevice:
            return "没有已授权的安卓手机。请用数据线连接手机，开启 USB 调试，并在手机上点“允许”。"
        case .multipleDevices:
            return "检测到多台 Android 设备，请暂时只保留一台手机。"
        case .commandFailed(let output):
            return "手机同步失败：\(output)"
        }
    }
}

enum AdbService {
    struct SyncResult: Sendable {
        let count: Int
        let remoteDirectory: String
    }

    static func syncToAndroidPhone(
        sourceURLs: [URL],
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws -> SyncResult {
        try await Task.detached(priority: .userInitiated) {
            guard let adb = locateAdb() else { throw AdbServiceError.adbNotInstalled }
            let devicesOutput = try run(adb, arguments: ["devices"])
            let devices = devicesOutput
                .split(separator: "\n")
                .dropFirst()
                .compactMap { line -> String? in
                    let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                    guard fields.count >= 2, fields[1] == "device" else { return nil }
                    return String(fields[0])
                }

            guard !devices.isEmpty else { throw AdbServiceError.noAuthorizedDevice }
            guard devices.count == 1 else { throw AdbServiceError.multipleDevices }
            let serial = devices[0]
            let prefix = ["-s", serial]
            let remoteDirectory = AppIdentity.androidAlbumDirectory
            _ = try run(adb, arguments: prefix + ["shell", "mkdir", "-p", remoteDirectory])

            for (index, source) in sourceURLs.enumerated() {
                try Task.checkCancellation()
                let safeName = sanitizedFileName(source.lastPathComponent)
                let remotePath = "\(remoteDirectory)/\(safeName)"
                _ = try run(adb, arguments: prefix + ["push", source.path, remotePath])
                _ = try? run(
                    adb,
                    arguments: prefix + [
                        "shell", "am", "broadcast",
                        "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                        "-d", "file://\(remotePath)"
                    ]
                )
                progress(index + 1, sourceURLs.count)
            }

            // 同步完成后打开手机微信；不自动选择联系人或发送。
            _ = try? run(
                adb,
                arguments: prefix + [
                    "shell", "monkey", "-p", "com.tencent.mm",
                    "-c", "android.intent.category.LAUNCHER", "1"
                ]
            )
            return SyncResult(count: sourceURLs.count, remoteDirectory: remoteDirectory)
        }.value
    }

    private static func locateAdb() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ]
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("platform-tools/adb").path)
        }
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        candidates.append(contentsOf: pathDirectories.map { "\($0)/adb" })

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }
        return scalars.joined()
    }

    @discardableResult
    private static func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw AdbServiceError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
