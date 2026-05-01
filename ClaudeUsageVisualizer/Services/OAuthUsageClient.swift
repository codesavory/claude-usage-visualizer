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
    private var cached: OAuthUsageSnapshot?
    private var consecutive429s: Int = 0
    private var nextAllowedFetch: Date = .distantPast
    private let defaultTTL: TimeInterval = 360 // 6 minutes

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Returns the last-known snapshot. Does not trigger a network call.
    func lastKnown() -> OAuthUsageSnapshot? { cached }

    /// Fetches if the cache is empty or older than TTL. Safe to call frequently;
    /// returns the cached snapshot unchanged if we're inside the TTL or backoff
    /// window.
    func refreshIfNeeded(now: Date = .now) async -> OAuthUsageSnapshot? {
        if let cached, now.timeIntervalSince(cached.fetchedAt) < defaultTTL {
            return cached
        }
        if now < nextAllowedFetch {
            return cached
        }
        return await performFetch(now: now)
    }

    /// Force a fetch regardless of TTL (still respects backoff window).
    func forceRefresh(now: Date = .now) async -> OAuthUsageSnapshot? {
        if now < nextAllowedFetch { return cached }
        return await performFetch(now: now)
    }

    // MARK: - Private

    private func performFetch(now: Date) async -> OAuthUsageSnapshot? {
        let creds: KeychainReader.ClaudeCredentials
        do {
            creds = try KeychainReader.readClaudeCredentials()
        } catch {
            cached = OAuthUsageSnapshot(
                fiveHour: OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                sevenDay: OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                sevenDaySonnet: nil,
                sevenDayOpus: nil,
                fetchedAt: now,
                status: .unavailable
            )
            return cached
        }

        if let expiresAt = creds.expiresAt, expiresAt < now {
            // Token is expired. Claude Code refreshes it in the background
            // when the CLI runs; don't attempt refresh ourselves.
            cached = OAuthUsageSnapshot(
                fiveHour: cached?.fiveHour ?? OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                sevenDay: cached?.sevenDay ?? OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture),
                sevenDaySonnet: cached?.sevenDaySonnet,
                sevenDayOpus: cached?.sevenDayOpus,
                fetchedAt: cached?.fetchedAt ?? now,
                status: .unauthorized
            )
            return cached
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
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

            guard (200..<300).contains(http.statusCode) else {
                // Other error — keep cache, don't burn backoff
                return cached
            }

            consecutive429s = 0
            nextAllowedFetch = .distantPast

            if let snap = parseResponse(data, fetchedAt: now) {
                cached = snap
                return snap
            }
            return cached
        } catch {
            return cached
        }
    }

    private func parseResponse(_ data: Data, fetchedAt: Date) -> OAuthUsageSnapshot? {
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

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
