import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

private actor ImageDecodeLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        availablePermits = permits
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

@MainActor
final class ImageService {
    static let shared = ImageService()

    private let cache = NSCache<NSString, NSImage>()
    nonisolated private static let decodeLimiter = ImageDecodeLimiter(permits: 4)

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 600
    }

    func image(
        url: URL,
        cacheKey: String,
        maxPixelSize: Int,
        isVideo: Bool = false
    ) async -> NSImage? {
        let key = cacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let diskCachedImage = await Self.loadDiskThumbnail(cacheKey: cacheKey) {
            let image = NSImage(cgImage: diskCachedImage, size: .zero)
            let cost = max(1, diskCachedImage.width * diskCachedImage.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
            return image
        }

        let generatedImage = await Task.detached(priority: .utility) { () async -> CGImage? in
            await Self.decodeLimiter.acquire()
            defer {
                Task {
                    await Self.decodeLimiter.release()
                }
            }
            guard Task.isCancelled == false else { return nil }
            if isVideo {
                return Self.videoThumbnail(url: url, maxPixelSize: maxPixelSize)
            }
            return Self.downsample(url: url, maxPixelSize: maxPixelSize)
        }.value

        if let generatedImage {
            let generated = NSImage(cgImage: generatedImage, size: .zero)
            let cost = max(1, generatedImage.width * generatedImage.height * 4)
            cache.setObject(generated, forKey: key, cost: cost)
            Task.detached(priority: .utility) {
                Self.saveDiskThumbnail(generatedImage, cacheKey: cacheKey)
            }
            return generated
        }
        return nil
    }

    nonisolated private static func loadDiskThumbnail(cacheKey: String) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let url = diskThumbnailURL(cacheKey: cacheKey)
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
    }

    nonisolated private static func saveDiskThumbnail(_ image: CGImage, cacheKey: String) {
        let url = diskThumbnailURL(cacheKey: cacheKey)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return
            }
            let options = [
                kCGImageDestinationLossyCompressionQuality: 0.84
            ] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
            if CGImageDestinationFinalize(destination) == false {
                AppLogger.warning("保存缩略图缓存失败：\(url.path)")
            }
        } catch {
            AppLogger.warning("创建缩略图缓存目录失败：\(url.deletingLastPathComponent().path)", error: error)
        }
    }

    nonisolated private static func diskThumbnailURL(cacheKey: String) -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let safeKey = LivePhotoParser.fingerprint(
            path: cacheKey,
            size: Int64(cacheKey.utf8.count),
            modifiedAt: .distantPast
        )
        let bucket = String(safeKey.prefix(2))
        return baseURL
            .appendingPathComponent("MotionAlbum", isDirectory: true)
            .appendingPathComponent("ThumbnailCache", isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent("\(safeKey).jpg")
    }

    nonisolated private static func downsample(url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func videoThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        for second in [0.2, 0.0, 1.0] {
            do {
                return try generator.copyCGImage(
                    at: CMTime(seconds: second, preferredTimescale: 600),
                    actualTime: nil
                )
            } catch {
                AppLogger.warning("生成视频缩略图失败：\(url.path) @ \(second)", error: error)
            }
        }
        return nil
    }
}
