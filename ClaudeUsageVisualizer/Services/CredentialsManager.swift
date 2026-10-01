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

    /// Drops the in-memory cache and re-reads the access token straight from
    /// disk, WITHOUT refreshing (so it never rotates the shared OAuth grant).
    /// Returns the disk token when one is present and not past expiry, else nil.
    ///
    /// This is the first recovery step on a 401: Claude Code (or a manual
    /// refresh) frequently writes a fresh, valid token to disk while the widget
    /// is still holding an older one in memory. Reading it back recovers the
    /// live numbers with zero risk of invalidating anyone's session. Only when
    /// the disk token is also gone/expired do we fall back to an actual refresh.
    func reloadValidTokenFromDisk(now: Date = .now) -> String? {
        cache = nil
        guard let envelope = try? PlainCredentialStore.read() else { return nil }
        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            return nil // on-disk token is itself expired; a refresh is required
        }
        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
    }

    /// Called by `OAuthUsageClient` on 401/403 as a LAST resort. Forces a refresh
    /// of the stored token; returns the new token, or nil when no usable token
    /// exists. Prefer `reloadValidTokenFromDisk` first — refreshing rotates the
    /// shared grant and can race Claude Code's own rotation.
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
        #if os(macOS)
        guard let creds = try? KeychainReader.readClaudeCredentials(allowInteraction: true) else {
            return nil
        }
        persist(accessToken: creds.accessToken, refreshToken: creds.refreshToken, expiresAt: creds.expiresAt)
        return creds.accessToken
        #else
        // iOS has no Claude Code keychain to borrow; sign-in is OAuth-only.
        return nil
        #endif
    }

    /// Silent variant of `adoptClaudeCodeToken`: reads Claude Code's keychain
    /// token WITHOUT ever raising the password prompt (`allowInteraction: false`).
    /// If the login keychain would need user presence it just returns nil and
    /// leaves any stored token untouched. Safe to call on every widget open —
    /// it refreshes the token opportunistically when the OS lets us read it, and
    /// is a silent no-op otherwise. The prompting path stays on the manual
    /// refresh button only.
    @discardableResult
    func adoptClaudeCodeTokenSilently() -> String? {
        #if os(macOS)
        guard let creds = try? KeychainReader.readClaudeCredentials(allowInteraction: false) else {
            return nil
        }
        persist(accessToken: creds.accessToken, refreshToken: creds.refreshToken, expiresAt: creds.expiresAt)
        return creds.accessToken
        #else
        return nil
        #endif
    }

    /// Persists a freshly obtained token from the optional OAuth sign-in, and
    /// publishes it to iCloud so the other device picks it up automatically.
    func storeOwnToken(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        persist(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    /// Pulls the token the other device published to iCloud and adopts it when
    /// it is fresher than what we hold locally (or we hold nothing). Returns
    /// true if a newer token was adopted. No-op without iCloud. Never pushes
    /// back, so it cannot loop with the other device.
    @discardableResult
    func syncFromICloudIfNewer(now: Date = .now) -> Bool {
        guard let remote = ICloudTokenSync.pull() else { return false }
        let local = try? PlainCredentialStore.read()
        if let local {
            if local.accessToken == remote.accessToken { return false }
            if !Self.isNewer(remote, than: local) { return false }
        }
        try? PlainCredentialStore.write(remote)
        cache = InMemoryCache(accessToken: remote.accessToken, expiresAt: remote.expiresAt)
        return true
    }

    /// Adopts a token written to the credentials file by an EXTERNAL writer (the
    /// Claude Code SessionStart hook, which copies Claude Code's keychain token
    /// in on every login) and publishes it to iCloud so the iPhone gets it too.
    /// Returns true when a different token was adopted. Called on each poll and
    /// on popover open so a hook-written token is picked up within one cycle.
    @discardableResult
    func adoptDiskIfNewerAndPush(now: Date = .now) -> Bool {
        guard let disk = try? PlainCredentialStore.read() else { return false }
        if let cache, cache.accessToken == disk.accessToken { return false }
        cache = InMemoryCache(accessToken: disk.accessToken, expiresAt: disk.expiresAt)
        ICloudTokenSync.push(disk)
        return true
    }

    private static func isNewer(
        _ a: BiometricCredentialStore.Envelope,
        than b: BiometricCredentialStore.Envelope
    ) -> Bool {
        if let au = a.updatedAt, let bu = b.updatedAt { return au > bu }
        if let ae = a.expiresAt, let be = b.expiresAt { return ae > be }
        return a.updatedAt != nil // remote stamped, local not -> prefer remote
    }

    /// Single write path: stamps `updatedAt`, writes the 0600 file, updates the
    /// in-memory cache, and publishes to iCloud for the other device.
    private func persist(accessToken: String, refreshToken: String?, expiresAt: Date?, now: Date = .now) {
        let env = BiometricCredentialStore.Envelope(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            updatedAt: now
        )
        try? PlainCredentialStore.write(env)
        cache = InMemoryCache(accessToken: accessToken, expiresAt: expiresAt)
        ICloudTokenSync.push(env)
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
            persist(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? refreshToken,
                expiresAt: token.expiresAt,
                now: now
            )
            return token.accessToken
        } catch {
            if case OAuthEndpoint.EndpointError.http(let code) = error, code == 400 || code == 401 {
                throw CredentialError.needsLogin
            }
            throw CredentialError.temporarilyUnavailable
        }
    }
}
