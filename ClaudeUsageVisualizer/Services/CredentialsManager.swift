import Foundation
import LocalAuthentication

/// Single source of truth for the OAuth access token used by `OAuthUsageClient`.
///
/// Steady-state (no password ever after first launch):
///   1. Return in-memory cache if still fresh.
///   2. Touch ID-read the biometric store, return token if fresh.
///   3. If expired, POST refresh_token → update biometric store → return new token.
///
/// Bootstrap (biometric store missing = first ever launch):
///   1. Read source `Claude Code-credentials` keychain — one password prompt.
///   2. Write envelope into biometric store. All future reads are Touch ID only.
///
/// 401/403 from the API:
///   Callers should call `forceTokenRefresh()`. It silently attempts an OAuth
///   refresh using the stored refresh_token. On failure it surfaces nothing —
///   the next scheduled poll will reflect the unauthorized state. The biometric
///   store is NEVER deleted here, so no password prompt is ever triggered.
actor CredentialsManager {
    private struct InMemoryCache {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cache: InMemoryCache?
    private let session: URLSession
    private let refreshEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let expiryGracePeriod: TimeInterval = 60

    enum CredentialError: Error {
        case noCredentials      // biometric store empty and no source fallback
        case userCancelled      // user dismissed the Touch ID / biometric prompt
        case refreshFailed      // OAuth refresh endpoint returned an error
        case biometryError      // Touch ID read failed for a non-user reason
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Returns a valid access token.
    ///
    /// Will trigger Touch ID when the in-memory cache is cold.
    /// Will trigger a password prompt ONLY on the very first launch
    /// (when the biometric store has never been written).
    func currentAccessToken(now: Date = .now) async throws -> String {
        // 1. Warm in-memory cache — no prompt at all.
        if let cache, let exp = cache.expiresAt, exp.timeIntervalSince(now) > expiryGracePeriod {
            return cache.accessToken
        }

        // 2. No biometrics on this Mac — fall back to source keychain once.
        guard BiometricCredentialStore.isBiometryAvailable() else {
            return try await bootstrapFromSource(now: now)
        }

        let context = BiometricCredentialStore.makeContext(reason: "Access your Claude Code OAuth token")

        // 3. Read biometric store (Touch ID prompt).
        let envelope: BiometricCredentialStore.Envelope
        do {
            envelope = try BiometricCredentialStore.read(context: context)
        } catch BiometricCredentialStore.StoreError.notFound {
            // First-ever launch: bootstrap from source (single password prompt).
            return try await bootstrapFromSource(now: now)
        } catch BiometricCredentialStore.StoreError.userCancelled {
            throw CredentialError.userCancelled
        } catch {
            // Read failure for any other reason — do NOT fall back to source keychain.
            throw CredentialError.biometryError
        }

        // 4. Token expired — try OAuth refresh. Do NOT fall back to source on failure.
        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            guard let refreshToken = envelope.refreshToken else {
                throw CredentialError.noCredentials
            }
            // throws CredentialError.refreshFailed on network/server error — propagates up,
            // caller surfaces an error state rather than prompting for a password.
            let refreshed = try await refresh(refreshToken: refreshToken, now: now)
            try? BiometricCredentialStore.write(refreshed, context: context)
            cache = InMemoryCache(accessToken: refreshed.accessToken, expiresAt: refreshed.expiresAt)
            return refreshed.accessToken
        }

        // 5. Token still fresh.
        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
    }

    /// Called by OAuthUsageClient on 401/403. Silently tries to obtain a fresh
    /// access token using the stored refresh_token and updates the biometric
    /// store in place. Never deletes the biometric store, never prompts for a
    /// password. Returns the new token on success, nil on failure.
    func forceTokenRefresh() async -> String? {
        guard BiometricCredentialStore.isBiometryAvailable() else { return nil }
        let context = BiometricCredentialStore.makeContext(reason: "Refresh your Claude Code OAuth token")
        guard
            let envelope = try? BiometricCredentialStore.read(context: context),
            let refreshToken = envelope.refreshToken
        else { return nil }

        guard let refreshed = try? await refresh(refreshToken: refreshToken, now: .now) else {
            return nil
        }
        try? BiometricCredentialStore.write(refreshed, context: context)
        cache = InMemoryCache(accessToken: refreshed.accessToken, expiresAt: refreshed.expiresAt)
        return refreshed.accessToken
    }

    /// Clears only the in-memory cache. Leaves the biometric store intact so
    /// the next call uses Touch ID rather than the source keychain.
    func clearMemoryCache() {
        cache = nil
    }

    // MARK: - Private

    private func bootstrapFromSource(now: Date) async throws -> String {
        let creds: KeychainReader.ClaudeCredentials
        do {
            creds = try KeychainReader.readClaudeCredentials()
        } catch {
            throw CredentialError.noCredentials
        }

        let envelope = BiometricCredentialStore.Envelope(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt
        )

        if BiometricCredentialStore.isBiometryAvailable() {
            let writeCtx = BiometricCredentialStore.makeContext(
                reason: "Save your Claude Code OAuth token for Touch ID access"
            )
            try? BiometricCredentialStore.write(envelope, context: writeCtx)
        }

        cache = InMemoryCache(accessToken: creds.accessToken, expiresAt: creds.expiresAt)
        return creds.accessToken
    }

    private func refresh(refreshToken: String, now: Date) async throws -> BiometricCredentialStore.Envelope {
        struct RequestBody: Encodable {
            let grant_type: String
            let refresh_token: String
            let client_id: String
        }
        struct ResponseBody: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            grant_type: "refresh_token",
            refresh_token: refreshToken,
            client_id: clientId
        ))

        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else { throw CredentialError.refreshFailed }

        let parsed = try JSONDecoder().decode(ResponseBody.self, from: data)
        let expiresAt = parsed.expires_in.map { now.addingTimeInterval(TimeInterval($0)) }
        return BiometricCredentialStore.Envelope(
            accessToken: parsed.access_token,
            refreshToken: parsed.refresh_token ?? refreshToken,
            expiresAt: expiresAt
        )
    }
}
