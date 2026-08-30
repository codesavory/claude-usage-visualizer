import Foundation

/// Source of the OAuth access token used by `OAuthUsageClient`.
///
/// macOS: reads Claude Code's own token straight from its login-keychain item
/// (`Claude Code-credentials`). Claude Code keeps that token refreshed on its
/// own and it carries the `user:profile` scope the usage endpoint requires, so
/// the widget never has to run or maintain a login of its own. The read is
/// silent after a one-time "Always Allow" (the app is stable-signed, so it stays
/// in the item's ACL across rebuilds). The widget only ever READS — it never
/// writes or refreshes Claude Code's token, so it cannot disturb the CLI's
/// session.
///
/// Why not our own grant: a token minted by the widget shares Claude Code's
/// public OAuth client, and Anthropic revokes it within a day; a long-lived
/// `setup-token` is scoped for inference only and gets 403 on the usage
/// endpoint. Borrowing Claude Code's already-fresh token is the only durable,
/// correctly-scoped source.
///
/// iOS: there is no Claude Code keychain to borrow from, so the app keeps its
/// own token (file store + OAuth refresh) as before.
actor CredentialsManager {
    private struct InMemoryCache {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cache: InMemoryCache?
    private let expiryGracePeriod: TimeInterval = 60

    enum CredentialError: Error, Equatable {
        case needsLogin              // no token available (macOS: keychain read denied / Claude Code signed out)
        case temporarilyUnavailable // a transient refresh failure (iOS); the stored token is still good
    }

    init() {}

    /// Returns a valid access token. Never prompts after the one-time keychain
    /// grant on macOS. Throws `needsLogin` when no token can be read.
    func currentAccessToken(now: Date = .now) async throws -> String {
        if let cache, let exp = cache.expiresAt, exp.timeIntervalSince(now) > expiryGracePeriod {
            return cache.accessToken
        }

        #if os(macOS)
        // Read Claude Code's fresh token. Even if it is momentarily past its
        // expiry (Claude Code refreshes in place), return it: a stale token just
        // yields one 401 and the next read picks up the refreshed one. We must
        // not refresh it ourselves.
        guard let creds = try? KeychainReader.readClaudeCredentials(allowInteraction: true) else {
            throw CredentialError.needsLogin
        }
        cache = InMemoryCache(accessToken: creds.accessToken, expiresAt: creds.expiresAt)
        return creds.accessToken
        #else
        guard let envelope = try? PlainCredentialStore.read() else {
            throw CredentialError.needsLogin
        }
        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            return try await refreshStoredToken(envelope, now: now)
        }
        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
        #endif
    }

    /// Called by `OAuthUsageClient` on 401/403. On macOS this just re-reads the
    /// keychain, in case Claude Code has rotated its token in place. Returns the
    /// token, or nil when sign-in is required.
    func forceTokenRefresh() async -> String? {
        cache = nil
        #if os(macOS)
        guard let creds = try? KeychainReader.readClaudeCredentials(allowInteraction: true) else { return nil }
        cache = InMemoryCache(accessToken: creds.accessToken, expiresAt: creds.expiresAt)
        return creds.accessToken
        #else
        guard let envelope = try? PlainCredentialStore.read() else { return nil }
        return try? await refreshStoredToken(envelope, now: .now)
        #endif
    }

    /// True when a token can be read right now (macOS: Claude Code is signed in
    /// and the keychain read is permitted; iOS: a token is stored).
    func hasStoredToken() -> Bool {
        #if os(macOS)
        return (try? KeychainReader.readClaudeCredentials(allowInteraction: true)) != nil
        #else
        return (try? PlainCredentialStore.read()) != nil
        #endif
    }

    /// Clears the in-memory cache only.
    func clearMemoryCache() {
        cache = nil
    }

    /// Persists a freshly obtained token from the OAuth sign-in. Used by the iOS
    /// sign-in; on macOS the widget reads Claude Code's token instead, so this is
    /// never called there (kept compiled because the login service is shared).
    func storeOwnToken(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        let envelope = BiometricCredentialStore.Envelope(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
        try? PlainCredentialStore.write(envelope)
        cache = InMemoryCache(accessToken: accessToken, expiresAt: expiresAt)
    }

    /// iOS only: forgets the stored token (sign-out).
    func signOut() {
        cache = nil
        PlainCredentialStore.delete()
    }

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
