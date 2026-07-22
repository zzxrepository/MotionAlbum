import Foundation

enum LivePhotoStatus: String, Codable {
    case unknown
    case live
    case still
    case unreadable
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case live = "仅实况"
    case selected = "已精选"

    var id: String { rawValue }
}

@MainActor
final class PhotoItem: ObservableObject, Identifiable {
    let id: String
    let url: URL
    let companionVideoURL: URL?
    let fileName: String
    let fileSize: Int64
    let modifiedAt: Date
    let cacheKey: String
    let selectionKey: String
    let metadata: PhotoMetadata

    @Published var liveStatus: LivePhotoStatus
    @Published var isSelected: Bool
    @Published var tags: [String]
    @Published var holdFrameTime: Double?
    @Published var placeName: String?
    @Published var isResolvingPlaceName = false

    init(
        descriptor: PhotoFileDescriptor,
        liveStatus: LivePhotoStatus,
        isSelected: Bool,
        selectionKey: String,
        tags: [String]
    ) {
        id = descriptor.url.path
        url = descriptor.url
        companionVideoURL = descriptor.companionVideoURL
        fileName = descriptor.url.lastPathComponent
        fileSize = descriptor.fileSize
        modifiedAt = descriptor.modifiedAt
        cacheKey = descriptor.cacheKey
        self.selectionKey = selectionKey
        metadata = descriptor.metadata
        self.liveStatus = liveStatus
        self.isSelected = isSelected
        self.tags = tags
        holdFrameTime = nil
    }

    var originalResourceURLs: [URL] {
        if let companionVideoURL {
            return [url, companionVideoURL]
        }
        return [url]
    }
}

struct PhotoFileDescriptor: Sendable {
    let url: URL
    let companionVideoURL: URL?
    let companionVideoFileSize: Int64?
    let companionVideoModifiedAt: Date?
    let fileSize: Int64
    let modifiedAt: Date
    let metadata: PhotoMetadata

    var cacheKey: String {
        let companionSeed = [
            companionVideoURL?.path,
            companionVideoFileSize.map(String.init),
            companionVideoModifiedAt.map { String($0.timeIntervalSince1970) }
        ]
        .compactMap { $0 }
        .joined(separator: "|")
        return LivePhotoParser.fingerprint(
            path: companionSeed.isEmpty ? url.path : "\(url.path)|\(companionSeed)",
            size: fileSize + (companionVideoFileSize ?? 0),
            modifiedAt: max(modifiedAt, companionVideoModifiedAt ?? .distantPast)
        )
    }
}
