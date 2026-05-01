import Foundation

/// Persists block-level usage records to disk so trend data survives beyond the
/// 7-day JSONL backfill window. Merges new live blocks on every recompute cycle.
actor UsageHistoryStore {
    struct SavedBlock: Codable, Sendable, Identifiable {
        let id: String      // startedAt ISO8601 rounded to minute — stable dedup key
        let startedAt: Date
        let endsAt: Date
        let messageCount: Int
        let totalTokens: Int
        let costUSD: Double
        let dominantModel: String   // "opus47" | "sonnet46" | "haiku45" | "unknown"
    }

    private let storeURL: URL
    private var records: [String: SavedBlock] = [:]  // keyed by id
    private let maxAge: TimeInterval = 90 * 24 * 3600

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("ClaudeUsageVisualizer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("block_history.json")
        // Load synchronously during init (before actor isolation kicks in)
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([SavedBlock].self, from: data) {
            for b in saved { records[b.id] = b }
        }
    }

    // Merge live blocks from the aggregator into the persistent store.
    func merge(blocks: [UsageBlock]) {
        var changed = false
        for block in blocks {
            let key = blockKey(block.startedAt)
            if records[key] == nil {
                let dominant = block.totalsByModel
                    .max(by: { $0.value.total < $1.value.total })?.key.rawValue ?? "unknown"
                records[key] = SavedBlock(
                    id: key,
                    startedAt: block.startedAt,
                    endsAt: block.endsAt,
                    messageCount: block.messageCount,
                    totalTokens: block.totals.total,
                    costUSD: block.totalCostUSD,
                    dominantModel: dominant
                )
                changed = true
            }
        }
        if changed { prune(); save() }
    }

    /// All saved blocks sorted oldest → newest, includes the live 7-day window.
    func allBlocks() -> [SavedBlock] {
        records.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Blocks older than the 7-day live window — the "historical" tier.
    func oldBlocks(before cutoff: Date) -> [SavedBlock] {
        records.values.filter { $0.startedAt < cutoff }.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Private

    private func blockKey(_ date: Date) -> String {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.minute = ((comps.minute ?? 0) / 5) * 5  // round to 5-min bucket for stability
        let snapped = cal.date(from: comps) ?? date
        return ISO8601DateFormatter().string(from: snapped)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        records = records.filter { $0.value.startedAt >= cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        try? data.write(to: storeURL)
    }

}
