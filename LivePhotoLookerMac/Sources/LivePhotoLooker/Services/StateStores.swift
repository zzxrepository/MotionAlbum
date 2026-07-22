import Foundation

final class LiveStatusCache {
    private let queue = DispatchQueue(label: "MotionAlbum.LiveStatusCache")
    private var values: [String: LivePhotoStatus]
    private var pendingSave: DispatchWorkItem?
    private let fileURL: URL

    init() {
        fileURL = AppDirectories.cacheRoot.appendingPathComponent("live-status.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: LivePhotoStatus].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    func status(for key: String) -> LivePhotoStatus? {
        queue.sync { values[key] }
    }

    func set(_ status: LivePhotoStatus, for key: String) {
        queue.async {
            self.values[key] = status
            self.pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveNow() }
            self.pendingSave = work
            self.queue.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    func flush() {
        queue.sync { saveNow() }
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.warning("保存实况检测缓存失败", error: error)
        }
    }
}

final class SelectionStore {
    private let queue = DispatchQueue(label: "MotionAlbum.SelectionStore")
    private var selections: [String: Set<String>]
    private let fileURL: URL

    init() {
        fileURL = AppDirectories.supportRoot.appendingPathComponent("selections.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            selections = decoded
        } else {
            selections = [:]
        }
    }

    func selectedFileNames(in folder: URL) -> Set<String> {
        queue.sync { selections[folder.standardizedFileURL.path] ?? [] }
    }

    func setSelected(_ selected: Bool, fileName: String, folder: URL) {
        queue.sync {
            let key = folder.standardizedFileURL.path
            var folderSelections = selections[key] ?? []
            if selected {
                folderSelections.insert(fileName)
            } else {
                folderSelections.remove(fileName)
            }
            selections[key] = folderSelections
            saveNow()
        }
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(selections)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.warning("保存精选状态失败", error: error)
        }
    }
}

final class TagStore {
    private let queue = DispatchQueue(label: "MotionAlbum.TagStore")
    private var tagsByFolder: [String: [String: [String]]]
    private let fileURL: URL

    init() {
        fileURL = AppDirectories.supportRoot.appendingPathComponent("tags.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: [String]]].self, from: data) {
            tagsByFolder = decoded
        } else {
            tagsByFolder = [:]
        }
    }

    func tagsByFileName(in folder: URL) -> [String: [String]] {
        queue.sync { tagsByFolder[folder.standardizedFileURL.path] ?? [:] }
    }

    func setTags(_ tags: [String], fileName: String, folder: URL) {
        queue.sync {
            let folderKey = folder.standardizedFileURL.path
            var folderTags = tagsByFolder[folderKey] ?? [:]
            let normalized = Self.sortedUnique(tags)
            if normalized.isEmpty {
                folderTags.removeValue(forKey: fileName)
            } else {
                folderTags[fileName] = normalized
            }
            if folderTags.isEmpty {
                tagsByFolder.removeValue(forKey: folderKey)
            } else {
                tagsByFolder[folderKey] = folderTags
            }
            saveNow()
        }
    }

    private static func sortedUnique(_ tags: [String]) -> [String] {
        Array(Set(tags)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(tagsByFolder)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.warning("保存标签失败", error: error)
        }
    }
}

final class HoldFrameStore {
    private let queue = DispatchQueue(label: "MotionAlbum.HoldFrameStore")
    private var framesByFolder: [String: [String: Double]]
    private let fileURL: URL

    init() {
        fileURL = AppDirectories.supportRoot.appendingPathComponent("hold-frames.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            framesByFolder = decoded
        } else {
            framesByFolder = [:]
        }
    }

    func holdFrameTimes(in folder: URL) -> [String: Double] {
        queue.sync { framesByFolder[folder.standardizedFileURL.path] ?? [:] }
    }

    func setHoldFrameTime(_ seconds: Double?, fileName: String, folder: URL) {
        queue.sync {
            let folderKey = folder.standardizedFileURL.path
            var folderFrames = framesByFolder[folderKey] ?? [:]
            if let seconds, seconds.isFinite, seconds >= 0 {
                folderFrames[fileName] = seconds
            } else {
                folderFrames.removeValue(forKey: fileName)
            }
            if folderFrames.isEmpty {
                framesByFolder.removeValue(forKey: folderKey)
            } else {
                framesByFolder[folderKey] = folderFrames
            }
            saveNow()
        }
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(framesByFolder)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.warning("保存实况停留帧失败", error: error)
        }
    }
}

struct RecentFolderEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    let displayName: String
    let path: String
    let originalPath: String
    let lastOpenedAt: Date
    let isAvailable: Bool
    let wasResolvedFromBookmark: Bool
}

private struct RecentFolderRecord: Codable {
    var path: String
    var displayName: String
    var lastOpenedAt: Date
    var bookmarkData: Data?
}

final class RecentFolderStore {
    private let queue = DispatchQueue(label: "MotionAlbum.RecentFolderStore")
    private var records: [RecentFolderRecord]
    private let fileURL: URL
    private let maximumCount = 8

    init() {
        fileURL = AppDirectories.supportRoot.appendingPathComponent("recent-folders.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([RecentFolderRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    func entries() -> [RecentFolderEntry] {
        queue.sync {
            records
                .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
                .map { Self.entry(for: $0) }
        }
    }

    func add(_ folder: URL) {
        let standardized = folder.standardizedFileURL
        let path = standardized.path
        let record = RecentFolderRecord(
            path: path,
            displayName: Self.displayName(for: standardized),
            lastOpenedAt: Date(),
            bookmarkData: Self.makeBookmarkData(for: standardized)
        )

        queue.sync {
            records.removeAll { $0.path == path }
            records.insert(record, at: 0)
            if records.count > maximumCount {
                records.removeLast(records.count - maximumCount)
            }
            saveNow()
        }
    }

    func remove(id: String) {
        queue.sync {
            records.removeAll { $0.path == id }
            saveNow()
        }
    }

    func removeUnavailable() {
        queue.sync {
            records.removeAll { Self.entry(for: $0).isAvailable == false }
            saveNow()
        }
    }

    func removeAll() {
        queue.sync {
            records.removeAll()
            saveNow()
        }
    }

    private static func entry(for record: RecentFolderRecord) -> RecentFolderEntry {
        var resolvedFromBookmark = false
        let fallbackURL = URL(fileURLWithPath: record.path).standardizedFileURL
        let resolvedURL: URL

        if let bookmarkData = record.bookmarkData {
            var isStale = false
            if let bookmarkURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedURL = bookmarkURL.standardizedFileURL
                resolvedFromBookmark = resolvedURL.path != record.path || isStale
            } else {
                resolvedURL = fallbackURL
            }
        } else {
            resolvedURL = fallbackURL
        }

        return RecentFolderEntry(
            id: record.path,
            url: resolvedURL,
            displayName: Self.displayName(for: resolvedURL, fallback: record.displayName),
            path: resolvedURL.path,
            originalPath: record.path,
            lastOpenedAt: record.lastOpenedAt,
            isAvailable: Self.isReadableDirectory(resolvedURL),
            wasResolvedFromBookmark: resolvedFromBookmark
        )
    }

    private static func makeBookmarkData(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            AppLogger.warning("保存最近目录书签失败：\(url.path)", error: error)
            return nil
        }
    }

    private static func displayName(for url: URL, fallback: String? = nil) -> String {
        if url.lastPathComponent.isEmpty == false {
            return url.lastPathComponent
        }
        return fallback?.isEmpty == false ? fallback! : url.path
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.warning("保存最近目录失败", error: error)
        }
    }
}
