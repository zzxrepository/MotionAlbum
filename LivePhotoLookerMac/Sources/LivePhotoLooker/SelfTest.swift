import Foundation

private final class AsyncResultBox<T>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
}

private struct SelfTestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []

        let expectedOffsets: [String: UInt64?] = [
            "Honor_LivePhoto_01.jpg": 5_540_912,
            "Honor_LivePhoto_02.jpg": 4_747_784,
            "Honor_LivePhoto_03.jpg": 5_934_399,
            "Honor_LivePhoto_04.jpg": 4_787_971,
            "Honor_StillPhoto_01.jpg": nil
        ]

        let samples = findSamplesDirectory(expectedFileName: expectedOffsets.keys.sorted()[0])

        if let samples {
            for (fileName, expectedOffset) in expectedOffsets.sorted(by: { $0.key < $1.key }) {
                let url = samples.appendingPathComponent(fileName)
                do {
                    let actualOffset = try LivePhotoParser.findVideoOffset(in: url)
                    if actualOffset != expectedOffset {
                        failures.append("\(fileName) 偏移错误：\(String(describing: actualOffset))")
                    }
                } catch {
                    failures.append("\(fileName) 检测异常：\(error.localizedDescription)")
                }
            }

            let source = samples.appendingPathComponent("Honor_LivePhoto_01.jpg")
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MotionAlbumSelfTest-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            do {
                let beforeAttributes = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let videoURL = try LivePhotoParser.extractVideo(from: source, cacheDirectory: tempDirectory)
                let handle = try FileHandle(forReadingFrom: videoURL)
                let header = try handle.read(upToCount: 12) ?? Data()
                try handle.close()
                if header.count < 8 || String(data: header[4..<8], encoding: .ascii) != "ftyp" {
                    failures.append("提取视频缺少 ftyp 头")
                }
                if let range = try LivePhotoParser.embeddedVideoRange(in: source),
                   let extractedSize = try videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    if UInt64(extractedSize) != range.length {
                        failures.append("荣耀视频没有按精确范围提取")
                    }
                    if range.offset + range.length >= UInt64(beforeAttributes.fileSize ?? 0) {
                        failures.append("荣耀私有尾数据仍被包含在视频范围内")
                    }
                    try Data([0x00]).write(to: videoURL)
                    _ = try LivePhotoParser.extractVideo(from: source, cacheDirectory: tempDirectory)
                    let repairedSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber
                    if repairedSize?.uint64Value != range.length {
                        failures.append("损坏的视频缓存没有被原子替换")
                    }
                } else {
                    failures.append("荣耀视频范围解析失败")
                }
                let afterAttributes = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if beforeAttributes.fileSize != afterAttributes.fileSize ||
                    beforeAttributes.contentModificationDate != afterAttributes.contentModificationDate {
                    failures.append("提取过程修改了原始 JPG")
                }

                let pairedImage = tempDirectory.appendingPathComponent("ApplePair.HEIC")
                let pairedVideo = tempDirectory.appendingPathComponent("ApplePair.MOV")
                _ = FileManager.default.createFile(
                    atPath: pairedImage.path,
                    contents: Data([0x00, 0x00, 0x00, 0x00])
                )
                try FileManager.default.copyItem(at: videoURL, to: pairedVideo)
                if LivePhotoParser.isLivePhoto(pairedImage, companionVideoURL: pairedVideo) == false {
                    failures.append("苹果 HEIC + MOV 配对未识别为实况")
                }
                let playableURL = try LivePhotoParser.playableVideoURL(
                    for: pairedImage,
                    companionVideoURL: pairedVideo
                )
                if playableURL.standardizedFileURL != pairedVideo.standardizedFileURL {
                    failures.append("苹果配对视频没有直接使用同名 MOV")
                }
                if try LivePhotoParser.findVideoOffset(in: pairedVideo) != nil {
                    failures.append("MOV 文件被误当作内嵌实况图片")
                }

                try testAndroidMotionPhotoProtocols(videoURL: videoURL, in: tempDirectory)
                try testCopiedPhoneSamples(
                    samplesRoot: samples.deletingLastPathComponent(),
                    videoURL: videoURL,
                    in: tempDirectory
                )
            } catch {
                failures.append("视频提取异常：\(error.localizedDescription)")
            }
        } else {
            print("ℹ️ 未找到 samples 目录，已跳过荣耀样本解析测试")
        }

        let largeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionAlbumStatic-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: largeFile) }
        do {
            FileManager.default.createFile(atPath: largeFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: largeFile)
            let block = Data(repeating: 0x41, count: LivePhotoParser.chunkSize)
            for _ in 0..<24 { try handle.write(contentsOf: block) }
            try handle.close()
            if try LivePhotoParser.findVideoOffset(in: largeFile) != nil {
                failures.append("大静态文件被误判为实况")
            }
        } catch {
            failures.append("大文件扫描异常：\(error.localizedDescription)")
        }

        let missingTrashCandidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionAlbumMissingTrash-\(UUID().uuidString).jpg")
        do {
            let trashResult = try awaitResult {
                try await TrashService.moveToTrash([missingTrashCandidate]) { _, _ in }
            }
            if trashResult.missingCount != 1 || trashResult.trashedCount != 0 || trashResult.failedCount != 0 {
                failures.append("废纸篓缺失文件处理异常")
            }
        } catch {
            failures.append("废纸篓缺失文件测试异常：\(error.localizedDescription)")
        }

        do {
            try testLibraryIndexStore()
        } catch {
            failures.append("SQLite 图库索引测试异常：\(error.localizedDescription)")
        }

        if failures.isEmpty {
            if samples == nil {
                print("✅ 自检通过：24 MB 大文件扫描、废纸篓缺失文件处理、SQLite 图库索引")
            } else {
                print("✅ 自检通过：荣耀/华为/Apple/Android V1-V2/OPPO 实况解析、精确视频提取、24 MB 大文件扫描、废纸篓与 SQLite 索引")
            }
            return 0
        }
        for failure in failures { print("❌ \(failure)") }
        return 1
    }

    private static func findSamplesDirectory(expectedFileName: String) -> URL? {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let executableDirectory = executableURL()
            .deletingLastPathComponent()
            .standardizedFileURL

        var candidates: [URL] = [
            currentDirectory.appendingPathComponent("samples", isDirectory: true),
            currentDirectory.deletingLastPathComponent().appendingPathComponent("samples", isDirectory: true)
        ]

        var ancestor = executableDirectory
        for _ in 0..<8 {
            candidates.append(ancestor.appendingPathComponent("samples", isDirectory: true))
            ancestor.deleteLastPathComponent()
        }

        for candidate in candidates {
            for directory in sampleDirectories(under: candidate) {
                if FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(expectedFileName).path
                ) {
                    return directory
                }
            }
        }
        return nil
    }

    private static func testAndroidMotionPhotoProtocols(videoURL: URL, in directory: URL) throws {
        let videoData = try Data(contentsOf: videoURL)
        let jpegPrefix = Data([0xFF, 0xD8, 0xFF, 0xE1])

        let v1URL = directory.appendingPathComponent("XiaomiV1.jpg")
        let v1XMP = #"<x:xmpmeta GCamera:MicroVideo="1" GCamera:MicroVideoOffset="\#(videoData.count)"/>"#
        var v1Data = jpegPrefix + Data(v1XMP.utf8) + Data([0xFF, 0xD9])
        let v1Offset = UInt64(v1Data.count)
        v1Data.append(videoData)
        try v1Data.write(to: v1URL)
        let v1Range = try LivePhotoParser.embeddedVideoRange(in: v1URL)
        if v1Range != EmbeddedVideoRange(
            offset: v1Offset,
            length: UInt64(videoData.count),
            source: .androidMicroVideoV1
        ) {
            throw SelfTestError("小米/Google Motion Photo V1 范围解析错误")
        }

        let v2URL = directory.appendingPathComponent("XiaomiV2.jpg")
        let v2XMP = """
        <Container:Directory>
          <Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/>
          <Container:Item Item:Mime="video/mp4" Item:Length="\(videoData.count)" Item:Semantic="MotionPhoto"/>
        </Container:Directory>
        """
        var v2Data = jpegPrefix + Data(v2XMP.utf8) + Data([0xFF, 0xD9])
        let v2Offset = UInt64(v2Data.count)
        v2Data.append(videoData)
        try v2Data.write(to: v2URL)
        let v2Range = try LivePhotoParser.embeddedVideoRange(in: v2URL)
        if v2Range != EmbeddedVideoRange(
            offset: v2Offset,
            length: UInt64(videoData.count),
            source: .androidMotionPhotoV2
        ) {
            throw SelfTestError("小米/Google Motion Photo V2 范围解析错误")
        }

        let trailer = Data(repeating: 0x54, count: 128)
        let oppoURL = directory.appendingPathComponent("OppoMotionPhoto.jpg")
        let containerLength = videoData.count + trailer.count
        let oppoXMP = """
        <Container:Directory>
          <Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/>
          <Container:Item Item:Semantic="MotionPhoto" Item:Length="\(containerLength)" Item:Mime="video/mp4"/>
        </Container:Directory>
        <rdf:Description OpCamera:VideoLength="\(videoData.count)"/>
        """
        var oppoData = jpegPrefix + Data(oppoXMP.utf8) + Data([0xFF, 0xD9])
        let oppoOffset = UInt64(oppoData.count)
        oppoData.append(videoData)
        oppoData.append(trailer)
        try oppoData.write(to: oppoURL)
        let oppoRange = try LivePhotoParser.embeddedVideoRange(in: oppoURL)
        if oppoRange != EmbeddedVideoRange(
            offset: oppoOffset,
            length: UInt64(videoData.count),
            source: .oppoMotionPhoto
        ) {
            throw SelfTestError("OPPO trailer/纯视频范围解析错误")
        }
    }

    private static func testCopiedPhoneSamples(
        samplesRoot: URL,
        videoURL: URL,
        in directory: URL
    ) throws {
        let appleDirectory = samplesRoot.appendingPathComponent("Apple", isDirectory: true)
        let applePairs = [
            "Apple_LivePhoto_01",
            "Apple_LivePhoto_02"
        ]
        for stem in applePairs {
            let imageExtension = stem == "Apple_LivePhoto_02" ? "JPG" : "HEIC"
            let imageURL = appleDirectory.appendingPathComponent("\(stem).\(imageExtension)")
            let movieURL = appleDirectory.appendingPathComponent("\(stem).MOV")
            guard FileManager.default.fileExists(atPath: imageURL.path),
                  FileManager.default.fileExists(atPath: movieURL.path) else { continue }
            let imageID = LivePhotoParser.imageContentIdentifier(in: imageURL)
            let movieID = LivePhotoParser.videoContentIdentifier(in: movieURL)
            if imageID == nil || imageID != movieID {
                throw SelfTestError("Apple \(stem) 的元数据 UUID 配对失败")
            }
            let resolved = LivePhotoParser.resolvedCompanionVideos(
                imageURLs: [imageURL],
                videoURLs: [movieURL]
            )
            if resolved[imageURL.standardizedFileURL.path]?.standardizedFileURL != movieURL.standardizedFileURL {
                throw SelfTestError("Apple \(stem) 未按 UUID 解析为 Live Photo")
            }
        }

        let mismatchImageSource = appleDirectory.appendingPathComponent("Apple_LivePhoto_02.JPG")
        let mismatchVideoSource = appleDirectory.appendingPathComponent("Apple_LivePhoto_01.MOV")
        if FileManager.default.fileExists(atPath: mismatchImageSource.path),
           FileManager.default.fileExists(atPath: mismatchVideoSource.path) {
            let mismatchImage = directory.appendingPathComponent("SameName.JPG")
            let mismatchVideo = directory.appendingPathComponent("SameName.MOV")
            try FileManager.default.copyItem(at: mismatchImageSource, to: mismatchImage)
            try FileManager.default.copyItem(at: mismatchVideoSource, to: mismatchVideo)
            let resolved = LivePhotoParser.resolvedCompanionVideos(
                imageURLs: [mismatchImage],
                videoURLs: [mismatchVideo]
            )
            if resolved[mismatchImage.standardizedFileURL.path] != nil {
                throw SelfTestError("Apple UUID 不一致的同名 JPG/MOV 被错误配对")
            }
        }

        let huaweiDirectory = samplesRoot.appendingPathComponent("Huawei", isDirectory: true)
        for name in ["Huawei_StillPhoto_01.jpg", "Huawei_StillPhoto_02.jpg"] {
            let url = huaweiDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path),
               LivePhotoParser.isLivePhoto(url) {
                throw SelfTestError("华为静态样本被误判为实况：\(name)")
            }
        }

        let appleHEIC = appleDirectory.appendingPathComponent("Apple_LivePhoto_01.HEIC")
        guard FileManager.default.fileExists(atPath: appleHEIC.path) else { return }
        let syntheticHuawei = directory.appendingPathComponent("HuaweiEmbedded.HEIC")
        try FileManager.default.copyItem(at: appleHEIC, to: syntheticHuawei)
        let baseSize = try syntheticHuawei.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let input = try FileHandle(forReadingFrom: videoURL)
        let output = try FileHandle(forWritingTo: syntheticHuawei)
        try output.seekToEnd()
        while let data = try input.read(upToCount: LivePhotoParser.chunkSize), data.isEmpty == false {
            try output.write(contentsOf: data)
        }
        var liveTail = Data(repeating: 0, count: 60)
        liveTail.replaceSubrange(0..<5, with: Data("LIVE_".utf8))
        try output.write(contentsOf: liveTail)
        try input.close()
        try output.close()
        let videoSize = try videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let range = try LivePhotoParser.embeddedVideoRange(in: syntheticHuawei)
        if range != EmbeddedVideoRange(
            offset: UInt64(baseSize),
            length: UInt64(videoSize),
            source: .huaweiHonor
        ) {
            throw SelfTestError(
                "华为 HEIC 第二 ftyp/LIVE_ 协议解析错误：\(String(describing: range))，期望 offset=\(baseSize) length=\(videoSize)"
            )
        }
    }

    private static func sampleDirectories(under root: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let childDirectories = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return [root] + childDirectories
    }

    private static func executableURL() -> URL {
        let executablePath = CommandLine.arguments[0]
        if executablePath.hasPrefix("/") {
            return URL(fileURLWithPath: executablePath)
        }

        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(executablePath)
    }

    private static func testLibraryIndexStore() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MotionAlbumIndexSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let file = folder.appendingPathComponent("IndexSample.jpg")
        let contents = Data(repeating: 0x42, count: 128)
        try contents.write(to: file)
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)

        let descriptor = PhotoFileDescriptor(
            url: file,
            companionVideoURL: nil,
            companionVideoFileSize: nil,
            companionVideoModifiedAt: nil,
            fileSize: Int64(contents.count),
            modifiedAt: modifiedAt,
            metadata: PhotoMetadata(),
            mediaKind: .image,
            indexedLiveStatus: nil
        )

        let metadata = PhotoMetadata(
            make: "Motion",
            model: "Album",
            software: "SelfTest",
            capturedAt: "2026:07:25 10:11:12",
            capturedAtDate: Date(timeIntervalSince1970: 1_785_000_000),
            pixelWidth: 4032,
            pixelHeight: 3024,
            latitude: 36.5,
            longitude: 101.7
        )

        let loaded = try awaitResult {
            let store = LibraryIndexStore()
            await store.replaceFolderIndex(
                descriptors: [descriptor],
                folder: folder,
                recursively: false
            )
            await store.updateMetadata(metadata, for: file, folder: folder, recursively: false)
            await store.updateLiveStatus(.still, for: file, folder: folder, recursively: false)
            guard let loaded = await store.load(folder: folder, recursively: false) else {
                throw SelfTestError("SQLite 索引读取为空")
            }
            await store.removeFolderIndex(folder: folder, recursively: false)
            return loaded
        }

        guard loaded.count == 1 else {
            throw SelfTestError("SQLite 索引数量错误：\(loaded.count)")
        }
        guard loaded[0].metadata.model == "Album",
              loaded[0].metadata.pixelWidth == 4032,
              loaded[0].indexedLiveStatus == .still else {
            throw SelfTestError("SQLite 索引元信息回读错误")
        }
    }

    private static func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let box = AsyncResultBox<T>()
        Task {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            box.semaphore.signal()
        }
        box.semaphore.wait()
        return try box.result!.get()
    }
}
