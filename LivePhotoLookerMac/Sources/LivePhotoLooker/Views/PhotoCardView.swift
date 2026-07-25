import AppKit
import SwiftUI

struct PhotoCardView: View {
    @ObservedObject var item: PhotoItem
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void
    let thumbnailSize: CGFloat
    let isFocused: Bool
    let isInteractionDisabled: Bool

    @State private var thumbnail: NSImage?
    @State private var isHovering = false
    @State private var didFailThumbnail = false

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetails ? 9 : 0) {
            thumbnailLayer

            if showsDetails {
                detailLayer
            }
        }
        .frame(width: thumbnailSize)
        .padding(showsDetails ? 9 : 0)
        .background { cardBackground }
        .overlay {
            cardBorder
        }
        .shadow(
            color: .black.opacity(showsDetails ? (isHovering ? 0.11 : 0.055) : 0.035),
            radius: showsDetails ? (isHovering ? 14 : 8) : 3,
            x: 0,
            y: showsDetails ? (isHovering ? 7 : 3) : 1
        )
        .scaleEffect(isHovering && showsDetails ? 1.012 : 1)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .onTapGesture(count: 2) {
            guard !isInteractionDisabled else { return }
            onOpen()
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .animation(.easeInOut(duration: 0.16), value: item.isSelected)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
        .contextMenu {
            Button("查看") { onOpen() }
                .disabled(isInteractionDisabled)
            Button(item.isSelected ? "取消精选" : "加入精选") { onToggleSelection() }
                .disabled(isInteractionDisabled)
            if item.tags.isEmpty == false {
                Divider()
                Text("标签：\(item.tags.joined(separator: "、"))")
            }
            Divider()
            Button("在访达中显示") { onReveal() }
                .disabled(isInteractionDisabled)
            Button("移入废纸篓", role: .destructive) { onTrash() }
                .disabled(isInteractionDisabled)
        }
        .task(id: "\(item.cacheKey)-\(thumbnailCacheBucket)") {
            didFailThumbnail = false
            let loaded = await ImageService.shared.image(
                url: item.url,
                cacheKey: "\(item.cacheKey)-\(item.mediaKind.rawValue)-\(thumbnailCacheBucket)",
                maxPixelSize: thumbnailPixelSize,
                isVideo: item.mediaKind == .video
            )
            guard !Task.isCancelled else { return }
            thumbnail = loaded
            didFailThumbnail = loaded == nil
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var thumbnailLayer: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: thumbnailSize, height: imageHeight)
                } else if didFailThumbnail {
                    placeholder
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: thumbnailSize, height: imageHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous))

            if isFocused {
                focusedBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(showsDetails ? 8 : 5)
            }

            Button(action: onToggleSelection) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: selectionIconSize, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        item.isSelected ? Color.white : Color.white.opacity(0.9),
                        item.isSelected ? Color.accentColor : Color.black.opacity(0.35)
                    )
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)
            .padding(showsDetails ? 8 : 5)
            .help(item.isSelected ? "取消精选" : "加入精选")

            mediaBadge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(showsDetails ? 8 : 5)

            if showsDetails == false, item.tags.isEmpty == false {
                compactTagIndicator
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
    }

    private var detailLayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(item.fileName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if item.mediaKind == .image && item.liveStatus == .unknown {
                    ProgressView()
                        .controlSize(.mini)
                } else if item.mediaKind == .video {
                    Image(systemName: "play.rectangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if item.tags.isEmpty == false {
                HStack(spacing: 4) {
                    ForEach(Array(item.tags.prefix(2)), id: \.self) { tag in
                        TagBadgeView(tag: tag)
                    }
                    if item.tags.count > 2 {
                        Text("+\(item.tags.count - 2)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if showsDetails {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(
                    isFocused
                        ? Color.accentColor.opacity(0.08)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.86)
                )
        } else {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.02))
        }
    }

    private var cardBorder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(
                    item.isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.12 : 0.07),
                    lineWidth: item.isSelected ? (showsDetails ? 2.5 : 2) : 1
                )

            if isFocused {
                RoundedRectangle(cornerRadius: cardCornerRadius + 2, style: .continuous)
                    .stroke(Color.orange.opacity(0.96), lineWidth: showsDetails ? 4 : 3)
                    .padding(showsDetails ? -4 : -3)

                RoundedRectangle(cornerRadius: cardCornerRadius + 3, style: .continuous)
                    .stroke(Color.white.opacity(0.75), lineWidth: 1)
                    .padding(showsDetails ? -7 : -5)
            }
        }
    }

    @ViewBuilder
    private var mediaBadge: some View {
        if item.liveStatus == .live {
            if showsDetails {
                Label("LIVE", systemImage: "livephoto")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.68), in: Capsule())
            } else {
                Image(systemName: "livephoto")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.48), in: Circle())
            }
        } else if item.mediaKind == .video {
            if showsDetails {
                Label("VIDEO", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.68), in: Capsule())
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.48), in: Circle())
            }
        }
    }

    private var focusedBadge: some View {
        HStack(spacing: showsDetails ? 4 : 0) {
            Image(systemName: "eye.fill")
            if showsDetails {
                Text("刚刚查看")
            }
        }
        .font(.system(size: showsDetails ? 10 : 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, showsDetails ? 7 : 5)
        .padding(.vertical, showsDetails ? 4 : 5)
        .background(Color.orange.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
    }

    private var compactTagIndicator: some View {
        HStack(spacing: 3) {
            Image(systemName: "tag.fill")
            Text(item.tags.count.formatted())
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.48), in: Capsule())
    }

    private var placeholder: some View {
        VStack(spacing: showsDetails ? 8 : 4) {
            Image(systemName: item.mediaKind == .video ? "play.rectangle" : "photo")
                .font(.system(size: showsDetails ? 26 : 20))
            if showsDetails {
                Text(item.mediaKind == .video ? "视频" : "无法预览")
                    .font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var showsDetails: Bool {
        thumbnailSize >= 150
    }

    private var imageHeight: CGFloat {
        showsDetails ? min(178, max(122, thumbnailSize * 0.72)) : thumbnailSize
    }

    private var cardCornerRadius: CGFloat {
        showsDetails ? 16 : 6
    }

    private var imageCornerRadius: CGFloat {
        showsDetails ? 12 : 5
    }

    private var selectionIconSize: CGFloat {
        showsDetails ? 23 : max(17, min(22, thumbnailSize * 0.18))
    }

    private var thumbnailCacheBucket: Int {
        max(96, Int((thumbnailSize / 24).rounded()) * 24)
    }

    private var thumbnailPixelSize: Int {
        max(220, min(760, Int((thumbnailSize * 3).rounded(.up))))
    }

    private var accessibilityLabel: String {
        if item.liveStatus == .live {
            return "\(item.fileName)，实况照片"
        }
        if item.mediaKind == .video {
            return "\(item.fileName)，视频"
        }
        return item.fileName
    }
}
