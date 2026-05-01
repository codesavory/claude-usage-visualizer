import SwiftUI

struct WeeklyUsageView: View {
    let blocks: [UsageBlock]
    let weeklyTotals: TokenTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("7-DAY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
                Spacer()
                Text("\(TokenFormatter.tokens(weeklyTotals.total)) · \(TokenFormatter.usd(weeklyTotals.costUSD))")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 3) {
                let maxVal = max(1, blocks.map { $0.totals.total }.max() ?? 1)
                ForEach(blocks.suffix(14)) { block in
                    let h = CGFloat(Double(block.totals.total) / Double(maxVal)) * 28
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(block))
                        .frame(width: 6, height: max(2, h))
                }
                if blocks.isEmpty {
                    Text("No history yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(height: 30)
        }
    }

    private func barColor(_ block: UsageBlock) -> Color {
        if let opus = block.totalsByModel[.opus47]?.total,
           block.totals.total > 0,
           Double(opus) / Double(block.totals.total) > 0.6 {
            return ClaudeModel.opus47.accentColor
        }
        if let sonnet = block.totalsByModel[.sonnet46]?.total,
           block.totals.total > 0,
           Double(sonnet) / Double(block.totals.total) > 0.5 {
            return ClaudeModel.sonnet46.accentColor
        }
        return Color.accentColor.opacity(0.7)
    }
}
