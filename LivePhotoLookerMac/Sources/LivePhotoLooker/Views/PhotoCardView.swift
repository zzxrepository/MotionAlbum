import AppKit
import SwiftUI

struct PhotoCardView: View {
    @ObservedObject var item: PhotoItem
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onReveal: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 164)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(action: onToggleSelection) {
                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 23, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            item.isSelected ? Color.white : Color.white.opacity(0.9),
                            item.isSelected ? Color.accentColor : Color.black.opacity(0.35)
                        )
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(item.isSelected ? "取消精选" : "加入精选")

                if item.liveStatus == .live {
                    Label("LIVE", systemImage: "livephoto")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.68), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(item.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if item.liveStatus == .unknown {
                        ProgressView()
                            .controlSize(.mini)
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
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    item.isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.12 : 0.07),
                    lineWidth: item.isSelected ? 2.5 : 1
                )
        }
        .shadow(
            color: .black.opacity(isHovering ? 0.11 : 0.055),
            radius: isHovering ? 14 : 8,
            x: 0,
            y: isHovering ? 7 : 3
        )
        .scaleEffect(isHovering ? 1.012 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(count: 2, perform: onOpen)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .animation(.easeInOut(duration: 0.16), value: item.isSelected)
        .contextMenu {
            Button("查看") { onOpen() }
            Button(item.isSelected ? "取消精选" : "加入精选") { onToggleSelection() }
            if item.tags.isEmpty == false {
                Divider()
                Text("标签：\(item.tags.joined(separator: "、"))")
            }
            Divider()
            Button("在访达中显示") { onReveal() }
        }
        .task(id: item.cacheKey) {
            let loaded = await ImageService.shared.image(
                url: item.url,
                cacheKey: "\(item.cacheKey)-420",
                maxPixelSize: 420
            )
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
        .accessibilityLabel("\(item.fileName)\(item.liveStatus == .live ? "，实况照片" : "")")
    }
}
