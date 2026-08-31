import SwiftUI

/// OPTIONAL sign-in for the exact server numbers. The widget works without it
/// (local transcript estimate), so this is never forced and never a wall — it
/// only appears when the user explicitly chooses "show exact %". Signing in
/// stores the widget's own token (file store, no keychain); if it later lapses
/// the widget silently falls back to the estimate rather than nagging.
struct LoginView: View {
    @EnvironmentObject var login: OAuthLoginService
    @State private var pastedCode: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text("Show exact usage")
                .font(.headline)

            switch login.phase {
            case .idle, .done:
                Text("Optional: connect your Claude account to show the exact usage %. Skip it and the widget shows a local estimate from your transcripts — no sign-in needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Claude account") { login.beginLogin() }
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

            Button("Use local estimate instead") { login.reset() }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: Theme.popoverWidth, height: 300)
    }

    private func submit() {
        let code = pastedCode
        Task { await login.submitCode(code) }
    }
}
