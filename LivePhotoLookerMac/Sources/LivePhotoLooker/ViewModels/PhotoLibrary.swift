import AppKit
import Foundation

private struct VisibleCacheSignature: Equatable {
    let generation: UUID
    let count: Int
    let revision: Int
    let filter: PhotoFilter
    let searchText: String
    let selectedTag: String?
    let sortOrder: PhotoSortOrder
    let rootFolderPath: String?
    let browsingFolderPath: String?
    let includeSubfolders: Bool
}

@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [PhotoItem] = []
    @Published private(set) var currentFolder: URL?
    @Published private(set) var browsingFolder: URL?
    @Published private(set) var directories: [PhotoDirectory] = []
    @Published var filter: PhotoFilter = .all
    @Published var searchText = "" {
        didSet {
            schedulePlaceResolutionForSearch()
        }
    }
    @Published var sortOrder: PhotoSortOrder = .captureNewest {
        didSet {
            revision &+= 1
        }
    }
    @Published var selectedTag: String?
    @Published var includeSubfolders = false {
        didSet {
            guard includeSubfolders != oldValue else { return }
            placeSearchTask?.cancel()
            isResolvingSearchPlaces = false
            normalizeSelectedTagForCurrentScope()
            invalidateVisibleCache()
            revision &+= 1
            statusMessage = summaryText
            schedulePlaceResolutionForSearch()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isDetecting = false
    @Published private(set) var isIndexingMetadata = false
    @Published private(set) var isResolvingSearchPlaces = false
    @Published private(set) var detectedCount = 0
    @Published private(set) var indexedMetadataCount = 0
    @Published private(set) var metadataIndexTotal = 0
    @Published private(set) var statusMessage = "请选择一个照片文件夹"
    @Published private(set) var revision = 0
    @Published private(set) var recentFolders: [RecentFolderEntry] = []

    private let liveCache = LiveStatusCache()
    private let selectionStore = SelectionStore()
    private let tagStore = TagStore()
    private let holdFrameStore = HoldFrameStore()
    private let recentFolderStore = RecentFolderStore()
    private let libraryIndexStore = LibraryIndexStore()
    private let detectionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MotionAlbum.LiveDetection"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let metadataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MotionAlbum.MetadataIndexing"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var scanTask: Task<Void, Never>?
    private var placeSearchTask: Task<Void, Never>?
    private var generation = UUID()
    private var visibleCacheSignature: VisibleCacheSignature?
    private var visibleCache: [PhotoItem] = []
    private var photoIDSet = Set<String>()
    private var directoryChildrenByPath: [String: [PhotoDirectory]] = [:]
    private var directPhotosByPath: [String: [PhotoItem]] = [:]
    private var directPhotoCountsByPath: [String: Int] = [:]
    private var descendantPhotoCountsByPath: [String: Int] = [:]
    private var directPhotoSizesByPath: [String: Int64] = [:]
    private var descendantPhotoSizesByPath: [String: Int64] = [:]

    init() {
        refreshRecentFolders()
    }

    var filteredPhotos: [PhotoItem] {
        let signature = VisibleCacheSignature(
            generation: generation,
            count: photos.count,
            revision: revision,
            filter: filter,
            searchText: searchText,
            selectedTag: selectedTag,
            sortOrder: sortOrder,
            rootFolderPath: currentFolder?.path,
            browsingFolderPath: browsingFolder?.path,
            includeSubfolders: includeSubfolders
        )
        if visibleCacheSignature == signature {
            return visibleCache
        }

        let terms = Self.searchTerms(from: searchText)
        let filtered = photos.filter { item in
            guard isItemInCurrentScope(item) else { return false }
            if terms.isEmpty == false,
               Self.matchesSearchTerms(terms, item: item, root: currentFolder) == false {
                return false
            }
            if let selectedTag, item.tags.contains(selectedTag) == false {
                return false
            }
            switch filter {
            case .all:
                return true
            case .live:
                return item.liveStatus == .live
            case .video:
                return item.mediaKind == .video
            case .selected:
                return item.isSelected
            }
        }
        let sorted = Self.sorted(filtered, by: sortOrder)
        visibleCacheSignature = signature
        visibleCache = sorted
        return sorted
    }

    var browsingPhotos: [PhotoItem] { photos.filter(isItemInCurrentScope) }
    var photoCount: Int { browsingPhotos.count }
    var liveCount: Int { browsingPhotos.lazy.filter { $0.liveStatus == .live }.count }
    var videoCount: Int { browsingPhotos.lazy.filter { $0.mediaKind == .video }.count }
    var selectedCount: Int { browsingPhotos.lazy.filter(\.isSelected).count }
    var selectedPhotos: [PhotoItem] { browsingPhotos.filter(\.isSelected) }
    var unknownCount: Int { photos.lazy.filter { $0.liveStatus == .unknown }.count }
    var taggedCount: Int { browsingPhotos.lazy.filter { $0.tags.isEmpty == false }.count }
    var allTags: [String] {
        Array(Set(browsingPhotos.flatMap(\.tags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    var hasUnavailableRecentFolders: Bool {
        recentFolders.contains { $0.isAvailable == false }
    }

    deinit {
        scanTask?.cancel()
        placeSearchTask?.cancel()
        detectionQueue.cancelAllOperations()
        metadataQueue.cancelAllOperations()
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
        placeSearchTask?.cancel()
        detectionQueue.cancelAllOperations()
        metadataQueue.cancelAllOperations()
        generation = UUID()
        let currentGeneration = generation

        if remember {
            recentFolderStore.add(folder)
            refreshRecentFolders()
        }

        currentFolder = folder
        browsingFolder = folder
        directories = [PhotoDirectory(url: folder, parentPath: nil)]
        directoryChildrenByPath = [:]
        directPhotosByPath = [:]
        directPhotoCountsByPath = [:]
        descendantPhotoCountsByPath = [:]
        directPhotoSizesByPath = [:]
        descendantPhotoSizesByPath = [:]
        photos = []
        photoIDSet = []
        selectedTag = nil
        visibleCacheSignature = nil
        visibleCache = []
        isResolvingSearchPlaces = false
        detectedCount = 0
        indexedMetadataCount = 0
        metadataIndexTotal = 0
        isDetecting = false
        isIndexingMetadata = false
        isLoading = true
        statusMessage = "正在扫描 \(folder.lastPathComponent)…"
        let recursive = true

        scanTask = Task { [weak self] in
            var didShowCachedIndex = false
            do {
                guard let self else { return }
                if let cachedDescriptors = await self.libraryIndexStore.load(folder: folder, recursively: recursive),
                   cachedDescriptors.isEmpty == false {
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration else { return }

                    self.applyDescriptors(
                        cachedDescriptors,
                        in: folder,
                        generation: currentGeneration,
                        statusMessage: "已从索引快速加载 \(cachedDescriptors.count) 个媒体文件，正在后台核对目录…"
                    )
                    didShowCachedIndex = true
                }

                let descriptors = try await Task.detached(priority: .userInitiated) {
                    try Self.scanPhotoFiles(in: folder, recursively: recursive)
                }.value
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }

                if didShowCachedIndex {
                    await self.libraryIndexStore.replaceFolderIndex(
                        descriptors: descriptors,
                        folder: folder,
                        recursively: recursive
                    )
                    let indexedDescriptors = await self.libraryIndexStore.load(folder: folder, recursively: recursive)
                    self.applyDescriptors(
                        indexedDescriptors ?? descriptors,
                        in: folder,
                        generation: currentGeneration,
                        statusMessage: descriptors.isEmpty
                            ? "该文件夹中没有可支持的照片或视频"
                            : "已核对目录，当前 \(descriptors.count) 个媒体文件"
                    )
                } else {
                    self.applyDescriptors(
                        descriptors,
                        in: folder,
                        generation: currentGeneration,
                        statusMessage: descriptors.isEmpty
                            ? "该文件夹中没有可支持的照片或视频"
                            : "已加载 \(descriptors.count) 个媒体文件"
                    )

                    Task { [libraryIndexStore] in
                        await libraryIndexStore.replaceFolderIndex(
                            descriptors: descriptors,
                            folder: folder,
                            recursively: recursive
                        )
                    }
                }
            } catch is CancellationError {
                // 用户切换目录，旧任务自然结束。
            } catch {
                guard let self else { return }
                self.isLoading = false
                if didShowCachedIndex {
                    self.statusMessage = "已显示索引缓存；后台核对失败：\(error.localizedDescription)"
                } else {
                    self.statusMessage = "扫描失败：\(error.localizedDescription)"
                }
                AppLogger.error("扫描照片目录失败：\(folder.path)", error: error)
            }
        }
        return true
    }

    private func applyDescriptors(
        _ descriptors: [PhotoFileDescriptor],
        in folder: URL,
        generation currentGeneration: UUID,
        statusMessage message: String
    ) {
        detectionQueue.cancelAllOperations()
        metadataQueue.cancelAllOperations()
        visibleCacheSignature = nil
        visibleCache = []
        isDetecting = false
        isIndexingMetadata = false
        indexedMetadataCount = 0
        metadataIndexTotal = 0

        let selectedNames = selectionStore.selectedFileNames(in: folder)
        let tagMap = tagStore.tagsByFileName(in: folder)
        let holdFrameMap = holdFrameStore.holdFrameTimes(in: folder)
        photos = descriptors.map { descriptor in
            let selectionKey = Self.relativeSelectionKey(for: descriptor.url, root: folder)
            let initialLiveStatus = descriptor.mediaKind == .video
                ? LivePhotoStatus.still
                : descriptor.indexedLiveStatus ?? liveCache.status(for: descriptor.cacheKey) ?? .unknown
            let item = PhotoItem(
                descriptor: descriptor,
                liveStatus: initialLiveStatus,
                isSelected: selectedNames.contains(selectionKey),
                selectionKey: selectionKey,
                tags: tagMap[selectionKey] ?? []
            )
            item.holdFrameTime = holdFrameMap[selectionKey]
            return item
        }
        rebuildDirectoryIndex(root: folder)
        photoIDSet = Set(photos.map(\.id))
        revision &+= 1
        isLoading = false
        detectedCount = photos.lazy.filter { $0.liveStatus != .unknown }.count
        statusMessage = message
        startMetadataIndexing(generation: currentGeneration)
        startLiveDetection(generation: currentGeneration)
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
        statusMessage = item.isSelected ? "已加入我喜欢：\(item.fileName)" : "已取消喜欢：\(item.fileName)"
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
        normalizeSelectedTagForCurrentScope()
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
        browsingPhotos.lazy.filter { $0.tags.contains(tag) }.count
    }

    func selectBrowsingFolder(_ folder: URL) {
        guard let currentFolder else { return }
        let folder = folder.standardizedFileURL
        guard Self.isPath(folder.path, equalToOrDescendantOf: currentFolder.path),
              directories.contains(where: { $0.id == folder.path }) else { return }
        guard browsingFolder?.standardizedFileURL.path != folder.path else { return }

        placeSearchTask?.cancel()
        isResolvingSearchPlaces = false
        browsingFolder = folder
        normalizeSelectedTagForCurrentScope()
        invalidateVisibleCache()
        revision &+= 1
        statusMessage = summaryText
        schedulePlaceResolutionForSearch()
    }

    func childDirectories(of directory: PhotoDirectory) -> [PhotoDirectory] {
        directoryChildrenByPath[directory.id] ?? []
    }

    func hasChildDirectories(_ directory: PhotoDirectory) -> Bool {
        directoryChildrenByPath[directory.id]?.isEmpty == false
    }

    func directPhotos(in directory: PhotoDirectory) -> [PhotoItem] {
        directPhotosByPath[directory.id] ?? []
    }

    func directPhotoCount(in directory: PhotoDirectory) -> Int {
        directPhotoCountsByPath[directory.id] ?? 0
    }

    func descendantPhotoCount(in directory: PhotoDirectory) -> Int {
        descendantPhotoCountsByPath[directory.id] ?? 0
    }

    func directPhotoSize(in directory: PhotoDirectory) -> Int64 {
        directPhotoSizesByPath[directory.id] ?? 0
    }

    func descendantPhotoSize(in directory: PhotoDirectory) -> Int64 {
        descendantPhotoSizesByPath[directory.id] ?? 0
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

    private func schedulePlaceResolutionForSearch() {
        placeSearchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            isResolvingSearchPlaces = false
            return
        }

        let currentGeneration = generation
        placeSearchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }

            guard let self,
                  self.generation == currentGeneration,
                  self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }

            let terms = Self.searchTerms(from: query)
            guard terms.isEmpty == false,
                  self.browsingPhotos.contains(where: {
                      Self.matchesSearchTerms(terms, item: $0, root: self.currentFolder, includePlace: false)
                  }) == false else { return }

            let candidates = self.browsingPhotos.filter { item in
                item.mediaKind == .image
                    && item.placeName == nil
                    && item.isResolvingPlaceName == false
                    && item.metadata.latitude != nil
                    && item.metadata.longitude != nil
            }
            guard candidates.isEmpty == false else { return }

            self.isResolvingSearchPlaces = true
            var pendingRevisionCount = 0
            for item in candidates {
                guard Task.isCancelled == false,
                      self.generation == currentGeneration,
                      self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { break }
                guard let latitude = item.metadata.latitude,
                      let longitude = item.metadata.longitude else { continue }

                item.isResolvingPlaceName = true
                let placeName = await PlaceNameResolver.shared.resolve(latitude: latitude, longitude: longitude)
                item.placeName = placeName
                item.isResolvingPlaceName = false
                pendingRevisionCount += 1
                if pendingRevisionCount >= 12 {
                    self.revision &+= 1
                    pendingRevisionCount = 0
                }
            }
            if pendingRevisionCount > 0 {
                self.revision &+= 1
            }
            self.isResolvingSearchPlaces = false
        }
    }

    @discardableResult
    func removeItemsFromLibrary(_ items: [PhotoItem]) -> Int {
        guard let currentFolder, items.isEmpty == false else { return 0 }
        let itemIDs = Set(items.map(\.id))
        let selectionKeys = Set(items.map(\.selectionKey))
        let beforeCount = photos.count

        photos.removeAll { itemIDs.contains($0.id) }
        let removedCount = beforeCount - photos.count
        guard removedCount > 0 else { return 0 }
        photoIDSet.subtract(itemIDs)
        visibleCacheSignature = nil
        visibleCache = []
        rebuildDirectoryIndex(root: currentFolder)

        selectionStore.remove(fileNames: selectionKeys, in: currentFolder)
        tagStore.remove(fileNames: selectionKeys, in: currentFolder)
        holdFrameStore.remove(fileNames: selectionKeys, in: currentFolder)
        Task { [libraryIndexStore, currentFolder] in
            await libraryIndexStore.removeFolderIndex(folder: currentFolder, recursively: true)
        }

        normalizeSelectedTagForCurrentScope()

        detectedCount = photos.lazy.filter { $0.liveStatus != .unknown }.count
        if photos.contains(where: { $0.liveStatus == .unknown }) == false {
            isDetecting = false
            liveCache.flush()
        }

        revision &+= 1
        statusMessage = summaryText
        return removedCount
    }

    private func refreshRecentFolders() {
        recentFolders = recentFolderStore.entries()
    }

    private func startLiveDetection(generation currentGeneration: UUID) {
        guard let folder = currentFolder else { return }
        let recursive = true
        let unknownItems = photos.filter { $0.mediaKind == .image && $0.liveStatus == .unknown }
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
                              self.generation == currentGeneration,
                              self.photoIDSet.contains(item.id) else { return }
                        item.liveStatus = newStatus
                        self.liveCache.set(newStatus, for: item.cacheKey)
                        Task { [libraryIndexStore = self.libraryIndexStore, url = item.url] in
                            await libraryIndexStore.updateLiveStatus(
                                newStatus,
                                for: url,
                                folder: folder,
                                recursively: recursive
                            )
                        }
                        self.detectedCount = min(self.detectedCount + 1, self.photos.count)
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

    private func startMetadataIndexing(generation currentGeneration: UUID) {
        guard let folder = currentFolder else { return }
        let recursive = true
        let imageItems = photos.filter { $0.mediaKind == .image && $0.metadata.isEmpty }
        guard imageItems.isEmpty == false else {
            isIndexingMetadata = false
            return
        }

        isIndexingMetadata = true
        indexedMetadataCount = 0
        metadataIndexTotal = imageItems.count
        let entries = imageItems.map { (item: $0, url: $0.url) }
        let workerCount = min(metadataQueue.maxConcurrentOperationCount, entries.count)
        for workerIndex in 0..<workerCount {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                var index = workerIndex
                while index < entries.count {
                    guard operation?.isCancelled == false else { return }
                    let entry = entries[index]
                    let metadata = PhotoMetadataReader.read(from: entry.url)
                    guard operation?.isCancelled == false else { return }

                    Task { @MainActor [weak self, weak item = entry.item] in
                        guard let self,
                              let item,
                              self.generation == currentGeneration,
                              self.photoIDSet.contains(item.id) else { return }
                        item.metadata = metadata
                        Task { [libraryIndexStore = self.libraryIndexStore, url = item.url] in
                            await libraryIndexStore.updateMetadata(
                                metadata,
                                for: url,
                                folder: folder,
                                recursively: recursive
                            )
                        }
                        self.indexedMetadataCount = min(self.indexedMetadataCount + 1, imageItems.count)
                        if self.indexedMetadataCount.isMultiple(of: 24) {
                            self.revision &+= 1
                        }
                        if self.indexedMetadataCount >= imageItems.count {
                            self.isIndexingMetadata = false
                            self.metadataIndexTotal = imageItems.count
                            self.revision &+= 1
                        }
                    }
                    index += workerCount
                }
            }
            metadataQueue.addOperation(operation)
        }
    }

    private var summaryText: String {
        if videoCount > 0 {
            return "共 \(photoCount) 个 · 实况 \(liveCount) 张 · 视频 \(videoCount) 个 · 喜欢 \(selectedCount) 个 · 已打标签 \(taggedCount) 个"
        }
        return "共 \(photoCount) 张 · 实况 \(liveCount) 张 · 喜欢 \(selectedCount) 张 · 已打标签 \(taggedCount) 张"
    }

    private func invalidateVisibleCache() {
        visibleCacheSignature = nil
        visibleCache = []
    }

    private func isItemInCurrentScope(_ item: PhotoItem) -> Bool {
        guard let browsingFolder else { return true }
        let parentPath = item.url.deletingLastPathComponent().standardizedFileURL.path
        if includeSubfolders {
            return Self.isPath(parentPath, equalToOrDescendantOf: browsingFolder.path)
        }
        return parentPath == browsingFolder.standardizedFileURL.path
    }

    private func normalizeSelectedTagForCurrentScope() {
        guard let selectedTag else { return }
        if browsingPhotos.contains(where: { $0.tags.contains(selectedTag) }) == false {
            self.selectedTag = nil
        }
    }

    private func rebuildDirectoryIndex(root: URL) {
        let root = root.standardizedFileURL
        let rootPath = root.path
        var directoriesByPath: [String: PhotoDirectory] = [
            rootPath: PhotoDirectory(url: root, parentPath: nil)
        ]
        var directPhotos: [String: [PhotoItem]] = [:]
        var directCounts: [String: Int] = [:]
        var descendantCounts: [String: Int] = [:]
        var directSizes: [String: Int64] = [:]
        var descendantSizes: [String: Int64] = [:]

        for item in photos {
            var directory = item.url.deletingLastPathComponent().standardizedFileURL
            guard Self.isPath(directory.path, equalToOrDescendantOf: rootPath) else { continue }
            directPhotos[directory.path, default: []].append(item)
            directCounts[directory.path, default: 0] += 1
            directSizes[directory.path, default: 0] += item.originalResourceFileSize

            while Self.isPath(directory.path, equalToOrDescendantOf: rootPath) {
                let path = directory.path
                descendantCounts[path, default: 0] += 1
                descendantSizes[path, default: 0] += item.originalResourceFileSize
                if directoriesByPath[path] == nil {
                    let parent = directory.deletingLastPathComponent().standardizedFileURL
                    directoriesByPath[path] = PhotoDirectory(
                        url: directory,
                        parentPath: path == rootPath ? nil : parent.path
                    )
                }
                guard path != rootPath else { break }
                directory = directory.deletingLastPathComponent().standardizedFileURL
            }
        }

        let sortedDirectories = directoriesByPath.values.sorted { left, right in
            if left.url.pathComponents.count != right.url.pathComponents.count {
                return left.url.pathComponents.count < right.url.pathComponents.count
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        var children: [String: [PhotoDirectory]] = [:]
        for directory in sortedDirectories {
            guard let parentPath = directory.parentPath else { continue }
            children[parentPath, default: []].append(directory)
        }
        for key in children.keys {
            children[key]?.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        for key in directPhotos.keys {
            directPhotos[key]?.sort {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
        }

        directories = sortedDirectories
        directoryChildrenByPath = children
        directPhotosByPath = directPhotos
        directPhotoCountsByPath = directCounts
        descendantPhotoCountsByPath = descendantCounts
        directPhotoSizesByPath = directSizes
        descendantPhotoSizesByPath = descendantSizes

        if let browsingFolder,
           directoriesByPath[browsingFolder.standardizedFileURL.path] == nil {
            self.browsingFolder = root
        }
    }

    nonisolated private static func isPath(_ path: String, equalToOrDescendantOf ancestorPath: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let ancestorPath = URL(fileURLWithPath: ancestorPath).standardizedFileURL.path
        if path == ancestorPath { return true }
        let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
        return path.hasPrefix(prefix)
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

    private static func searchTerms(from text: String) -> [String] {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func matchesSearchTerms(
        _ terms: [String],
        item: PhotoItem,
        root: URL?,
        includePlace: Bool = true
    ) -> Bool {
        let fields = searchableFields(for: item, root: root, includePlace: includePlace)
        return terms.allSatisfy { term in
            fields.contains { field in
                field.localizedCaseInsensitiveContains(term)
            }
        }
    }

    private static func sorted(_ items: [PhotoItem], by sortOrder: PhotoSortOrder) -> [PhotoItem] {
        items.sorted { left, right in
            switch sortOrder {
            case .captureNewest:
                if left.timelineDate != right.timelineDate {
                    return left.timelineDate > right.timelineDate
                }
            case .captureOldest:
                if left.timelineDate != right.timelineDate {
                    return left.timelineDate < right.timelineDate
                }
            case .modifiedNewest:
                if left.modifiedAt != right.modifiedAt {
                    return left.modifiedAt > right.modifiedAt
                }
            case .fileNameAscending:
                break
            }
            return left.fileName.localizedStandardCompare(right.fileName) == .orderedAscending
        }
    }

    private static func searchableFields(
        for item: PhotoItem,
        root: URL?,
        includePlace: Bool
    ) -> [String] {
        var fields = [
            item.fileName,
            item.url.path,
            item.url.deletingLastPathComponent().lastPathComponent,
            item.url.deletingLastPathComponent().path,
            item.selectionKey,
            item.mediaKind == .video ? "视频 video mov mp4 m4v" : "照片 图片 photo image",
            item.liveStatus == .live ? "实况 live 动态照片" : ""
        ]

        if let root {
            fields.append(root.path)
            fields.append(root.lastPathComponent)
        }
        fields.append(contentsOf: item.tags)
        if includePlace, let placeName = item.placeName {
            fields.append(placeName)
        }
        fields.append(contentsOf: [
            item.metadata.deviceText,
            item.metadata.software,
            item.metadata.capturedAt,
            item.metadata.sizeText
        ].compactMap { $0 })

        return fields.filter { $0.isEmpty == false }
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

        let imageURLs = candidateURLs.filter {
            imageExtensions.contains($0.pathExtension.lowercased())
        }
        let videoURLs = candidateURLs.filter {
            videoExtensions.contains($0.pathExtension.lowercased())
        }
        let companions = LivePhotoParser.resolvedCompanionVideos(
            imageURLs: imageURLs,
            videoURLs: videoURLs
        )
        let pairedVideoPaths = Set(companions.values.map { $0.standardizedFileURL.path })
        let results = candidateURLs.compactMap { url in
            descriptor(
                for: url,
                keys: keys,
                companions: companions,
                pairedVideoPaths: pairedVideoPaths
            )
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
        companions: [String: URL],
        pairedVideoPaths: Set<String>
    ) -> PhotoFileDescriptor? {
        let extensionName = url.pathExtension.lowercased()
        let mediaKind: MediaKind
        if imageExtensions.contains(extensionName) {
            mediaKind = .image
        } else if videoExtensions.contains(extensionName),
                  pairedVideoPaths.contains(url.standardizedFileURL.path) == false {
            mediaKind = .video
        } else {
            return nil
        }

        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        let companionVideoURL = mediaKind == .image
            ? companions[url.standardizedFileURL.path]
            : nil
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
            metadata: PhotoMetadata(),
            mediaKind: mediaKind,
            indexedLiveStatus: nil
        )
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
