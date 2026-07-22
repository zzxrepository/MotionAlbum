import Foundation

enum ExportService {
    static func exportOriginals(
        _ sourceURLs: [URL],
        to destinationDirectory: URL,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )

            var outputs: [URL] = []
            outputs.reserveCapacity(sourceURLs.count)
            for (index, source) in sourceURLs.enumerated() {
                try Task.checkCancellation()
                let destination = availableDestination(
                    named: source.lastPathComponent,
                    in: destinationDirectory
                )
                let partial = destination.appendingPathExtension("partial")
                try? FileManager.default.removeItem(at: partial)
                do {
                    try FileManager.default.copyItem(at: source, to: partial)
                    try FileManager.default.moveItem(at: partial, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
                outputs.append(destination)
                progress(index + 1, sourceURLs.count)
            }
            return outputs
        }.value
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
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
