import SwiftUI

struct PopoverContentView: View {
    @EnvironmentObject var viewModel: UsageViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var login: OAuthLoginService
    @ObservedObject var apply: ApplyService

    /// True when the OAuth usage API returned real numbers. Those come from
    /// Anthropic's servers and are independent of any local `~/.claude/projects`
    /// transcript, so the popover shows them even with no local session.
    private var hasLiveUsage: Bool {
        guard let live = viewModel.liveUsage else { return false }
        return live.status == .live || live.status == .rateLimited
    }

    /// True when the widget has no usable token of its own and needs a one-time
    /// interactive sign-in.
    private var needsLogin: Bool {
        switch viewModel.liveUsage?.status {
        case .needsLogin, .unauthorized: return true
        default: return false
        }
    }

    /// True when we hold real usage numbers (seeded from disk or a prior live
    /// poll), even if the current status is stale/needsLogin. Keeps the popover
    /// on the usage view instead of a full-screen sign-in wall.
    private var hasLastKnownUsage: Bool {
        viewModel.liveUsage?.hasRealNumbers == true
    }

    /// True while an interactive sign-in is underway (browser opened, awaiting the
    /// pasted code). The paste step lives in `LoginView`, so show it then.
    private var signingIn: Bool {
        switch login.phase {
        case .awaitingCode, .exchanging, .failed: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loading
            } else if signingIn || (needsLogin && !hasLastKnownUsage) {
                LoginView()
            } else if viewModel.snapshot.currentBlock == nil && viewModel.snapshot.sessions.isEmpty && !hasLiveUsage && !hasLastKnownUsage {
                OnboardingView()
            } else {
                content
            }
            if let live = viewModel.liveUsage, live.sevenDay.resetsAt != .distantFuture {
                weeklyBar(live.sevenDay)
            }
            footer
        }
        .frame(width: Theme.popoverWidth)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            if let message = apply.hudMessage {
                HUDView(message: message)
                    .padding(.bottom, 36)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: apply.hudMessage)
        .sheet(item: Binding(
            get: { apply.pendingPatch.map { PatchBox(patch: $0) } },
            set: { _ in }
        )) { box in
            ApplyConfirmSheet(
                patch: box.patch,
                onConfirm: { apply.confirmPendingPatch() },
                onCancel: { apply.dismissPendingPatch() }
            )
        }
    }

    private var content: some View {
        VStack(spacing: Theme.sectionSpacing) {
            if needsLogin {
                signInBanner
            }

            UsageHeaderView()

            Divider()

            SessionListView(sessions: viewModel.snapshot.sessions)

            Divider()

            BlockScheduleView(
                allBlocks: (viewModel.snapshot.previousBlocks + [viewModel.snapshot.currentBlock].compactMap { $0 }).sorted { $0.startedAt < $1.startedAt },
                currentBlock: viewModel.snapshot.currentBlock,
                liveUsage: viewModel.liveUsage,
                weeklyTotals: viewModel.snapshot.weeklyTotals,
                aiInsight: viewModel.aiScheduleInsight,
                profile: viewModel.behavioralProfile,
                savedBlocks: viewModel.savedBlocks
            )
        }
        .padding(Theme.popoverPadding)
    }

    /// Non-blocking sign-in prompt shown above the numbers when the grant has
    /// lapsed. The numbers stay visible (marked stale); tapping starts the
    /// one-time re-sign-in, which then switches to `LoginView` for the paste step.
    private var signInBanner: some View {
        Button {
            Task { await viewModel.refreshNow() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                Text("Numbers may be stale — allow keychain access.")
                    .font(.caption2)
                Spacer()
                Text("Retry")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func weeklyBar(_ week: OAuthUsageWindow) -> some View {
        let r = min(1.0, week.utilization / 100.0)
        let secs = week.resetsAt == .distantFuture ? 0 : max(0, week.resetsAt.timeIntervalSince(Date()))
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.07))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.20))
                        .frame(width: geo.size.width * r)
                        .animation(.easeInOut(duration: 0.4), value: r)
                }
            }
            .frame(height: 2)
            HStack(spacing: 0) {
                Text("\(Int((r * 100).rounded()))% weekly")
                if secs > 0 {
                    Text(" · resets \(DurationFormatter.daysAndHours(secs)) · \(DurationFormatter.clockTimeWithWeekday(week.resetsAt))")
                }
                Spacer()
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.quaternary)
            .padding(.horizontal, Theme.popoverPadding)
            .padding(.bottom, 4)
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Scanning transcripts…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 200)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("live")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.popoverPadding)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct PatchBox: Identifiable {
    let patch: SettingsPatch
    var id: String { patch.keyPath }
}

private struct HUDView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(.ultraThickMaterial)
            )
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
