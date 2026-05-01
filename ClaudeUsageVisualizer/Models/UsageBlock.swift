import Foundation

struct TokenTotals: Sendable, Hashable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0
    var messages: Int = 0
    var costUSD: Double = 0

    var total: Int { input + output + cacheCreation + cacheRead }

    static func + (l: TokenTotals, r: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: l.input + r.input,
            output: l.output + r.output,
            cacheCreation: l.cacheCreation + r.cacheCreation,
            cacheRead: l.cacheRead + r.cacheRead,
            messages: l.messages + r.messages,
            costUSD: l.costUSD + r.costUSD
        )
    }

    mutating func add(_ event: UsageEvent) {
        input += event.inputTokens
        output += event.outputTokens
        cacheCreation += event.cacheCreationInputTokens
        cacheRead += event.cacheReadInputTokens
        messages += 1
        costUSD += event.costUSD
    }
}

struct UsageBlock: Sendable, Identifiable, Hashable {
    let id: UUID
    let startedAt: Date
    var totalsByModel: [ClaudeModel: TokenTotals]
    var eventCountBySession: [String: Int]

    var endsAt: Date { startedAt.addingTimeInterval(5 * 3600) }

    var totals: TokenTotals {
        totalsByModel.values.reduce(TokenTotals(), +)
    }

    var messageCount: Int { totals.messages }
    var totalCostUSD: Double { totals.costUSD }

    func timeRemaining(now: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    func contains(_ date: Date) -> Bool {
        date >= startedAt && date < endsAt
    }
}
