import SwiftUI

struct ContentView: View {
    @StateObject private var vm = IOSUsageViewModel()

    private var needsLogin: Bool {
        switch vm.liveUsage?.status {
        case .needsLogin, .unauthorized: return true
        default: return false
        }
    }
    private var hasNumbers: Bool { vm.liveUsage?.hasRealNumbers == true }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.liveUsage == nil {
                    ProgressView("Loading usage…")
                } else if needsLogin && !hasNumbers {
                    LoginScreen(login: vm.loginService)
                } else {
                    UsageScreen(snapshot: vm.liveUsage, needsLogin: needsLogin, login: vm.loginService) {
                        await vm.refreshNow()
                    }
                }
            }
            .navigationTitle("Claude Usage")
        }
        .onAppear { vm.start() }
    }
}

// MARK: - Usage

private struct UsageScreen: View {
    let snapshot: OAuthUsageSnapshot?
    let needsLogin: Bool
    let login: OAuthLoginService
    let refresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if needsLogin {
                    SignInBanner(login: login)
                }
                if let s = snapshot {
                    UsageRing(title: "5-hour block",
                              ratio: min(1, s.fiveHour.utilization / 100),
                              resetsAt: s.fiveHour.projectedReset(period: UsageWindowPeriod.fiveHour),
                              status: s.status)
                    if s.sevenDay.resetsAt != .distantFuture {
                        WeeklyBar(ratio: min(1, s.sevenDay.utilization / 100),
                                  resetsAt: s.sevenDay.projectedReset(period: UsageWindowPeriod.weekly))
                    }
                }
            }
            .padding(24)
        }
        .refreshable { await refresh() }
    }
}

private struct UsageRing: View {
    let title: String
    let ratio: Double
    let resetsAt: Date
    let status: OAuthUsageSnapshot.Staleness

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 18)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(tint, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: ratio)
                VStack(spacing: 2) {
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)

            if resetsAt != .distantFuture {
                Text("resets \(resetsAt, style: .relative) · \(resetsAt, format: .dateTime.hour().minute())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            statusLabel
        }
    }

    private var tint: Color {
        if ratio > 0.9 { return .red }
        if ratio > 0.75 { return .orange }
        if ratio > 0.5 { return .yellow }
        return .green
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .live:
            Label("live", systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .rateLimited:
            Label("cached", systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(.orange)
        default:
            Label("stale", systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct WeeklyBar: View {
    let ratio: Double
    let resetsAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weekly (all models)").font(.headline)
                Spacer()
                Text("\(Int((ratio * 100).rounded()))%").font(.headline).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * ratio)
                        .animation(.easeInOut(duration: 0.5), value: ratio)
                }
            }
            .frame(height: 10)
            Text("resets \(resetsAt, style: .relative) · \(resetsAt, format: .dateTime.weekday().hour().minute())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }
}

private struct SignInBanner: View {
    let login: OAuthLoginService
    var body: some View {
        Button {
            login.beginLogin()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                Text("Signed out — numbers may be stale.")
                    .font(.subheadline)
                Spacer()
                Text("Sign in").fontWeight(.semibold)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Login

private struct LoginScreen: View {
    @ObservedObject var login: OAuthLoginService
    @State private var pastedCode = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Sign in to Claude").font(.title2.bold())

            switch login.phase {
            case .idle, .done:
                Text("Connect this app to your Claude account once to see your live usage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Claude to sign in") { login.beginLogin() }
                    .buttonStyle(.borderedProminent)

            case .awaitingCode, .failed:
                Text("Approve access in Safari, then paste the code Anthropic shows you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("Paste code here", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if case .failed(let message) = login.phase {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Button("Reopen") { login.beginLogin() }
                    Spacer()
                    Button("Sign in") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            case .exchanging:
                ProgressView("Signing in…")
            }
            Spacer()
        }
        .padding(28)
    }

    private func submit() {
        let code = pastedCode
        Task { await login.submitCode(code) }
    }
}
