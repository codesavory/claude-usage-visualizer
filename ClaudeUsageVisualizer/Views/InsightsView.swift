import SwiftUI

struct InsightsView: View {
    let suggestions: [OptimizationSuggestion]
    let onApply: (OptimizationSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INSIGHTS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .kerning(0.8)

            if suggestions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("All good — usage looks healthy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(suggestions) { s in
                    SuggestionRow(suggestion: s, onApply: onApply)
                }
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: OptimizationSuggestion
    let onApply: (OptimizationSuggestion) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.icon)
                .foregroundStyle(severityColor)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.caption.weight(.semibold))
                Text(suggestion.rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: { onApply(suggestion) }) {
                Text(suggestion.applyLabel)
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(severityColor)
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(severityColor.opacity(0.08))
        )
    }

    private var severityColor: Color {
        switch suggestion.severity {
        case .critical: return .red
        case .warn: return .orange
        case .info: return .blue
        }
    }
}
