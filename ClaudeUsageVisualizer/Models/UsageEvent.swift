import Foundation

struct UsageEvent: Sendable, Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let sessionId: String
    let cwd: String
    let model: ClaudeModel
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    var costUSD: Double {
        model.pricing.cost(
            input: inputTokens,
            output: outputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens
        )
    }
}
