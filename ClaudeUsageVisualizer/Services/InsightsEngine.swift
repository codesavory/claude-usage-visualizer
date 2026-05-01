import Foundation

/// Pure heuristics — takes a UsageSnapshot + live OAuth data, returns ranked suggestions + optional nudge.
actor InsightsEngine {
    struct Output: Sendable {
        let suggestions: [OptimizationSuggestion]
        let nudge: BreakNudge?
    }

    func evaluate(_ snapshot: UsageSnapshot, tier: UsageTier, liveUsage: OAuthUsageSnapshot?) -> Output {
        var suggestions: [OptimizationSuggestion] = []
        var nudge: BreakNudge? = nil

        let block = snapshot.currentBlock
        let totals = block?.totals ?? TokenTotals()
        let burn = snapshot.burn
        let msgCap = tier.messagesPerBlock
        let messages = totals.messages

        // Live utilization (0–1) from OAuth, falling back to local message ratio
        let liveRatio: Double? = {
            guard let live = liveUsage, live.status == .live || live.status == .rateLimited else { return nil }
            return live.fiveHour.utilization / 100.0
        }()
        let effectiveRatio = liveRatio ?? (Double(messages) / Double(max(msgCap, 1)))

        // Reset timing from live data
        let resetSeconds: TimeInterval = {
            if let live = liveUsage, live.status == .live || live.status == .rateLimited {
                return max(0, live.fiveHour.resetsAt.timeIntervalSince(Date()))
            }
            return block.map { $0.timeRemaining(now: snapshot.generatedAt) } ?? 0
        }()

        let blockElapsedFraction: Double = {
            guard let block else { return 0 }
            let elapsed = snapshot.generatedAt.timeIntervalSince(block.startedAt)
            return min(1.0, elapsed / (5 * 3600))
        }()

        // 1. Block reset imminent — positive framing when possible
        if resetSeconds > 0 && resetSeconds < 20 * 60 {
            let mins = Int(resetSeconds / 60) + 1
            if effectiveRatio < 0.85 {
                suggestions.append(OptimizationSuggestion(
                    kind: .pasteCommand("/usage"),
                    title: "Fresh block in \(mins) min — you're clear",
                    rationale: "At \(Int(effectiveRatio * 100))% used, you've made it through. Let this block expire; start your next task in the new window.",
                    applyLabel: "Check /usage",
                    severity: .info,
                    icon: "arrow.clockwise.circle"
                ))
            } else {
                suggestions.append(OptimizationSuggestion(
                    kind: .pasteCommand("/usage"),
                    title: "Scraping the limit — \(mins) min to reset",
                    rationale: "Hold off on new heavy prompts. Queue your next task and send it right after the block refreshes.",
                    applyLabel: "Check /usage",
                    severity: .warn,
                    icon: "timer"
                ))
            }
        }

        // 2. New block headroom — encourage deep work when we just reset
        if resetSeconds > 4 * 3600 && effectiveRatio < 0.15 && blockElapsedFraction > 0.1 {
            suggestions.append(OptimizationSuggestion(
                kind: .pasteCommand("/model claude-opus-4-7"),
                title: "Fresh block, plenty of room",
                rationale: "You're early in a new 5h window with \(Int((1 - effectiveRatio) * 100))% quota left. Good time for heavy Opus work — big refactors, long analysis tasks.",
                applyLabel: "Switch to Opus",
                severity: .info,
                icon: "sparkles"
            ))
        }

        // 3. Historical pattern — is this time slot usually heavy?
        let patternWarning = historicalPatternSuggestion(snapshot: snapshot, tier: tier, effectiveRatio: effectiveRatio)
        if let p = patternWarning { suggestions.append(p) }

        // 4. Opus share
        if let block, block.totals.total > 5_000 {
            let opusTokens = block.totalsByModel[.opus47]?.total ?? 0
            let total = block.totals.total
            if total > 0 {
                let opusShare = Double(opusTokens) / Double(total)
                if opusShare > 0.6 {
                    let costSaved = TokenFormatter.usd(block.totalsByModel[.opus47]?.costUSD ?? 0 * 0.4)
                    suggestions.append(OptimizationSuggestion(
                        kind: .pasteCommand("/model claude-sonnet-4-6"),
                        title: "Opus is \(TokenFormatter.percent(opusShare)) of this block",
                        rationale: "Sonnet costs ~5× less per output token. Switching now could save ~\(costSaved) before reset. Use Opus only for the trickiest parts.",
                        applyLabel: "Copy /model",
                        severity: opusShare > 0.8 ? .critical : .warn,
                        icon: "arrow.triangle.branch"
                    ))
                }
            }
        }

        // 5. Cache efficiency — more specific context
        if totals.total > 10_000 {
            let cacheReadRatio = Double(totals.cacheRead) / Double(max(totals.total, 1))
            if cacheReadRatio < 0.35 {
                let wasted = TokenFormatter.tokens(totals.input - totals.cacheRead)
                suggestions.append(OptimizationSuggestion(
                    kind: .pasteCommand("/compact"),
                    title: "Only \(TokenFormatter.percent(cacheReadRatio)) cache reuse this block",
                    rationale: "\(wasted) tokens re-sent as fresh input instead of cached. /compact rebuilds a hot cache prefix and cuts costs on the next round of prompts.",
                    applyLabel: "Copy /compact",
                    severity: cacheReadRatio < 0.2 ? .warn : .info,
                    icon: "externaldrive.badge.minus"
                ))
            }
        }

        // 6. Verbose output
        if totals.input > 5_000 {
            let outRatio = Double(totals.output) / Double(max(totals.input + totals.cacheRead, 1))
            if outRatio > 0.4 {
                suggestions.append(OptimizationSuggestion(
                    kind: .openFile(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")),
                    title: "Output is \(TokenFormatter.percent(outRatio)) of input — verbose",
                    rationale: "Add a one-line brevity directive to ~/.claude/CLAUDE.md. Something like: 'Be concise. Skip preamble. Don't restate the question.' Small instruction, big token savings.",
                    applyLabel: "Open CLAUDE.md",
                    severity: .info,
                    icon: "text.append"
                ))
            }
        }

        // 7. Near-cap — switch to Haiku for housekeeping
        if effectiveRatio > 0.85 {
            let activeSessionCount = snapshot.sessions.filter { $0.isRunning }.count
            let who = activeSessionCount == 1 ? "your session" : "\(activeSessionCount) active sessions"
            suggestions.append(OptimizationSuggestion(
                kind: .pasteCommand("/model claude-haiku-4-5"),
                title: "\(Int(effectiveRatio * 100))% of block used — throttle down",
                rationale: "With \(who) still running, switch to Haiku for git commits, quick lookups, and formatting tasks. Save the remaining quota for anything that needs real reasoning.",
                applyLabel: "Copy /model",
                severity: .critical,
                icon: "gauge.with.dots.needle.bottom.100percent"
            ))
        }

        // 8. Long Opus session — compact suggestion with cost context
        for session in snapshot.sessions where session.isRunning {
            if session.dominantModel == .opus47 && session.tokensInCurrentBlock > 80_000 {
                let cost = TokenFormatter.usd(session.costInCurrentBlock)
                suggestions.append(OptimizationSuggestion(
                    kind: .pasteCommand("/compact"),
                    title: "\(session.displayName): \(TokenFormatter.tokens(session.tokensInCurrentBlock)) tok (\(cost))",
                    rationale: "This session is deep and expensive. /compact drops the raw history and replaces it with a summary — usually 80–90% fewer tokens, keeping context intact.",
                    applyLabel: "Copy /compact",
                    severity: .warn,
                    icon: "scissors"
                ))
                break
            }
        }

        // 9. Weekly context — is today heavier than usual?
        if let weeklyInsight = weeklyPatternSuggestion(snapshot: snapshot, tier: tier) {
            suggestions.append(weeklyInsight)
        }

        // Break nudge
        if effectiveRatio > 0.9 {
            nudge = BreakNudge(
                mood: .coolDown,
                headline: "You've used \(Int(effectiveRatio * 100))% of this 5h block",
                body: resetSeconds > 0
                    ? "Block resets in \(DurationFormatter.compact(resetSeconds)). A short break now means a fresh start then."
                    : "Step back for 15 minutes. Your context, and your brain, will thank you.",
                minutesSuggested: 15
            )
        } else if let projected = burn.projectedBlockExhaustion, let block {
            let secondsUntilExhaustion = projected.timeIntervalSince(snapshot.generatedAt)
            let secondsUntilReset = block.timeRemaining(now: snapshot.generatedAt)
            if secondsUntilExhaustion > 0, secondsUntilExhaustion < secondsUntilReset - 1800 {
                let gap = DurationFormatter.compact(secondsUntilReset - secondsUntilExhaustion)
                nudge = BreakNudge(
                    mood: pickMood(burn: burn),
                    headline: "On pace to hit cap \(gap) early",
                    body: "A \(breakMinutes(burn: burn))-min pause stretches your remaining quota past the reset window.",
                    minutesSuggested: breakMinutes(burn: burn)
                )
            }
        }

        // Rank: critical first, then warn, then info; keep top 3
        let rank: (OptimizationSuggestion.Severity) -> Int = {
            switch $0 {
            case .critical: return 0
            case .warn: return 1
            case .info: return 2
            }
        }
        let ranked = suggestions.sorted { rank($0.severity) < rank($1.severity) }
        return Output(suggestions: Array(ranked.prefix(3)), nudge: nudge)
    }

    // MARK: - Pattern analysis

    private func historicalPatternSuggestion(snapshot: UsageSnapshot, tier: UsageTier, effectiveRatio: Double) -> OptimizationSuggestion? {
        guard snapshot.previousBlocks.count >= 3 else { return nil }
        let msgCap = tier.messagesPerBlock
        let currentHour = Calendar.current.component(.hour, from: Date())

        // Find blocks from similar time-of-day (±3h)
        let similarBlocks = snapshot.previousBlocks.filter { block in
            let h = Calendar.current.component(.hour, from: block.startedAt)
            let diff = abs(h - currentHour)
            return min(diff, 24 - diff) <= 3
        }
        guard similarBlocks.count >= 2 else { return nil }

        let avgUtil = similarBlocks.map { Double($0.messageCount) / Double(max(msgCap, 1)) }.reduce(0, +) / Double(similarBlocks.count)

        if avgUtil > 0.7 && effectiveRatio < 0.5 {
            return OptimizationSuggestion(
                kind: .pasteCommand("/usage"),
                title: "This time slot usually runs hot",
                rationale: "Your \(hourLabel(currentHour)) blocks have averaged \(Int(avgUtil * 100))% usage historically. You're at \(Int(effectiveRatio * 100))% now — get your heavy lifting done before the usual surge.",
                applyLabel: "Check /usage",
                severity: .warn,
                icon: "chart.line.uptrend.xyaxis"
            )
        } else if avgUtil < 0.35 && effectiveRatio > 0.6 {
            return OptimizationSuggestion(
                kind: .pasteCommand("/usage"),
                title: "Running hotter than usual for \(hourLabel(currentHour))",
                rationale: "Typical \(hourLabel(currentHour)) blocks average \(Int(avgUtil * 100))% usage. You're at \(Int(effectiveRatio * 100))% — consider switching heavier tasks to Sonnet or Haiku.",
                applyLabel: "Check /usage",
                severity: .warn,
                icon: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
        return nil
    }

    private func weeklyPatternSuggestion(snapshot: UsageSnapshot, tier: UsageTier) -> OptimizationSuggestion? {
        guard snapshot.previousBlocks.count >= 5 else { return nil }
        let msgCap = tier.messagesPerBlock
        let today = Calendar.current.startOfDay(for: Date())

        // Tokens used in last 24h vs daily average over past week
        let todayBlocks = snapshot.previousBlocks.filter { $0.startedAt >= today }
        let todayMessages = todayBlocks.reduce(0) { $0 + $1.messageCount }
        let dailyAvg = Double(snapshot.previousBlocks.reduce(0) { $0 + $1.messageCount }) / max(7.0, Double(snapshot.previousBlocks.count))

        guard dailyAvg > 10 else { return nil }

        if Double(todayMessages) > dailyAvg * 1.8 {
            return OptimizationSuggestion(
                kind: .pasteCommand("/model claude-sonnet-4-6"),
                title: "Heavy day — \(Int(Double(todayMessages) / dailyAvg * 100))% of your daily average",
                rationale: "You've used \(todayMessages) messages today vs. your \(Int(dailyAvg))-message daily average. Switching to Sonnet for the rest of the day preserves Opus quota for tomorrow.",
                applyLabel: "Copy /model",
                severity: .warn,
                icon: "calendar.badge.exclamationmark"
            )
        }
        return nil
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "am" : "pm"
        return "\(h)\(ampm)"
    }

    private func pickMood(burn: BurnRate) -> BreakNudge.Mood {
        switch burn.severity {
        case .chill: return .stretch
        case .warm: return .coffee
        case .hot: return .walk
        case .critical: return .coolDown
        }
    }

    private func breakMinutes(burn: BurnRate) -> Int {
        switch burn.severity {
        case .chill: return 5
        case .warm: return 10
        case .hot: return 15
        case .critical: return 20
        }
    }
}
