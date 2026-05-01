import Foundation

/// The brain: accepts UsageEvents + SessionRegistry snapshots,
/// maintains a 7-day ring buffer, computes 5h blocks + burn rate,
/// and produces immutable UsageSnapshots for the UI.
actor UsageAggregator {
    private var events: [UsageEvent] = []
    private var seen: Set<String> = []
    private var sessions: [SessionRegistry.RawSession] = []

    // Configurable thresholds
    var burnWarmThreshold: Double = 2_000
    var burnHotThreshold: Double = 8_000
    var burnCriticalThreshold: Double = 20_000

    private let retentionSeconds: TimeInterval = 7 * 24 * 3600
    private let blockSeconds: TimeInterval = 5 * 3600
    private let burnWindowSeconds: TimeInterval = 300

    // MARK: - Ingestion

    func ingest(_ event: UsageEvent) {
        if seen.contains(event.id) { return }
        seen.insert(event.id)
        events.append(event)
        prune()
    }

    func ingestBatch(_ batch: [UsageEvent]) {
        for e in batch { ingest(e) }
    }

    func bind(sessions: [SessionRegistry.RawSession]) {
        self.sessions = sessions
    }

    func updateThresholds(warm: Double, hot: Double, critical: Double) {
        self.burnWarmThreshold = warm
        self.burnHotThreshold = hot
        self.burnCriticalThreshold = critical
    }

    // MARK: - Pruning

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retentionSeconds)
        if let firstRetainIdx = events.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstRetainIdx > 0 {
                let dropped = events.prefix(firstRetainIdx)
                for e in dropped { seen.remove(e.id) }
                events.removeFirst(firstRetainIdx)
            }
        } else if let last = events.last, last.timestamp < cutoff {
            seen.removeAll(keepingCapacity: true)
            events.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Snapshot

    func currentSnapshot(now: Date = Date()) -> UsageSnapshot {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let (current, previous) = buildBlocks(sorted: sorted, now: now)
        let burn = computeBurnRate(events: sorted, now: now, currentBlock: current)
        let sessionInfos = buildSessions(sorted: sorted, currentBlock: current, burn: burn, now: now)
        let weekly = computeWeeklyTotals(events: sorted, now: now)

        return UsageSnapshot(
            currentBlock: current,
            previousBlocks: previous,
            burn: burn,
            sessions: sessionInfos,
            weeklyTotals: weekly,
            generatedAt: now
        )
    }

    // MARK: - Block construction

    private func buildBlocks(sorted: [UsageEvent], now: Date) -> (current: UsageBlock?, previous: [UsageBlock]) {
        guard !sorted.isEmpty else { return (nil, []) }

        var blocks: [UsageBlock] = []
        var anchor: Date? = nil
        var totalsByModel: [ClaudeModel: TokenTotals] = [:]
        var countBySession: [String: Int] = [:]

        func flush() {
            guard let a = anchor else { return }
            blocks.append(UsageBlock(
                id: UUID(),
                startedAt: a,
                totalsByModel: totalsByModel,
                eventCountBySession: countBySession
            ))
            anchor = nil
            totalsByModel = [:]
            countBySession = [:]
        }

        for ev in sorted {
            if let a = anchor {
                if ev.timestamp.timeIntervalSince(a) >= blockSeconds {
                    flush()
                    anchor = ev.timestamp
                }
            } else {
                anchor = ev.timestamp
            }

            var t = totalsByModel[ev.model] ?? TokenTotals()
            t.add(ev)
            totalsByModel[ev.model] = t
            countBySession[ev.sessionId, default: 0] += 1
        }
        flush()

        let current = blocks.last.flatMap { $0.contains(now) ? $0 : nil }
        let previous = current == nil ? blocks : Array(blocks.dropLast())
        return (current, previous)
    }

    // MARK: - Burn rate

    private func computeBurnRate(events sorted: [UsageEvent], now: Date, currentBlock: UsageBlock?) -> BurnRate {
        let windowStart = now.addingTimeInterval(-burnWindowSeconds)
        var tokens = 0
        var messages = 0
        for e in sorted.reversed() {
            if e.timestamp < windowStart { break }
            tokens += e.totalTokens
            messages += 1
        }
        let minutes = burnWindowSeconds / 60.0
        let tpm = Double(tokens) / minutes
        let mpm = Double(messages) / minutes
        let severity = BurnRate.severity(
            forTokensPerMinute: tpm,
            warmThreshold: burnWarmThreshold,
            hotThreshold: burnHotThreshold,
            criticalThreshold: burnCriticalThreshold
        )

        var projected: Date? = nil
        if let block = currentBlock, tpm > 0 {
            let elapsed = block.totalCostUSD
            _ = elapsed
            // Projected exhaustion based on messages budget for simplicity
            let used = block.messageCount
            let remaining = max(0, 225 - used)
            if mpm > 0 {
                let secondsUntilExhaustion = Double(remaining) / mpm * 60.0
                projected = now.addingTimeInterval(secondsUntilExhaustion)
            }
        }

        return BurnRate(
            tokensPerMinute: tpm,
            messagesPerMinute: mpm,
            projectedBlockExhaustion: projected,
            severity: severity
        )
    }

    // MARK: - Sessions

    private func buildSessions(sorted: [UsageEvent], currentBlock: UsageBlock?, burn: BurnRate, now: Date) -> [SessionInfo] {
        let windowStart = now.addingTimeInterval(-burnWindowSeconds)
        var byId: [String: (last: Date, tokens: Int, cost: Double, recentTokens: Int, modelCounts: [ClaudeModel: Int])] = [:]

        let blockEvents: [UsageEvent]
        if let b = currentBlock {
            blockEvents = sorted.filter { b.contains($0.timestamp) }
        } else {
            blockEvents = []
        }

        // Also track the cwd seen for each session ID so orphaned subagents can be matched.
        var sessionCwd: [String: String] = [:]
        for e in blockEvents {
            var entry = byId[e.sessionId] ?? (last: .distantPast, tokens: 0, cost: 0, recentTokens: 0, modelCounts: [:])
            if e.timestamp > entry.last { entry.last = e.timestamp }
            entry.tokens += e.totalTokens
            entry.cost += e.costUSD
            if e.timestamp >= windowStart { entry.recentTokens += e.totalTokens }
            entry.modelCounts[e.model, default: 0] += 1
            byId[e.sessionId] = entry
            if sessionCwd[e.sessionId] == nil { sessionCwd[e.sessionId] = e.cwd }
        }

        var results: [SessionInfo] = []
        let knownSessionIds = Set(sessions.map { $0.sessionId })
        for raw in sessions {
            let agg = byId[raw.sessionId]
            let dominant = agg?.modelCounts.max(by: { $0.value < $1.value })?.key ?? .unknown
            results.append(SessionInfo(
                sessionId: raw.sessionId,
                pid: raw.pid,
                cwd: raw.cwd,
                startedAt: raw.startedAt,
                kind: raw.kind,
                entrypoint: raw.entrypoint,
                name: raw.name,
                isRunning: raw.isRunning,
                lastEventAt: agg?.last,
                tokensInCurrentBlock: agg?.tokens ?? 0,
                costInCurrentBlock: agg?.cost ?? 0,
                tokensPerMinute: Double(agg?.recentTokens ?? 0) / (burnWindowSeconds / 60.0),
                dominantModel: dominant
            ))
        }

        // Orphaned session IDs (subagents, background tasks) not in the registry:
        // roll their tokens/cost into the registered session with the same cwd.
        for (sid, agg) in byId where !knownSessionIds.contains(sid) {
            let cwd = sessionCwd[sid] ?? ""
            if let idx = results.firstIndex(where: { $0.cwd == cwd }) {
                results[idx].tokensInCurrentBlock += agg.tokens
                results[idx].costInCurrentBlock += agg.cost
                if let last = agg.last as Date?, results[idx].lastEventAt == nil || last > results[idx].lastEventAt! {
                    results[idx].lastEventAt = last
                }
            }
            // No matching registered session → discard (subagent from a closed session)
        }

        return results.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.tokensInCurrentBlock > rhs.tokensInCurrentBlock
        }
    }

    // MARK: - Weekly

    private func computeWeeklyTotals(events: [UsageEvent], now: Date) -> TokenTotals {
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        var totals = TokenTotals()
        for e in events where e.timestamp >= cutoff {
            totals.add(e)
        }
        return totals
    }
}
