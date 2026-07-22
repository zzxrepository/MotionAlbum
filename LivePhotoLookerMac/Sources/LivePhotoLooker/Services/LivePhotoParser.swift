import CryptoKit
import Foundation

enum LivePhotoParserError: LocalizedError {
    case notLivePhoto
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .notLivePhoto:
            return "这张图片不包含可识别的实况视频"
        case .invalidFile:
            return "图片文件无效或已被移动"
        }
    }
}

/// 多来源动态照片解析器。
///
/// 目前支持两类常见结构：
/// - 荣耀 / 华为 / Android Motion Photo：图片文件尾部内嵌完整 MP4，入口是 ISO BMFF 的 ftyp box。
/// - Apple Live Photo 常见导出形态：静态图片旁边存在同名 MOV/MP4 sidecar。
///
/// 内嵌视频扫描和提取均以固定大小缓冲区进行，不会随照片大小线性增加内存占用。
enum LivePhotoParser {
    static let chunkSize = 1024 * 1024
    private static let overlapSize = 16
    private static let maxCacheBytes: Int64 = 1024 * 1024 * 1024

    static var videoCacheDirectory: URL {
        AppDirectories.temporaryVideoRoot
    }

    static func findVideoOffset(in fileURL: URL) throws -> UInt64? {
        guard fileURL.isFileURL else { throw LivePhotoParserError.invalidFile }
        guard ["jpg", "jpeg"].contains(fileURL.pathExtension.lowercased()) else {
            return nil
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var carry = Data()
        var bytesRead: UInt64 = 0

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return nil
            }

            var window = Data(capacity: carry.count + chunk.count)
            window.append(carry)
            window.append(chunk)

            if let markerIndex = validatedFtypMarkerIndex(in: window) {
                let windowStart = bytesRead - UInt64(carry.count)
                return windowStart + UInt64(markerIndex - 4)
            }

            bytesRead += UInt64(chunk.count)
            carry = window.suffix(overlapSize)
        }
    }

    static func isLivePhoto(_ fileURL: URL, companionVideoURL: URL? = nil) -> Bool {
        do {
            if let companionVideoURL, try isLikelyVideoFile(companionVideoURL) {
                return true
            }
            return try findVideoOffset(in: fileURL) != nil
        } catch is CancellationError {
            return false
        } catch {
            AppLogger.warning("实况检测失败：\(fileURL.path)", error: error)
            return false
        }
    }

    static func playableVideoURL(
        for fileURL: URL,
        companionVideoURL: URL?,
        cacheDirectory: URL? = nil
    ) throws -> URL {
        if let companionVideoURL, try isLikelyVideoFile(companionVideoURL) {
            return companionVideoURL
        }
        return try extractVideo(from: fileURL, cacheDirectory: cacheDirectory)
    }

    static func extractVideo(
        from fileURL: URL,
        cacheDirectory: URL? = nil
    ) throws -> URL {
        guard let offset = try findVideoOffset(in: fileURL) else {
            throw LivePhotoParserError.notLivePhoto
        }

        let values = try fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        guard let fileSize = values.fileSize else {
            throw LivePhotoParserError.invalidFile
        }

        let cacheRoot = cacheDirectory ?? videoCacheDirectory
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )

        let fingerprint = fingerprint(
            path: fileURL.path,
            size: Int64(fileSize),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
        let outputURL = cacheRoot.appendingPathComponent("\(fingerprint).mp4")
        let expectedSize = Int64(fileSize) - Int64(offset)

        if let cachedSize = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(cachedSize) == expectedSize {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: outputURL.path
            )
            return outputURL
        }

        let partialURL = outputURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: partialURL)
        defer { try? output.close() }

        do {
            try input.seek(toOffset: offset)
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else {
                    break
                }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try output.close()
            try input.close()
            _ = try FileManager.default.replaceItemAtIfNeeded(
                destination: outputURL,
                source: partialURL
            )
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }

        trimVideoCache(at: cacheRoot)
        return outputURL
    }

    static func exportVideo(from sourceURL: URL, to destinationURL: URL) throws {
        guard let offset = try findVideoOffset(in: sourceURL) else {
            throw LivePhotoParserError.notLivePhoto
        }

        let partialURL = destinationURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)

        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: partialURL)
        defer {
            try? input.close()
            try? output.close()
        }

        do {
            try input.seek(toOffset: offset)
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else {
                    break
                }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try output.close()
            try input.close()
            _ = try FileManager.default.replaceItemAtIfNeeded(
                destination: destinationURL,
                source: partialURL
            )
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    static func fingerprint(path: String, size: Int64, modifiedAt: Date) -> String {
        let source = "\(path)|\(size)|\(modifiedAt.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatedFtypMarkerIndex(in data: Data) -> Int? {
        guard data.count >= 12 else { return nil }

        return data.withUnsafeBytes { rawBuffer -> Int? in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }

            var index = 4
            while index <= data.count - 8 {
                if bytes[index] == 0x66,
                   bytes[index + 1] == 0x74,
                   bytes[index + 2] == 0x79,
                   bytes[index + 3] == 0x70 {
                    let boxSize = UInt32(bytes[index - 4]) << 24 |
                        UInt32(bytes[index - 3]) << 16 |
                        UInt32(bytes[index - 2]) << 8 |
                        UInt32(bytes[index - 1])

                    if (8...1024).contains(boxSize) {
                        var brandIsPrintable = true
                        for brandOffset in 0..<4 {
                            let value = bytes[index + 4 + brandOffset]
                            if value < 32 || value > 126 {
                                brandIsPrintable = false
                                break
                            }
                        }
                        if brandIsPrintable { return index }
                    }
                }
                index += 1
            }
            return nil
        }
    }

    private static func isLikelyVideoFile(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw LivePhotoParserError.invalidFile }
        let extensionName = url.pathExtension.lowercased()
        guard ["mov", "mp4", "m4v"].contains(extensionName) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) >= 12 else { return false }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        return validatedFtypMarkerIndex(in: header) != nil
    }

    private static func trimVideoCache(at directory: URL) {
        do {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let files = urls.compactMap { url -> (URL, Int64, Date)? in
                guard url.pathExtension.lowercased() == "mp4",
                      let values = try? url.resourceValues(forKeys: keys),
                      let size = values.fileSize else { return nil }
                return (url, Int64(size), values.contentModificationDate ?? .distantPast)
            }
            var total = files.reduce(Int64(0)) { $0 + $1.1 }
            for file in files.sorted(by: { $0.2 < $1.2 }) where total > maxCacheBytes {
                try? FileManager.default.removeItem(at: file.0)
                total -= file.1
            }
        } catch {
            AppLogger.warning("清理视频缓存失败", error: error)
        }
    }
}

private extension FileManager {
    func replaceItemAtIfNeeded(destination: URL, source: URL) throws -> URL {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try moveItem(at: source, to: destination)
        return destination
    }
}
