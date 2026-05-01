import Foundation

struct OAuthUsageWindow: Sendable, Hashable {
    let utilization: Double   // 0–100
    let resetsAt: Date
}

struct OAuthUsageSnapshot: Sendable, Hashable {
    let fiveHour: OAuthUsageWindow
    let sevenDay: OAuthUsageWindow
    let sevenDaySonnet: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let fetchedAt: Date

    enum Staleness: Sendable, Hashable { case live, stale, rateLimited, unauthorized, unavailable }
    let status: Staleness
}
