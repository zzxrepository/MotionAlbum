import AppKit
import Foundation

@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [PhotoItem] = []
    @Published private(set) var currentFolder: URL?
    @Published var filter: PhotoFilter = .all
    @Published var searchText = ""
    @Published var selectedTag: String?
    @Published var includeSubfolders = false
    @Published private(set) var isLoading = false
    @Published private(set) var isDetecting = false
    @Published private(set) var detectedCount = 0
    @Published private(set) var statusMessage = "请选择一个照片文件夹"
    @Published private(set) var revision = 0
    @Published private(set) var recentFolders: [RecentFolderEntry] = []

    private let liveCache = LiveStatusCache()
    private let selectionStore = SelectionStore()
    private let tagStore = TagStore()
    private let holdFrameStore = HoldFrameStore()
    private let recentFolderStore = RecentFolderStore()
    private let detectionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MotionAlbum.LiveDetection"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var scanTask: Task<Void, Never>?
    private var generation = UUID()

    init() {
        refreshRecentFolders()
    }

    var filteredPhotos: [PhotoItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return photos.filter { item in
            if !query.isEmpty {
                let matchesFileName = item.fileName.localizedCaseInsensitiveContains(query)
                let matchesTag = item.tags.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
                if matchesFileName == false && matchesTag == false {
                    return false
                }
            }
            if let selectedTag, item.tags.contains(selectedTag) == false {
                return false
            }
            switch filter {
            case .all:
                return true
            case .live:
                return item.liveStatus == .live
            case .selected:
                return item.isSelected
            }
        }
    }

    var liveCount: Int { photos.lazy.filter { $0.liveStatus == .live }.count }
    var selectedCount: Int { photos.lazy.filter(\.isSelected).count }
    var unknownCount: Int { photos.lazy.filter { $0.liveStatus == .unknown }.count }
    var taggedCount: Int { photos.lazy.filter { $0.tags.isEmpty == false }.count }
    var allTags: [String] {
        Array(Set(photos.flatMap(\.tags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    var hasUnavailableRecentFolders: Bool {
        recentFolders.contains { $0.isAvailable == false }
    }

    deinit {
        scanTask?.cancel()
        detectionQueue.cancelAllOperations()
        liveCache.flush()
    }

    func chooseAndOpenFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择包含实况照片的文件夹"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let currentFolder {
            panel.directoryURL = currentFolder
        } else if let recentFolder = recentFolders.first(where: \.isAvailable) {
            panel.directoryURL = recentFolder.url
        } else {
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func reload() {
        guard let currentFolder else { return }
        openFolder(currentFolder)
    }

    @discardableResult
    func openRecentFolder(_ entry: RecentFolderEntry) -> Bool {
        let opened = openFolder(entry.url)
        if opened, entry.id != entry.path {
            recentFolderStore.remove(id: entry.id)
            refreshRecentFolders()
        }
        return opened
    }

    func removeRecentFolder(_ entry: RecentFolderEntry) {
        recentFolderStore.remove(id: entry.id)
        refreshRecentFolders()
        statusMessage = "已从历史目录移除：\(entry.displayName)"
    }

    func removeUnavailableRecentFolders() {
        recentFolderStore.removeUnavailable()
        refreshRecentFolders()
        statusMessage = "已清理不可用的历史目录"
    }

    func clearRecentFolders() {
        recentFolderStore.removeAll()
        refreshRecentFolders()
        statusMessage = "已清空历史目录"
    }

    @discardableResult
    func openFolder(_ folder: URL, remember: Bool = true) -> Bool {
        let folder = folder.standardizedFileURL
        guard Self.isReadableDirectory(folder) else {
            refreshRecentFolders()
            statusMessage = "打不开目录，可能已被移动或删除：\(folder.path)"
            return false
        }

        scanTask?.cancel()
        detectionQueue.cancelAllOperations()
        generation = UUID()
        let currentGeneration = generation

        if remember {
            recentFolderStore.add(folder)
            refreshRecentFolders()
        }

        currentFolder = folder
        photos = []
        selectedTag = nil
        detectedCount = 0
        isDetecting = false
        isLoading = true
        statusMessage = "正在扫描 \(folder.lastPathComponent)…"
        let recursive = includeSubfolders

        scanTask = Task { [weak self] in
            do {
                let descriptors = try await Task.detached(priority: .userInitiated) {
                    try Self.scanPhotoFiles(in: folder, recursively: recursive)
                }.value
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }

                let selectedNames = self.selectionStore.selectedFileNames(in: folder)
                let tagMap = self.tagStore.tagsByFileName(in: folder)
                let holdFrameMap = self.holdFrameStore.holdFrameTimes(in: folder)
                self.photos = descriptors.map { descriptor in
                    let selectionKey = Self.relativeSelectionKey(for: descriptor.url, root: folder)
                    let item = PhotoItem(
                        descriptor: descriptor,
                        liveStatus: self.liveCache.status(for: descriptor.cacheKey) ?? .unknown,
                        isSelected: selectedNames.contains(selectionKey),
                        selectionKey: selectionKey,
                        tags: tagMap[selectionKey] ?? []
                    )
                    item.holdFrameTime = holdFrameMap[selectionKey]
                    return item
                }
                self.isLoading = false
                self.detectedCount = self.photos.lazy.filter { $0.liveStatus != .unknown }.count
                self.statusMessage = self.photos.isEmpty
                    ? "该文件夹中没有 JPG/JPEG/HEIC 照片"
                    : "已加载 \(self.photos.count) 张照片"
                self.startLiveDetection(generation: currentGeneration)
            } catch is CancellationError {
                // 用户切换目录，旧任务自然结束。
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.statusMessage = "扫描失败：\(error.localizedDescription)"
                AppLogger.error("扫描照片目录失败：\(folder.path)", error: error)
            }
        }
        return true
    }

    func toggleSelection(_ item: PhotoItem) {
        guard let currentFolder else { return }
        item.isSelected.toggle()
        selectionStore.setSelected(
            item.isSelected,
            fileName: item.selectionKey,
            folder: currentFolder
        )
        revision &+= 1
        statusMessage = item.isSelected ? "已加入精选：\(item.fileName)" : "已取消精选：\(item.fileName)"
    }

    func addTag(_ rawTag: String, to item: PhotoItem) {
        guard let currentFolder,
              let tag = Self.normalizedTag(rawTag),
              item.tags.contains(tag) == false else { return }
        var updatedTags = item.tags
        updatedTags.append(tag)
        item.tags = updatedTags.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        tagStore.setTags(item.tags, fileName: item.selectionKey, folder: currentFolder)
        revision &+= 1
        statusMessage = "已添加标签：\(tag)"
    }

    func removeTag(_ tag: String, from item: PhotoItem) {
        guard let currentFolder else { return }
        item.tags = item.tags.filter { $0 != tag }
        tagStore.setTags(item.tags, fileName: item.selectionKey, folder: currentFolder)
        if selectedTag == tag, photos.contains(where: { $0.tags.contains(tag) }) == false {
            selectedTag = nil
        }
        revision &+= 1
        statusMessage = "已移除标签：\(tag)"
    }

    func setHoldFrameTime(_ seconds: Double?, for item: PhotoItem) {
        guard let currentFolder else { return }
        if let seconds, seconds.isFinite, seconds >= 0 {
            item.holdFrameTime = seconds
            holdFrameStore.setHoldFrameTime(seconds, fileName: item.selectionKey, folder: currentFolder)
            statusMessage = "已设置实况停留帧：\(Self.formatSeconds(seconds))"
        } else {
            item.holdFrameTime = nil
            holdFrameStore.setHoldFrameTime(nil, fileName: item.selectionKey, folder: currentFolder)
            statusMessage = "已清除实况停留帧"
        }
        revision &+= 1
    }

    func selectTag(_ tag: String?) {
        selectedTag = tag
        if let tag {
            statusMessage = "正在查看标签：\(tag)"
        } else {
            statusMessage = summaryText
        }
    }

    func count(forTag tag: String) -> Int {
        photos.lazy.filter { $0.tags.contains(tag) }.count
    }

    func setStatus(_ message: String) {
        statusMessage = message
    }

    func finishStatus(_ message: String) {
        statusMessage = message
        revision &+= 1
    }

    func revealInFinder(_ item: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func refreshRecentFolders() {
        recentFolders = recentFolderStore.entries()
    }

    private func startLiveDetection(generation currentGeneration: UUID) {
        let unknownItems = photos.filter { $0.liveStatus == .unknown }
        guard !unknownItems.isEmpty else {
            isDetecting = false
            statusMessage = summaryText
            return
        }

        isDetecting = true
        let entries = unknownItems.map { (
            item: $0,
            url: $0.url,
            companionVideoURL: $0.companionVideoURL
        ) }
        let workerCount = min(detectionQueue.maxConcurrentOperationCount, entries.count)
        for workerIndex in 0..<workerCount {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                var index = workerIndex
                while index < entries.count {
                    guard operation?.isCancelled == false else { return }
                    let entry = entries[index]
                    let isLive = LivePhotoParser.isLivePhoto(
                        entry.url,
                        companionVideoURL: entry.companionVideoURL
                    )
                    guard operation?.isCancelled == false else { return }
                    let newStatus: LivePhotoStatus = isLive ? .live : .still

                    Task { @MainActor [weak self, weak item = entry.item] in
                        guard let self,
                              let item,
                              self.generation == currentGeneration else { return }
                        item.liveStatus = newStatus
                        self.liveCache.set(newStatus, for: item.cacheKey)
                        self.detectedCount += 1
                        self.revision &+= 1
                        if self.detectedCount >= self.photos.count {
                            self.isDetecting = false
                            self.statusMessage = self.summaryText
                            self.liveCache.flush()
                        } else if self.detectedCount.isMultiple(of: 10) {
                            self.statusMessage = "正在识别实况照片 \(self.detectedCount)/\(self.photos.count)…"
                        }
                    }
                    index += workerCount
                }
            }
            detectionQueue.addOperation(operation)
        }
    }

    private var summaryText: String {
        "共 \(photos.count) 张 · 实况 \(liveCount) 张 · 精选 \(selectedCount) 张 · 已打标签 \(taggedCount) 张"
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let totalTenths = Int((seconds * 10).rounded())
        return String(format: "%02d:%02d.%d", totalTenths / 600, totalTenths / 10 % 60, totalTenths % 10)
    }

    private static func normalizedTag(_ tag: String) -> String? {
        var trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.first == "#" || trimmed.first == "＃" {
            trimmed.removeFirst()
        }
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard collapsed.isEmpty == false else { return nil }
        return String(collapsed.prefix(24))
    }

    nonisolated private static func scanPhotoFiles(
        in folder: URL,
        recursively: Bool
    ) throws -> [PhotoFileDescriptor] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey
        ]
        var candidateURLs: [URL] = []

        if recursively {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    AppLogger.warning("无法读取目录：\(url.path)", error: error)
                    return true
                }
            ) else { return [] }

            for case let url as URL in enumerator {
                try Task.checkCancellation()
                guard supportedFileExtensions.contains(url.pathExtension.lowercased()) else { continue }
                candidateURLs.append(url)
            }
        } else {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            candidateURLs = urls.filter { supportedFileExtensions.contains($0.pathExtension.lowercased()) }
        }

        let sidecars = sidecarVideoURLs(from: candidateURLs)
        let results = candidateURLs.compactMap { url in
            descriptor(for: url, keys: keys, sidecars: sidecars)
        }
        return results.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    nonisolated private static let imageExtensions = Set(["jpg", "jpeg", "heic", "heif"])
    nonisolated private static let videoExtensions = Set(["mov", "mp4", "m4v"])
    nonisolated private static let supportedFileExtensions = imageExtensions.union(videoExtensions)

    nonisolated private static func descriptor(
        for url: URL,
        keys: Set<URLResourceKey>,
        sidecars: [String: URL]
    ) -> PhotoFileDescriptor? {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        let companionVideoURL = sidecars[sidecarKey(for: url)]
        var companionVideoFileSize: Int64?
        var companionVideoModifiedAt: Date?
        if let companionVideoURL,
           let companionValues = try? companionVideoURL.resourceValues(forKeys: keys) {
            companionVideoFileSize = companionValues.fileSize.map(Int64.init)
            companionVideoModifiedAt = companionValues.contentModificationDate
        }
        return PhotoFileDescriptor(
            url: url,
            companionVideoURL: companionVideoURL,
            companionVideoFileSize: companionVideoFileSize,
            companionVideoModifiedAt: companionVideoModifiedAt,
            fileSize: Int64(size),
            modifiedAt: values.contentModificationDate ?? .distantPast,
            metadata: PhotoMetadataReader.read(from: url)
        )
    }

    nonisolated private static func sidecarVideoURLs(from urls: [URL]) -> [String: URL] {
        var sidecars: [String: URL] = [:]
        for url in urls where videoExtensions.contains(url.pathExtension.lowercased()) {
            sidecars[sidecarKey(for: url)] = url
        }
        return sidecars
    }

    nonisolated private static func sidecarKey(for url: URL) -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return "\(directory)/\(stem)"
    }

    nonisolated private static func relativeSelectionKey(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    nonisolated private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }
}
