import SwiftUI

struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Sign in to see your usage")
                .font(.headline)
            Text("Tap the refresh button below (or “exact %”) to unlock your usage with your Mac password. Sign in once on your Mac or iPhone and it syncs to both. A running Claude session in the terminal will also fill this in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: Theme.popoverWidth, height: 240)
    }
}
