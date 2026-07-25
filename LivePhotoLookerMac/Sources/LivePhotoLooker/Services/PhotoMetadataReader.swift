import CoreGraphics
import Foundation
import ImageIO

struct PhotoMetadata: Sendable {
    var make: String?
    var model: String?
    var software: String?
    var capturedAt: String?
    var capturedAtDate: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var latitude: Double?
    var longitude: Double?

    var isEmpty: Bool {
        make == nil &&
            model == nil &&
            software == nil &&
            capturedAt == nil &&
            capturedAtDate == nil &&
            pixelWidth == nil &&
            pixelHeight == nil &&
            latitude == nil &&
            longitude == nil
    }

    var deviceText: String? {
        [make, model]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")
            .nilIfEmpty
    }

    var sizeText: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var coordinateText: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }
}

enum PhotoMetadataReader {
    static func read(from url: URL) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return PhotoMetadata()
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        let capturedAt = stringValue(exif?[kCGImagePropertyExifDateTimeOriginal as String])
            ?? stringValue(tiff?[kCGImagePropertyTIFFDateTime as String])

        return PhotoMetadata(
            make: stringValue(tiff?[kCGImagePropertyTIFFMake as String]),
            model: stringValue(tiff?[kCGImagePropertyTIFFModel as String]),
            software: stringValue(tiff?[kCGImagePropertyTIFFSoftware as String]),
            capturedAt: capturedAt,
            capturedAtDate: dateValue(capturedAt),
            pixelWidth: intValue(properties[kCGImagePropertyPixelWidth as String])
                ?? intValue(exif?[kCGImagePropertyExifPixelXDimension as String]),
            pixelHeight: intValue(properties[kCGImagePropertyPixelHeight as String])
                ?? intValue(exif?[kCGImagePropertyExifPixelYDimension as String]),
            latitude: coordinateValue(
                value: gps?[kCGImagePropertyGPSLatitude as String],
                reference: gps?[kCGImagePropertyGPSLatitudeRef as String],
                negativeReference: "S"
            ),
            longitude: coordinateValue(
                value: gps?[kCGImagePropertyGPSLongitude as String],
                reference: gps?[kCGImagePropertyGPSLongitudeRef as String],
                negativeReference: "W"
            )
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text: String
        if let string = value as? String {
            text = string
        } else {
            text = String(describing: value)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func dateValue(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value
            .split(separator: " ")
            .flatMap { $0.split(separator: $0.contains(":") ? ":" : "-") }
            .compactMap { Int($0) }
        guard parts.count >= 6 else { return nil }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = parts[3]
        components.minute = parts[4]
        components.second = parts[5]
        return components.date
    }

    private static func coordinateValue(
        value: Any?,
        reference: Any?,
        negativeReference: String
    ) -> Double? {
        guard var coordinate = doubleValue(value) else { return nil }
        if stringValue(reference)?.uppercased() == negativeReference {
            coordinate = -coordinate
        }
        return coordinate
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
