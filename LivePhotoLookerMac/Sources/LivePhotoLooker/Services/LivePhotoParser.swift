import CryptoKit
import Darwin
import Foundation
import ImageIO

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

struct EmbeddedVideoRange: Equatable, Sendable {
    enum Source: String, Sendable {
        case androidMotionPhotoV2
        case androidMicroVideoV1
        case oppoMotionPhoto
        case huaweiHonor
        case embeddedMP4
    }

    let offset: UInt64
    let length: UInt64
    let source: Source
}

/// Apple 双文件 Live Photo，以及华为/荣耀和 Android Motion Photo 解析器。
///
/// 解析只读取元数据和固定大小缓冲区。视频提取严格限制在 MP4 的真实范围内，
/// 不会把荣耀稳定矩阵、华为 LIVE_ 尾标或 OPPO trailer 一起写入缓存。
enum LivePhotoParser {
    static let chunkSize = 1024 * 1024
    private static let overlapSize = 32
    private static let metadataProbeSize = 1024 * 1024
    private static let maxCacheBytes: Int64 = 1024 * 1024 * 1024
    private static let appleContentIdentifierKey = "com.apple.quicktime.content.identifier"
    private static let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#

    static var videoCacheDirectory: URL {
        AppDirectories.temporaryVideoRoot
    }

    static func findVideoOffset(in fileURL: URL) throws -> UInt64? {
        try embeddedVideoRange(in: fileURL)?.offset
    }

    static func embeddedVideoRange(in fileURL: URL) throws -> EmbeddedVideoRange? {
        guard fileURL.isFileURL else { throw LivePhotoParserError.invalidFile }
        let extensionName = fileURL.pathExtension.lowercased()
        guard ["jpg", "jpeg", "heic", "heif"].contains(extensionName) else { return nil }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard values.isRegularFile == true,
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.uint64Value >= 16 else { throw LivePhotoParserError.invalidFile }
        let fileSize = byteCount.uint64Value
        let metadataText = try motionMetadataText(in: fileURL, fileSize: fileSize)

        if metadataText.contains("MotionPhoto") || metadataText.contains("video/mp4") {
            if let v2Range = containerMotionPhotoRange(
                metadataText: metadataText,
                fileSize: fileSize,
                fileURL: fileURL
            ) {
                return v2Range
            }
        }

        if (metadataText.contains("MicroVideoOffset") || metadataText.contains("MediaDataOffset")),
           let microVideoLength = firstUnsignedInteger(
            in: metadataText,
            patterns: [
                #"(?:[A-Za-z_][\w.-]*:)?MicroVideoOffset\s*=\s*[\"'](\d+)[\"']"#,
                #"(?:[A-Za-z_][\w.-]*:)?MediaDataOffset\s*=\s*[\"'](\d+)[\"']"#
            ]
        ), microVideoLength < fileSize {
            let offset = fileSize - microVideoLength
            if validatedVideoStart(in: fileURL, suggestedOffset: offset, maximumLength: microVideoLength) == offset {
                return EmbeddedVideoRange(
                    offset: offset,
                    length: microVideoLength,
                    source: .androidMicroVideoV1
                )
            }
        }

        let hasHuaweiTail = try containsTailMarker("LIVE_", in: fileURL, fileSize: fileSize)
        let ftypOffsets = try findFtypOffsets(
            in: fileURL,
            maximumCount: ["heic", "heif"].contains(extensionName) ? 2 : 1
        )

        // HEIC/HEIF 自身从 ftyp 开始；只有 LIVE_ 尾标存在时，第二个 ftyp
        // 才是华为内嵌视频，避免把普通 Apple HEIC 误判为实况。
        if ["heic", "heif"].contains(extensionName) {
            guard hasHuaweiTail, ftypOffsets.count >= 2 else { return nil }
            let offset = ftypOffsets[1]
            guard let length = try parsedMP4Length(
                in: fileURL,
                offset: offset,
                maximumLength: fileSize - offset
            ) else { return nil }
            return EmbeddedVideoRange(offset: offset, length: length, source: .huaweiHonor)
        }

        guard let offset = ftypOffsets.first,
              let length = try parsedMP4Length(
                in: fileURL,
                offset: offset,
                maximumLength: fileSize - offset
              ) else { return nil }
        return EmbeddedVideoRange(
            offset: offset,
            length: length,
            source: hasHuaweiTail ? .huaweiHonor : .embeddedMP4
        )
    }

    static func isLivePhoto(_ fileURL: URL, companionVideoURL: URL? = nil) -> Bool {
        do {
            if let companionVideoURL, try isLikelyVideoFile(companionVideoURL) {
                return true
            }
            return try embeddedVideoRange(in: fileURL) != nil
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
        guard let range = try embeddedVideoRange(in: fileURL) else {
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
            path: "\(fileURL.path)|\(range.offset)|\(range.length)",
            size: Int64(fileSize),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
        let outputURL = cacheRoot.appendingPathComponent("\(fingerprint).mp4")
        let expectedSize = Int64(range.length)

        if let cachedSize = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(cachedSize) == expectedSize {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: outputURL.path)
            return outputURL
        }

        try copyVideoRange(range, from: fileURL, to: outputURL)
        trimVideoCache(at: cacheRoot)
        return outputURL
    }

    static func exportVideo(from sourceURL: URL, to destinationURL: URL) throws {
        guard let range = try embeddedVideoRange(in: sourceURL) else {
            throw LivePhotoParserError.notLivePhoto
        }
        try copyVideoRange(range, from: sourceURL, to: destinationURL)
    }

    /// 读取 Apple 静态资源 MakerApple 字典中的 tag 17。
    static func imageContentIdentifier(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary else {
            return nil
        }
        let rawValue = makerApple[17] ?? makerApple["17"] ?? makerApple[NSNumber(value: 17)]
        return normalizedContentIdentifier(rawValue as? String)
    }

    /// MOV 的 content.identifier 位于 QuickTime mdta 中。流式搜索不会加载整段视频。
    static func videoContentIdentifier(in url: URL) -> String? {
        guard let metadata = movieMetadataBox(in: url) else { return nil }
        let text = String(decoding: metadata, as: UTF8.self)
        guard text.contains(appleContentIdentifierKey) else { return nil }
        return allMatches(in: text, pattern: uuidPattern)
            .compactMap(normalizedContentIdentifier)
            .first
    }

    /// 先按 Apple 元数据 UUID 配对；仅当双方都没有 UUID 时才回退到同目录同名。
    static func resolvedCompanionVideos(imageURLs: [URL], videoURLs: [URL]) -> [String: URL] {
        var imageIDs: [String: String] = [:]
        var videosByID: [String: [URL]] = [:]
        var videoIDs: [String: String] = [:]

        for imageURL in imageURLs {
            if let identifier = imageContentIdentifier(in: imageURL) {
                imageIDs[standardPath(imageURL)] = identifier
            }
        }
        for videoURL in videoURLs {
            if let identifier = videoContentIdentifier(in: videoURL) {
                videoIDs[standardPath(videoURL)] = identifier
                videosByID[identifier, default: []].append(videoURL)
            }
        }

        var result: [String: URL] = [:]
        var usedVideos = Set<String>()
        for imageURL in imageURLs {
            let imagePath = standardPath(imageURL)
            guard let identifier = imageIDs[imagePath],
                  let candidates = videosByID[identifier],
                  let videoURL = candidates.first(where: { usedVideos.contains(standardPath($0)) == false }) else {
                continue
            }
            result[imagePath] = videoURL
            usedVideos.insert(standardPath(videoURL))
        }

        var unpairedVideosByStem: [String: [URL]] = [:]
        for videoURL in videoURLs where usedVideos.contains(standardPath(videoURL)) == false {
            unpairedVideosByStem[sidecarKey(for: videoURL), default: []].append(videoURL)
        }
        for imageURL in imageURLs where result[standardPath(imageURL)] == nil {
            let imagePath = standardPath(imageURL)
            guard imageIDs[imagePath] == nil,
                  let candidates = unpairedVideosByStem[sidecarKey(for: imageURL)],
                  let videoURL = candidates.first(where: {
                      videoIDs[standardPath($0)] == nil && usedVideos.contains(standardPath($0)) == false
                  }) else { continue }
            result[imagePath] = videoURL
            usedVideos.insert(standardPath(videoURL))
        }
        return result
    }

    static func fingerprint(path: String, size: Int64, modifiedAt: Date) -> String {
        let source = "\(path)|\(size)|\(modifiedAt.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func containerMotionPhotoRange(
        metadataText: String,
        fileSize: UInt64,
        fileURL: URL
    ) -> EmbeddedVideoRange? {
        let itemTags = allMatches(
            in: metadataText,
            pattern: #"(?is)<(?:[A-Za-z_][\w.-]*:)?Item\b[^>]*>"#
        )
        var trailingLength: UInt64 = 0

        for attributes in itemTags.reversed() {
            let semantic = firstString(
                in: attributes,
                pattern: #"(?:[A-Za-z_][\w.-]*:)?Semantic\s*=\s*[\"']([^\"']+)[\"']"#
            )
            let mime = firstString(
                in: attributes,
                pattern: #"(?:[A-Za-z_][\w.-]*:)?Mime\s*=\s*[\"']([^\"']+)[\"']"#
            )
            let length = firstUnsignedInteger(
                in: attributes,
                patterns: [#"(?:[A-Za-z_][\w.-]*:)?Length\s*=\s*[\"'](\d+)[\"']"#]
            ) ?? 0
            let padding = firstUnsignedInteger(
                in: attributes,
                patterns: [#"(?:[A-Za-z_][\w.-]*:)?Padding\s*=\s*[\"'](\d+)[\"']"#]
            ) ?? 0

            if semantic?.caseInsensitiveCompare("MotionPhoto") == .orderedSame ||
                mime?.caseInsensitiveCompare("video/mp4") == .orderedSame {
                guard length > 0,
                      trailingLength <= fileSize,
                      length + padding <= fileSize - trailingLength else { return nil }
                trailingLength += length + padding
                let containerOffset = fileSize - trailingLength
                let pureLength = firstUnsignedInteger(
                    in: metadataText,
                    patterns: [
                        #"OpCamera:VideoLength\s*=\s*[\"'](\d+)[\"']"#,
                        #"MiCamera:VideoLength\s*=\s*[\"'](\d+)[\"']"#
                    ]
                ) ?? length
                guard pureLength > 0, pureLength <= length,
                      let videoOffset = validatedVideoStart(
                        in: fileURL,
                        suggestedOffset: containerOffset,
                        maximumLength: length
                      ) else { return nil }
                let skippedHeader = videoOffset - containerOffset
                guard skippedHeader < length, pureLength <= length - skippedHeader else { return nil }
                return EmbeddedVideoRange(
                    offset: videoOffset,
                    length: pureLength,
                    source: metadataText.contains("OpCamera:VideoLength")
                        ? .oppoMotionPhoto
                        : .androidMotionPhotoV2
                )
            }
            guard length + padding <= fileSize - trailingLength else { return nil }
            trailingLength += length + padding
        }
        return nil
    }

    private static func validatedVideoStart(
        in fileURL: URL,
        suggestedOffset: UInt64,
        maximumLength: UInt64
    ) -> UInt64? {
        guard maximumLength >= 12,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: suggestedOffset)
            let data = try handle.read(upToCount: Int(min(maximumLength, 128))) ?? Data()
            for markerIndex in validatedFtypMarkerIndices(in: data) {
                let relativeOffset = UInt64(markerIndex - 4)
                if relativeOffset + 12 <= maximumLength {
                    return suggestedOffset + relativeOffset
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func motionMetadataText(in fileURL: URL, fileSize: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let headLength = Int(min(fileSize, UInt64(metadataProbeSize)))
        let head = try handle.read(upToCount: headLength) ?? Data()
        if fileSize <= UInt64(metadataProbeSize) {
            return String(decoding: head, as: UTF8.self)
        }

        let tailLength = min(UInt64(512 * 1024), fileSize - UInt64(head.count))
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }

    private static func containsTailMarker(_ marker: String, in fileURL: URL, fileSize: UInt64) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let length = min(fileSize, UInt64(4096))
        try handle.seek(toOffset: fileSize - length)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        return data.range(of: Data(marker.utf8)) != nil
    }

    private static func findFtypOffsets(in fileURL: URL, maximumCount: Int) throws -> [UInt64] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offsets: [UInt64] = []
        var carry = Data()
        var bytesRead: UInt64 = 0

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), chunk.isEmpty == false else { break }
            var window = Data(capacity: carry.count + chunk.count)
            window.append(carry)
            window.append(chunk)
            let windowStart = bytesRead - UInt64(carry.count)
            for markerIndex in validatedFtypMarkerIndices(in: window) {
                let offset = windowStart + UInt64(markerIndex - 4)
                if offsets.last != offset { offsets.append(offset) }
                if offsets.count >= maximumCount { return offsets }
            }
            bytesRead += UInt64(chunk.count)
            carry = window.suffix(overlapSize)
        }
        return offsets
    }

    private static func validatedFtypMarkerIndices(in data: Data) -> [Int] {
        guard data.count >= 12 else { return [] }
        let marker = Data("ftyp".utf8)
        var indices: [Int] = []
        var searchStart = data.startIndex + 4
        while searchStart < data.endIndex,
              let range = data.range(of: marker, in: searchStart..<data.endIndex) {
            let index = range.lowerBound
            if index + 8 <= data.endIndex {
                let boxSize = readBigEndianUInt32(data, at: index - 4)
                let brand = data[index + 4..<index + 8]
                if (8...1024).contains(boxSize),
                   brand.allSatisfy({ (32...126).contains($0) }) {
                    indices.append(index)
                }
            }
            searchStart = range.lowerBound + 1
        }
        return indices
    }

    /// 只跳读 MOV 顶层 box 并载入 moov，避免为了一个 UUID 扫描整段 mdat。
    private static func movieMetadataBox(in url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let byteCount = values.fileSize,
              byteCount >= 16,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = UInt64(byteCount)
        var position: UInt64 = 0

        do {
            while position + 8 <= fileSize {
                try handle.seek(toOffset: position)
                let header = try handle.read(upToCount: 16) ?? Data()
                guard header.count >= 8 else { return nil }
                let size32 = UInt64(readBigEndianUInt32(header, at: 0))
                let type = String(data: header[4..<8], encoding: .ascii) ?? ""
                let boxLength: UInt64
                if size32 == 1 {
                    guard header.count >= 16 else { return nil }
                    boxLength = readBigEndianUInt64(header, at: 8)
                } else if size32 == 0 {
                    boxLength = fileSize - position
                } else {
                    boxLength = size32
                }
                guard boxLength >= 8, boxLength <= fileSize - position else { return nil }
                if type == "moov" {
                    guard boxLength <= UInt64(64 * 1024 * 1024) else { return nil }
                    try handle.seek(toOffset: position)
                    return try handle.read(upToCount: Int(boxLength))
                }
                position += boxLength
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func parsedMP4Length(
        in fileURL: URL,
        offset: UInt64,
        maximumLength: UInt64
    ) throws -> UInt64? {
        guard maximumLength >= 16 else { return nil }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let limit = offset + maximumLength
        var position = offset
        var sawFtyp = false
        var sawMoov = false
        var sawMdat = false
        var boxCount = 0

        while position + 8 <= limit, boxCount < 4096 {
            try Task.checkCancellation()
            try handle.seek(toOffset: position)
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header.count >= 8 else { return nil }
            let size32 = UInt64(readBigEndianUInt32(header, at: 0))
            let type = String(data: header[4..<8], encoding: .ascii) ?? ""
            let headerLength: UInt64
            let boxLength: UInt64
            if size32 == 1 {
                guard header.count >= 16 else { return nil }
                headerLength = 16
                boxLength = readBigEndianUInt64(header, at: 8)
            } else if size32 == 0 {
                headerLength = 8
                boxLength = limit - position
            } else {
                headerLength = 8
                boxLength = size32
            }
            guard boxLength >= headerLength, boxLength <= limit - position else { return nil }
            if boxCount == 0, type != "ftyp" { return nil }
            if type == "ftyp" { sawFtyp = true }
            if type == "moov" { sawMoov = true }
            if type == "mdat" { sawMdat = true }
            position += boxLength
            boxCount += 1
            if sawFtyp, sawMoov, sawMdat { return position - offset }
        }
        return nil
    }

    private static func copyVideoRange(
        _ range: EmbeddedVideoRange,
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
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
            try input.seek(toOffset: range.offset)
            var remaining = range.length
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(min(UInt64(chunkSize), remaining))
                guard let data = try input.read(upToCount: count), data.isEmpty == false else {
                    throw LivePhotoParserError.invalidFile
                }
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
            }
            try output.synchronize()
            try output.close()
            try input.close()
            try atomicallyRename(partialURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    private static func isLikelyVideoFile(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw LivePhotoParserError.invalidFile }
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) >= 12 else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        return validatedFtypMarkerIndices(in: header).contains(4)
    }

    /// partial 与目标位于同一目录，POSIX rename 会原子覆盖旧缓存/旧导出文件。
    private static func atomicallyRename(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(EINVAL) }
                if Darwin.rename(sourcePath, destinationPath) == 0 { return Int32(0) }
                return errno
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private static func firstUnsignedInteger(in text: String, patterns: [String]) -> UInt64? {
        for pattern in patterns {
            if let value = firstString(in: text, pattern: pattern), let integer = UInt64(value) {
                return integer
            }
        }
        return nil
    }

    private static func firstString(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ).compactMap { match in
            guard let range = Range(match.range(at: 0), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func normalizedContentIdentifier(_ value: String?) -> String? {
        guard let value,
              let match = allMatches(in: value, pattern: uuidPattern).first else { return nil }
        return match.uppercased()
    }

    private static func sidecarKey(for url: URL) -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return "\(directory)/\(stem)"
    }

    private static func standardPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readBigEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
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
