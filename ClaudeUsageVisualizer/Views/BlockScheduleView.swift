import SwiftUI

/// Shows your 5-hour Claude blocks as segments on a 7-day day-by-day timeline.
/// Each row = one calendar day. Each coloured bar = one 5h block, positioned
/// by start time on a 24h axis. Current block is highlighted.
struct BlockScheduleView: View {
    /// All live blocks (previousBlocks + currentBlock), sorted oldest → newest.
    let allBlocks: [UsageBlock]
    let currentBlock: UsageBlock?
    let liveUsage: OAuthUsageSnapshot?
    let weeklyTotals: TokenTotals
    let aiInsight: String?
    var profile: HabitEngine.BehavioralProfile? = nil
    var savedBlocks: [UsageHistoryStore.SavedBlock] = []
    var msgCap: Int = 225

    // MARK: - Derived data

    private var liveRatio: Double? {
        guard let live = liveUsage, live.status == .live || live.status == .rateLimited else { return nil }
        return live.fiveHour.utilization / 100.0
    }

    /// Max message count seen, used for relative-scale colouring of past blocks.
    private var maxMessages: Int {
        max(1, allBlocks.map(\.messageCount).max() ?? 1, msgCap)
    }

    private struct DayRow: Identifiable {
        var id: Date { date }
        let date: Date
        let label: String
        let blocks: [UsageBlock]
    }

    private var dayRows: [DayRow] {
        let cal = Calendar.current
        var grouped: [Date: [UsageBlock]] = [:]
        for block in allBlocks {
            let day = cal.startOfDay(for: block.startedAt)
            grouped[day, default: []].append(block)
        }
        return grouped
            .map { (date, blocks) in
                DayRow(
                    date: date,
                    label: dayLabel(date),
                    blocks: blocks.sorted { $0.startedAt < $1.startedAt }
                )
            }
            .sorted { $0.date > $1.date }  // today first
            .prefix(7)
            .map { $0 }
    }

    // Best and avoid windows derived from all available blocks (live + saved).
    private var windowStats: (best: [String], avoid: [String]) {
        let allSaved = savedBlocks
        // Use 5h start-hour buckets (0, 5, 10, 15, 20) — approximate the typical
        // Claude block anchors by snapping each block's start hour to nearest 5h slot.
        var bucketUtil: [Int: [Double]] = [:]
        for block in allBlocks {
            let h = Calendar.current.component(.hour, from: block.startedAt)
            let ratio = min(1.0, Double(block.messageCount) / Double(max(msgCap, 1)))
            bucketUtil[h, default: []].append(ratio)
        }
        for sb in allSaved {
            let h = Calendar.current.component(.hour, from: sb.startedAt)
            let ratio = min(1.0, Double(sb.messageCount) / Double(max(msgCap, 1)))
            bucketUtil[h, default: []].append(ratio)
        }
        guard !bucketUtil.isEmpty else { return ([], []) }
        let avgByHour = bucketUtil.mapValues { $0.reduce(0, +) / Double($0.count) }
        let best = avgByHour.filter { $0.value < 0.3 }
            .sorted { $0.value < $1.value }.prefix(2)
            .map { blockTimeLabel($0.key) }
        let avoid = avgByHour.filter { $0.value > 0.65 }
            .sorted { $0.value > $1.value }.prefix(2)
            .map { blockTimeLabel($0.key) }
        return (best, avoid)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if allBlocks.isEmpty {
                emptyState
            } else {
                ForEach(dayRows) { row in
                    dayRowView(row)
                }
                windowHints
                if let p = profile, allBlocks.count >= 3 {
                    behaviorLine(p)
                }
            }
            if let insight = aiInsight {
                aiCard(insight)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("SCHEDULE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .kerning(0.8)
            Spacer()
            if let live = liveUsage, live.status == .live || live.status == .rateLimited {
                let secs = max(0, live.fiveHour.resetsAt.timeIntervalSince(Date()))
                if secs > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary)
                        Text("resets \(DurationFormatter.compact(secs))")
                            .font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("\(TokenFormatter.usd(weeklyTotals.costUSD))")
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary)
            Text("Use Claude Code for a bit — your block history will appear here.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Day row

    private func dayRowView(_ row: DayRow) -> some View {
        let dayCost = row.blocks.reduce(0.0) { $0 + $1.totalCostUSD }
        return HStack(alignment: .top, spacing: 6) {
            Text(row.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.08))
                            .frame(height: 12)
                        ForEach([6, 12, 18], id: \.self) { h in
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 1, height: 12)
                                .offset(x: geo.size.width * CGFloat(h) / 24.0)
                        }
                        ForEach(row.blocks) { block in
                            blockSegment(block: block, width: geo.size.width)
                        }
                    }
                }
                .frame(height: 12)

                HStack(spacing: 4) {
                    ForEach(row.blocks) { block in
                        blockLabel(block: block)
                    }
                    Spacer(minLength: 0)
                }
            }

            if dayCost > 0 {
                Text(TokenFormatter.usd(dayCost))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func blockSegment(block: UsageBlock, width: CGFloat) -> some View {
        let startFraction = hourFraction(block.startedAt)
        let segWidth = max(6, width * (5.0 / 24.0))
        let isCurrent = block.id == currentBlock?.id
        let ratio = utilization(block)

        return Capsule()
            .fill(
                LinearGradient(
                    colors: [blockColor(ratio).opacity(0.65), blockColor(ratio)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: segWidth, height: isCurrent ? 14 : 12)
            .offset(x: width * startFraction, y: isCurrent ? -1 : 0)
            .overlay(
                isCurrent ? Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1) : nil
            )
    }

    private func blockLabel(block: UsageBlock) -> some View {
        let isCurrent = block.id == currentBlock?.id
        let ratio = utilization(block)
        let label = blockTimeRangeLabel(block.startedAt)
        let pctStr = "\(Int((ratio * 100).rounded()))%"

        return HStack(spacing: 2) {
            if isCurrent {
                Circle().fill(blockColor(ratio).opacity(0.9)).frame(width: 4, height: 4)
            }
            Text("\(label) · \(pctStr)")
                .font(.system(size: 8, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? blockColor(ratio) : .secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Window hints

    private var windowHints: some View {
        let (best, avoid) = windowStats
        return HStack(alignment: .top, spacing: 8) {
            if !best.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    Text("Light: \(best.joined(separator: " · "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !avoid.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.caption2).foregroundStyle(.orange)
                    Text("Heavy: \(avoid.joined(separator: " · "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    // MARK: - Behavioural line

    private func behaviorLine(_ p: HabitEngine.BehavioralProfile) -> some View {
        let todayStr = UsagePersonality.compareTodayVsAverage(
            todayMessages: p.todayMessages,
            avgMessages: p.avgDailyMessages
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: p.isNightOwl ? "moon.stars.fill" : (p.isMorningCoder ? "sunrise.fill" : "sun.max.fill"))
                    .font(.caption2).foregroundStyle(p.isNightOwl ? .purple : .orange)
                Text(p.isNightOwl ? "Night owl 🦉" : (p.isMorningCoder ? "Early bird 🐦" : "Day coder ☀️"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if p.streak > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill").font(.caption2).foregroundStyle(.orange)
                        Text("\(p.streak)d streak").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text(todayStr).font(.caption2).foregroundStyle(.tertiary)
            if let peak = p.peakHour {
                Text(UsagePersonality.patternDescription(peakHour: peak, avgUtil: p.avgPeakUtilization, blockCount: allBlocks.count))
                    .font(.caption2).foregroundStyle(.tertiary).italic()
            }
        }
        .padding(.top, 2)
    }

    // MARK: - AI card

    private func aiCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple).padding(.top, 1)
            Text(text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.purple.opacity(0.07)))
    }

    // MARK: - Helpers

    private func utilization(_ block: UsageBlock) -> Double {
        if let current = currentBlock, block.id == current.id, let ratio = liveRatio {
            return ratio
        }
        return min(1.0, Double(block.messageCount) / Double(max(maxMessages, 1)))
    }

    private func blockColor(_ ratio: Double) -> Color {
        if ratio > 0.85 { return .red }
        if ratio > 0.65 { return Color(red: 0.95, green: 0.35, blue: 0.20) }
        if ratio > 0.4  { return .orange }
        if ratio > 0.2  { return Color(red: 0.85, green: 0.75, blue: 0.20) }
        return .green
    }

    private func hourFraction(_ date: Date) -> CGFloat {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return CGFloat(h) / 24.0 + CGFloat(m) / (24.0 * 60.0)
    }

    /// "8pm–1am" style label for a block starting at `date`
    private func blockTimeRangeLabel(_ date: Date) -> String {
        let endDate = date.addingTimeInterval(5 * 3600)
        let startStr = timeStr(date)
        let endStr = timeStr(endDate)
        return "\(startStr)–\(endStr)"
    }

    private func timeStr(_ date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let hh = h % 12 == 0 ? 12 : h % 12
        let suffix = h < 12 ? "am" : "pm"
        return m == 0 ? "\(hh)\(suffix)" : "\(hh):\(String(format: "%02d", m))\(suffix)"
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yest" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date)
    }

    /// "8pm–1am" style label for a block window starting at `hour`
    private func blockTimeLabel(_ hour: Int) -> String {
        let endHour = (hour + 5) % 24
        return "\(shortHour(hour))–\(shortHour(endHour))"
    }

    private func shortHour(_ h: Int) -> String {
        let hh = h % 12 == 0 ? 12 : h % 12
        return "\(hh)\(h < 12 ? "am" : "pm")"
    }
}
