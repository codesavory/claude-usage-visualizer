import Foundation

struct OAuthUsageWindow: Sendable, Hashable, Codable {
    let utilization: Double   // 0–100
    let resetsAt: Date

    /// The reset time rolled forward onto the CURRENT window. Anthropic's weekly
    /// window resets on a fixed weekly grid and the 5-hour block every 5 hours,
    /// so a stale last-known reset can be projected onto the live window with no
    /// network call. This keeps the "resets in Xh · <clock>" countdown correct
    /// even when we only hold a last-known snapshot and no live token.
    func projectedReset(period: TimeInterval, now: Date = Date()) -> Date {
        guard resetsAt != .distantFuture, period > 0 else { return resetsAt }
        var r = resetsAt
        while r <= now { r = r.addingTimeInterval(period) }
        return r
    }

    /// How far through the current window we are, 0 to 1. Compared with
    /// `utilization` this says whether usage is ahead of or behind an even pace.
    func elapsedFraction(period: TimeInterval, now: Date = Date()) -> Double? {
        guard resetsAt != .distantFuture, period > 0 else { return nil }
        let remaining = projectedReset(period: period, now: now).timeIntervalSince(now)
        return min(1, max(0, 1 - remaining / period))
    }

    /// Short pace summary for the weekly indicator, for example "12% over pace".
    func paceLabel(period: TimeInterval, now: Date = Date()) -> String? {
        guard let elapsed = elapsedFraction(period: period, now: now) else { return nil }
        let delta = Int((utilization - elapsed * 100).rounded())
        if abs(delta) < 3 { return "on pace" }
        return delta > 0 ? "\(delta)% over pace" : "\(-delta)% under pace"
    }
}

/// Standard Anthropic window lengths, for projecting a stale reset forward.
enum UsageWindowPeriod {
    static let fiveHour: TimeInterval = 5 * 3600
    static let weekly: TimeInterval = 7 * 24 * 3600
}

struct OAuthUsageSnapshot: Sendable, Hashable, Codable {
    let fiveHour: OAuthUsageWindow
    let sevenDay: OAuthUsageWindow
    let sevenDaySonnet: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let fetchedAt: Date

    enum Staleness: Sendable, Hashable, Codable { case live, stale, rateLimited, unauthorized, unavailable, needsLogin }
    let status: Staleness

    /// True when the snapshot carries real usage numbers (a real reset time),
    /// regardless of how fresh it is. Used to keep showing the last-known
    /// numbers instead of a full-screen sign-in wall when the token lapses.
    var hasRealNumbers: Bool {
        fiveHour.resetsAt != .distantFuture
    }

    func withStatus(_ newStatus: Staleness) -> OAuthUsageSnapshot {
        OAuthUsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDaySonnet: sevenDaySonnet,
            sevenDayOpus: sevenDayOpus,
            fetchedAt: fetchedAt,
            status: newStatus
        )
    }
}

/// Decides what the iPhone shows. The Mac is the source of truth: it reads Claude
/// Code's own token and publishes both that token and the usage numbers over
/// iCloud. The phone shows whichever reading is newest and never needs a sign-in.
enum UsageSourcePicker {
    /// While the Mac's reading is this recent the phone doesn't call the endpoint
    /// too. The endpoint is rate limited and a second poller only earns 429s.
    static let macFreshFor: TimeInterval = 360
    /// A reading older than this is labelled stale rather than live.
    static let liveFor: TimeInterval = 900

    static func isFresh(_ mac: OAuthUsageSnapshot?, within: TimeInterval = macFreshFor, now: Date = .now) -> Bool {
        guard let mac, mac.hasRealNumbers else { return false }
        return now.timeIntervalSince(mac.fetchedAt) < within
    }

    /// `own` carries a failure status with a misleading `fetchedAt` when the token
    /// was rejected, so a failed own fetch never outranks a real Mac reading.
    static func pick(own: OAuthUsageSnapshot?, mac: OAuthUsageSnapshot?, now: Date = .now) -> OAuthUsageSnapshot? {
        let ownOK = own.flatMap { ($0.hasRealNumbers && ($0.status == .live || $0.status == .rateLimited)) ? $0 : nil }
        let macOK = mac.flatMap { $0.hasRealNumbers ? $0 : nil }
        if let ownOK, let macOK {
            return ownOK.fetchedAt >= macOK.fetchedAt ? ownOK : labelled(macOK, now: now)
        }
        if let ownOK { return ownOK }
        if let macOK { return labelled(macOK, now: now) }
        return own.flatMap { $0.hasRealNumbers ? $0.withStatus(.stale) : nil }
    }

    private static func labelled(_ s: OAuthUsageSnapshot, now: Date) -> OAuthUsageSnapshot {
        s.withStatus(now.timeIntervalSince(s.fetchedAt) < liveFor ? .live : .stale)
    }
}

/// Persists the last-known-good usage snapshot so the popover can show numbers
/// the instant it opens — before the first network poll, and even if that poll
/// fails because the token needs a re-sign-in. Without this the widget would
/// blank out to a sign-in wall whenever the grant lapsed, losing the numbers
/// the user wants to see even while idle.
enum UsageSnapshotStore {
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("ClaudeUsageVisualizer", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last_usage.json")
    }

    static func save(_ snapshot: OAuthUsageSnapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url)
    }

    /// Loads the last saved snapshot, marked `.stale` (it is by definition not a
    /// fresh reading). Returns nil when nothing was ever saved.
    static func load() -> OAuthUsageSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(OAuthUsageSnapshot.self, from: data),
              snap.hasRealNumbers else { return nil }
        return OAuthUsageSnapshot(
            fiveHour: snap.fiveHour,
            sevenDay: snap.sevenDay,
            sevenDaySonnet: snap.sevenDaySonnet,
            sevenDayOpus: snap.sevenDayOpus,
            fetchedAt: snap.fetchedAt,
            status: .stale
        )
    }
}
