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
}
