import SwiftUI

struct PopoverContentView: View {
    @EnvironmentObject var viewModel: UsageViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @ObservedObject var apply: ApplyService

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loading
            } else if viewModel.snapshot.currentBlock == nil && viewModel.snapshot.sessions.isEmpty {
                OnboardingView()
            } else {
                content
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
