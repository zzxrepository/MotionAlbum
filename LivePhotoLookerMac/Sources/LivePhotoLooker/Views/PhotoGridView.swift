import Foundation
import SwiftUI

struct PhotoGridView: View {
    let photos: [PhotoItem]
    let thumbnailSize: CGFloat
    let thumbnailSizeRange: ClosedRange<CGFloat>
    let scrollTargetID: String?
    let scrollToTopToken: Int
    let focusedItemID: String?
    let groupByTime: Bool
    let onThumbnailSizeChange: (CGFloat) -> Void
    let onScrollTargetConsumed: () -> Void
    let onOpen: (PhotoItem) -> Void
    let onToggleSelection: (PhotoItem) -> Void
    let onReveal: (PhotoItem) -> Void
    let onTrash: (PhotoItem) -> Void
    let isInteractionDisabled: Bool

    @State private var magnificationBaseSize: CGFloat?
    private static let topID = "MotionAlbum.PhotoGrid.Top"
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    private var timelineGranularity: TimelineGranularity {
        thumbnailSize < 150 ? .month : .day
    }

    private var spacing: CGFloat {
        thumbnailSize < 150 ? 2 : 12
    }

    private var horizontalPadding: CGFloat {
        thumbnailSize < 150 ? 14 : 24
    }

    private var verticalPadding: CGFloat {
        thumbnailSize < 150 ? 12 : 22
    }

    private var tileWidth: CGFloat {
        thumbnailSize + (thumbnailSize >= 150 ? 18 : 0)
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: tileWidth, maximum: tileWidth + 16),
                spacing: spacing,
                alignment: .top
            )
        ]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id(Self.topID)

                if groupByTime {
                    LazyVStack(alignment: .leading, spacing: thumbnailSize < 150 ? 16 : 22) {
                        ForEach(timelineSections) { section in
                            VStack(alignment: .leading, spacing: thumbnailSize < 150 ? 7 : 10) {
                                sectionHeader(section)
                                photoGrid(section.photos)
                            }
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                } else {
                    photoGrid(photos)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                }
            }
            .background(Color.clear)
            .task(id: scrollToTopToken) {
                guard scrollToTopToken != 0 else { return }
                try? await Task.sleep(nanoseconds: 40_000_000)
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
            }
            .task(id: scrollTargetID) {
                guard let scrollTargetID else { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(scrollTargetID, anchor: .center)
                }
                onScrollTargetConsumed()
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let base = magnificationBaseSize ?? thumbnailSize
                    magnificationBaseSize = base
                    onThumbnailSizeChange(clamped(base * value))
                }
                .onEnded { value in
                    let base = magnificationBaseSize ?? thumbnailSize
                    onThumbnailSizeChange(clamped(base * value))
                    magnificationBaseSize = nil
                }
        )
        .animation(.easeInOut(duration: 0.16), value: Int(thumbnailSize))
    }

    private func clamped(_ size: CGFloat) -> CGFloat {
        min(thumbnailSizeRange.upperBound, max(thumbnailSizeRange.lowerBound, size))
    }

    private func photoGrid(_ items: [PhotoItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(items) { item in
                PhotoCardView(
                    item: item,
                    onOpen: { onOpen(item) },
                    onToggleSelection: { onToggleSelection(item) },
                    onReveal: { onReveal(item) },
                    onTrash: { onTrash(item) },
                    thumbnailSize: thumbnailSize,
                    isFocused: item.id == focusedItemID,
                    isInteractionDisabled: isInteractionDisabled
                )
                .id(item.id)
            }
        }
    }

    private func sectionHeader(_ section: PhotoTimelineSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.system(size: thumbnailSize < 150 ? 18 : 22, weight: .bold))
            Text("\(section.photos.count) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, thumbnailSize < 150 ? 4 : 8)
    }

    private var timelineSections: [PhotoTimelineSection] {
        let granularity = timelineGranularity
        var sections: [PhotoTimelineSection] = []
        sections.reserveCapacity(granularity == .month ? 16 : min(128, photos.count))

        for item in photos {
            let key = Self.timelineKey(for: item.timelineDate, granularity: granularity)
            if sections.last?.id == key {
                sections[sections.count - 1].photos.append(item)
            } else {
                sections.append(PhotoTimelineSection(
                    id: key,
                    title: Self.timelineTitle(for: item.timelineDate, granularity: granularity),
                    photos: [item]
                ))
            }
        }
        return sections
    }

    private static func timelineKey(for date: Date, granularity: TimelineGranularity) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        switch granularity {
        case .month:
            return String(format: "month-%04d-%02d", components.year ?? 0, components.month ?? 0)
        case .day:
            return String(
                format: "day-%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }
    }

    private static func timelineTitle(for date: Date, granularity: TimelineGranularity) -> String {
        switch granularity {
        case .month:
            monthFormatter.string(from: date)
        case .day:
            dayFormatter.string(from: date)
        }
    }
}

private enum TimelineGranularity {
    case month
    case day
}

private struct PhotoTimelineSection: Identifiable {
    let id: String
    let title: String
    var photos: [PhotoItem]
}
