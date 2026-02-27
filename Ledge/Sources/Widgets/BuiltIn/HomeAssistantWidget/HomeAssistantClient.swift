import Foundation
import os.log

/// REST API client for Home Assistant.
///
/// Uses long-lived access tokens for authentication.
/// Polls entity states and sends service calls for toggles/brightness.
class HomeAssistantClient {

    private let logger = Logger(subsystem: "com.ledge.app", category: "HomeAssistantClient")

    struct EntityState: Identifiable {
        let id: String  // entity_id
        let state: String
        let friendlyName: String
        let domain: String  // light, switch, sensor, etc.
        var brightness: Int?  // 0-255, lights only
        var unitOfMeasurement: String?
    }

    struct FetchResult {
        var entities: [EntityState] = []
        var errors: [String] = []
    }

    var serverURL: String = ""
    var accessToken: String = ""

    var isConfigured: Bool {
        !serverURL.isEmpty && !accessToken.isEmpty
    }

    /// Normalise the server URL: ensure it has an http(s) scheme and no trailing slash.
    private var normalisedURL: String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty && !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://\(url)"
        }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// Fetch states for the given entity IDs.
    func fetchStates(entityIDs: [String]) async -> FetchResult {
        var result = FetchResult()

        guard isConfigured else {
            return result
        }

        let base = normalisedURL

        for entityID in entityIDs {
            let urlString = "\(base)/api/states/\(entityID)"
            guard let url = URL(string: urlString) else {
                logger.error("Invalid URL for entity \(entityID): \(urlString)")
                result.errors.append("Invalid URL for \(entityID)")
                continue
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 401 {
                        result.errors.append("401 Unauthorized — check access token")
                        logger.error("HTTP 401 for \(entityID) — invalid or expired access token")
                        continue
                    } else if httpResponse.statusCode == 404 {
                        result.errors.append("'\(entityID)' not found — use full ID (e.g. light.name)")
                        logger.error("HTTP 404 for \(entityID) — entity not found on server")
                        continue
                    } else if httpResponse.statusCode != 200 {
                        let body = String(data: data, encoding: .utf8) ?? "(binary)"
                        result.errors.append("HTTP \(httpResponse.statusCode) for \(entityID)")
                        logger.error("HTTP \(httpResponse.statusCode) for \(entityID): \(body)")
                        continue
                    }
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    logger.error("Failed to parse JSON for \(entityID)")
                    result.errors.append("Invalid response for \(entityID)")
                    continue
                }

                let state = json["state"] as? String ?? "unknown"
                let attrs = json["attributes"] as? [String: Any] ?? [:]
                let friendlyName = attrs["friendly_name"] as? String ?? entityID
                let domain = entityID.components(separatedBy: ".").first ?? "unknown"
                let brightness = attrs["brightness"] as? Int
                let unit = attrs["unit_of_measurement"] as? String

                result.entities.append(EntityState(
                    id: entityID,
                    state: state,
                    friendlyName: friendlyName,
                    domain: domain,
                    brightness: brightness,
                    unitOfMeasurement: unit
                ))
            } catch let error as URLError {
                let msg: String
                switch error.code {
                case .cannotFindHost: msg = "Cannot find host '\(self.serverURL)'"
                case .cannotConnectToHost: msg = "Cannot connect to '\(self.serverURL)'"
                case .timedOut: msg = "Connection timed out"
                case .notConnectedToInternet: msg = "No internet connection"
                default: msg = error.localizedDescription
                }
                result.errors.append(msg)
                logger.error("Network error fetching \(entityID): \(error.localizedDescription) (code: \(error.code.rawValue))")
            } catch {
                result.errors.append(error.localizedDescription)
                logger.error("Failed to fetch \(entityID): \(error.localizedDescription)")
            }
        }

        if !result.errors.isEmpty {
            logger.warning("Fetched \(result.entities.count)/\(entityIDs.count) entities, \(result.errors.count) errors")
        }
        return result
    }

    /// Fetch all entity states from the server (for entity picker).
    func fetchAllStates() async -> [EntityState] {
        guard isConfigured else { return [] }
        guard let url = URL(string: "\(normalisedURL)/api/states") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return [] }
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            return jsonArray.compactMap { json -> EntityState? in
                guard let entityID = json["entity_id"] as? String else { return nil }
                let state = json["state"] as? String ?? "unknown"
                let attrs = json["attributes"] as? [String: Any] ?? [:]
                let friendlyName = attrs["friendly_name"] as? String ?? entityID
                let domain = entityID.components(separatedBy: ".").first ?? "unknown"
                let brightness = attrs["brightness"] as? Int
                let unit = attrs["unit_of_measurement"] as? String
                return EntityState(
                    id: entityID, state: state, friendlyName: friendlyName,
                    domain: domain, brightness: brightness, unitOfMeasurement: unit
                )
            }
        } catch {
            logger.error("Failed to fetch all states: \(error.localizedDescription)")
            return []
        }
    }

    /// Toggle a light or switch entity.
    func toggle(entityID: String) async {
        let domain = entityID.components(separatedBy: ".").first ?? "light"
        await callService(domain: domain, service: "toggle", entityID: entityID)
    }

    /// Set brightness for a light entity (0-255).
    func setBrightness(entityID: String, brightness: Int) async {
        await callService(domain: "light", service: "turn_on", entityID: entityID, data: ["brightness": brightness])
    }

    private func callService(domain: String, service: String, entityID: String, data: [String: Any] = [:]) async {
        guard isConfigured else { return }
        guard let url = URL(string: "\(normalisedURL)/api/services/\(domain)/\(service)") else { return }

        var body: [String: Any] = ["entity_id": entityID]
        for (key, value) in data { body[key] = value }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                logger.error("Service call failed: \(httpResponse.statusCode)")
            }
        } catch {
            logger.error("Service call error: \(error.localizedDescription)")
        }
    }
}
