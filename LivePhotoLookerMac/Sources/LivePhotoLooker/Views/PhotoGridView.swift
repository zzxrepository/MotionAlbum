import AppKit
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
    let onFocus: (PhotoItem) -> Void
    let isInteractionDisabled: Bool
    let isKeyboardNavigationEnabled: Bool

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

    private var isShowcaseMode: Bool {
        thumbnailSize >= 520
    }

    private var spacing: CGFloat {
        isShowcaseMode ? 22 : (thumbnailSize < 150 ? 6 : 10)
    }

    private var horizontalPadding: CGFloat {
        isShowcaseMode ? 28 : (thumbnailSize < 150 ? 12 : 18)
    }

    private var verticalPadding: CGFloat {
        isShowcaseMode ? 20 : (thumbnailSize < 150 ? 12 : 16)
    }

    private var tileWidth: CGFloat {
        thumbnailSize + (thumbnailSize >= 150 ? 18 : 0)
    }

    private func columns(availableWidth: CGFloat) -> [GridItem] {
        if isShowcaseMode {
            return [
                GridItem(
                    .flexible(minimum: 0, maximum: availableWidth),
                    spacing: spacing,
                    alignment: .top
                )
            ]
        }

        return [
            GridItem(
                .adaptive(minimum: tileWidth, maximum: tileWidth + 16),
                spacing: spacing,
                alignment: .top
            )
        ]
    }

    var body: some View {
        GeometryReader { geometry in
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
                                    photoGrid(section.photos, availableWidth: geometry.size.width)
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                    } else {
                        photoGrid(photos, availableWidth: geometry.size.width)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.vertical, verticalPadding)
                    }
                }
                .background(Color.clear)
                .background {
                    GalleryKeyboardMonitor(
                        isEnabled: isKeyboardNavigationEnabled,
                        onAction: { action in
                            handleKeyboardAction(
                                action,
                                availableWidth: geometry.size.width,
                                proxy: proxy
                            )
                        }
                    )
                    .accessibilityHidden(true)
                }
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

    private func handleKeyboardAction(
        _ action: GalleryKeyboardAction,
        availableWidth: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard isKeyboardNavigationEnabled, photos.isEmpty == false else { return }

        if action == .open {
            let item = focusedPhoto ?? photos.first
            if let item {
                onOpen(item)
            }
            return
        }

        let columnCount = estimatedColumnCount(availableWidth: availableWidth)
        guard let target = navigationTarget(for: action, columnCount: columnCount) else { return }
        onFocus(target)

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(target.id)
            }
        }
    }

    private var focusedPhoto: PhotoItem? {
        guard let focusedItemID else { return nil }
        return photos.first { $0.id == focusedItemID }
    }

    private func estimatedColumnCount(availableWidth: CGFloat) -> Int {
        if isShowcaseMode {
            return 1
        }
        let contentWidth = max(0, availableWidth - (horizontalPadding * 2))
        return max(1, Int((contentWidth + spacing) / (tileWidth + spacing)))
    }

    private func navigationTarget(
        for action: GalleryKeyboardAction,
        columnCount: Int
    ) -> PhotoItem? {
        guard let current = focusedPhoto,
              let currentIndex = photos.firstIndex(where: { $0.id == current.id }) else {
            return photos.first
        }

        switch action {
        case .left:
            return photos[max(0, currentIndex - 1)]
        case .right:
            return photos[min(photos.count - 1, currentIndex + 1)]
        case .up, .down:
            return verticalNavigationTarget(
                from: current,
                globalIndex: currentIndex,
                movingDown: action == .down,
                columnCount: columnCount
            )
        case .open:
            return current
        }
    }

    private func verticalNavigationTarget(
        from current: PhotoItem,
        globalIndex: Int,
        movingDown: Bool,
        columnCount: Int
    ) -> PhotoItem {
        guard groupByTime else {
            let offset = movingDown ? columnCount : -columnCount
            let targetIndex = min(photos.count - 1, max(0, globalIndex + offset))
            return photos[targetIndex]
        }

        let sections = timelineSections
        guard let sectionIndex = sections.firstIndex(where: { section in
            section.photos.contains(where: { $0.id == current.id })
        }),
        let itemIndex = sections[sectionIndex].photos.firstIndex(where: { $0.id == current.id }) else {
            return current
        }

        let sectionItems = sections[sectionIndex].photos
        let column = itemIndex % columnCount

        if movingDown {
            let nextRowIndex = itemIndex + columnCount
            if nextRowIndex < sectionItems.count {
                return sectionItems[nextRowIndex]
            }
            guard sectionIndex + 1 < sections.count else { return current }
            let nextItems = sections[sectionIndex + 1].photos
            return nextItems[min(column, nextItems.count - 1)]
        }

        let previousRowIndex = itemIndex - columnCount
        if previousRowIndex >= 0 {
            return sectionItems[previousRowIndex]
        }
        guard sectionIndex > 0 else { return current }
        let previousItems = sections[sectionIndex - 1].photos
        let lastRowStart = ((previousItems.count - 1) / columnCount) * columnCount
        let targetIndex = lastRowStart + min(column, previousItems.count - 1 - lastRowStart)
        return previousItems[targetIndex]
    }

    private func clamped(_ size: CGFloat) -> CGFloat {
        min(thumbnailSizeRange.upperBound, max(thumbnailSizeRange.lowerBound, size))
    }

    private func photoGrid(_ items: [PhotoItem], availableWidth: CGFloat) -> some View {
        let cardWidth = effectiveCardWidth(availableWidth: availableWidth)
        return LazyVGrid(
            columns: columns(availableWidth: availableWidth),
            alignment: isShowcaseMode ? .center : .leading,
            spacing: spacing
        ) {
            ForEach(items) { item in
                PhotoCardView(
                    item: item,
                    onOpen: { onOpen(item) },
                    onFocus: { onFocus(item) },
                    onToggleSelection: { onToggleSelection(item) },
                    onReveal: { onReveal(item) },
                    onTrash: { onTrash(item) },
                    thumbnailSize: cardWidth,
                    isShowcaseMode: isShowcaseMode,
                    isFocused: item.id == focusedItemID,
                    isInteractionDisabled: isInteractionDisabled
                )
                .id(item.id)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func effectiveCardWidth(availableWidth: CGFloat) -> CGFloat {
        guard isShowcaseMode else { return thumbnailSize }
        let availableContentWidth = max(320, availableWidth - (horizontalPadding * 2))
        return min(thumbnailSize, min(1_100, availableContentWidth))
    }

    private func sectionHeader(_ section: PhotoTimelineSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: thumbnailSize < 150 ? 15 : (isShowcaseMode ? 18 : 17), weight: .semibold))
            Text("\(section.photos.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.top, thumbnailSize < 150 ? 2 : 5)
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

private enum GalleryKeyboardAction: Equatable {
    case left
    case right
    case up
    case down
    case open
}

private struct GalleryKeyboardMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onAction: (GalleryKeyboardAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onAction: onAction)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onAction = onAction
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onAction: (GalleryKeyboardAction) -> Void
        private var monitor: Any?

        init(
            isEnabled: Bool,
            onAction: @escaping (GalleryKeyboardAction) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onAction = onAction
        }

        func install(for hostView: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak hostView] event in
                guard let self,
                      self.isEnabled,
                      event.window === hostView?.window,
                      self.shouldYieldToFocusedControl(event.window?.firstResponder) == false,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let action = Self.action(for: event) else {
                    return event
                }

                self.onAction(action)
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func shouldYieldToFocusedControl(_ responder: NSResponder?) -> Bool {
            if let textView = responder as? NSTextView, textView.isEditable {
                return true
            }
            return responder is NSTextField
                || responder is NSSlider
                || responder is NSComboBox
                || responder is NSStepper
        }

        private static func action(for event: NSEvent) -> GalleryKeyboardAction? {
            switch event.keyCode {
            case 123, 0: return .left       // ← / A
            case 124, 2: return .right      // → / D
            case 126, 13: return .up        // ↑ / W
            case 125, 1: return .down       // ↓ / S
            case 36, 76: return .open       // Return / keypad Enter
            default: return nil
            }
        }

        deinit {
            stop()
        }
    }
}

private struct PhotoTimelineSection: Identifiable {
    let id: String
    let title: String
    var photos: [PhotoItem]
}
