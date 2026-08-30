import SwiftUI

/// Shown on macOS when the widget can't read Claude Code's usage token. The
/// widget borrows Claude Code's own token from the keychain (Claude Code keeps
/// it fresh and it has the right scope), so there is no separate sign-in — the
/// only thing needed is a one-time keychain "Always Allow".
struct LoginView: View {
    @EnvironmentObject var viewModel: UsageViewModel
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Grant usage access")
                .font(.headline)
            Text("The widget reads Claude Code's usage token from your keychain. macOS asks once — click \u{201C}Always Allow\u{201D} and you won't see it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                retrying = true
                Task { await viewModel.refreshNow(); retrying = false }
            } label: {
                if retrying { ProgressView().controlSize(.small) }
                else { Text("Allow & load usage") }
            }
            .buttonStyle(.borderedProminent)

            Text("Nothing happens? Make sure Claude Code is signed in — run `claude` in Terminal.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: Theme.popoverWidth, height: 300)
    }
}
