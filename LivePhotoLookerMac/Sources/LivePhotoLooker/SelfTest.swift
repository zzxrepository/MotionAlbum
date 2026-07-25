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
            "IMG_20260617_140640.jpg": 5_540_912,
            "IMG_20260617_141022.jpg": 4_747_784,
            "IMG_20260617_151140.jpg": 5_934_399,
            "IMG_20260617_192759.jpg": 4_787_971,
            "IMG_20260617_200957.jpg": nil
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

            let source = samples.appendingPathComponent("IMG_20260617_140640.jpg")
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
                print("✅ 自检通过：5 个荣耀样本、苹果配对实况、视频提取、24 MB 大文件扫描、废纸篓缺失文件处理、SQLite 图库索引")
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
