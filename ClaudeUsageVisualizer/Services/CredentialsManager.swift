import Foundation

/// Single source of truth for the OAuth access token used by `OAuthUsageClient`.
///
/// Re-architected: the token is the widget's OWN grant, obtained via
/// `OAuthLoginService` (interactive sign-in) and stored in the app-owned
/// `PlainCredentialStore`. The app created that keychain item, so reading it is
/// always silent — no login-password prompt, no Touch ID. Because the grant is
/// independent of Claude Code, the widget refreshes it freely without ever
/// touching (or invalidating) the CLI's session.
///
/// Steady state (no prompt of any kind):
///   1. Return the in-memory cache while fresh.
///   2. Read the app-owned store (silent).
///   3. If the access token expired, refresh it with our own refresh token.
///   4. If there is no stored token, or the refresh token is dead, report
///      `needsLogin` so the UI can offer a one-time sign-in.
actor CredentialsManager {
    private struct InMemoryCache {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cache: InMemoryCache?
    private let expiryGracePeriod: TimeInterval = 60

    enum CredentialError: Error, Equatable {
        case needsLogin   // no stored token, or the refresh token is no longer valid
    }

    init() {}

    /// Returns a valid access token, refreshing silently if needed. Throws
    /// `needsLogin` when interactive sign-in is required. Never prompts.
    func currentAccessToken(now: Date = .now) async throws -> String {
        if let cache, let exp = cache.expiresAt, exp.timeIntervalSince(now) > expiryGracePeriod {
            return cache.accessToken
        }

        guard let envelope = try? PlainCredentialStore.read() else {
            throw CredentialError.needsLogin
        }

        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            return try await refreshStoredToken(envelope, now: now)
        }
        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
    }

    /// Called by `OAuthUsageClient` on 401/403. Forces a refresh; returns the new
    /// token, or nil when sign-in is required.
    func forceTokenRefresh() async -> String? {
        cache = nil
        guard let envelope = try? PlainCredentialStore.read() else { return nil }
        return try? await refreshStoredToken(envelope, now: .now)
    }

    /// Persists a freshly obtained token (from `OAuthLoginService`) and warms the
    /// in-memory cache.
    func storeOwnToken(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        let envelope = BiometricCredentialStore.Envelope(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
        try? PlainCredentialStore.write(envelope)
        cache = InMemoryCache(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// True when a token is stored, so the UI can distinguish "never signed in"
    /// from a transient fetch failure.
    func hasStoredToken() -> Bool {
        (try? PlainCredentialStore.read()) != nil
    }

    /// Clears the in-memory cache only. Leaves the stored token intact.
    func clearMemoryCache() {
        cache = nil
    }

    /// Forgets the stored token entirely (used when the user signs out).
    func signOut() {
        cache = nil
        PlainCredentialStore.delete()
    }

    // MARK: - Private

    private func refreshStoredToken(
        _ envelope: BiometricCredentialStore.Envelope,
        now: Date
    ) async throws -> String {
        guard let refreshToken = envelope.refreshToken else {
            throw CredentialError.needsLogin
        }
        do {
            let token = try await OAuthEndpoint.refresh(refreshToken: refreshToken, now: now)
            let stored = BiometricCredentialStore.Envelope(
                accessToken: token.accessToken,
                // Anthropic rotates the refresh token; keep the new one, and fall
                // back to the old one if the response omitted it.
                refreshToken: token.refreshToken ?? refreshToken,
                expiresAt: token.expiresAt
            )
            try? PlainCredentialStore.write(stored)
            cache = InMemoryCache(accessToken: token.accessToken, expiresAt: token.expiresAt)
            return token.accessToken
        } catch {
            // A dead refresh token means the user must sign in again.
            throw CredentialError.needsLogin
        }
    }
}
