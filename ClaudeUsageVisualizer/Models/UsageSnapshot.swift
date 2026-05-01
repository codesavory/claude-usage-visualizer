import Foundation

struct UsageSnapshot: Sendable {
    let currentBlock: UsageBlock?
    let previousBlocks: [UsageBlock]
    let burn: BurnRate
    let sessions: [SessionInfo]
    let weeklyTotals: TokenTotals
    let generatedAt: Date

    static let empty = UsageSnapshot(
        currentBlock: nil,
        previousBlocks: [],
        burn: .idle,
        sessions: [],
        weeklyTotals: TokenTotals(),
        generatedAt: Date()
    )
}
