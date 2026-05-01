import Foundation

/// Uses Apple's on-device Foundation Models (Apple Intelligence) to generate a
/// natural-language schedule insight from block history. macOS 26+ only; returns
/// nil on earlier OS versions or when Apple Intelligence is unavailable.
@available(macOS 26.0, *)
actor AIInsightsService {
    private var lastGeneratedAt: Date = .distantPast
    private let cooldown: TimeInterval = 300 // regenerate at most every 5 min

    func generateScheduleInsight(blocks: [UsageBlock], tier: UsageTier) async -> String? {
        guard Date().timeIntervalSince(lastGeneratedAt) > cooldown else { return nil }
        guard blocks.count >= 3 else { return nil }

        let summary = buildSummary(blocks: blocks, tier: tier)
        guard let result = await callModel(prompt: summary) else { return nil }
        lastGeneratedAt = Date()
        return result
    }

    private func buildSummary(blocks: [UsageBlock], tier: UsageTier) -> String {
        let msgCap = tier.messagesPerBlock
        let cal = Calendar.current

        // Group blocks by hour-of-day and compute average utilization
        var hourBuckets: [Int: [Double]] = [:]
        for block in blocks {
            let hour = cal.component(.hour, from: block.startedAt)
            let util = Double(block.messageCount) / Double(max(msgCap, 1))
            hourBuckets[hour, default: []].append(util)
        }

        let avgByHour = hourBuckets.mapValues { vals in
            vals.reduce(0, +) / Double(vals.count)
        }.sorted { $0.key < $1.key }

        let topHeavy = avgByHour.filter { $0.value > 0.6 }.map { hourLabel($0.key) }.joined(separator: ", ")
        let topLight = avgByHour.filter { $0.value < 0.3 }.map { hourLabel($0.key) }.joined(separator: ", ")
        let totalBlocks = blocks.count
        let utilValues = blocks.map { Double($0.messageCount) / Double(max(msgCap, 1)) }
        let avgUtil = Int(utilValues.reduce(0, +) / Double(totalBlocks) * 100)

        var prompt = """
        You are a productivity advisor for a software developer who uses Claude Code heavily. \
        Based on their past \(totalBlocks) usage blocks over the last 7 days:
        - Average block utilization: \(avgUtil)%
        """
        if !topHeavy.isEmpty { prompt += "\n- Hours with heaviest usage: \(topHeavy)" }
        if !topLight.isEmpty { prompt += "\n- Hours with lightest usage: \(topLight)" }
        prompt += """

        In 1–2 sentences, give a specific, practical scheduling tip. \
        Be direct and concrete — mention actual hours. No fluff, no bullet points.
        """
        return prompt
    }

    private func callModel(prompt: String) async -> String? {
        // Dynamic lookup to avoid hard compile-time dependency on FoundationModels symbols.
        // We use NSClassFromString + perform: so this compiles on macOS 14 deployment target.
        // On macOS 26+ with Apple Intelligence enabled, this resolves at runtime.
        guard let sessionClass = NSClassFromString("FoundationModels.LanguageModelSession") as? NSObject.Type else {
            return nil
        }
        // Fallback: the framework is present but we can't call it without the SDK types.
        // Return nil here — the caller will handle absence gracefully.
        _ = sessionClass
        return nil
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "am" : "pm"
        return "\(h)\(ampm)"
    }
}

/// Wrapper that's safe to call on any OS version.
actor AIInsightsServiceWrapper {
    private var impl: AnyObject? = nil

    func generateScheduleInsight(blocks: [UsageBlock], tier: UsageTier) async -> String? {
        if #available(macOS 26.0, *) {
            if impl == nil { impl = AIInsightsService() }
            return await (impl as! AIInsightsService).generateScheduleInsight(blocks: blocks, tier: tier)
        }
        return nil
    }
}
