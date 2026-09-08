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
            } else if signingIn {
                // Only when the user explicitly opted into the exact-numbers
                // sign-in. Auth is never forced; a missing/dead token just falls
                // back to the local estimate below.
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

    /// Unobtrusive opt-in for the exact server numbers. Shown in the footer only
    /// when we're on the local estimate. Tapping starts the optional OAuth
    /// sign-in (no keychain); the widget never requires it.
    private var exactButton: some View {
        Button {
            Task { await viewModel.refreshFromKeychain() }
        } label: {
            Text("exact %")
                .font(.caption2)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .help("Unlock Claude Code's keychain token (laptop password) to show the exact usage %")
    }

    @ViewBuilder
    private func weeklyBar(_ week: OAuthUsageWindow) -> some View {
        let r = min(1.0, week.utilization / 100.0)
        // Project the weekly reset onto the current window so the countdown stays
        // correct even from a stale last-known snapshot (weekly grid is fixed).
        let reset = week.projectedReset(period: UsageWindowPeriod.weekly)
        let secs = reset == .distantFuture ? 0 : max(0, reset.timeIntervalSince(Date()))
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
                    Text(" · resets \(DurationFormatter.daysAndHours(secs)) · \(DurationFormatter.clockTimeWithWeekday(reset))")
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
                    .fill(hasLiveUsage ? .green : Color.secondary)
                    .frame(width: 6, height: 6)
                // live = fresh server number; cached = last-known server total
                // (still the true cross-surface usage, just not re-fetched);
                // estimate = local transcript fallback, no server number yet.
                Text(hasLiveUsage ? "live" : (hasLastKnownUsage ? "cached" : "estimate"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !hasLiveUsage {
                exactButton
            }
            Spacer()

            // Usage credits: pay-as-you-go past the plan cap. When on, hitting the
            // cap no longer flips the menu-bar icon to the dead "XO".
            Toggle(isOn: $settings.usageCreditsEnabled) {
                Image(systemName: "creditcard")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(settings.usageCreditsEnabled ? Color.green : .secondary)
            .help("Usage credits — keep going past the plan cap (no dead XO at 100%)")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)

            Button {
                // Manual refresh reads Claude Code's own keychain token (raises
                // the laptop password prompt) to show the exact server number.
                // No browser sign-in. Background polls stay silent.
                Task { await viewModel.refreshFromKeychain() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh · unlocks Claude Code's keychain token for the exact usage %")

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
