import AppKit
import Foundation
import ImageIO

@MainActor
final class ImageService {
    static let shared = ImageService()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 600
    }

    func image(url: URL, cacheKey: String, maxPixelSize: Int) async -> NSImage? {
        let key = cacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let generatedImage = await Task.detached(priority: .utility) {
            Self.downsample(url: url, maxPixelSize: maxPixelSize)
        }.value

        if let generatedImage {
            let generated = NSImage(cgImage: generatedImage, size: .zero)
            let cost = max(1, Int(generated.size.width * generated.size.height * 4))
            cache.setObject(generated, forKey: key, cost: cost)
            return generated
        }
        return nil
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
}
