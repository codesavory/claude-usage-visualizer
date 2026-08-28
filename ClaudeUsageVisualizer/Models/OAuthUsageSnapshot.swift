import Foundation

struct OAuthUsageWindow: Sendable, Hashable, Codable {
    let utilization: Double   // 0–100
    let resetsAt: Date
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
