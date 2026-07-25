import AppKit
import SwiftUI

private struct UserFacingAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct PendingTrashRequest: Identifiable {
    let id = UUID()
    let items: [PhotoItem]
    let title: String
    let message: String
    let confirmationTitle: String
    let fallbackViewerItem: PhotoItem?
}

private struct AppQuote: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let source: String?
}

private enum AppQuotes {
    static let toolbar: [AppQuote] = bundled + localQuotes()

    static let userQuotesFileURL: URL = {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("MotionAlbum", isDirectory: true)
            .appendingPathComponent("quotes.txt")
    }()

    private static let bundled: [AppQuote] = [
        AppQuote(text: "当时只道是寻常", source: "纳兰性德"),
        AppQuote(text: "浮云一别后，流水十年间", source: "韦应物"),
        AppQuote(text: "诗酒趁年华", source: "苏轼"),
        AppQuote(text: "平凡的一天，也值得收藏", source: "灵动相册"),
        AppQuote(text: "把时间折好，放进相册", source: "灵动相册"),
        AppQuote(text: "照片不说话，却替我们记得", source: "灵动相册")
    ]

    private static func localQuotes() -> [AppQuote] {
        guard let text = try? String(contentsOf: userQuotesFileURL, encoding: .utf8) else {
            return []
        }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> AppQuote? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else { return nil }
                let parts = trimmed.components(separatedBy: " — ")
                if parts.count >= 2 {
                    return AppQuote(
                        text: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                        source: parts.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                return AppQuote(text: trimmed, source: nil)
            }
    }
}

private enum AppIconImageProvider {
    static let image: NSImage = {
        let bundleCandidates = [
            Bundle.main.url(forResource: "app_icon", withExtension: "png"),
            Bundle.main.url(forResource: "app_icon", withExtension: "icns")
        ].compactMap { $0 }

        for url in bundleCandidates {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        if let namedIcon = NSImage(named: "app_icon") {
            return namedIcon
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let packageRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceCandidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/app_icon.png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("LivePhotoLookerMac/Resources/app_icon.png"),
            packageRoot.appendingPathComponent("Resources/app_icon.png")
        ]

        for url in sourceCandidates {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return NSApplication.shared.applicationIconImage
    }()
}

struct ContentView: View {
    @StateObject private var library = PhotoLibrary()
    @State private var viewerItem: PhotoItem?
    @State private var alert: UserFacingAlert?
    @State private var showPhoneSyncConfirmation = false
    @State private var isWorking = false
    @State private var pendingTrashRequest: PendingTrashRequest?
    @State private var galleryThumbnailSize: CGFloat = 126
    @State private var galleryScrollTargetID: String?
    @State private var galleryScrollToTopToken = 0
    @State private var focusedGalleryItemID: String?
    @State private var focusedGalleryItemName: String?
    @State private var groupPhotosByTime = true

    private let galleryThumbnailSizeRange: ClosedRange<CGFloat> = 72...230

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .frame(minWidth: 1080, minHeight: 700)
        .toolbar { toolbar }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "同步 \(library.selectedCount) 张精选照片到安卓手机？",
            isPresented: $showPhoneSyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("同步并打开手机微信") { syncSelectedToAndroidPhone() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原始照片文件会原样复制到手机 DCIM/MotionAlbum。之后请在手机微信中从相册选择，并在大图预览左下角打开“实况”开关再发送。")
        }
        .confirmationDialog(
            pendingTrashRequest?.title ?? "移入废纸篓？",
            isPresented: Binding(
                get: { pendingTrashRequest != nil },
                set: { if !$0 { pendingTrashRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let request = pendingTrashRequest {
                Button(request.confirmationTitle, role: .destructive) {
                    pendingTrashRequest = nil
                    moveItemsToTrash(request)
                }
            }
            Button("取消", role: .cancel) {
                pendingTrashRequest = nil
            }
        } message: {
            Text(pendingTrashRequest?.message ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPhotoFolder)) { _ in
            guard !isWorking else { return }
            resetViewerContext()
            library.chooseAndOpenFolder()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandHeader
            folderSummaryCard

            Button {
                resetViewerContext()
                library.chooseAndOpenFolder()
            } label: {
                Label("打开文件夹", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            Menu {
                recentFolderMenuItems
            } label: {
                Label("打开历史目录", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(isWorking)

            Toggle("包含子文件夹", isOn: Binding(
                get: { library.includeSubfolders },
                set: { value in
                    guard !isWorking else { return }
                    library.includeSubfolders = value
                    if library.currentFolder != nil {
                        resetViewerContext()
                        library.reload()
                    }
                }
            ))
            .disabled(library.isLoading || isWorking)

            Divider()

            sidebarSectionTitle("筛选")
            ForEach(PhotoFilter.allCases) { filter in
                Button {
                    library.filter = filter
                } label: {
                    HStack {
                        Label(filter.rawValue, systemImage: filterIcon(filter))
                        Spacer()
                        Text(filterCount(filter).formatted())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        library.filter == filter ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .buttonStyle(.plain)
            }

            if library.allTags.isEmpty == false {
                Divider()

                HStack {
                    sidebarSectionTitle("标签")
                    Spacer()
                    if library.selectedTag != nil {
                        Button("清除") {
                            library.selectTag(nil)
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                    }
                }

                VStack(spacing: 4) {
                    ForEach(library.allTags, id: \.self) { tag in
                        Button {
                            library.selectTag(library.selectedTag == tag ? nil : tag)
                        } label: {
                            HStack(spacing: 6) {
                                Label(tag, systemImage: "tag")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text(library.count(forTag: tag).formatted())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                library.selectedTag == tag ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            Button {
                exportFilteredOriginals()
            } label: {
                Label("导出当前筛选", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(library.filteredPhotos.isEmpty || isWorking)

            Button(role: .destructive) {
                requestTrashSelectedItems()
            } label: {
                Label("移入废纸篓精选", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(library.selectedCount == 0 || isWorking)

            Button {
                showPhoneSyncConfirmation = true
            } label: {
                Label("同步精选到安卓手机", systemImage: "iphone.and.arrow.forward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(library.selectedCount == 0 || isWorking)

            Spacer()

            if library.isDetecting {
                ProgressView(
                    value: Double(library.detectedCount),
                    total: Double(max(1, library.photos.count))
                )
                Text("后台识别实况 \(library.detectedCount)/\(library.photos.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if library.isIndexingMetadata {
                ProgressView(
                    value: Double(library.indexedMetadataCount),
                    total: Double(max(1, library.metadataIndexTotal))
                )
                Text("后台读取元信息 \(library.indexedMetadataCount)/\(library.metadataIndexTotal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            authorSignature
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconImageProvider.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(.white.opacity(0.5), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.displayName)
                    .font(.system(size: 19, weight: .bold))
                Text(AppIdentity.englishName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var authorSignature: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.58))
            Text("神马都会亿点点的毛毛张")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("作者：神马都会亿点点的毛毛张")
    }

    private var folderSummaryCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("照片目录", systemImage: "folder")
                .font(.headline)
            Text(library.currentFolder?.path ?? "尚未选择")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private var detail: some View {
        if library.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(library.statusMessage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.currentFolder == nil {
            emptyState(
                title: "打开照片文件夹",
                systemImage: "livephoto",
                description: "直接读取手机导出的原始照片，静态图、内嵌视频和同名 MOV 都会尽量保留。"
            ) {
                Button("选择文件夹") {
                    viewerItem = nil
                    library.chooseAndOpenFolder()
                }
                    .controlSize(.large)
            }
        } else {
            ZStack {
                libraryContent
                    .opacity(viewerItem == nil ? 1 : 0)
                    .allowsHitTesting(viewerItem == nil)
                    .accessibilityHidden(viewerItem != nil)

                if let viewerItem {
                    viewer(for: viewerItem)
                        .transition(.opacity)
                }
            }
            .background(pageBackground)
            .animation(.easeInOut(duration: 0.12), value: viewerItem?.id)
            .animation(.easeInOut(duration: 0.18), value: library.filter)
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            libraryHeader
            if library.filteredPhotos.isEmpty {
                emptyState(
                    title: "没有符合条件的照片",
                    systemImage: "photo.on.rectangle.angled",
                    description: library.isDetecting && library.filter == .live
                        ? "实况照片仍在后台识别，请稍候。"
                        : "请调整筛选或搜索条件。"
                ) { EmptyView() }
            } else {
                PhotoGridView(
                    photos: library.filteredPhotos,
                    thumbnailSize: galleryThumbnailSize,
                    thumbnailSizeRange: galleryThumbnailSizeRange,
                    scrollTargetID: galleryScrollTargetID,
                    scrollToTopToken: galleryScrollToTopToken,
                    focusedItemID: focusedGalleryItemID,
                    groupByTime: groupPhotosByTime,
                    onThumbnailSizeChange: setGalleryThumbnailSize,
                    onScrollTargetConsumed: { galleryScrollTargetID = nil },
                    onOpen: openViewer,
                    onToggleSelection: library.toggleSelection,
                    onReveal: library.revealInFinder,
                    onTrash: { requestTrashItems([$0], fallbackViewerItem: nil) },
                    isInteractionDisabled: isWorking
                )
            }
            Divider()
            statusFooter
        }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("照片库")
                        .font(.system(size: 24, weight: .bold))
                    Text(library.currentFolder?.path ?? "选择一个照片目录开始")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if library.isDetecting {
                    HStack(spacing: 8) {
                        ProgressView(
                            value: Double(library.detectedCount),
                            total: Double(max(1, library.photos.count))
                        )
                        .frame(width: 92)
                        Text("\(library.detectedCount)/\(library.photos.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                }

                if library.isIndexingMetadata {
                    HStack(spacing: 8) {
                        ProgressView(
                            value: Double(library.indexedMetadataCount),
                            total: Double(max(1, library.metadataIndexTotal))
                        )
                        .frame(width: 92)
                        Text("元信息 \(library.indexedMetadataCount)/\(library.metadataIndexTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.10), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                metricBadge("全部", value: library.photos.count, systemImage: "photo.stack")
                metricBadge("实况", value: library.liveCount, systemImage: "livephoto")
                if library.videoCount > 0 {
                    metricBadge("视频", value: library.videoCount, systemImage: "play.rectangle")
                }
                metricBadge("精选", value: library.selectedCount, systemImage: "checkmark.circle")
                metricBadge("标签", value: library.taggedCount, systemImage: "tag")
                if let selectedTag = library.selectedTag {
                    TagBadgeView(tag: selectedTag, count: library.count(forTag: selectedTag), isActive: true)
                }
                Spacer()
                sortMenu
                thumbnailSizeControl
                if focusedGalleryItemID != nil {
                    Button {
                        returnToFocusedGalleryItem()
                    } label: {
                        Label("回到查看位置", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .help(focusedGalleryItemName.map { "回到刚刚查看的照片：\($0)" } ?? "回到刚刚查看的照片")
                }
                Button {
                    galleryScrollToTopToken &+= 1
                } label: {
                    Label("回到顶部", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.bordered)
                .help("回到照片库顶部")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var statusFooter: some View {
        HStack {
            if isWorking || library.isResolvingSearchPlaces || library.isIndexingMetadata {
                ProgressView().controlSize(.small)
            }
            Text(statusFooterMessage)
                .lineLimit(1)
            Spacer()
            Text("当前显示 \(library.filteredPhotos.count) 张")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
    }

    private var statusFooterMessage: String {
        if library.isResolvingSearchPlaces {
            return "正在解析照片地点用于搜索…"
        }
        if library.isIndexingMetadata {
            return "正在后台读取拍摄时间、设备和尺寸，不影响浏览…"
        }
        return library.statusMessage
    }

    private var pageBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor).opacity(0.72)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func emptyState<Actions: View>(
        title: String,
        systemImage: String,
        description: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .background(pageBackground)
    }

    private func metricBadge(_ title: String, value: Int, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
            Text(value.formatted())
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var thumbnailSizeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.magnifyingglass")
            Slider(
                value: Binding(
                    get: { Double(galleryThumbnailSize) },
                    set: { setGalleryThumbnailSize(CGFloat($0)) }
                ),
                in: Double(galleryThumbnailSizeRange.lowerBound)...Double(galleryThumbnailSizeRange.upperBound)
            )
            .frame(width: 118)
            Image(systemName: "plus.magnifyingglass")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .help("调整照片墙缩略图大小；触控板也可以捏合缩放")
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $library.sortOrder) {
                ForEach(PhotoSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            Divider()
            Toggle("按时间分组（小图按月，大图按日）", isOn: $groupPhotosByTime)
        } label: {
            Label(library.sortOrder.shortTitle, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .help("选择照片库排序方式")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                resetViewerContext()
                library.chooseAndOpenFolder()
            } label: {
                Label("打开", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(isWorking)

            Menu {
                recentFolderMenuItems
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
            .disabled(isWorking)

            Button {
                resetViewerContext()
                library.reload()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(library.currentFolder == nil || library.isLoading || isWorking)
        }

        ToolbarItem(placement: .principal) {
            QuoteRotatorView(quotes: AppQuotes.toolbar)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            MacSearchField(
                text: $library.searchText,
                placeholder: "搜索文件名、标签、地点或目录"
            )
            .frame(width: 310, height: 28)

            Button {
                exportFilteredOriginals()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(library.filteredPhotos.isEmpty || isWorking)

            Button(role: .destructive) {
                requestTrashSelectedItems()
            } label: {
                Label("移入废纸篓精选", systemImage: "trash")
            }
            .disabled(library.selectedCount == 0 || isWorking)
        }
    }

    @ViewBuilder
    private var recentFolderMenuItems: some View {
        if library.recentFolders.isEmpty {
            Button("暂无历史目录") {}
                .disabled(true)
        } else {
            ForEach(library.recentFolders) { folder in
                Button {
                    openRecentFolder(folder)
                } label: {
                    Label(
                        recentFolderTitle(folder),
                        systemImage: folder.isAvailable ? "folder" : "exclamationmark.triangle"
                    )
                }
                .help(recentFolderHelp(folder))
            }

            Divider()

            if library.hasUnavailableRecentFolders {
                Button("清理不可用目录") {
                    library.removeUnavailableRecentFolders()
                }
            }

            Button("清空历史目录", role: .destructive) {
                library.clearRecentFolders()
            }
        }
    }

    private func viewer(for item: PhotoItem) -> some View {
        ViewerView(
            item: item,
            canGoPrevious: viewerNeighbor(of: item, offset: -1) != nil,
            canGoNext: viewerNeighbor(of: item, offset: 1) != nil,
            onPrevious: { moveViewer(from: item, offset: -1) },
            onNext: { moveViewer(from: item, offset: 1) },
            onClose: { closeViewer(focusing: item) },
            onToggleSelection: { library.toggleSelection(item) },
            onAddTag: { library.addTag($0, to: item) },
            onRemoveTag: { library.removeTag($0, from: item) },
            onSetHoldFrame: { library.setHoldFrameTime($0, for: item) },
            onTrash: { requestTrashViewerItem(item) },
            isLibraryBusy: isWorking
        )
        .id(item.id)
    }

    private func filterIcon(_ filter: PhotoFilter) -> String {
        switch filter {
        case .all: return "photo.stack"
        case .live: return "livephoto"
        case .video: return "play.rectangle"
        case .selected: return "checkmark.circle"
        }
    }

    private func filterCount(_ filter: PhotoFilter) -> Int {
        switch filter {
        case .all: return library.photos.count
        case .live: return library.liveCount
        case .video: return library.videoCount
        case .selected: return library.selectedCount
        }
    }

    private func setGalleryThumbnailSize(_ size: CGFloat) {
        galleryThumbnailSize = min(
            galleryThumbnailSizeRange.upperBound,
            max(galleryThumbnailSizeRange.lowerBound, size)
        )
    }

    private func openViewer(_ item: PhotoItem) {
        setFocusedGalleryItem(item)
        viewerItem = item
    }

    private func closeViewer(focusing item: PhotoItem) {
        setFocusedGalleryItem(item)
        galleryScrollTargetID = item.id
        viewerItem = nil
    }

    private func setFocusedGalleryItem(_ item: PhotoItem?) {
        focusedGalleryItemID = item?.id
        focusedGalleryItemName = item?.fileName
    }

    private func resetViewerContext() {
        viewerItem = nil
        galleryScrollTargetID = nil
        focusedGalleryItemID = nil
        focusedGalleryItemName = nil
    }

    private func returnToFocusedGalleryItem() {
        guard let focusedGalleryItemID else { return }
        guard library.filteredPhotos.contains(where: { $0.id == focusedGalleryItemID }) else {
            library.setStatus("刚刚查看的照片不在当前筛选结果中，请先调整筛选或搜索")
            return
        }

        galleryScrollTargetID = nil
        DispatchQueue.main.async {
            galleryScrollTargetID = focusedGalleryItemID
        }
    }

    private func requestTrashSelectedItems() {
        requestTrashItems(library.selectedPhotos, fallbackViewerItem: nil)
    }

    private func requestTrashViewerItem(_ item: PhotoItem) {
        let fallback = viewerNeighbor(of: item, offset: 1) ?? viewerNeighbor(of: item, offset: -1)
        requestTrashItems([item], fallbackViewerItem: fallback)
    }

    private func requestTrashItems(_ items: [PhotoItem], fallbackViewerItem: PhotoItem?) {
        guard !isWorking else { return }
        let items = uniquePhotoItems(items)
        guard items.isEmpty == false else { return }

        let resourceCount = uniqueResourceURLs(from: items).count
        let title: String
        let message: String
        let confirmationTitle: String

        if items.count == 1, let item = items.first {
            title = "将这张照片移入废纸篓？"
            confirmationTitle = "移入废纸篓"
            message = """
            \(item.fileName)

            会被移到 macOS 废纸篓，不会永久删除。如果外接硬盘不支持废纸篓，会改为移入同目录下隐藏的 .MotionAlbumTrash 安全删除区。如果它有同名 MOV/MP4 实况视频，也会一起移动。
            """
        } else {
            title = "将 \(items.count) 张精选照片移入废纸篓？"
            confirmationTitle = "移入废纸篓 \(items.count) 张"
            message = """
            将移动 \(items.count) 张照片及其配套视频，共 \(resourceCount) 个原始文件。

            文件会优先进入 macOS 废纸篓；如果外接硬盘不支持废纸篓，会改为移入同目录下隐藏的 .MotionAlbumTrash 安全删除区。灵动相册会同时清理这些照片的精选、标签和封面帧记录。
            """
        }

        pendingTrashRequest = PendingTrashRequest(
            items: items,
            title: title,
            message: message,
            confirmationTitle: confirmationTitle,
            fallbackViewerItem: fallbackViewerItem
        )
    }

    private func moveItemsToTrash(_ request: PendingTrashRequest) {
        guard !isWorking else { return }
        let items = uniquePhotoItems(request.items)
        let sourceURLs = uniqueResourceURLs(from: items)
        guard sourceURLs.isEmpty == false else { return }

        isWorking = true
        library.setStatus("正在移入废纸篓 0/\(sourceURLs.count)…")

        Task { @MainActor in
            do {
                let result = try await TrashService.moveToTrash(sourceURLs) { completed, total in
                    Task { @MainActor in
                        library.setStatus("正在移入废纸篓 \(completed)/\(total)…")
                    }
                }

                let processedPaths = Set(result.processedURLs.map { $0.standardizedFileURL.path })
                let removableItems = items.filter { processedPaths.contains($0.url.standardizedFileURL.path) }
                let removedIDs = Set(removableItems.map(\.id))
                let removedCount = library.removeItemsFromLibrary(removableItems)

                if let viewerItem, removedIDs.contains(viewerItem.id) {
                    if let fallback = request.fallbackViewerItem,
                       removedIDs.contains(fallback.id) == false {
                        self.setFocusedGalleryItem(fallback)
                        self.galleryScrollTargetID = fallback.id
                        self.viewerItem = fallback
                    } else {
                        self.setFocusedGalleryItem(nil)
                        self.viewerItem = nil
                    }
                }

                if result.failedCount == 0 {
                    let missingSuffix = result.missingCount > 0 ? "，其中 \(result.missingCount) 个文件已不存在" : ""
                    let fallbackSuffix = result.fallbackMovedCount > 0
                        ? "，\(result.fallbackMovedCount) 个文件进入外接盘安全删除区"
                        : ""
                    library.finishStatus("已处理 \(removedCount) 张照片（废纸篓 \(result.trashedCount) 个文件\(fallbackSuffix)\(missingSuffix)）")
                } else {
                    let fallbackSuffix = result.fallbackMovedCount > 0
                        ? "，\(result.fallbackMovedCount) 个文件进入外接盘安全删除区"
                        : ""
                    library.finishStatus("已处理 \(removedCount) 张照片\(fallbackSuffix)，\(result.failedCount) 个文件未能移动")
                    alert = UserFacingAlert(
                        title: "部分文件未能移入废纸篓",
                        message: result.failureMessage.isEmpty
                            ? "有 \(result.failedCount) 个文件移动失败，请检查文件是否被其他应用占用或是否有权限。"
                            : result.failureMessage
                    )
                }
            } catch is CancellationError {
                library.finishStatus("已取消移入废纸篓")
            } catch {
                alert = UserFacingAlert(title: "移入废纸篓失败", message: error.localizedDescription)
                AppLogger.error("移入废纸篓任务失败", error: error)
            }
            isWorking = false
        }
    }

    private func exportFilteredOriginals() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "选择导出位置"
        panel.prompt = "导出到这里"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let sourceURLs = uniqueResourceURLs(from: library.filteredPhotos)
        isWorking = true
        Task {
            do {
                let outputs = try await ExportService.exportOriginals(
                    sourceURLs,
                    to: destination
                ) { completed, total in
                    Task { @MainActor in
                        library.setStatus("正在导出 \(completed)/\(total)…")
                    }
                }
                library.finishStatus("已原样导出 \(outputs.count) 个原始文件到 \(destination.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting(Array(outputs.prefix(1)))
            } catch is CancellationError {
                library.finishStatus("已取消导出")
            } catch {
                alert = UserFacingAlert(title: "导出失败", message: error.localizedDescription)
                AppLogger.error("导出筛选照片失败", error: error)
            }
            isWorking = false
        }
    }

    private func syncSelectedToAndroidPhone() {
        guard !isWorking else { return }
        let sourceURLs = uniqueResourceURLs(from: library.photos.filter(\.isSelected))
        guard !sourceURLs.isEmpty else { return }
        isWorking = true
        Task {
            do {
                let result = try await AdbService.syncToAndroidPhone(sourceURLs: sourceURLs) { completed, total in
                    Task { @MainActor in
                        library.setStatus("正在同步到手机 \(completed)/\(total)…")
                    }
                }
                library.finishStatus("已同步 \(result.count) 个原始文件到手机")
                alert = UserFacingAlert(
                    title: "同步完成",
                    message: "文件位于手机 \(result.remoteDirectory)。微信已在手机上打开；请从相册选择照片，进入大图预览并打开左下角“实况”开关后发送。"
                )
            } catch {
                alert = UserFacingAlert(title: "无法同步到手机", message: error.localizedDescription)
                AppLogger.error("ADB 同步失败", error: error)
            }
            isWorking = false
        }
    }

    private func uniquePhotoItems(_ items: [PhotoItem]) -> [PhotoItem] {
        var seen = Set<String>()
        var unique: [PhotoItem] = []
        unique.reserveCapacity(items.count)
        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            unique.append(item)
        }
        return unique
    }

    private func viewerNeighbor(of item: PhotoItem, offset: Int) -> PhotoItem? {
        let items = library.filteredPhotos
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let target = index + offset
        guard items.indices.contains(target) else { return nil }
        return items[target]
    }

    private func uniqueResourceURLs(from items: [PhotoItem]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for item in items {
            for url in item.originalResourceURLs {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    private func moveViewer(from item: PhotoItem, offset: Int) {
        if let target = viewerNeighbor(of: item, offset: offset) {
            setFocusedGalleryItem(target)
            galleryScrollTargetID = target.id
            viewerItem = target
        }
    }

    private func openRecentFolder(_ folder: RecentFolderEntry) {
        resetViewerContext()
        if library.openRecentFolder(folder) == false {
            alert = UserFacingAlert(
                title: "打不开历史目录",
                message: "这个目录可能已经被移动、删除或没有读取权限：\n\(folder.path)\n\n你可以在“打开历史目录”中清理不可用目录。"
            )
        }
    }

    private func recentFolderTitle(_ folder: RecentFolderEntry) -> String {
        if folder.isAvailable {
            return folder.displayName
        }
        return "\(folder.displayName)（不可用）"
    }

    private func recentFolderHelp(_ folder: RecentFolderEntry) -> String {
        if folder.wasResolvedFromBookmark, folder.originalPath != folder.path {
            return "\(folder.path)\n原位置：\(folder.originalPath)"
        }
        return folder.path
    }
}

private struct QuoteRotatorView: View {
    let quotes: [AppQuote]
    @State private var currentIndex = 0

    private let timer = Timer.publish(every: 8.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let quote = currentQuote {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.68))

                    Text(quote.text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let source = quote.source {
                        Text("· \(source)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.54))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .center)
                .id(quote.id)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }
        }
        .frame(minWidth: 300, idealWidth: 470, maxWidth: 560, minHeight: 28, idealHeight: 28)
        .clipped()
        .help("可在 \(AppQuotes.userQuotesFileURL.path) 添加本地语句；每行一句，也可以写成「句子 — 来源」。")
        .onReceive(timer) { _ in
            guard quotes.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                currentIndex = (currentIndex + 1) % quotes.count
            }
        }
    }

    private var currentQuote: AppQuote? {
        guard quotes.isEmpty == false else { return nil }
        return quotes[currentIndex % quotes.count]
    }
}

private struct MacSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.controlSize = .regular
        field.focusRingType = .default
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.maximumNumberOfLines = 1
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        nsView.placeholderString = placeholder
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
