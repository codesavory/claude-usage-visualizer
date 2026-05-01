import SwiftUI

struct BreakNudgeView: View {
    let nudge: BreakNudge
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(nudge.mood.emoji)
                .font(.system(size: 32))

            VStack(alignment: .leading, spacing: 4) {
                Text(nudge.headline)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(nudge.body)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Button(action: onSnooze) {
                        Text("Snooze \(nudge.minutesSuggested)m")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(action: onDismiss) {
                        Text("I'll stop")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.pink.opacity(0.18), Color.purple.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .stroke(Color.pink.opacity(0.25), lineWidth: 0.5)
        )
    }
}
