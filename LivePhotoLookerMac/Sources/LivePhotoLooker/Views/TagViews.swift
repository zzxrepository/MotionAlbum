import SwiftUI

struct TagBadgeView: View {
    let tag: String
    var count: Int?
    var isActive = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(tag)
                .lineLimit(1)
            if let count {
                Text(count.formatted())
                    .foregroundStyle(isActive ? .white.opacity(0.82) : .secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isActive ? .white : .primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            isActive ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.18),
            in: Capsule()
        )
    }
}

struct RemovableTagBadgeView: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TagBadgeView(tag: tag)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除标签")
        }
        .padding(.trailing, 2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: Capsule())
    }
}
