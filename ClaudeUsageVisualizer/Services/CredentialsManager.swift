import Foundation

/// Source of the OAuth access token used by `OAuthUsageClient`, for the EXACT
/// usage numbers. This is now entirely OPTIONAL: the widget shows a local
/// transcript-based estimate with no auth at all, and only overlays the exact
/// server numbers when a valid token happens to be present.
///
/// The token lives in the app-owned file store (`PlainCredentialStore`, a 0600
/// file). We never read Claude Code's keychain item — Claude Code owns and
/// rewrites that item, which wipes our access grant and re-triggers the
/// login-password prompt, so borrowing it is fundamentally unreliable. And we
/// never block the UI on auth: a missing or dead token just means "no exact
/// number right now", and the widget falls back to the local estimate silently.
actor CredentialsManager {
    private struct InMemoryCache {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cache: InMemoryCache?
    private let expiryGracePeriod: TimeInterval = 60

    enum CredentialError: Error, Equatable {
        case needsLogin              // no stored token, or the refresh token is dead
        case temporarilyUnavailable // a transient refresh failure; the stored token is still good
    }

    init() {}

    /// Returns a valid access token, refreshing silently if needed. Throws
    /// `needsLogin` when no usable token exists. Never prompts, never blocks.
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
    /// token, or nil when no usable token exists.
    func forceTokenRefresh() async -> String? {
        cache = nil
        guard let envelope = try? PlainCredentialStore.read() else { return nil }
        return try? await refreshStoredToken(envelope, now: .now)
    }

    /// Adopts Claude Code's OWN OAuth token straight from the login keychain
    /// (`Claude Code-credentials`). This is the shortcut that replaces the whole
    /// browser sign-in routine: the user types their laptop (login-keychain)
    /// password once, macOS hands over the token, and we cache + persist it so
    /// `OAuthUsageClient` can read the exact server numbers.
    ///
    /// This raises the macOS login-keychain password prompt (this app is not in
    /// that item's ACL), so ONLY call it from an explicit user action such as a
    /// manual refresh — never on a background poll. Returns the access token on
    /// success, or nil if the item is missing or the user cancelled the prompt.
    func adoptClaudeCodeToken() -> String? {
        guard let creds = try? KeychainReader.readClaudeCredentials(allowInteraction: true) else {
            return nil
        }
        let envelope = BiometricCredentialStore.Envelope(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt
        )
        try? PlainCredentialStore.write(envelope)
        cache = InMemoryCache(accessToken: creds.accessToken, expiresAt: creds.expiresAt)
        return creds.accessToken
    }

    /// Persists a freshly obtained token from the optional OAuth sign-in.
    func storeOwnToken(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        let envelope = BiometricCredentialStore.Envelope(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
        try? PlainCredentialStore.write(envelope)
        cache = InMemoryCache(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// True when a token is stored.
    func hasStoredToken() -> Bool {
        (try? PlainCredentialStore.read()) != nil
    }

    /// Clears the in-memory cache only.
    func clearMemoryCache() {
        cache = nil
    }

    /// Forgets the stored token entirely (sign-out).
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
                refreshToken: token.refreshToken ?? refreshToken,
                expiresAt: token.expiresAt
            )
            try? PlainCredentialStore.write(stored)
            cache = InMemoryCache(accessToken: token.accessToken, expiresAt: token.expiresAt)
            return token.accessToken
        } catch {
            if case OAuthEndpoint.EndpointError.http(let code) = error, code == 400 || code == 401 {
                throw CredentialError.needsLogin
            }
            throw CredentialError.temporarilyUnavailable
        }
    }
}
