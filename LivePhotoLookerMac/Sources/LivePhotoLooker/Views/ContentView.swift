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

private enum DirectoryOutlineEntry: Identifiable {
    case directory(PhotoDirectory, depth: Int)
    case media(PhotoItem, directory: PhotoDirectory, depth: Int)

    var id: String {
        switch self {
        case let .directory(directory, _):
            return "directory:\(directory.id)"
        case let .media(item, _, _):
            return "media:\(item.id)"
        }
    }
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
    @AppStorage("workspace.sidebar.isVisible") private var isSidebarVisible = true
    @AppStorage("workspace.sidebar.preferredWidth.v2") private var preferredSidebarWidth = 238.0
    @State private var viewerItem: PhotoItem?
    @State private var alert: UserFacingAlert?
    @State private var showPhoneSyncConfirmation = false
    @State private var isWorking = false
    @State private var pendingTrashRequest: PendingTrashRequest?
    @State private var galleryThumbnailSize: CGFloat = 126
    @State private var galleryScrollTargetID: String?
    @State private var galleryScrollTargetToken = 0
    @State private var galleryScrollToTopToken = 0
    @State private var focusedGalleryItemID: String?
    @State private var focusedGalleryItemName: String?
    @State private var previousGalleryItemID: String?
    @State private var previousGalleryItemName: String?
    @State private var groupPhotosByTime = true
    @State private var expandedDirectoryPaths = Set<String>()
    @State private var visibleSidebarWidth = 238.0
    @State private var sidebarResizeStartWidth: Double?
    @State private var isSidebarResizeHandleHovered = false
    @State private var isSidebarResizing = false

    private let galleryThumbnailSizeRange: ClosedRange<CGFloat> = 72...1_100
    private let galleryZoomStops: [CGFloat] = [72, 96, 126, 160, 220, 300, 420, 520, 720, 900, 1_100]
    private let workspaceCornerRadius: CGFloat = 14
    private let defaultSidebarWidth = 238.0
    private let sidebarWidthRange = 210.0...600.0
    private let minimumLibraryWidth = 620.0
    private let sidebarDividerWidth = 12.0

    var body: some View {
        ZStack {
            MotionWorkspaceBackground()

            GeometryReader { geometry in
                let sidebarMaximumWidth = maximumSidebarWidth(
                    for: Double(geometry.size.width)
                )

                HStack(spacing: 0) {
                    if isSidebarVisible {
                        workspacePanel(usesGlass: true) {
                            sidebar
                        }
                        .frame(
                            width: clampedSidebarWidth(
                                visibleSidebarWidth,
                                maximumWidth: sidebarMaximumWidth
                            )
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .accessibilityIdentifier("workspace.sidebar")

                        sidebarResizeHandle(maximumWidth: sidebarMaximumWidth)
                    }

                    workspacePanel(usesGlass: false) {
                        detail
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("workspace.library")
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .onAppear {
                    visibleSidebarWidth = clampedSidebarWidth(
                        preferredSidebarWidth,
                        maximumWidth: sidebarMaximumWidth
                    )
                }
                .onChange(of: geometry.size.width) { width in
                    guard !isSidebarResizing else { return }
                    visibleSidebarWidth = clampedSidebarWidth(
                        preferredSidebarWidth,
                        maximumWidth: maximumSidebarWidth(for: Double(width))
                    )
                }
                .onChange(of: preferredSidebarWidth) { width in
                    guard !isSidebarResizing else { return }
                    visibleSidebarWidth = clampedSidebarWidth(
                        width,
                        maximumWidth: sidebarMaximumWidth
                    )
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .animation(.easeInOut(duration: 0.20), value: isSidebarVisible)
        .toolbar { toolbar }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .confirmationDialog(
            "同步 \(library.selectedCount) 张“我喜欢”照片到安卓手机？",
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
        .onChange(of: library.currentFolder?.standardizedFileURL.path) { path in
            guard let path else {
                expandedDirectoryPaths = []
                return
            }
            expandedDirectoryPaths = [path]
        }
    }

    private func sidebarResizeHandle(maximumWidth: Double) -> some View {
        let isActive = isSidebarResizeHandleHovered || isSidebarResizing

        return ZStack {
            Rectangle()
                .fill(Color.clear)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(
                    isActive
                        ? Color.accentColor.opacity(0.72)
                        : Color.primary.opacity(0.08)
                )
                .frame(width: isActive ? 3 : 1)
                .padding(.vertical, 12)

            if isActive {
                Capsule()
                    .fill(Color.accentColor.opacity(isSidebarResizing ? 0.95 : 0.72))
                    .frame(width: 4, height: 56)
                    .shadow(color: Color.accentColor.opacity(0.24), radius: 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: sidebarDividerWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isSidebarResizeHandleHovered = hovering
            if hovering || isSidebarResizing {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .background(
            isActive
                ? Color.accentColor.opacity(0.055)
                : Color.clear
        )
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if sidebarResizeStartWidth == nil {
                        sidebarResizeStartWidth = visibleSidebarWidth
                        isSidebarResizing = true
                        NSCursor.resizeLeftRight.set()
                    }
                    let startWidth = sidebarResizeStartWidth ?? visibleSidebarWidth
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        visibleSidebarWidth = clampedSidebarWidth(
                            startWidth + Double(value.translation.width),
                            maximumWidth: maximumWidth
                        )
                    }
                }
                .onEnded { _ in
                    preferredSidebarWidth = visibleSidebarWidth
                    sidebarResizeStartWidth = nil
                    isSidebarResizing = false
                    if !isSidebarResizeHandleHovered {
                        NSCursor.arrow.set()
                    }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        visibleSidebarWidth = clampedSidebarWidth(
                            defaultSidebarWidth,
                            maximumWidth: maximumWidth
                        )
                    }
                    preferredSidebarWidth = defaultSidebarWidth
                }
        )
        .overlay(alignment: .top) {
            if isSidebarResizing {
                Text("\(Int(visibleSidebarWidth.rounded())) pt")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .motionGlassCapsule(tint: Color.accentColor.opacity(0.10))
                    .offset(y: 16)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.12), value: isSidebarResizing)
        .zIndex(20)
        .onDisappear {
            if isSidebarResizeHandleHovered || isSidebarResizing {
                NSCursor.arrow.set()
            }
        }
        .help("沿整条边界左右拖动调整宽度；双击恢复默认宽度")
        .accessibilityLabel("调整侧边栏宽度")
        .accessibilityIdentifier("workspace.sidebar.resize")
    }

    private func maximumSidebarWidth(for containerWidth: Double) -> Double {
        let availableWidth = containerWidth
            - 20
            - sidebarDividerWidth
            - minimumLibraryWidth
        return min(
            sidebarWidthRange.upperBound,
            max(sidebarWidthRange.lowerBound, availableWidth)
        )
    }

    private func clampedSidebarWidth(
        _ width: Double,
        maximumWidth: Double? = nil
    ) -> Double {
        min(
            maximumWidth ?? sidebarWidthRange.upperBound,
            max(sidebarWidthRange.lowerBound, width)
        )
    }

    @ViewBuilder
    private func workspacePanel<Content: View>(
        usesGlass: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let panel = content()
            .frame(maxHeight: .infinity)
            .clipShape(
                RoundedRectangle(cornerRadius: workspaceCornerRadius, style: .continuous)
            )

        if usesGlass {
            panel.motionGlassSurface(
                cornerRadius: workspaceCornerRadius,
                shadowOpacity: 0.10,
                shadowRadius: 18,
                shadowY: 7
            )
        } else {
            panel
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(0.16),
                    in: RoundedRectangle(cornerRadius: workspaceCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: workspaceCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            brandHeader
            folderSummaryCard

            ScrollView {
                VStack(spacing: 10) {
                    sidebarBlock("资源管理器", systemImage: "folder") {
                        Menu {
                            recentFolderMenuItems
                        } label: {
                            sidebarMenuLabel("最近打开", systemImage: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: .infinity)
                        .disabled(isWorking)

                        Divider()

                        Toggle("包含所选目录的子目录", isOn: Binding(
                            get: { library.includeSubfolders },
                            set: { value in
                                guard !isWorking else { return }
                                resetViewerContext()
                                library.includeSubfolders = value
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(library.currentFolder == nil || isWorking)

                        if library.currentFolder != nil {
                            Divider()

                            LazyVStack(spacing: 2) {
                                ForEach(visibleDirectoryEntries) { entry in
                                    switch entry {
                                    case let .directory(directory, depth):
                                        directoryOutlineRow(directory, depth: depth)
                                    case let .media(item, directory, depth):
                                        directoryMediaRow(item, directory: directory, depth: depth)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    sidebarBlock("照片库", systemImage: "photo.stack") {
                        VStack(spacing: 3) {
                            ForEach(PhotoFilter.allCases) { filter in
                                Button {
                                    library.filter = filter
                                } label: {
                                    HStack {
                                        Label(filter.rawValue, systemImage: filterIcon(filter))
                                        Spacer()
                                        Text(filterCount(filter).formatted())
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .contentShape(Rectangle())
                                    .background(
                                        library.filter == filter
                                            ? Color.accentColor.opacity(0.16)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    if library.allTags.isEmpty == false {
                        sidebarBlock("标签", systemImage: "tag") {
                            VStack(spacing: 3) {
                                ForEach(library.allTags, id: \.self) { tag in
                                    Button {
                                        library.selectTag(library.selectedTag == tag ? nil : tag)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(tag)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Spacer()
                                            Text(library.count(forTag: tag).formatted())
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 8)
                                        .frame(maxWidth: .infinity, minHeight: 28)
                                        .contentShape(Rectangle())
                                        .background(
                                            library.selectedTag == tag
                                                ? Color.accentColor.opacity(0.16)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity)
                                }
                                if library.selectedTag != nil {
                                    Button("清除标签筛选") { library.selectTag(nil) }
                                        .font(.caption)
                                        .buttonStyle(.plain)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                    }

                    sidebarBlock("操作", systemImage: "command") {
                        VStack(spacing: 2) {
                            sidebarActionButton("导出当前筛选", systemImage: "square.and.arrow.up") {
                                exportFilteredOriginals()
                            }
                            .disabled(library.filteredPhotos.isEmpty || isWorking)

                            sidebarActionButton("同步我喜欢到安卓手机", systemImage: "iphone.and.arrow.forward") {
                                showPhoneSyncConfirmation = true
                            }
                            .disabled(library.selectedCount == 0 || isWorking)

                            Button(role: .destructive) {
                                requestTrashSelectedItems()
                            } label: {
                                sidebarMenuLabel("将我喜欢移入废纸篓", systemImage: "trash")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .disabled(library.selectedCount == 0 || isWorking)
                        }
                    }

                    if library.isDetecting || library.isIndexingMetadata {
                        sidebarBlock("后台任务", systemImage: "waveform.path.ecg") {
                            VStack(alignment: .leading, spacing: 8) {
                                if library.isDetecting {
                                    ProgressView(
                                        value: Double(library.detectedCount),
                                        total: Double(max(1, library.photos.count))
                                    )
                                    Text("识别实况 \(library.detectedCount)/\(library.photos.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                if library.isIndexingMetadata {
                                    ProgressView(
                                        value: Double(library.indexedMetadataCount),
                                        total: Double(max(1, library.metadataIndexTotal))
                                    )
                                    Text("读取元信息 \(library.indexedMetadataCount)/\(library.metadataIndexTotal)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            authorSignature
        }
        .padding(10)
        .background(Color.clear)
    }

    private var visibleDirectoryEntries: [DirectoryOutlineEntry] {
        guard let root = library.directories.first(where: { $0.parentPath == nil }) else { return [] }
        var entries: [DirectoryOutlineEntry] = []

        func append(_ directory: PhotoDirectory, depth: Int) {
            entries.append(.directory(directory, depth: depth))
            guard expandedDirectoryPaths.contains(directory.id) else { return }
            for child in library.childDirectories(of: directory) {
                append(child, depth: depth + 1)
            }
            for item in library.directPhotos(in: directory) {
                entries.append(.media(item, directory: directory, depth: depth + 1))
            }
        }

        append(root, depth: 0)
        return entries
    }

    private func directoryOutlineRow(_ directory: PhotoDirectory, depth: Int) -> some View {
        let hasExpandableContent = library.hasChildDirectories(directory)
            || library.directPhotoCount(in: directory) > 0
        let isExpanded = expandedDirectoryPaths.contains(directory.id)
        let isSelected = library.browsingFolder?.standardizedFileURL.path == directory.id
        let directCount = library.directPhotoCount(in: directory)
        let totalCount = library.descendantPhotoCount(in: directory)

        return HStack(spacing: 3) {
            Button {
                guard hasExpandableContent else { return }
                withAnimation(.easeInOut(duration: 0.14)) {
                    if isExpanded {
                        expandedDirectoryPaths.remove(directory.id)
                    } else {
                        expandedDirectoryPaths.insert(directory.id)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasExpandableContent ? 0.72 : 0)
                    .frame(width: 15, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hasExpandableContent == false)

            Button {
                guard !isWorking else { return }
                resetViewerContext()
                library.selectBrowsingFolder(directory.url)
                if hasExpandableContent {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        expandedDirectoryPaths = expandedDirectoryPaths.union([directory.id])
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(directory.name.isEmpty ? directory.url.path : directory.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(totalCount.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(
                totalCount == directCount
                    ? "\(directory.url.path)\n共 \(totalCount) 个媒体文件"
                    : "\(directory.url.path)\n共 \(totalCount) 个媒体文件，其中本层 \(directCount) 个"
            )
        }
        .padding(.leading, min(CGFloat(depth) * 12, 72))
    }

    private func directoryMediaRow(
        _ item: PhotoItem,
        directory: PhotoDirectory,
        depth: Int
    ) -> some View {
        let isFocused = focusedGalleryItemID == item.id

        return Button {
            focusDirectoryMedia(item, in: directory)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.mediaKind == .video ? "play.rectangle" : "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
            .background(
                isFocused ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.leading, min(CGFloat(depth) * 12 + 18, 90))
        .help(item.url.path)
        .accessibilityLabel("媒体文件 \(item.fileName)")
        .accessibilityIdentifier("resource.media.\(item.id)")
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconImageProvider.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Text(AppIdentity.englishName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("当前目录", systemImage: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if library.currentFolder != nil {
                    Button {
                        resetViewerContext()
                        library.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(library.isLoading || isWorking)
                    .help("重新扫描当前目录")
                }
            }
            Text(library.currentFolder?.path ?? "尚未选择")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Button {
                resetViewerContext()
                library.chooseAndOpenFolder()
            } label: {
                Label(library.currentFolder == nil ? "打开照片文件夹" : "切换文件夹", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.040),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }

    private func sidebarBlock<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.032),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
    }

    private func sidebarMenuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 0)
        }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Color.clear)
            .contentShape(Rectangle())
    }

    private func sidebarActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            sidebarMenuLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
        VStack(spacing: 12) {
            libraryHeader
            Group {
                if library.filteredPhotos.isEmpty {
                    emptyState(
                        title: library.photoCount == 0 ? "这个目录没有照片" : "没有符合条件的照片",
                        systemImage: "photo.on.rectangle.angled",
                        description: emptyLibraryDescription
                    ) { EmptyView() }
                } else {
                    PhotoGridView(
                        photos: library.filteredPhotos,
                        thumbnailSize: galleryThumbnailSize,
                        thumbnailSizeRange: galleryThumbnailSizeRange,
                        scrollTargetID: galleryScrollTargetID,
                        scrollTargetToken: galleryScrollTargetToken,
                        scrollToTopToken: galleryScrollToTopToken,
                        focusedItemID: focusedGalleryItemID,
                        groupByTime: groupPhotosByTime,
                        onThumbnailSizeChange: setGalleryThumbnailSize,
                        onOpen: openViewer,
                        onToggleSelection: library.toggleSelection,
                        onReveal: library.revealInFinder,
                        onTrash: { requestTrashItems([$0], fallbackViewerItem: nil) },
                        onFocus: { setFocusedGalleryItem($0) },
                        isInteractionDisabled: isWorking,
                        isKeyboardNavigationEnabled: viewerItem == nil && isWorking == false
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.52),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            }
            statusFooter
        }
        .padding(12)
    }

    private var libraryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                libraryTitleArea
                Spacer(minLength: 12)
                libraryMetricBadges
                libraryBrowsePrimaryControls
                libraryBrowseNavigationControls
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    libraryTitleArea
                    Spacer(minLength: 12)
                    libraryMetricBadges
                }
                libraryBalancedBrowseControls
            }

            VStack(alignment: .leading, spacing: 10) {
                libraryTitleArea
                libraryMetricBadges
                libraryBalancedBrowseControls
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 14)
        .motionGlassSurface(
            cornerRadius: 16,
            shadowOpacity: 0.075,
            shadowRadius: 13,
            shadowY: 5
        )
    }

    private var libraryTitleArea: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("照片库")
                    .font(.system(size: 24, weight: .bold))
                Text(library.browsingFolder?.path ?? "选择一个照片目录开始")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 300, alignment: .leading)

            if library.isDetecting {
                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(library.detectedCount),
                        total: Double(max(1, library.photos.count))
                    )
                    .frame(width: 72)
                    Text("\(library.detectedCount)/\(library.photos.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
            }

            if library.isIndexingMetadata {
                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(library.indexedMetadataCount),
                        total: Double(max(1, library.metadataIndexTotal))
                    )
                    .frame(width: 72)
                    Text("元信息 \(library.indexedMetadataCount)/\(library.metadataIndexTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10), in: Capsule())
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var libraryMetricBadges: some View {
        MotionGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                metricBadge("全部", value: library.photoCount, systemImage: "photo.stack")
                metricBadge("实况", value: library.liveCount, systemImage: "livephoto")
                if library.videoCount > 0 {
                    metricBadge("视频", value: library.videoCount, systemImage: "play.rectangle")
                }
                metricBadge("喜欢", value: library.selectedCount, systemImage: "heart.fill")
                metricBadge("标签", value: library.taggedCount, systemImage: "tag")
                if let selectedTag = library.selectedTag {
                    TagBadgeView(tag: selectedTag, count: library.count(forTag: selectedTag), isActive: true)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var libraryBalancedBrowseControls: some View {
        HStack(spacing: 10) {
            libraryBrowsePrimaryControls
            Spacer(minLength: 12)
            libraryBrowseNavigationControls
        }
        .frame(maxWidth: .infinity)
    }

    private var libraryBrowsePrimaryControls: some View {
        HStack(spacing: 6) {
            sortMenu
            thumbnailSizeControl
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var libraryBrowseNavigationControls: some View {
        MotionGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                if previousGalleryItemID != nil {
                    Button {
                        returnToPreviousGalleryItem()
                    } label: {
                        Label("上次", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .help(previousGalleryItemName.map { "返回上次查看的照片：\($0)" } ?? "返回上次查看的照片")
                }
                if focusedGalleryItemID != nil {
                    Button {
                        returnToFocusedGalleryItem()
                    } label: {
                        Label("当前", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .help(
                        focusedGalleryItemName.map {
                            "当前照片是最近单击或打开的照片；定位到：\($0)"
                        } ?? "定位到最近单击或打开的照片"
                    )
                }
                Button {
                    galleryScrollToTopToken &+= 1
                } label: {
                    Label("顶部", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.bordered)
                .help("回到照片库顶部")
            }
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
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
        .padding(.horizontal, 12)
        .frame(height: 27)
        .motionGlassSurface(
            cornerRadius: 10,
            shadowOpacity: 0.045,
            shadowRadius: 7,
            shadowY: 2
        )
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

    private var emptyLibraryDescription: String {
        if library.isDetecting && library.filter == .live {
            return "实况照片仍在后台识别，请稍候。"
        }
        if library.photoCount == 0, let folder = library.browsingFolder {
            if library.includeSubfolders == false,
               library.directories.contains(where: { $0.parentPath == folder.standardizedFileURL.path }) {
                return "“\(folder.lastPathComponent)”本层没有照片。可在左侧选择子目录，或勾选“包含所选目录的子目录”。"
            }
            return "“\(folder.lastPathComponent)”中没有可支持的照片或视频，请在左侧选择其他目录。"
        }
        return "请调整筛选、标签或搜索条件。"
    }

    private var pageBackground: some View {
        Color.clear
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value.formatted())
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Color.primary.opacity(0.045),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
        }
    }

    private var thumbnailSizeControl: some View {
        HStack(spacing: 8) {
            galleryZoomButton(
                systemImage: "minus.magnifyingglass",
                accessibilityLabel: "缩小照片",
                direction: -1
            )
            Slider(
                value: Binding(
                    get: { galleryZoomPosition },
                    set: { setGalleryThumbnailSize(thumbnailSize(forZoomPosition: $0)) }
                ),
                in: 0...1
            )
            .frame(width: 118)
            galleryZoomButton(
                systemImage: "plus.magnifyingglass",
                accessibilityLabel: "放大照片",
                direction: 1
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Color.primary.opacity(0.040),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
        }
        .help("调整照片墙大小；最大档进入单图画廊，触控板也可以捏合缩放")
    }

    private func galleryZoomButton(
        systemImage: String,
        accessibilityLabel: String,
        direction: Int
    ) -> some View {
        Button {
            stepGalleryZoom(direction: direction)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .disabled(canStepGalleryZoom(direction: direction) == false)
        .accessibilityLabel(accessibilityLabel)
        .help(direction < 0 ? "缩小一级" : "放大一级")
    }

    private var galleryZoomPosition: Double {
        let lower = Double(galleryThumbnailSizeRange.lowerBound)
        let upper = Double(galleryThumbnailSizeRange.upperBound)
        let current = Double(min(upper, max(lower, galleryThumbnailSize)))
        return log(current / lower) / log(upper / lower)
    }

    private func thumbnailSize(forZoomPosition position: Double) -> CGFloat {
        let lower = Double(galleryThumbnailSizeRange.lowerBound)
        let upper = Double(galleryThumbnailSizeRange.upperBound)
        let clampedPosition = min(1, max(0, position))
        return CGFloat(lower * pow(upper / lower, clampedPosition))
    }

    private func canStepGalleryZoom(direction: Int) -> Bool {
        let tolerance: CGFloat = 0.5
        if direction < 0 {
            return galleryThumbnailSize > galleryThumbnailSizeRange.lowerBound + tolerance
        }
        return galleryThumbnailSize < galleryThumbnailSizeRange.upperBound - tolerance
    }

    private func stepGalleryZoom(direction: Int) {
        let tolerance: CGFloat = 0.5
        let target: CGFloat?
        if direction < 0 {
            target = galleryZoomStops.last { $0 < galleryThumbnailSize - tolerance }
        } else {
            target = galleryZoomStops.first { $0 > galleryThumbnailSize + tolerance }
        }

        guard let target else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            setGalleryThumbnailSize(target)
        }
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.040), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
                }
        }
        .menuStyle(.borderlessButton)
        .help("选择照片库排序方式")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    isSidebarVisible.toggle()
                }
            } label: {
                Label(
                    isSidebarVisible ? "隐藏边栏" : "显示边栏",
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut("b", modifiers: .command)
            .help(isSidebarVisible ? "隐藏边栏（⌘B）" : "显示边栏（⌘B）")
            .accessibilityIdentifier("workspace.sidebar.toggle")

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
                Label("将我喜欢移入废纸篓", systemImage: "trash")
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
        case .selected: return "heart.fill"
        }
    }

    private func filterCount(_ filter: PhotoFilter) -> Int {
        switch filter {
        case .all: return library.photoCount
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
        viewerItem = nil
        DispatchQueue.main.async {
            requestGalleryScroll(to: item.id)
        }
    }

    private func focusDirectoryMedia(_ item: PhotoItem, in directory: PhotoDirectory) {
        guard !isWorking else { return }

        viewerItem = nil
        library.filter = .all
        library.selectTag(nil)
        library.searchText = ""
        library.selectBrowsingFolder(directory.url)
        setFocusedGalleryItem(item)

        DispatchQueue.main.async {
            guard library.filteredPhotos.contains(where: { $0.id == item.id }) else {
                library.setStatus("无法在当前目录中定位：\(item.fileName)")
                return
            }
            requestGalleryScroll(to: item.id)
        }
    }

    private func setFocusedGalleryItem(_ item: PhotoItem?) {
        guard let item else {
            focusedGalleryItemID = nil
            focusedGalleryItemName = nil
            return
        }

        guard focusedGalleryItemID != item.id else {
            focusedGalleryItemName = item.fileName
            library.setStatus("当前照片：\(item.fileName)")
            return
        }

        if let focusedGalleryItemID {
            previousGalleryItemID = focusedGalleryItemID
            previousGalleryItemName = focusedGalleryItemName
        }
        focusedGalleryItemID = item.id
        focusedGalleryItemName = item.fileName
        library.setStatus("当前照片：\(item.fileName)")
    }

    private func resetViewerContext() {
        viewerItem = nil
        galleryScrollTargetID = nil
        focusedGalleryItemID = nil
        focusedGalleryItemName = nil
        previousGalleryItemID = nil
        previousGalleryItemName = nil
    }

    private func returnToFocusedGalleryItem() {
        guard let focusedGalleryItemID else { return }
        guard library.filteredPhotos.contains(where: { $0.id == focusedGalleryItemID }) else {
            library.setStatus("当前查看的照片不在筛选结果中，请先调整筛选或搜索")
            return
        }

        requestGalleryScroll(to: focusedGalleryItemID)
        library.setStatus("已定位当前照片：\(focusedGalleryItemName ?? "未知照片")")
    }

    private func returnToPreviousGalleryItem() {
        guard let previousGalleryItemID else { return }
        guard let target = library.filteredPhotos.first(where: { $0.id == previousGalleryItemID }) else {
            library.setStatus("上次查看的照片不在筛选结果中，请先调整筛选或搜索")
            return
        }

        let currentID = focusedGalleryItemID
        let currentName = focusedGalleryItemName
        focusedGalleryItemID = target.id
        focusedGalleryItemName = target.fileName
        self.previousGalleryItemID = currentID
        previousGalleryItemName = currentName

        requestGalleryScroll(to: target.id)
        library.setStatus("已返回上次查看：\(target.fileName)")
    }

    private func requestGalleryScroll(to itemID: String) {
        galleryScrollTargetID = itemID
        galleryScrollTargetToken &+= 1
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
            title = "将“我喜欢”中的 \(items.count) 张照片移入废纸篓？"
            confirmationTitle = "移入废纸篓 \(items.count) 张"
            message = """
            将移动 \(items.count) 张照片及其配套视频，共 \(resourceCount) 个原始文件。

            文件会优先进入 macOS 废纸篓；如果外接硬盘不支持废纸篓，会改为移入同目录下隐藏的 .MotionAlbumTrash 安全删除区。灵动相册会同时清理这些照片的喜欢状态、标签和封面帧记录。
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
                        self.requestGalleryScroll(to: fallback.id)
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
        let sourceURLs = uniqueResourceURLs(from: library.selectedPhotos)
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
            requestGalleryScroll(to: target.id)
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
