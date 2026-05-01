import SwiftUI

struct UsageHeaderView: View {
    @EnvironmentObject var viewModel: UsageViewModel
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        let live = viewModel.liveUsage
        let tier = settings.tier
        let messages = viewModel.snapshot.currentBlock?.messageCount ?? 0
        let fallbackReset = viewModel.snapshot.currentBlock?.timeRemaining(now: viewModel.snapshot.generatedAt) ?? 0

        let ratio: Double = {
            if let live, live.status == .live || live.status == .rateLimited {
                return min(1.0, live.fiveHour.utilization / 100.0)
            }
            let cap = tier.messagesPerBlock
            return min(1.0, Double(messages) / Double(max(cap, 1)))
        }()

        let resetSeconds: TimeInterval = {
            if let live {
                return max(0, live.fiveHour.resetsAt.timeIntervalSince(Date()))
            }
            return fallbackReset
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(colorForRatio(ratio))
                    .monospacedDigit()
                Text("of 5h block")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if resetSeconds > 0 {
                    Text("resets \(DurationFormatter.compact(resetSeconds))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [colorForRatio(max(0.05, ratio * 0.6)), colorForRatio(ratio)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * ratio)
                        .animation(.easeInOut(duration: 0.4), value: ratio)
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text("\(messages) msgs · \(tier.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                sourceLabel(live)
            }

            Text(headerQuip)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerQuip: String {
        let live = viewModel.liveUsage
        let tier = settings.tier
        let messages = viewModel.snapshot.currentBlock?.messageCount ?? 0
        let ratio: Double = {
            if let live, live.status == .live || live.status == .rateLimited {
                return min(1.0, live.fiveHour.utilization / 100.0)
            }
            return min(1.0, Double(messages) / Double(max(tier.messagesPerBlock, 1)))
        }()
        return UsagePersonality.headerQuip(
            ratio: ratio,
            tokensPerMinute: viewModel.snapshot.burn.tokensPerMinute,
            hour: Calendar.current.component(.hour, from: Date()),
            continuousHours: viewModel.behavioralProfile?.continuousHoursToday ?? 0,
            blocks: viewModel.snapshot.previousBlocks
        )
    }

    @ViewBuilder
    private func sourceLabel(_ live: OAuthUsageSnapshot?) -> some View {
        switch live?.status {
        case .live:
            HStack(spacing: 3) {
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text("live").font(.caption2).foregroundStyle(.green)
            }
        case .rateLimited:
            HStack(spacing: 3) {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                Text("cached").font(.caption2).foregroundStyle(.orange)
            }
        case .unauthorized:
            Text("sign in to Claude Code").font(.caption2).foregroundStyle(.tertiary)
        case .stale, .unavailable, .none:
            Text("estimated").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func colorForRatio(_ r: Double) -> Color {
        if r > 0.9 { return .red }
        if r > 0.75 { return Color(red: 0.95, green: 0.35, blue: 0.20) }
        if r > 0.5 { return .orange }
        if r > 0.25 { return Color(red: 0.95, green: 0.65, blue: 0.20) }
        return Color(red: 0.95, green: 0.80, blue: 0.30)
    }
}
