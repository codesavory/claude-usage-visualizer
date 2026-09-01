import Foundation

/// Polls Anthropic's unofficial /api/oauth/usage endpoint to get the exact
/// percentage shown by Claude Code's `/usage` command. Cached aggressively
/// (default 6 min TTL) with exponential backoff on 429s, since the endpoint
/// is rate-limited and also powers the real /usage call.
///
/// NOTE: This uses the OAuth token issued to Claude Code. Anthropic considers
/// the token for first-party client use; read the Claude ToS if distributing.
actor OAuthUsageClient {
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    private let credentials: CredentialsManager
    private var cached: OAuthUsageSnapshot?
    private var consecutive429s: Int = 0
    private var nextAllowedFetch: Date = .distantPast
    private let defaultTTL: TimeInterval = 360 // 6 minutes

    init(credentials: CredentialsManager = CredentialsManager()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.credentials = credentials
    }

    /// Returns the last-known snapshot. Does not trigger a network call.
    func lastKnown() -> OAuthUsageSnapshot? { cached }

    /// Seeds the in-memory cache from a persisted snapshot at launch, so a failed
    /// first poll (e.g. the token needs a re-sign-in) preserves the last-known
    /// numbers instead of blanking out. Only fills an empty cache.
    func seed(_ snapshot: OAuthUsageSnapshot) {
        if cached == nil { cached = snapshot }
    }

    /// Fetches if the cache is empty or older than TTL. Safe to call frequently.
    func refreshIfNeeded(now: Date = .now) async -> OAuthUsageSnapshot? {
        if let cached, now.timeIntervalSince(cached.fetchedAt) < defaultTTL {
            return cached
        }
        if now < nextAllowedFetch { return cached }
        return await performFetch(now: now)
    }

    /// Force a fetch regardless of TTL (still respects backoff window).
    func forceRefresh(now: Date = .now) async -> OAuthUsageSnapshot? {
        if now < nextAllowedFetch { return cached }
        return await performFetch(now: now)
    }

    /// Open/foreground refresh: opportunistically pull Claude Code's keychain
    /// token WITHOUT prompting, then fetch the latest usage. Always runs the
    /// fetch (clears the backoff) so opening the widget shows current numbers.
    /// Never raises the password prompt — that stays on the manual refresh path.
    func refreshOnAppear(now: Date = .now) async -> OAuthUsageSnapshot? {
        await credentials.adoptClaudeCodeTokenSilently()
        nextAllowedFetch = .distantPast
        return await performFetch(now: now)
    }

    /// Manual-refresh shortcut: adopt Claude Code's keychain token (raises the
    /// laptop password prompt) and then fetch immediately. Clears the backoff
    /// window so the fetch always runs. Returns `cached` unchanged if the user
    /// cancels the password prompt or the keychain item is missing.
    func adoptClaudeCodeTokenAndRefresh(now: Date = .now) async -> OAuthUsageSnapshot? {
        guard await credentials.adoptClaudeCodeToken() != nil else { return cached }
        consecutive429s = 0
        nextAllowedFetch = .distantPast
        return await performFetch(now: now)
    }

    // MARK: - Private

    private func performFetch(now: Date, isRetry: Bool = false) async -> OAuthUsageSnapshot? {
        let accessToken: String
        do {
            accessToken = try await credentials.currentAccessToken(now: now)
        } catch {
            // No usable token. A genuinely dead refresh token surfaces as
            // `needsLogin` so the UI can offer sign-in; anything transient stays
            // `unavailable`. Either way, if we already hold real numbers (seeded
            // from disk or a prior live poll), keep them and only mark the
            // freshness — never blank out to a sign-in wall over a lapse.
            let status: OAuthUsageSnapshot.Staleness =
                (error as? CredentialsManager.CredentialError) == .needsLogin ? .needsLogin : .unavailable
            if let prior = cached, prior.hasRealNumbers {
                cached = OAuthUsageSnapshot(
                    fiveHour: prior.fiveHour,
                    sevenDay: prior.sevenDay,
                    sevenDaySonnet: prior.sevenDaySonnet,
                    sevenDayOpus: prior.sevenDayOpus,
                    fetchedAt: prior.fetchedAt,
                    status: status
                )
            } else {
                cached = OAuthUsageSnapshot(
                    fiveHour: OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                    sevenDay: OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                    sevenDaySonnet: nil,
                    sevenDayOpus: nil,
                    fetchedAt: now,
                    status: status
                )
            }
            return cached
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return cached }

            if http.statusCode == 429 {
                consecutive429s = min(consecutive429s + 1, 8)
                let delay = min(1800.0, 60.0 * pow(2.0, Double(consecutive429s - 1)))
                nextAllowedFetch = now.addingTimeInterval(delay)
                if let cached {
                    self.cached = OAuthUsageSnapshot(
                        fiveHour: cached.fiveHour,
                        sevenDay: cached.sevenDay,
                        sevenDaySonnet: cached.sevenDaySonnet,
                        sevenDayOpus: cached.sevenDayOpus,
                        fetchedAt: cached.fetchedAt,
                        status: .rateLimited
                    )
                }
                return self.cached
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                if !isRetry {
                    // Try a silent token refresh (Touch ID, no password). If it
                    // yields a new token, retry the fetch once.
                    if let _ = await credentials.forceTokenRefresh() {
                        return await performFetch(now: now, isRetry: true)
                    }
                }
                // Refresh either failed or we already retried — surface unauthorized.
                cached = OAuthUsageSnapshot(
                    fiveHour: cached?.fiveHour ?? OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                    sevenDay: cached?.sevenDay ?? OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                    sevenDaySonnet: cached?.sevenDaySonnet,
                    sevenDayOpus: cached?.sevenDayOpus,
                    fetchedAt: now,
                    status: .unauthorized
                )
                return cached
            }

            guard (200..<300).contains(http.statusCode) else { return cached }

            consecutive429s = 0
            nextAllowedFetch = .distantPast

            if let snap = Self.parseResponse(data, fetchedAt: now) {
                cached = snap
                return snap
            }
            return cached
        } catch {
            return cached
        }
    }

    static func parseResponse(_ data: Data, fetchedAt: Date) -> OAuthUsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func window(_ key: String) -> OAuthUsageWindow? {
            guard let d = obj[key] as? [String: Any] else { return nil }
            let util = (d["utilization"] as? Double)
                ?? (d["utilization"] as? Int).map(Double.init)
                ?? 0
            let resetsStr = d["resets_at"] as? String ?? d["resetsAt"] as? String ?? ""
            let resets = Self.parseDate(resetsStr) ?? .distantFuture
            return OAuthUsageWindow(utilization: util, resetsAt: resets)
        }

        let five = window("five_hour") ?? window("fiveHour")
        let seven = window("seven_day") ?? window("sevenDay")
        guard let five, let seven else { return nil }

        return OAuthUsageSnapshot(
            fiveHour: five,
            sevenDay: seven,
            sevenDaySonnet: window("seven_day_sonnet") ?? window("weekly_sonnet"),
            sevenDayOpus: window("seven_day_opus") ?? window("weekly_opus"),
            fetchedAt: fetchedAt,
            status: .live
        )
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
