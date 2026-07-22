import CoreLocation
import Foundation

actor PlaceNameResolver {
    static let shared = PlaceNameResolver()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    func resolve(latitude: Double, longitude: Double) async -> String? {
        guard latitude.isFinite,
              longitude.isFinite,
              abs(latitude) <= 90,
              abs(longitude) <= 180 else { return nil }

        let cacheKey = Self.cacheKey(latitude: latitude, longitude: longitude)
        if let cached = cache[cacheKey] {
            return cached
        }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await reverseGeocode(location)
            guard let placeName = Self.displayName(from: placemarks.first) else {
                return nil
            }
            cache[cacheKey] = placeName
            return placeName
        } catch {
            AppLogger.warning("反解析照片地点失败：\(cacheKey)", error: error)
            return nil
        }
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> [CLPlacemark] {
        try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: placemarks ?? [])
                }
            }
        }
    }

    private static func displayName(from placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }

        let areaParts = [
            placemark.administrativeArea,
            placemark.subAdministrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.name
        ]
        .compactMap(normalizedText)

        let distinctParts = areaParts.reduce(into: [String]()) { result, part in
            guard result.contains(part) == false else { return }
            if let previous = result.last, previous.localizedCaseInsensitiveContains(part) {
                return
            }
            result.append(part)
        }

        if distinctParts.isEmpty == false {
            return distinctParts.prefix(4).joined(separator: " · ")
        }

        return normalizedText(placemark.country)
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cacheKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}
