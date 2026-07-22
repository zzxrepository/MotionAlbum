import AVKit
import AppKit
import SwiftUI

struct ViewerView: View {
    @ObservedObject var item: PhotoItem
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    let onToggleSelection: () -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void
    let onSetHoldFrame: (Double?) -> Void

    @State private var previewImage: NSImage?
    @State private var originalPreviewImage: NSImage?
    @State private var player: AVPlayer?
    @State private var preparedVideoURL: URL?
    @State private var isPreparingVideo = false
    @State private var errorMessage: String?
    @State private var showingVideo = false
    @State private var videoTask: Task<Void, Never>?
    @State private var didAutoPlayVideo = false
    @State private var tagInput = ""
    @State private var placeTask: Task<Void, Never>?
    @State private var isEditingCoverFrame = false
    @State private var coverFrameTask: Task<Void, Never>?
    @State private var coverFrames: [CoverFrameCandidate] = []
    @State private var selectedCoverFrameIndex = 0
    @State private var isPreparingCoverFrames = false
    @State private var coverPreviewImage: NSImage?
    @State private var isPreparingCoverPreview = false
    @State private var coverPreviewTask: Task<Void, Never>?
    @State private var coverFrameErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            mediaStage
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.cacheKey) {
            resetVideoForNewItem()
            resetCoverFrameEditor()
            placeTask?.cancel()
            previewImage = nil
            originalPreviewImage = nil
            errorMessage = nil
            tagInput = ""
            resolvePlaceNameIfNeeded()
            autoPlayIfNeeded()
            let loaded = await ImageService.shared.image(
                url: item.url,
                cacheKey: "\(item.cacheKey)-2800",
                maxPixelSize: 2800
            )
            guard !Task.isCancelled else { return }
            previewImage = loaded
            originalPreviewImage = loaded
            autoPlayIfNeeded()
        }
        .onReceive(item.$liveStatus) { status in
            if status == .live {
                autoPlayIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem == player?.currentItem else { return }
            finishVideoPlayback()
        }
        .onDisappear {
            videoTask?.cancel()
            videoTask = nil
            placeTask?.cancel()
            placeTask = nil
            coverFrameTask?.cancel()
            coverFrameTask = nil
            coverPreviewTask?.cancel()
            coverPreviewTask = nil
            stopVideo()
        }
        .alert("无法播放实况", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var mediaStage: some View {
        ZStack {
            Color.black.opacity(0.94)

            if isEditingCoverFrame {
                coverFrameEditor
            } else {
                GeometryReader { proxy in
                    ZStack {
                        if showingVideo, let player {
                            NativePlayerView(player: player)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .onAppear { player.play() }
                        } else if let previewImage {
                            Image(nsImage: previewImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else {
                            ProgressView("正在读取图片…")
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }

            if isPreparingVideo {
                ProgressView("正在准备实况…")
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var coverFrameEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("选择封面帧", systemImage: "film")
                    .font(.headline)
                    .foregroundStyle(.white)

                if let selectedFrame = selectedCoverFrame {
                    Text(formatSeconds(selectedFrame.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Button("取消") {
                    closeCoverFrameEditor()
                }
                .disabled(isPreparingCoverFrames)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.12), in: Capsule())

                Button {
                    applySelectedCoverFrame()
                } label: {
                    Label("设为封面", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCoverFrame == nil || isPreparingCoverFrames)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ZStack {
                Color.black
                if let selectedFrame = selectedCoverFrame {
                    Image(nsImage: coverPreviewImage ?? selectedFrame.thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                    if isPreparingCoverPreview {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在加载高清帧…")
                                .font(.caption)
                        }
                        .padding(12)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    }
                } else if isPreparingCoverFrames {
                    ProgressView("正在生成可选帧…")
                        .foregroundStyle(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                        Text(coverFrameErrorMessage ?? "没有生成可用的封面帧")
                    }
                    .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("左右滑动缩略条，点击一帧后设为封面")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    if item.holdFrameTime != nil {
                        Button {
                            clearHoldFrame()
                            closeCoverFrameEditor()
                        } label: {
                            Label("恢复原封面", systemImage: "arrow.uturn.backward.circle")
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(coverFrames.enumerated()), id: \.element.id) { index, frame in
                            Button {
                                selectCoverFrame(at: index)
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    Image(nsImage: frame.thumbnailImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 96, height: 58)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    Text(formatSeconds(frame.seconds))
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .foregroundStyle(.white)
                                        .background(.black.opacity(0.58), in: Capsule())
                                        .padding(5)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(
                                            index == selectedCoverFrameIndex ? Color.accentColor : Color.white.opacity(0.14),
                                            lineWidth: index == selectedCoverFrameIndex ? 3 : 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.84))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                if item.liveStatus == .live {
                    Label("实况照片", systemImage: "livephoto")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            metadataLine

            if item.liveStatus == .live {
                liveFrameControls
            }

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if item.tags.isEmpty {
                            Text("暂无标签")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(item.tags, id: \.self) { tag in
                                RemovableTagBadgeView(tag: tag) {
                                    onRemoveTag(tag)
                                }
                            }
                        }
                    }
                }

                TextField("添加标签", text: $tagInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(addCurrentTag)

                Button(action: addCurrentTag) {
                    Label("添加", systemImage: "plus")
                }
                .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var metadataLine: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let deviceText = item.metadata.deviceText {
                    metadataChip(deviceText, systemImage: "camera")
                }
                if let capturedAt = item.metadata.capturedAt {
                    metadataChip(capturedAt, systemImage: "calendar")
                }
                if let sizeText = item.metadata.sizeText {
                    metadataChip(sizeText, systemImage: "rectangle")
                }
                if let placeName = item.placeName {
                    metadataChip(placeName, systemImage: "mappin.and.ellipse")
                } else if item.isResolvingPlaceName {
                    metadataChip("正在解析地点…", systemImage: "location")
                }
                if item.metadata.deviceText == nil,
                   item.metadata.capturedAt == nil,
                   item.placeName == nil,
                   item.isResolvingPlaceName == false,
                   item.metadata.sizeText == nil {
                    Text("没有可展示的 EXIF 元信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var liveFrameControls: some View {
        HStack(spacing: 8) {
            Label(
                item.holdFrameTime.map { "停留帧 \(formatSeconds($0))" } ?? "播放结束后回到封面",
                systemImage: item.holdFrameTime == nil ? "photo" : "pin"
            )
            .foregroundStyle(.secondary)

            Button {
                openCoverFrameEditor()
            } label: {
                Label("编辑封面帧", systemImage: "rectangle.on.rectangle")
            }
            .disabled(isPreparingVideo || isPreparingCoverFrames)

            if item.holdFrameTime != nil {
                Button {
                    clearHoldFrame()
                } label: {
                    Label("恢复原封面", systemImage: "arrow.uturn.backward.circle")
                }
            }
        }
        .font(.caption)
    }

    private func metadataChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: Capsule())
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onPrevious) {
                Label("上一张", systemImage: "chevron.left")
            }
            .disabled(!canGoPrevious)

            Button(action: onNext) {
                Label("下一张", systemImage: "chevron.right")
            }
            .disabled(!canGoNext)

            Divider().frame(height: 20)

            Button(action: toggleVideo) {
                Label(showingVideo ? "显示照片" : "播放实况", systemImage: showingVideo ? "photo" : "play.fill")
            }
            .disabled(item.liveStatus != .live || isPreparingVideo)

            Button(action: onToggleSelection) {
                Label(item.isSelected ? "取消精选" : "加入精选", systemImage: item.isSelected ? "checkmark.circle.fill" : "circle")
            }

            Spacer()
            Button("返回图库") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.ultraThinMaterial)
    }

    private func toggleVideo() {
        if showingVideo {
            showOriginalPhoto()
            return
        }
        playVideo()
    }

    private func addCurrentTag() {
        onAddTag(tagInput)
        tagInput = ""
    }

    private var selectedCoverFrame: CoverFrameCandidate? {
        guard coverFrames.indices.contains(selectedCoverFrameIndex) else { return nil }
        return coverFrames[selectedCoverFrameIndex]
    }

    private func resolvePlaceNameIfNeeded() {
        guard let latitude = item.metadata.latitude,
              let longitude = item.metadata.longitude,
              item.placeName == nil,
              item.isResolvingPlaceName == false else { return }

        item.isResolvingPlaceName = true
        placeTask?.cancel()
        placeTask = Task { @MainActor in
            let placeName = await PlaceNameResolver.shared.resolve(latitude: latitude, longitude: longitude)
            if Task.isCancelled == false {
                item.placeName = placeName
            }
            item.isResolvingPlaceName = false
        }
    }

    private func autoPlayIfNeeded() {
        guard item.liveStatus == .live, didAutoPlayVideo == false else { return }
        didAutoPlayVideo = true
        playVideo()
    }

    private func loadPlayableVideoURL() async throws -> URL {
        if let preparedVideoURL {
            return preparedVideoURL
        }

        let sourceURL = item.url
        let companionVideoURL = item.companionVideoURL
        let videoURL = try await Task.detached(priority: .userInitiated) {
            try LivePhotoParser.playableVideoURL(
                for: sourceURL,
                companionVideoURL: companionVideoURL
            )
        }.value
        preparedVideoURL = videoURL
        return videoURL
    }

    private func playVideo() {
        if let player {
            closeCoverFrameEditor()
            showingVideo = true
            player.seek(to: .zero)
            player.play()
            return
        }

        guard isPreparingVideo == false else { return }
        isPreparingVideo = true
        let sourceURL = item.url
        videoTask?.cancel()
        videoTask = Task {
            do {
                let videoURL = try await loadPlayableVideoURL()
                try Task.checkCancellation()
                let newPlayer = AVPlayer(url: videoURL)
                player = newPlayer
                closeCoverFrameEditor()
                showingVideo = true
                newPlayer.play()
            } catch is CancellationError {
                // 关闭查看器时无需提示。
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.error("播放实况失败：\(sourceURL.path)", error: error)
            }
            isPreparingVideo = false
            videoTask = nil
        }
    }

    private func resetVideoForNewItem() {
        videoTask?.cancel()
        videoTask = nil
        player?.pause()
        player = nil
        preparedVideoURL = nil
        showingVideo = false
        didAutoPlayVideo = false
        isPreparingVideo = false
    }

    private func resetCoverFrameEditor() {
        coverFrameTask?.cancel()
        coverFrameTask = nil
        coverPreviewTask?.cancel()
        coverPreviewTask = nil
        isEditingCoverFrame = false
        coverFrames = []
        selectedCoverFrameIndex = 0
        isPreparingCoverFrames = false
        coverPreviewImage = nil
        isPreparingCoverPreview = false
        coverFrameErrorMessage = nil
    }

    private func stopVideo() {
        player?.pause()
        showingVideo = false
    }

    private func showOriginalPhoto() {
        player?.pause()
        if let originalPreviewImage {
            previewImage = originalPreviewImage
        }
        showingVideo = false
    }

    private func finishVideoPlayback() {
        player?.pause()
        showingVideo = false
        if let holdFrameTime = item.holdFrameTime {
            showFrame(at: holdFrameTime)
        } else {
            if let originalPreviewImage {
                previewImage = originalPreviewImage
            }
            player?.seek(to: .zero)
        }
    }

    private func setHoldFrameAtCurrentTime() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        onSetHoldFrame(seconds)
        player.pause()
        showingVideo = false
        showFrame(at: seconds)
    }

    private func openCoverFrameEditor() {
        guard isPreparingCoverFrames == false else { return }
        stopVideo()
        isEditingCoverFrame = true
        coverFrames = []
        selectedCoverFrameIndex = 0
        coverFrameErrorMessage = nil
        isPreparingCoverFrames = true

        coverFrameTask?.cancel()
        coverFrameTask = Task {
            do {
                let videoURL = try await loadPlayableVideoURL()
                try Task.checkCancellation()
                let frames = try await Task.detached(priority: .userInitiated) {
                    try await VideoFrameExtractor.timeline(from: videoURL)
                }.value
                try Task.checkCancellation()
                coverFrames = frames
                selectedCoverFrameIndex = nearestCoverFrameIndex(to: item.holdFrameTime, in: frames)
                loadCoverPreviewForSelectedFrame()
                if frames.isEmpty {
                    coverFrameErrorMessage = "没有生成可用的封面帧"
                }
            } catch is CancellationError {
                // 用户关闭查看器或切换照片，无需提示。
            } catch {
                coverFrameErrorMessage = error.localizedDescription
                AppLogger.error("生成封面帧失败：\(item.url.path)", error: error)
            }
            isPreparingCoverFrames = false
            coverFrameTask = nil
        }
    }

    private func closeCoverFrameEditor() {
        guard isEditingCoverFrame else { return }
        coverFrameTask?.cancel()
        coverFrameTask = nil
        coverPreviewTask?.cancel()
        coverPreviewTask = nil
        isPreparingCoverFrames = false
        isPreparingCoverPreview = false
        isEditingCoverFrame = false
    }

    private func applySelectedCoverFrame() {
        guard let selectedCoverFrame else { return }
        onSetHoldFrame(selectedCoverFrame.seconds)
        player?.pause()
        showingVideo = false
        previewImage = coverPreviewImage ?? selectedCoverFrame.thumbnailImage
        closeCoverFrameEditor()
    }

    private func clearHoldFrame() {
        onSetHoldFrame(nil)
        if showingVideo == false, let originalPreviewImage {
            previewImage = originalPreviewImage
        }
    }

    private func nearestCoverFrameIndex(to seconds: Double?, in frames: [CoverFrameCandidate]) -> Int {
        guard let seconds, frames.isEmpty == false else { return 0 }
        return frames.indices.min { left, right in
            abs(frames[left].seconds - seconds) < abs(frames[right].seconds - seconds)
        } ?? 0
    }

    private func selectCoverFrame(at index: Int) {
        guard coverFrames.indices.contains(index) else { return }
        selectedCoverFrameIndex = index
        loadCoverPreviewForSelectedFrame()
    }

    private func loadCoverPreviewForSelectedFrame() {
        guard let frame = selectedCoverFrame,
              let preparedVideoURL else { return }

        let seconds = frame.seconds
        coverPreviewTask?.cancel()
        coverPreviewImage = frame.thumbnailImage
        isPreparingCoverPreview = true
        coverPreviewTask = Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try CoverFramePreview(
                        image: VideoFrameExtractor.image(
                            from: preparedVideoURL,
                            seconds: seconds,
                            maximumSize: CGSize(width: 2200, height: 1600)
                        )
                    )
                }.value
                try Task.checkCancellation()
                guard selectedCoverFrame?.seconds == seconds else { return }
                coverPreviewImage = preview.image
            } catch is CancellationError {
                // 用户继续滑动选择帧，旧的高清抽帧任务自然取消。
                return
            } catch {
                AppLogger.warning("生成高清封面预览帧失败：\(preparedVideoURL.path) @ \(seconds)", error: error)
            }
            guard selectedCoverFrame?.seconds == seconds else { return }
            isPreparingCoverPreview = false
            coverPreviewTask = nil
        }
    }

    private func showFrame(at seconds: Double) {
        guard let preparedVideoURL else { return }
        do {
            previewImage = try VideoFrameExtractor.image(from: preparedVideoURL, seconds: seconds)
        } catch {
            AppLogger.warning("生成实况停留帧失败：\(preparedVideoURL.path)", error: error)
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let totalTenths = Int((seconds * 10).rounded())
        return String(format: "%02d:%02d.%d", totalTenths / 600, totalTenths / 10 % 60, totalTenths % 10)
    }
}

private struct CoverFrameCandidate: Identifiable, @unchecked Sendable {
    let id = UUID()
    let seconds: Double
    let thumbnailImage: NSImage
}

private struct CoverFramePreview: @unchecked Sendable {
    let image: NSImage
}

private enum VideoFrameExtractionError: LocalizedError {
    case noUsableFrames

    var errorDescription: String? {
        switch self {
        case .noUsableFrames:
            return "没有从实况视频中生成可用帧"
        }
    }
}

private enum VideoFrameExtractor {
    static func image(
        from url: URL,
        seconds: Double,
        maximumSize: CGSize? = nil
    ) throws -> NSImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maximumSize {
            generator.maximumSize = maximumSize
        }
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        return NSImage(cgImage: cgImage, size: .zero)
    }

    static func timeline(
        from url: URL,
        maximumFrameCount: Int = 18
    ) async throws -> [CoverFrameCandidate] {
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds
        let safeDuration = duration.isFinite && duration > 0 ? duration : 3
        let frameCount = max(6, min(maximumFrameCount, Int((safeDuration * 5).rounded(.up))))
        let lastUsableSecond = max(0, safeDuration - 0.05)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 260, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)

        var frames: [CoverFrameCandidate] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let denominator = max(frameCount - 1, 1)
            let seconds = lastUsableSecond * Double(index) / Double(denominator)
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            var actualTime = CMTime.zero
            do {
                let cgImage = try generator.copyCGImage(at: requestedTime, actualTime: &actualTime)
                let actualSeconds = actualTime.seconds.isFinite ? actualTime.seconds : seconds
                frames.append(CoverFrameCandidate(
                    seconds: max(0, actualSeconds),
                    thumbnailImage: NSImage(cgImage: cgImage, size: .zero)
                ))
            } catch {
                AppLogger.warning("抽取封面候选帧失败：\(url.path) @ \(seconds)", error: error)
            }
        }

        guard frames.isEmpty == false else {
            throw VideoFrameExtractionError.noUsableFrames
        }
        return frames
    }
}

/// 直接包装 AppKit 的 AVPlayerView，避开部分 macOS 版本中 SwiftUI VideoPlayer
/// 在动态插入视图时的运行时元数据崩溃。
private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.controlsStyle = .none
        nsView.videoGravity = .resizeAspect
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
