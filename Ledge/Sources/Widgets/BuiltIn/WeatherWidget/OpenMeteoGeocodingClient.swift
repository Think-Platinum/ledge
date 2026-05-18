import Foundation
import os.log

/// Client for the Open-Meteo Geocoding API (free, no key required).
///
/// Searches cities/places by name and returns coordinates plus a display label.
/// See: https://open-meteo.com/en/docs/geocoding-api
class OpenMeteoGeocodingClient {

    private let logger = Logger(subsystem: "com.ledge.app", category: "OpenMeteoGeocoding")

    struct Place: Identifiable, Hashable {
        let id: Int
        let name: String
        let admin1: String?
        let country: String?
        let countryCode: String?
        let latitude: Double
        let longitude: Double

        /// e.g. "Edinburgh, Scotland, United Kingdom" or "Berlin, Germany"
        var displayLabel: String {
            [name, admin1, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        }

        /// Shorter label for the widget: "Edinburgh, GB"
        var shortLabel: String {
            if let code = countryCode, !code.isEmpty {
                return "\(name), \(code)"
            }
            return name
        }
    }

    /// Search for places matching the given query. Returns an empty array on error or for queries < 2 chars.
    func search(query: String, count: Int = 10) async -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]

        guard let url = components.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            return results.compactMap { dict in
                guard let id = dict["id"] as? Int,
                      let name = dict["name"] as? String,
                      let lat = dict["latitude"] as? Double,
                      let lon = dict["longitude"] as? Double else {
                    return nil
                }
                return Place(
                    id: id,
                    name: name,
                    admin1: dict["admin1"] as? String,
                    country: dict["country"] as? String,
                    countryCode: dict["country_code"] as? String,
                    latitude: lat,
                    longitude: lon
                )
            }
        } catch {
            logger.error("Geocoding search failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Reverse-lookup: pick the nearest named place to the given coordinates.
    /// Uses the search endpoint with a small radius approximation — Open-Meteo doesn't have a true reverse endpoint,
    /// so we query Open-Meteo's `reverse` workaround: fetch the closest named feature via a single-result search.
    /// Returns nil if no match.
    func reverseLookup(latitude: Double, longitude: Double) async -> Place? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/reverse")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let id = first["id"] as? Int,
                  let name = first["name"] as? String,
                  let lat = first["latitude"] as? Double,
                  let lon = first["longitude"] as? Double else {
                return nil
            }
            return Place(
                id: id,
                name: name,
                admin1: first["admin1"] as? String,
                country: first["country"] as? String,
                countryCode: first["country_code"] as? String,
                latitude: lat,
                longitude: lon
            )
        } catch {
            logger.error("Reverse geocoding failed: \(error.localizedDescription)")
            return nil
        }
    }
}
