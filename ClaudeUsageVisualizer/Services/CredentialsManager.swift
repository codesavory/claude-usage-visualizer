import Foundation
import LocalAuthentication
import AppKit

/// Single source of truth for the OAuth access token used by `OAuthUsageClient`.
///
/// The token belongs to Claude Code, which stores it in the shared
/// `Claude Code-credentials` keychain item. Claude Code and this app therefore
/// hold the SAME refresh token, and Anthropic rotates refresh tokens per use:
/// whoever refreshes first invalidates the other's copy. Claude Code is the
/// live CLI and refreshes constantly, so this app must NEVER call the refresh
/// endpoint itself — doing so would rotate the shared token and break Claude
/// Code's auth, forcing the user to log in again. Instead it only ever reads
/// the source item, which Claude Code keeps refreshed for us.
///
/// Steady-state (no password after first launch):
///   1. Return in-memory cache if still fresh.
///   2. Touch ID-read the app's own store; return the token if still fresh.
///   3. If expired, re-read the source item (silent when its ACL trusts this
///      app) to pick up Claude Code's current, freshly rotated token.
///
/// First-ever launch: read the source item — one password prompt — then copy
/// it into the app's own store.
///
/// 401/403 from the API: callers call `forceTokenRefresh()`, which re-reads the
/// source item. No password prompt is triggered in steady state.
actor CredentialsManager {
    private struct InMemoryCache {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cache: InMemoryCache?
    private let expiryGracePeriod: TimeInterval = 60

    /// When the last source-keychain read actually FAILED. Only a failed read
    /// starts the cooldown: a successful read is silent (the source item's ACL
    /// trusts this app) and must stay unlimited, because Claude Code rotates the
    /// shared token several times an hour and each rotation invalidates our copy
    /// — we have to be free to re-copy on the very next poll. The cooldown
    /// exists only to stop a genuinely unreadable source (signed out of Claude
    /// Code) from prompt-storming.
    private var lastFailedBootstrap: Date = .distantPast
    private let bootstrapCooldown: TimeInterval = 3600

    enum CredentialError: Error {
        case noCredentials      // app store empty and source unreadable
        case userCancelled      // user dismissed the Touch ID / biometric prompt
        case biometryError      // Touch ID read failed for a non-user reason
    }

    init() {}

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
                return try await token(from: envelope, now: now)
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
            return try await token(from: envelope, now: now)
        }

        // 4. First-ever launch: bootstrap from source (single password prompt).
        return try await bootstrapFromSource(now: now)
    }

    /// Returns a usable access token from a stored envelope. When the token has
    /// expired we do NOT refresh it — the refresh token is shared with Claude
    /// Code and rotating it would break the CLI's auth — we re-read the source
    /// item instead, which Claude Code keeps refreshed.
    private func token(
        from envelope: BiometricCredentialStore.Envelope,
        now: Date
    ) async throws -> String {
        if let exp = envelope.expiresAt, exp.timeIntervalSince(now) <= expiryGracePeriod {
            return try await bootstrapFromSource(now: now)
        }
        cache = InMemoryCache(accessToken: envelope.accessToken, expiresAt: envelope.expiresAt)
        return envelope.accessToken
    }

    /// Called by OAuthUsageClient on 401/403. The stored access token was
    /// rejected, so re-read the source for Claude Code's current one. Never
    /// rotates the shared refresh token. Returns the new token, or nil.
    func forceTokenRefresh() async -> String? {
        cache = nil
        return try? await bootstrapFromSource(now: .now)
    }

    /// Clears only the in-memory cache. Leaves the app-owned store intact so
    /// the next call uses Touch ID rather than the source keychain.
    func clearMemoryCache() {
        cache = nil
    }

    // MARK: - Private

    /// Re-reads the shared `Claude Code-credentials` item and copies it into the
    /// app's own store. In steady state the source item's ACL trusts this app
    /// (stable code signature), so the read is silent — and because Claude Code
    /// invalidates our copy every time it rotates the shared token, this must be
    /// free to run on every poll. Only a read that would need a password prompt
    /// is rate-limited, via the foregrounded fallback below.
    private func bootstrapFromSource(now: Date) async throws -> String {
        // Silent path: no prompt, no foregrounding, no rate limit. Succeeds
        // whenever the ACL already trusts us — the common case after first launch.
        if let creds = try? KeychainReader.readClaudeCredentials(allowInteraction: false) {
            return persistBootstrapped(creds)
        }

        // The silent read failed — the source needs a password prompt (never
        // granted access, or the ACL was wiped). Rate-limit this so a genuinely
        // unreadable source (signed out of Claude Code) can't prompt-storm.
        guard now.timeIntervalSince(lastFailedBootstrap) >= bootstrapCooldown else {
            throw CredentialError.noCredentials
        }

        // This is an LSUIElement (menu-bar) app. A keychain prompt raised while
        // the app is a background accessory gets auto-cancelled by SecurityAgent
        // (errSecUserCanceled / -128) — the user's click never lands. Briefly
        // promote to a regular foreground app so the prompt is owned by an
        // active app and holds.
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
            lastFailedBootstrap = now
            throw CredentialError.noCredentials
        }
        return persistBootstrapped(creds)
    }

    /// Copies freshly-read source credentials into the app's own store and warms
    /// the in-memory cache. Prefers the Touch ID-gated store; falls back to the
    /// plain store when biometry is unavailable or its write fails.
    private func persistBootstrapped(_ creds: KeychainReader.ClaudeCredentials) -> String {
        let envelope = BiometricCredentialStore.Envelope(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt
        )

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
}
