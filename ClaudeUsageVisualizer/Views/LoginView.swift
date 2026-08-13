import SwiftUI

/// One-time sign-in shown when the widget has no usable token of its own.
/// Opens Anthropic's consent page in the browser, then takes the code the user
/// pastes back. After this the widget holds its own grant and never prompts for
/// a keychain password again.
struct LoginView: View {
    @EnvironmentObject var login: OAuthLoginService
    @State private var pastedCode: String = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Sign in to Claude")
                .font(.headline)

            switch login.phase {
            case .idle, .done:
                Text("Connect the widget to your Claude account once. It gets its own read-only token, so you'll never see a keychain password prompt again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Claude to sign in") { login.beginLogin() }
                    .buttonStyle(.borderedProminent)

            case .awaitingCode, .failed:
                Text("Approve access in your browser, then paste the code Anthropic shows you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Paste code here", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                if case .failed(let message) = login.phase {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Reopen browser") { login.beginLogin() }
                        .buttonStyle(.plain)
                        .font(.caption)
                    Spacer()
                    Button("Sign in") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            case .exchanging:
                ProgressView()
                Text("Signing in…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: Theme.popoverWidth, height: 300)
    }

    private func submit() {
        let code = pastedCode
        Task { await login.submitCode(code) }
    }
}
