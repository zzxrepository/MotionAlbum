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
    case video = "仅视频"
    case selected = "我喜欢"

    var id: String { rawValue }
}

enum PhotoSortOrder: String, CaseIterable, Identifiable {
    case captureNewest = "拍摄时间：新到旧"
    case captureOldest = "拍摄时间：旧到新"
    case modifiedNewest = "修改时间：新到旧"
    case fileNameAscending = "文件名：A 到 Z"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .captureNewest:
            return "新到旧"
        case .captureOldest:
            return "旧到新"
        case .modifiedNewest:
            return "修改时间"
        case .fileNameAscending:
            return "文件名"
        }
    }
}

enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

struct PhotoDirectory: Identifiable, Hashable {
    let url: URL
    let parentPath: String?

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
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
    let mediaKind: MediaKind

    @Published var metadata: PhotoMetadata
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
        mediaKind = descriptor.mediaKind
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

    var timelineDate: Date {
        metadata.capturedAtDate ?? modifiedAt
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
    let mediaKind: MediaKind
    let indexedLiveStatus: LivePhotoStatus?

    var cacheKey: String {
        let companionSeed = [
            companionVideoURL?.path,
            companionVideoFileSize.map(String.init),
            companionVideoModifiedAt.map { String($0.timeIntervalSince1970) }
        ]
        .compactMap { $0 }
        .joined(separator: "|")
        let pathSeed = companionSeed.isEmpty ? url.path : "\(url.path)|\(companionSeed)"
        return LivePhotoParser.fingerprint(
            path: "\(mediaKind.rawValue)|\(pathSeed)",
            size: fileSize + (companionVideoFileSize ?? 0),
            modifiedAt: max(modifiedAt, companionVideoModifiedAt ?? .distantPast)
        )
    }
}
