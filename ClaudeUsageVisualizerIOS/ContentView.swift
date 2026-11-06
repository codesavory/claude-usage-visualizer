import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = IOSUsageViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLogin = false

    private var hasNumbers: Bool { vm.liveUsage?.hasRealNumbers == true }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.liveUsage == nil {
                    ProgressView("Loading usage…")
                } else if !hasNumbers {
                    WaitingForMacScreen(onSignIn: { showLogin = true }) { await vm.refreshNow() }
                } else {
                    UsageScreen(snapshot: vm.liveUsage) { await vm.refreshNow() }
                }
            }
            .navigationTitle("Claude Usage")
        }
        // Only reachable from the first-run screen, for someone with no Mac running
        // the widget. Numbers normally arrive from the Mac over iCloud.
        .sheet(isPresented: $showLogin) {
            LoginScreen(login: vm.loginService) { showLogin = false }
        }
        .onAppear { vm.start() }
        .onChange(of: scenePhase) { _, phase in
            // Refresh on a real return to the foreground. Skip while the initial
            // load is still running (this fires on launch too, and start()
            // already handles the first fetch) so the two don't race and briefly
            // surface a login state before the numbers land.
            if phase == .active && !vm.isLoading {
                Task { await vm.refreshNow() }
            }
        }
    }
}

// MARK: - Usage

private struct UsageScreen: View {
    let snapshot: OAuthUsageSnapshot?
    let refresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let s = snapshot {
                    UsageRing(title: "5-hour block",
                              ratio: min(1, s.fiveHour.utilization / 100),
                              resetsAt: s.fiveHour.projectedReset(period: UsageWindowPeriod.fiveHour),
                              status: s.status)
                    if s.sevenDay.resetsAt != .distantFuture {
                        WeeklyBar(window: s.sevenDay, sonnet: s.sevenDaySonnet, opus: s.sevenDayOpus)
                    }
                    Freshness(snapshot: s)
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

/// When the reading was taken, plus what to do if it's old. Never a sign-in prompt.
private struct Freshness: View {
    let snapshot: OAuthUsageSnapshot

    var body: some View {
        VStack(spacing: 2) {
            Text("Updated \(snapshot.fetchedAt, style: .relative) ago")
            if Date().timeIntervalSince(snapshot.fetchedAt) > 1800 {
                Text("Wake your Mac to refresh these numbers.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}

/// First run only: nothing has arrived from the Mac yet.
private struct WaitingForMacScreen: View {
    let onSignIn: () -> Void
    let refresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Waiting for your Mac").font(.title3.bold())
                Text("Keep the widget running on your Mac with the same iCloud account. Your usage appears here on its own, with nothing to sign in to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Check again") { Task { await refresh() } }
                    .buttonStyle(.borderedProminent)
                Button("No Mac? Sign in on this iPhone", action: onSignIn)
                    .font(.footnote)
                    .padding(.top, 12)
            }
            .padding(28)
            .padding(.top, 60)
        }
        .refreshable { await refresh() }
    }
}

private struct WeeklyBar: View {
    let window: OAuthUsageWindow
    var sonnet: OAuthUsageWindow? = nil
    var opus: OAuthUsageWindow? = nil

    private var ratio: Double { min(1, window.utilization / 100) }
    private var resetsAt: Date { window.projectedReset(period: UsageWindowPeriod.weekly) }
    private var tint: Color {
        if ratio > 0.9 { return .red }
        if ratio > 0.75 { return .orange }
        if ratio > 0.5 { return .yellow }
        return .green
    }

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
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * ratio)
                        .animation(.easeInOut(duration: 0.5), value: ratio)
                    // Where an even pace through the week would be right now.
                    if let elapsed = window.elapsedFraction(period: UsageWindowPeriod.weekly) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 2)
                            .offset(x: geo.size.width * elapsed)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel("Weekly usage \(Int((ratio * 100).rounded())) percent")
            if let pace = window.paceLabel(period: UsageWindowPeriod.weekly) {
                Text(pace).font(.subheadline.weight(.medium))
            }
            if let opus { modelLine("Opus", opus) }
            if let sonnet { modelLine("Sonnet", sonnet) }
            Text("resets \(resetsAt, style: .relative) · \(resetsAt, format: .dateTime.weekday().hour().minute())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private func modelLine(_ name: String, _ w: OAuthUsageWindow) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(Int(w.utilization.rounded()))%").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Login

private struct LoginScreen: View {
    @ObservedObject var login: OAuthLoginService
    @State private var pastedCode = ""
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Sign in to Claude").font(.title2.bold())
            Text("Or just sign in on your Mac — the code syncs here over iCloud, no typing.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            switch login.phase {
            case .idle, .done:
                Text("Connect this app to your Claude account once to see your live usage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Claude to sign in") { login.beginLogin() }
                    .buttonStyle(.borderedProminent)

            case .awaitingCode, .failed:
                Text("Approve access in Safari, tap Copy code, then paste it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("Paste code here", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    if let clip = UIPasteboard.general.string { pastedCode = clip }
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                        .font(.footnote)
                }
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
        .onChange(of: login.phase) { _, phase in
            if phase == .done { onDone?() }
        }
    }

    private func submit() {
        let code = pastedCode
        Task { await login.submitCode(code) }
    }
}
