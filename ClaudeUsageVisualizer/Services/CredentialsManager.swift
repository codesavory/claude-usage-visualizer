import Foundation
import LocalAuthentication
import AppKit

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

        // 2. Biometric store (Touch ID prompt) when available. Best-effort:
        //    any failure EXCEPT an explicit user cancel falls through to the
        //    plain store. This covers ad-hoc-signed builds where the
        //    data-protection keychain rejects the read with
        //    errSecMissingEntitlement (-34018) rather than `notFound`. Without
        //    this fall-through the app would error out instead of using the
        //    plain store it already bootstrapped into.
        if BiometricCredentialStore.isBiometryAvailable() {
            let context = BiometricCredentialStore.makeContext(reason: "Access your Claude Code OAuth token")
            do {
                let envelope = try BiometricCredentialStore.read(context: context)
                return try await token(from: envelope, biometricContext: context, now: now)
            } catch BiometricCredentialStore.StoreError.userCancelled {
                throw CredentialError.userCancelled
            } catch {
                // notFound, missing entitlement, or any other keychain error —
                // fall through to the plain store / bootstrap.
            }
        }

        // 3. App-owned plain store (no prompt). Holds the token whenever the
        //    biometric write was unavailable or failed at bootstrap.
        if let envelope = try? PlainCredentialStore.read() {
            return try await token(from: envelope, biometricContext: nil, now: now)
        }

        // 4. First-ever launch: bootstrap from source (single password prompt).
        return try await bootstrapFromSource(now: now)
    }

    /// Returns a usable access token from a stored envelope, refreshing in place
    /// if it has expired. Writes any refreshed token back to the same store the
    /// envelope came from (biometric when `biometricContext` is non-nil, else
    /// the plain store). Never reads the source keychain.
    private func token(
        from envelope: BiometricCredentialStore.Envelope,
        biometricContext: LAContext?,
        now: Date
    ) async throws -> String {
        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            guard let refreshToken = envelope.refreshToken else {
                throw CredentialError.noCredentials
            }
            let refreshed = try await refresh(refreshToken: refreshToken, now: now)
            persist(refreshed, biometricContext: biometricContext)
            cache = InMemoryCache(accessToken: refreshed.accessToken, expiresAt: refreshed.expiresAt)
            return refreshed.accessToken
        }
        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
    }

    /// Writes back to whichever app-owned store the token came from.
    private func persist(_ envelope: BiometricCredentialStore.Envelope, biometricContext: LAContext?) {
        if let biometricContext {
            try? BiometricCredentialStore.write(envelope, context: biometricContext)
        } else {
            try? PlainCredentialStore.write(envelope)
        }
    }

    /// Called by OAuthUsageClient on 401/403. Silently tries to obtain a fresh
    /// access token using the stored refresh_token and updates the biometric
    /// store in place. Never deletes the biometric store, never prompts for a
    /// password. Returns the new token on success, nil on failure.
    func forceTokenRefresh() async -> String? {
        // Read the refresh token from whichever app-owned store holds it.
        var biometricContext: LAContext?
        var envelope: BiometricCredentialStore.Envelope?
        if BiometricCredentialStore.isBiometryAvailable() {
            let context = BiometricCredentialStore.makeContext(reason: "Refresh your Claude Code OAuth token")
            if let e = try? BiometricCredentialStore.read(context: context) {
                biometricContext = context
                envelope = e
            }
        }
        if envelope == nil {
            envelope = try? PlainCredentialStore.read()
        }
        guard let envelope, let refreshToken = envelope.refreshToken else { return nil }

        guard let refreshed = try? await refresh(refreshToken: refreshToken, now: .now) else {
            return nil
        }
        persist(refreshed, biometricContext: biometricContext)
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
        // This is an LSUIElement (menu-bar) app. A keychain prompt raised while
        // the app is a background accessory gets auto-cancelled by SecurityAgent
        // (errSecUserCanceled / -128) — the user's click never lands. Briefly
        // promote to a regular foreground app so the prompt is owned by an
        // active app and holds. IMPORTANT: do the activation on the main thread
        // but run the blocking SecItemCopyMatching OFF the main thread, so the
        // main run loop stays free to service the modal dialog.
        await MainActor.run {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        defer {
            Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
        }

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

        // Persist into an app-owned store so the source item is NEVER read
        // again. Prefer the Touch ID-gated store; if biometry is unavailable or
        // its write fails, fall back to the plain store. Either way the source
        // keychain (the login-password prompt) is touched at most once ever.
        var storedInBiometry = false
        if BiometricCredentialStore.isBiometryAvailable() {
            let writeCtx = BiometricCredentialStore.makeContext(
                reason: "Save your Claude Code OAuth token for Touch ID access"
            )
            do {
                try BiometricCredentialStore.write(envelope, context: writeCtx)
                storedInBiometry = true
            } catch {
                // Ad-hoc builds can't use the data-protection keychain
                // (errSecMissingEntitlement / -34018); fall back to the plain
                // store below.
                storedInBiometry = false
            }
        }
        if !storedInBiometry {
            try? PlainCredentialStore.write(envelope)
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
