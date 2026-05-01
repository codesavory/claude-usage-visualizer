import Combine
import Foundation
import SwiftUI

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var liveUsage: OAuthUsageSnapshot?
    @Published private(set) var suggestions: [OptimizationSuggestion] = []
    @Published private(set) var activeNudge: BreakNudge?
    @Published private(set) var statusIcon: StatusIconState = .offline
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var aiScheduleInsight: String? = nil
    @Published private(set) var habitSuggestion: HabitEngine.HabitSuggestion? = nil
    @Published private(set) var behavioralProfile: HabitEngine.BehavioralProfile? = nil
    @Published var dismissedNudgeIds: Set<UUID> = []
    @Published var dismissedHabitId: UUID? = nil

    func dismissHabit() { dismissedHabitId = habitSuggestion?.id }

    let apply = ApplyService()

    private let watcher = TranscriptWatcher()
    private let registry = SessionRegistry()
    private let aggregator = UsageAggregator()
    private let insights = InsightsEngine()

    private let oauth = OAuthUsageClient()
    private let aiService = AIInsightsServiceWrapper()
    private let habitEngine = HabitEngine()
    let historyStore = UsageHistoryStore()
    @Published private(set) var savedBlocks: [UsageHistoryStore.SavedBlock] = []
    private var oauthTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?

    private weak var settings: SettingsViewModel?
    private var watcherTask: Task<Void, Never>?
    private var registryTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastBlockAnchor: Date?

    func start(settings: SettingsViewModel) async {
        self.settings = settings
        isLoading = true
        await aggregator.updateThresholds(
            warm: settings.burnWarmThreshold,
            hot: settings.burnHotThreshold,
            critical: settings.burnCriticalThreshold
        )

        let backfillSince = Date().addingTimeInterval(-7 * 24 * 3600)
        let eventStream = await watcher.start(backfillSince: backfillSince)
        let sessionStream = await registry.start()

        watcherTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventStream {
                await self.aggregator.ingest(event)
            }
        }

        registryTask = Task { [weak self] in
            guard let self else { return }
            for await sessions in sessionStream {
                await self.aggregator.bind(sessions: sessions)
            }
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.recompute()
                try? await Task.sleep(nanoseconds: UInt64(max(1.0, settings.refreshIntervalSeconds) * 1_000_000_000))
            }
        }

        oauthTask = Task { [weak self] in
            // Prime immediately, then refresh every 60s — the client itself
            // enforces the 6-min TTL + 429 backoff internally.
            while !Task.isCancelled {
                await self?.refreshOAuthUsage()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func stop() async {
        watcherTask?.cancel()
        registryTask?.cancel()
        tickTask?.cancel()
        oauthTask?.cancel()
        await watcher.stop()
        await registry.stop()
    }

    func refreshOAuthUsage() async {
        let snap = await oauth.refreshIfNeeded()
        liveUsage = snap
    }

    func refreshNow() async {
        let snap = await oauth.forceRefresh()
        liveUsage = snap
        await recompute()
    }

    func dismissNudge(_ nudge: BreakNudge) {
        dismissedNudgeIds.insert(nudge.id)
        if activeNudge?.id == nudge.id {
            activeNudge = nil
        }
    }

    private func recompute() async {
        let snap = await aggregator.currentSnapshot()
        let tier = settings?.tier ?? .max5x
        let out = await insights.evaluate(snap, tier: tier, liveUsage: liveUsage)

        // Block-change housekeeping
        let anchor = snap.currentBlock?.startedAt
        if anchor != lastBlockAnchor {
            dismissedNudgeIds.removeAll()
            lastBlockAnchor = anchor
        }

        snapshot = snap
        suggestions = out.suggestions
        if let nudge = out.nudge, !dismissedNudgeIds.contains(nudge.id) {
            if activeNudge?.mood != nudge.mood {
                activeNudge = nudge
            }
        } else if out.nudge == nil {
            activeNudge = nil
        }
        statusIcon = computeStatusIcon(snap: snap, tier: tier)
        isLoading = false

        // Persist blocks to history store and expose saved blocks for schedule view
        let allLiveBlocks = (snap.previousBlocks + [snap.currentBlock].compactMap { $0 })
        await historyStore.merge(blocks: allLiveBlocks)
        savedBlocks = await historyStore.allBlocks()

        // Habit analysis
        let habitResult = await habitEngine.analyze(snap, liveUsage: liveUsage)
        habitSuggestion = habitResult
        behavioralProfile = await habitEngine.buildProfile(snapshot: snap, liveUsage: liveUsage)

        // Kick off AI insight generation in the background (throttled internally)
        let blocks = snap.previousBlocks
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            if let insight = await self.aiService.generateScheduleInsight(blocks: blocks, tier: tier) {
                self.aiScheduleInsight = insight
            }
        }
    }

    private func computeStatusIcon(snap: UsageSnapshot, tier: UsageTier) -> StatusIconState {
        // Prefer live Anthropic utilization if we have it.
        let ratio: Double
        if let live = liveUsage, live.status == .live || live.status == .rateLimited {
            ratio = live.fiveHour.utilization / 100.0
        } else if let block = snap.currentBlock {
            ratio = Double(block.messageCount) / Double(max(tier.messagesPerBlock, 1))
        } else {
            return snap.sessions.contains(where: { $0.isRunning }) ? .chill : .offline
        }

        if ratio >= 0.9 { return .critical }
        if ratio >= 0.75 {
            // Cap is close regardless of burn rate.
            return snap.burn.severity == .critical ? .critical : .hot
        }
        switch snap.burn.severity {
        case .chill: return ratio >= 0.5 ? .warm : .chill
        case .warm: return .warm
        case .hot: return .hot
        case .critical: return .critical
        }
    }
}
