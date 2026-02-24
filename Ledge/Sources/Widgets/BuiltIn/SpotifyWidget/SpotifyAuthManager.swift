import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import os.log

/// Manages Spotify OAuth authentication using the Authorization Code with PKCE flow.
///
/// No client secret is needed — PKCE (Proof Key for Code Exchange) replaces it.
/// The flow:
/// 1. Generate a random code verifier and its SHA256 challenge
/// 2. Open the Spotify authorization URL in the user's browser
/// 3. Spin up a temporary HTTP listener on localhost to receive the redirect
/// 4. Exchange the authorization code for access + refresh tokens
/// 5. Store tokens securely in the Keychain
///
/// Token refresh is automatic — call `validAccessToken()` which refreshes if needed.
@MainActor
class SpotifyAuthManager: ObservableObject {

    private let logger = Logger(subsystem: "com.ledge.app", category: "SpotifyAuth")

    // MARK: - Keychain Keys

    private enum Keys {
        static let accessToken = "spotify-access-token"
        static let refreshToken = "spotify-refresh-token"
        static let tokenExpiry = "spotify-token-expiry"
        static let userName = "spotify-user-name"
    }

    // MARK: - Published State

    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var userDisplayName: String?
    @Published private(set) var error: String?
    @Published private(set) var isAuthenticating: Bool = false

    // MARK: - Configuration

    /// The Spotify Client ID — provided by the user from their Spotify Developer Dashboard.
    var clientID: String = ""

    /// OAuth scopes needed for playback state and control.
    private let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing"
    ].joined(separator: " ")

    // MARK: - PKCE State

    private var codeVerifier: String?
    private var listener: NWListener?
    private var tokenExpiryDate: Date?

    // MARK: - Init

    init() {
        // Check if we already have tokens from a previous session
        if KeychainHelper.readString(key: Keys.accessToken) != nil,
           KeychainHelper.readString(key: Keys.refreshToken) != nil {
            isAuthenticated = true
            userDisplayName = KeychainHelper.readString(key: Keys.userName)

            if let expiryString = KeychainHelper.readString(key: Keys.tokenExpiry),
               let expiryInterval = Double(expiryString) {
                tokenExpiryDate = Date(timeIntervalSince1970: expiryInterval)
            }

            logger.info("Restored Spotify session for \(self.userDisplayName ?? "unknown user")")
        }
    }

    // MARK: - Public API

    /// Start the OAuth login flow — opens browser for Spotify authorization.
    func login() {
        guard !clientID.isEmpty else {
            error = "Spotify Client ID is required. Create an app at developer.spotify.com"
            return
        }

        isAuthenticating = true
        error = nil

        // Generate PKCE code verifier and challenge
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        // Start listening for the redirect on the fixed port
        startRedirectListener(port: Self.redirectPort)

        // Build the authorization URL
        let redirectURI = Self.redirectURI
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]

        guard let url = components.url else {
            error = "Failed to build authorization URL"
            isAuthenticating = false
            return
        }

        logger.info("Opening Spotify authorization URL (redirect to port \(Self.redirectPort))")
        NSWorkspace.shared.open(url)
    }

    /// Log out — clear all tokens and state.
    func logout() {
        KeychainHelper.delete(key: Keys.accessToken)
        KeychainHelper.delete(key: Keys.refreshToken)
        KeychainHelper.delete(key: Keys.tokenExpiry)
        KeychainHelper.delete(key: Keys.userName)

        isAuthenticated = false
        userDisplayName = nil
        tokenExpiryDate = nil
        error = nil

        logger.info("Logged out of Spotify")
    }

    /// Get a valid access token, refreshing if expired.
    /// Returns nil if not authenticated.
    func validAccessToken() async -> String? {
        guard isAuthenticated else { return nil }

        // Check if token needs refresh (with 60-second buffer)
        if let expiry = tokenExpiryDate, Date().addingTimeInterval(60) >= expiry {
            logger.info("Access token expired or expiring soon — refreshing")
            let refreshed = await refreshAccessToken()
            if !refreshed {
                return nil
            }
        }

        return KeychainHelper.readString(key: Keys.accessToken)
    }

    // MARK: - PKCE Helpers

    /// Generate a random code verifier (43-128 characters, URL-safe).
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate the code challenge from the verifier (SHA256, base64url-encoded).
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Redirect URI

    /// Fixed port for the OAuth redirect listener.
    /// Must match the redirect URI registered in the Spotify Developer Dashboard.
    /// Using a fixed port so the redirect URI is predictable: http://127.0.0.1:21829/callback
    static let redirectPort: UInt16 = 21829

    /// The redirect URI that must be registered in the Spotify Developer Dashboard.
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

    // MARK: - Redirect Listener

    /// Start a temporary HTTP listener to receive the OAuth redirect.
    private func startRedirectListener(port: UInt16) {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            logger.error("Failed to create redirect listener: \(error.localizedDescription)")
            self.error = "Failed to start auth listener"
            isAuthenticating = false
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                let log = Logger(subsystem: "com.ledge.app", category: "SpotifyAuth")
                log.info("Redirect listener ready on port \(port)")
            case .failed(let err):
                let log = Logger(subsystem: "com.ledge.app", category: "SpotifyAuth")
                log.error("Redirect listener failed: \(err.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.error = "Auth listener failed"
                    self?.isAuthenticating = false
                }
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))

        // Auto-cancel after 5 minutes (user might close browser)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            if self?.isAuthenticating == true {
                self?.stopListener()
                self?.error = "Authentication timed out"
                self?.isAuthenticating = false
            }
        }
    }

    /// Handle an incoming connection from the browser redirect.
    /// Must be nonisolated because NWListener calls this from a background queue.
    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the authorization code from the GET request
            // Request looks like: GET /callback?code=AUTH_CODE HTTP/1.1
            if let code = self.parseAuthCode(from: request) {
                // Send success response to the browser
                let html = """
                    <html><body style="font-family: -apple-system; text-align: center; padding-top: 100px;">
                    <h1>✓ Signed in to Spotify</h1>
                    <p>You can close this tab and return to Ledge.</p>
                    </body></html>
                    """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                // Exchange the code for tokens
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.exchangeCodeForTokens(code: code)
                    self.stopListener()
                }
            } else if request.contains("error=") {
                // User denied or error occurred
                let html = """
                    <html><body style="font-family: -apple-system; text-align: center; padding-top: 100px;">
                    <h1>Authentication Failed</h1>
                    <p>Spotify authorization was denied. You can close this tab.</p>
                    </body></html>
                    """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                Task { @MainActor [weak self] in
                    self?.error = "Spotify authorization was denied"
                    self?.isAuthenticating = false
                    self?.stopListener()
                }
            } else {
                connection.cancel()
            }
        }
    }

    /// Parse the authorization code from the HTTP request.
    /// Must be nonisolated because it's called from NWConnection receive callbacks.
    nonisolated private func parseAuthCode(from request: String) -> String? {
        // Extract the URL path from the HTTP request line
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: urlPart),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        return code
    }

    /// Stop the redirect listener.
    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Token Exchange

    /// Exchange the authorization code for access and refresh tokens.
    private func exchangeCodeForTokens(code: String) async {
        guard let verifier = codeVerifier else {
            error = "Missing PKCE verifier"
            isAuthenticating = false
            return
        }

        let redirectURI = Self.redirectURI

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(verifier)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Invalid response from Spotify"
                isAuthenticating = false
                return
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                logger.error("Token exchange failed (\(httpResponse.statusCode)): \(errorBody)")
                error = "Token exchange failed (HTTP \(httpResponse.statusCode))"
                isAuthenticating = false
                return
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveTokens(tokenResponse)

            // Fetch user profile
            await fetchUserProfile()

            isAuthenticated = true
            isAuthenticating = false
            codeVerifier = nil
            logger.info("Successfully authenticated with Spotify")

        } catch {
            logger.error("Token exchange error: \(error.localizedDescription)")
            self.error = "Token exchange failed: \(error.localizedDescription)"
            isAuthenticating = false
        }
    }

    /// Refresh the access token using the stored refresh token.
    @discardableResult
    func refreshAccessToken() async -> Bool {
        guard let refreshToken = KeychainHelper.readString(key: Keys.refreshToken) else {
            logger.warning("No refresh token available")
            isAuthenticated = false
            return false
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientID)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.error("Token refresh failed")
                isAuthenticated = false
                return false
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveTokens(tokenResponse)
            logger.info("Token refreshed successfully")
            return true

        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
            isAuthenticated = false
            return false
        }
    }

    // MARK: - Token Storage

    private func saveTokens(_ response: TokenResponse) {
        KeychainHelper.save(key: Keys.accessToken, string: response.accessToken)

        // Spotify may return a new refresh token — if so, update it
        if let newRefreshToken = response.refreshToken {
            KeychainHelper.save(key: Keys.refreshToken, string: newRefreshToken)
        }

        let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        tokenExpiryDate = expiry
        KeychainHelper.save(key: Keys.tokenExpiry, string: String(expiry.timeIntervalSince1970))
    }

    // MARK: - User Profile

    /// Fetch the authenticated user's display name.
    private func fetchUserProfile() async {
        guard let token = KeychainHelper.readString(key: Keys.accessToken) else { return }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let profile = try JSONDecoder().decode(UserProfile.self, from: data)
            userDisplayName = profile.displayName
            KeychainHelper.save(key: Keys.userName, string: profile.displayName ?? "Spotify User")
        } catch {
            logger.warning("Failed to fetch user profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Response Types

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct UserProfile: Decodable {
        let displayName: String?
        let id: String

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case id
        }
    }
}
