import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageRotationError: LocalizedError {
    case unsupportedFormat
    case cannotReadImage
    case cannotCreateOutput
    case cannotWriteOutput

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "这种图片格式暂不支持写入旋转结果。"
        case .cannotReadImage:
            return "无法读取原始图片。"
        case .cannotCreateOutput:
            return "无法创建旋转后的图片。"
        case .cannotWriteOutput:
            return "旋转后的图片写入失败。"
        }
    }
}

enum ImageRotationService {
    nonisolated static func saveRotatedImage(
        sourceURL: URL,
        destinationURL: URL,
        clockwiseQuarterTurns: Int,
        overwriteOriginal: Bool
    ) throws {
        let turns = ((clockwiseQuarterTurns % 4) + 4) % 4
        guard turns != 0 else { return }

        if overwriteOriginal {
            let temporaryURL = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(".MotionAlbum-rotate-\(UUID().uuidString)")
                .appendingPathExtension(sourceURL.pathExtension)
            do {
                try writeRotatedImage(
                    sourceURL: sourceURL,
                    destinationURL: temporaryURL,
                    clockwiseQuarterTurns: turns
                )
                _ = try FileManager.default.replaceItemAt(
                    sourceURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        } else {
            try writeRotatedImage(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                clockwiseQuarterTurns: turns
            )
        }
    }

    nonisolated private static func writeRotatedImage(
        sourceURL: URL,
        destinationURL: URL,
        clockwiseQuarterTurns: Int
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageRotationError.cannotReadImage
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
        let pixelWidth = sourceProperties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = sourceProperties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maximumPixelSize = max(1, max(pixelWidth, pixelHeight))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let normalizedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ), let rotatedImage = rotate(normalizedImage, clockwiseQuarterTurns: clockwiseQuarterTurns) else {
            throw ImageRotationError.cannotCreateOutput
        }

        let destinationType = outputType(
            for: destinationURL,
            fallback: CGImageSourceGetType(source)
        )
        guard let destinationType,
              let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                destinationType,
                1,
                nil
              ) else {
            throw ImageRotationError.unsupportedFormat
        }

        var metadata = sourceProperties
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if destinationType == UTType.jpeg.identifier as CFString {
            metadata[kCGImageDestinationLossyCompressionQuality] = 0.96
        }

        CGImageDestinationAddImage(destination, rotatedImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageRotationError.cannotWriteOutput
        }
    }

    nonisolated private static func outputType(
        for destinationURL: URL,
        fallback: CFString?
    ) -> CFString? {
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if let type = UTType(filenameExtension: destinationURL.pathExtension),
           type.conforms(to: .image),
           writableTypes.contains(type.identifier) {
            return type.identifier as CFString
        }
        return fallback
    }

    nonisolated private static func rotate(
        _ image: CGImage,
        clockwiseQuarterTurns: Int
    ) -> CGImage? {
        let turns = ((clockwiseQuarterTurns % 4) + 4) % 4
        let swapsDimensions = turns.isMultiple(of: 2) == false
        let outputWidth = swapsDimensions ? image.height : image.width
        let outputHeight = swapsDimensions ? image.width : image.height
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        switch turns {
        case 1:
            context.translateBy(x: CGFloat(outputWidth), y: 0)
            context.rotate(by: .pi / 2)
        case 2:
            context.translateBy(x: CGFloat(outputWidth), y: CGFloat(outputHeight))
            context.rotate(by: .pi)
        case 3:
            context.translateBy(x: 0, y: CGFloat(outputHeight))
            context.rotate(by: -.pi / 2)
        default:
            break
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }
}
