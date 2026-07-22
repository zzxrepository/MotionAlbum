import Foundation

enum AppIdentity {
    static let displayName = "灵动相册"
    static let englishName = "MotionAlbum"
    static let legacyDirectoryName = "LivePhotoLooker"
    static let androidAlbumDirectory = "/sdcard/DCIM/MotionAlbum"
}

enum AppDirectories {
    static let supportRoot: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let current = base.appendingPathComponent(AppIdentity.englishName, isDirectory: true)
        let legacy = base.appendingPathComponent(AppIdentity.legacyDirectoryName, isDirectory: true)
        copyLegacyDirectoryIfNeeded(from: legacy, to: current)
        return current
    }()

    static let cacheRoot: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.englishName, isDirectory: true)
    }()

    static let logRoot: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppIdentity.englishName, isDirectory: true)
    }()

    static let temporaryVideoRoot: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(AppIdentity.englishName, isDirectory: true)
            .appendingPathComponent("Videos", isDirectory: true)
    }()

    private static func copyLegacyDirectoryIfNeeded(from legacy: URL, to current: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: current.path) == false,
              fileManager.fileExists(atPath: legacy.path) else { return }
        do {
            try fileManager.createDirectory(
                at: current.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: legacy, to: current)
        } catch {
            AppLogger.warning("迁移旧应用数据失败：\(legacy.path) -> \(current.path)", error: error)
        }
    }
}
