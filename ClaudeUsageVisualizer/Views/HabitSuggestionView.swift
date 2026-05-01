import SwiftUI

struct HabitSuggestionView: View {
    let suggestion: HabitEngine.HabitSuggestion
    let profile: HabitEngine.BehavioralProfile
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(suggestion.mood.emoji)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(suggestion.headline)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    urgencyBadge
                }
                Text(suggestion.rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if profile.streak >= 3 {
                    streakNote
                }

                Button(action: onDismiss) {
                    Text("Got it")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [cardColor.opacity(0.15), cardColor.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .stroke(cardColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var cardColor: Color {
        switch suggestion.urgency {
        case 3: return .red
        case 2: return .orange
        default: return .teal
        }
    }

    @ViewBuilder
    private var urgencyBadge: some View {
        if suggestion.urgency >= 2 {
            Text(suggestion.urgency == 3 ? "urgent" : "nudge")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(cardColor.opacity(0.15)))
                .foregroundStyle(cardColor)
        }
    }

    private var streakNote: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("\(profile.streak)-day streak. Impressive and slightly concerning.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}
