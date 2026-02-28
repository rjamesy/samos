import Foundation

/// Manages OAuth2 authentication for Google APIs.
final class GoogleAuthService: @unchecked Sendable {
    private let settings: SettingsStoreProtocol
    private var accessToken: String?
    private var tokenExpiry: Date?

    init(settings: SettingsStoreProtocol) {
        self.settings = settings
    }

    /// Get a valid access token, refreshing if needed.
    func getAccessToken() async throws -> String {
        // Check for stored token
        let stored = settings.string(forKey: SettingsKey.gmailOAuthToken) ?? ""
        guard !stored.isEmpty else {
            throw GmailError.notAuthenticated
        }

        // If we have a cached token that hasn't expired, use it
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date() {
            return token
        }

        // Use stored token (in production, this would be a refresh token flow)
        accessToken = stored
        tokenExpiry = Date().addingTimeInterval(3600) // Assume 1 hour validity
        return stored
    }

    /// Check if authenticated.
    var isAuthenticated: Bool {
        !(settings.string(forKey: SettingsKey.gmailOAuthToken) ?? "").isEmpty
    }

    /// Clear stored credentials.
    func signOut() {
        accessToken = nil
        tokenExpiry = nil
        settings.setString("", forKey: SettingsKey.gmailOAuthToken)
    }
}
