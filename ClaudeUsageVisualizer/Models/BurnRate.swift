import Foundation

struct BurnRate: Sendable, Hashable {
    enum Severity: Sendable, Hashable { case chill, warm, hot, critical }

    let tokensPerMinute: Double
    let messagesPerMinute: Double
    let projectedBlockExhaustion: Date?
    let severity: Severity

    static let idle = BurnRate(
        tokensPerMinute: 0,
        messagesPerMinute: 0,
        projectedBlockExhaustion: nil,
        severity: .chill
    )

    static func severity(forTokensPerMinute tpm: Double,
                         warmThreshold: Double = 2000,
                         hotThreshold: Double = 8000,
                         criticalThreshold: Double = 20000) -> Severity {
        if tpm >= criticalThreshold { return .critical }
        if tpm >= hotThreshold { return .hot }
        if tpm >= warmThreshold { return .warm }
        return .chill
    }
}

enum StatusIconState: Sendable, Hashable {
    case chill, warm, hot, critical, offline
    // Fainted "XO" state: signed out of Claude, or the session budget is fully spent
    // (100%) with no usage credits enabled. Rendered as a dead-Pokemon "XO" face.
    case dead
}
