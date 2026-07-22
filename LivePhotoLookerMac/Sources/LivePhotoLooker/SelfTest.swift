import Foundation

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

        if failures.isEmpty {
            if samples == nil {
                print("✅ 自检通过：24 MB 大文件扫描")
            } else {
                print("✅ 自检通过：5 个荣耀样本、苹果配对实况、视频提取、24 MB 大文件扫描")
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

        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(expectedFileName).path
            )
        }
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
}
