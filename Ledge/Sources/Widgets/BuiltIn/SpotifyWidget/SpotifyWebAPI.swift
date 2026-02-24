import Foundation
import os.log

/// Spotify Web API client for playback state, control, and device management.
///
/// Uses the Spotify Web API (https://developer.spotify.com/documentation/web-api/)
/// with Bearer token authentication. Token management is handled by `SpotifyAuthManager`.
///
/// All methods are async and throw on network/API errors. The caller is responsible
/// for handling errors gracefully (e.g. falling back to AppleScript).
class SpotifyWebAPI {

    private let logger = Logger(subsystem: "com.ledge.app", category: "SpotifyWebAPI")
    private let baseURL = "https://api.spotify.com/v1"

    /// The auth manager that provides access tokens.
    private weak var authManager: SpotifyAuthManager?

    /// Whether the API is configured and authenticated.
    var isConfigured: Bool {
        authManager?.isAuthenticated ?? false
    }

    init(authManager: SpotifyAuthManager) {
        self.authManager = authManager
    }

    // MARK: - Playback State

    /// Fetch the current playback state (track, device, progress, etc.).
    /// Returns nil if nothing is playing or no active device.
    func getPlaybackState() async throws -> PlaybackState? {
        let data = try await request("GET", path: "/me/player")
        guard let data, !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PlaybackState.self, from: data)
    }

    /// Fetch available playback devices.
    func getDevices() async throws -> [Device] {
        guard let data = try await request("GET", path: "/me/player/devices") else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(DevicesResponse.self, from: data)
        return response.devices
    }

    // MARK: - Playback Control

    /// Resume playback on the active device.
    func play(deviceID: String? = nil) async throws {
        var path = "/me/player/play"
        if let id = deviceID { path += "?device_id=\(id)" }
        try await request("PUT", path: path)
    }

    /// Pause playback.
    func pause() async throws {
        try await request("PUT", path: "/me/player/pause")
    }

    /// Skip to next track.
    func nextTrack() async throws {
        try await request("POST", path: "/me/player/next")
    }

    /// Skip to previous track.
    func previousTrack() async throws {
        try await request("POST", path: "/me/player/previous")
    }

    /// Seek to a position in the current track.
    func seek(positionMs: Int) async throws {
        try await request("PUT", path: "/me/player/seek?position_ms=\(positionMs)")
    }

    /// Set playback volume.
    func setVolume(percent: Int) async throws {
        let clamped = max(0, min(100, percent))
        try await request("PUT", path: "/me/player/volume?volume_percent=\(clamped)")
    }

    /// Transfer playback to a specific device.
    func transferPlayback(to deviceID: String, play: Bool = true) async throws {
        let body = ["device_ids": [deviceID], "play": play] as [String: Any]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        try await request("PUT", path: "/me/player", body: bodyData)
    }

    // MARK: - Network

    /// Make an authenticated request to the Spotify Web API.
    /// Automatically refreshes the token on 401 and retries once.
    @discardableResult
    private func request(_ method: String, path: String, body: Data? = nil) async throws -> Data? {
        guard let authManager else {
            throw SpotifyAPIError.notAuthenticated
        }

        guard let token = await authManager.validAccessToken() else {
            throw SpotifyAPIError.notAuthenticated
        }

        let result = try await performRequest(method, path: path, token: token, body: body)

        // 401 → try refreshing the token once
        if result.statusCode == 401 {
            logger.info("Got 401 — refreshing token and retrying")
            let refreshed = await authManager.refreshAccessToken()
            guard refreshed, let newToken = await authManager.validAccessToken() else {
                throw SpotifyAPIError.authenticationExpired
            }
            let retry = try await performRequest(method, path: path, token: newToken, body: body)
            return try handleResponse(retry)
        }

        return try handleResponse(result)
    }

    private func performRequest(_ method: String, path: String, token: String, body: Data? = nil) async throws -> (data: Data, statusCode: Int) {
        guard let url = URL(string: baseURL + path) else {
            throw SpotifyAPIError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, statusCode)
    }

    private func handleResponse(_ result: (data: Data, statusCode: Int)) throws -> Data? {
        let statusCode = result.statusCode

        switch statusCode {
        case 200...299:
            // 204 No Content is common for PUT/POST commands
            return result.data.isEmpty ? nil : result.data
        case 401:
            throw SpotifyAPIError.authenticationExpired
        case 403:
            throw SpotifyAPIError.forbidden
        case 404:
            throw SpotifyAPIError.noActiveDevice
        case 429:
            // Rate limited — could parse Retry-After header but for now just throw
            throw SpotifyAPIError.rateLimited
        default:
            let body = String(data: result.data, encoding: .utf8) ?? ""
            logger.error("API error \(statusCode): \(body)")
            throw SpotifyAPIError.httpError(statusCode: statusCode, body: body)
        }
    }

    // MARK: - Response Types

    struct PlaybackState: Decodable {
        let isPlaying: Bool
        let progressMs: Int?
        let item: Track?
        let device: Device?
        let shuffleState: Bool?
        let repeatState: String?
    }

    struct Track: Decodable {
        let id: String?
        let name: String
        let durationMs: Int
        let artists: [Artist]
        let album: Album

        var artistName: String {
            artists.map(\.name).joined(separator: ", ")
        }
    }

    struct Artist: Decodable {
        let name: String
    }

    struct Album: Decodable {
        let name: String
        let images: [AlbumImage]

        /// Best available image URL (largest first).
        var imageURL: String? {
            images.first?.url
        }
    }

    struct AlbumImage: Decodable {
        let url: String
        let height: Int?
        let width: Int?
    }

    struct Device: Decodable, Identifiable {
        let id: String?
        let isActive: Bool
        let isPrivateSession: Bool?
        let isRestricted: Bool?
        let name: String
        let type: String
        let volumePercent: Int?

        /// SF Symbol name for the device type.
        var systemImage: String {
            switch type.lowercased() {
            case "computer": return "laptopcomputer"
            case "smartphone": return "iphone"
            case "speaker": return "hifispeaker"
            case "tv": return "tv"
            case "tablet": return "ipad"
            case "automobile": return "car"
            case "castaudio", "castdevice": return "airplayaudio"
            default: return "speaker.wave.2"
            }
        }
    }

    struct DevicesResponse: Decodable {
        let devices: [Device]
    }

    // MARK: - Errors

    enum SpotifyAPIError: LocalizedError {
        case notAuthenticated
        case authenticationExpired
        case forbidden
        case noActiveDevice
        case rateLimited
        case invalidURL(String)
        case httpError(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not signed in to Spotify"
            case .authenticationExpired: return "Spotify session expired — please sign in again"
            case .forbidden: return "Spotify Premium required for playback control"
            case .noActiveDevice: return "No active Spotify device"
            case .rateLimited: return "Too many requests — try again shortly"
            case .invalidURL(let path): return "Invalid API path: \(path)"
            case .httpError(let code, _): return "Spotify API error (HTTP \(code))"
            }
        }
    }
}
