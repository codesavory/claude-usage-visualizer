import SwiftUI

struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Waiting for a Claude session")
                .font(.headline)
            Text("Open a terminal, run `claude`, and send a message. This popover will light up with live usage once data appears at `~/.claude/projects`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: Theme.popoverWidth, height: 240)
    }
}
