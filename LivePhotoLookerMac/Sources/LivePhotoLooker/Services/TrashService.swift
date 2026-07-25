import Foundation

struct TrashOperationFailure: Identifiable, Sendable {
    let id: String
    let path: String
    let reason: String

    init(url: URL, error: Error) {
        path = url.standardizedFileURL.path
        id = path
        reason = (error as NSError).localizedDescription
    }
}

struct TrashOperationResult: Sendable {
    let trashedURLs: [URL]
    let fallbackMovedURLs: [URL]
    let missingURLs: [URL]
    let failures: [TrashOperationFailure]

    var processedURLs: [URL] {
        trashedURLs + fallbackMovedURLs + missingURLs
    }

    var trashedCount: Int {
        trashedURLs.count
    }

    var fallbackMovedCount: Int {
        fallbackMovedURLs.count
    }

    var missingCount: Int {
        missingURLs.count
    }

    var failedCount: Int {
        failures.count
    }

    var failureMessage: String {
        failures
            .prefix(6)
            .map { "\(($0.path as NSString).lastPathComponent)：\($0.reason)" }
            .joined(separator: "\n")
    }
}

enum TrashService {
    static func moveToTrash(
        _ sourceURLs: [URL],
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws -> TrashOperationResult {
        try await Task.detached(priority: .utility) {
            let urls = uniqueURLs(sourceURLs)
            let operationID = Self.operationID()
            var trashedURLs: [URL] = []
            var fallbackMovedURLs: [URL] = []
            var missingURLs: [URL] = []
            var failures: [TrashOperationFailure] = []

            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let standardized = url.standardizedFileURL

                guard FileManager.default.fileExists(atPath: standardized.path) else {
                    missingURLs.append(standardized)
                    progress(index + 1, urls.count)
                    continue
                }

                do {
                    try FileManager.default.trashItem(at: standardized, resultingItemURL: nil)
                    trashedURLs.append(standardized)
                } catch {
                    AppLogger.warning("移入废纸篓失败：\(standardized.path)", error: error)
                    do {
                        try moveToFallbackTrash(standardized, operationID: operationID)
                        fallbackMovedURLs.append(standardized)
                    } catch {
                        failures.append(TrashOperationFailure(url: standardized, error: error))
                        AppLogger.warning("移入灵动相册安全删除区失败：\(standardized.path)", error: error)
                    }
                }

                progress(index + 1, urls.count)
            }

            return TrashOperationResult(
                trashedURLs: trashedURLs,
                fallbackMovedURLs: fallbackMovedURLs,
                missingURLs: missingURLs,
                failures: failures
            )
        }.value
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)

        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            unique.append(standardized)
        }

        return unique
    }

    private static func moveToFallbackTrash(_ url: URL, operationID: String) throws {
        let fallbackDirectory = url
            .deletingLastPathComponent()
            .appendingPathComponent(".MotionAlbumTrash", isDirectory: true)
            .appendingPathComponent(operationID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: fallbackDirectory,
            withIntermediateDirectories: true
        )
        let destination = availableDestination(named: url.lastPathComponent, in: fallbackDirectory)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private static func availableDestination(named fileName: String, in directory: URL) -> URL {
        let original = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        let extensionName = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let candidateName = extensionName.isEmpty
                ? "\(stem)_\(suffix)"
                : "\(stem)_\(suffix).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if FileManager.default.fileExists(atPath: candidate.path) == false {
                return candidate
            }
            suffix += 1
        }
    }

    private static func operationID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
