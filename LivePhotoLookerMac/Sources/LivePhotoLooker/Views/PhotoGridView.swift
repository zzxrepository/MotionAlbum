import SwiftUI

struct PhotoGridView: View {
    let photos: [PhotoItem]
    let onOpen: (PhotoItem) -> Void
    let onToggleSelection: (PhotoItem) -> Void
    let onReveal: (PhotoItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 188, maximum: 250), spacing: 18, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(photos) { item in
                    PhotoCardView(
                        item: item,
                        onOpen: { onOpen(item) },
                        onToggleSelection: { onToggleSelection(item) },
                        onReveal: { onReveal(item) }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .background(Color.clear)
    }
}
