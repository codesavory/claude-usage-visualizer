import SwiftUI

struct ModelBreakdownView: View {
    let block: UsageBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL MIX")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .kerning(0.8)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments, id: \.model) { seg in
                        Rectangle()
                            .fill(seg.model.accentColor)
                            .frame(width: max(2, geo.size.width * seg.share))
                    }
                    if segments.isEmpty {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: geo.size.width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 10)

            HStack(spacing: 10) {
                ForEach(segments, id: \.model) { seg in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(seg.model.accentColor)
                            .frame(width: 6, height: 6)
                        Text("\(seg.model.shortName) \(Int(seg.share * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                if segments.isEmpty {
                    Text("no activity yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var segments: [Segment] {
        guard let block, block.totals.total > 0 else { return [] }
        let total = block.totals.total
        return ClaudeModel.allCases
            .compactMap { model -> Segment? in
                guard let t = block.totalsByModel[model], t.total > 0 else { return nil }
                return Segment(model: model, share: Double(t.total) / Double(total))
            }
            .sorted { $0.share > $1.share }
    }

    private struct Segment {
        let model: ClaudeModel
        let share: Double
    }
}
