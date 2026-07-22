import AppKit
import SwiftUI

private struct UserFacingAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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
        .onReceive(NotificationCenter.default.publisher(for: .openPhotoFolder)) { _ in
            viewerItem = nil
            library.chooseAndOpenFolder()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandHeader
            folderSummaryCard

            Button {
                viewerItem = nil
                library.chooseAndOpenFolder()
            } label: {
                Label("打开文件夹", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Menu {
                recentFolderMenuItems
            } label: {
                Label("打开历史目录", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Toggle("包含子文件夹", isOn: Binding(
                get: { library.includeSubfolders },
                set: { value in
                    library.includeSubfolders = value
                    if library.currentFolder != nil {
                        viewerItem = nil
                        library.reload()
                    }
                }
            ))
            .disabled(library.isLoading)

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
        }
        .padding(14)
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
        } else if let viewerItem, library.currentFolder != nil {
            viewer(for: viewerItem)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
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
                        onOpen: { viewerItem = $0 },
                        onToggleSelection: library.toggleSelection,
                        onReveal: library.revealInFinder
                    )
                }
                Divider()
                statusFooter
            }
            .background(pageBackground)
            .animation(.easeInOut(duration: 0.18), value: viewerItem?.id)
            .animation(.easeInOut(duration: 0.18), value: library.filter)
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
            }

            HStack(spacing: 8) {
                metricBadge("全部", value: library.photos.count, systemImage: "photo.stack")
                metricBadge("实况", value: library.liveCount, systemImage: "livephoto")
                metricBadge("精选", value: library.selectedCount, systemImage: "checkmark.circle")
                metricBadge("标签", value: library.taggedCount, systemImage: "tag")
                if let selectedTag = library.selectedTag {
                    TagBadgeView(tag: selectedTag, count: library.count(forTag: selectedTag), isActive: true)
                }
                Spacer()
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
            if isWorking { ProgressView().controlSize(.small) }
            Text(library.statusMessage)
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                viewerItem = nil
                library.chooseAndOpenFolder()
            } label: {
                Label("打开", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu {
                recentFolderMenuItems
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }

            Button {
                viewerItem = nil
                library.reload()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(library.currentFolder == nil || library.isLoading)

            TextField("搜索文件名或标签", text: $library.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, idealWidth: 240)

            Button {
                exportFilteredOriginals()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(library.filteredPhotos.isEmpty || isWorking)
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
            onClose: { viewerItem = nil },
            onToggleSelection: { library.toggleSelection(item) },
            onAddTag: { library.addTag($0, to: item) },
            onRemoveTag: { library.removeTag($0, from: item) },
            onSetHoldFrame: { library.setHoldFrameTime($0, for: item) }
        )
        .id(item.id)
    }

    private func filterIcon(_ filter: PhotoFilter) -> String {
        switch filter {
        case .all: return "photo.stack"
        case .live: return "livephoto"
        case .selected: return "checkmark.circle"
        }
    }

    private func filterCount(_ filter: PhotoFilter) -> Int {
        switch filter {
        case .all: return library.photos.count
        case .live: return library.liveCount
        case .selected: return library.selectedCount
        }
    }

    private func exportFilteredOriginals() {
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
            viewerItem = target
        }
    }

    private func openRecentFolder(_ folder: RecentFolderEntry) {
        viewerItem = nil
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
