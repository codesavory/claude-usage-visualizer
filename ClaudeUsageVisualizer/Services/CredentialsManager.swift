import Foundation
import LocalAuthentication

/// Single source of truth for the OAuth access token used by `OAuthUsageClient`.
///
/// Steady state:
///   1. Touch ID-read the cached envelope from `BiometricCredentialStore`.
///   2. If access token is fresh, return it.
///   3. If expired, POST refresh_token to Anthropic OAuth endpoint, update store.
///
/// Bootstrap (first launch, biometric store wiped, or refresh failure):
///   1. Read source `Claude Code-credentials` keychain item (one password prompt).
///   2. Copy envelope into biometric store. Subsequent reads are Touch ID only.
///
/// On 401 from `/api/oauth/usage`, callers should call `invalidate()` to wipe the
/// biometric store so the next access bootstraps fresh.
actor CredentialsManager {
    private struct InMemoryCache {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cache: InMemoryCache?
    private let session: URLSession
    private let refreshEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Public Claude Code OAuth client_id (visible in browser dev tools during
    /// the `claude login` flow). Reverse-engineered, may break if Anthropic
    /// rotates it — caller falls back to source-keychain bootstrap on failure.
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let expiryGracePeriod: TimeInterval = 60

    enum CredentialError: Error {
        case noCredentials
        case userCancelled
        case refreshFailed
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Returns a valid access token. May trigger Touch ID (steady state) or a
    /// keychain password prompt (bootstrap / fallback).
    func currentAccessToken(now: Date = .now) async throws -> String {
        if let cache, let exp = cache.expiresAt, exp.timeIntervalSince(now) > expiryGracePeriod {
            return cache.accessToken
        }

        guard BiometricCredentialStore.isBiometryAvailable() else {
            return try await bootstrapFromSource(now: now)
        }

        let context = BiometricCredentialStore.makeContext(reason: "Access your Claude Code OAuth token")

        let envelope: BiometricCredentialStore.Envelope
        do {
            envelope = try BiometricCredentialStore.read(context: context)
        } catch BiometricCredentialStore.StoreError.notFound {
            return try await bootstrapFromSource(now: now)
        } catch BiometricCredentialStore.StoreError.userCancelled {
            throw CredentialError.userCancelled
        } catch {
            return try await bootstrapFromSource(now: now)
        }

        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            guard let refreshToken = envelope.refreshToken else {
                return try await bootstrapFromSource(now: now)
            }
            do {
                let refreshed = try await refresh(refreshToken: refreshToken, now: now)
                try? BiometricCredentialStore.write(refreshed, context: context)
                cache = InMemoryCache(accessToken: refreshed.accessToken, expiresAt: refreshed.expiresAt)
                return refreshed.accessToken
            } catch {
                return try await bootstrapFromSource(now: now)
            }
        }

        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
    }

    /// Wipes in-memory + biometric cache. Next read bootstraps from source.
    /// Call when the API returns 401/403, indicating the cached token is no
    /// longer valid even after refresh.
    func invalidate() {
        cache = nil
        BiometricCredentialStore.delete()
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
        let body = RequestBody(
            grant_type: "refresh_token",
            refresh_token: refreshToken,
            client_id: clientId
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw CredentialError.refreshFailed
        }

        let parsed: ResponseBody
        do {
            parsed = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw CredentialError.refreshFailed
        }

        let expiresAt = parsed.expires_in.map { now.addingTimeInterval(TimeInterval($0)) }
        return BiometricCredentialStore.Envelope(
            accessToken: parsed.access_token,
            refreshToken: parsed.refresh_token ?? refreshToken,
            expiresAt: expiresAt
        )
    }
}
