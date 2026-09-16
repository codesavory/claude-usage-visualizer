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

    init() {
        let creds = CredentialsManager()
        credentials = creds
        oauth = OAuthUsageClient(credentials: creds)
        loginService = OAuthLoginService(credentials: creds)
        loginService.onSignedIn = { [weak self] in
            Task { await self?.refreshNow() }
        }
    }

    let apply = ApplyService()

    private let watcher = TranscriptWatcher()
    private let registry = SessionRegistry()
    private let aggregator = UsageAggregator()
    private let insights = InsightsEngine()

    /// Shared credential store: the usage client reads the token, the login
    /// service writes it after a one-time sign-in. Both talk to the same
    /// app-owned keychain item, so no login-password prompt ever fires.
    private let credentials: CredentialsManager
    private let oauth: OAuthUsageClient
    /// Exposed so the popover can present the sign-in UI.
    let loginService: OAuthLoginService

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

        // Seed last-known usage from disk so the popover shows numbers the moment
        // it opens — before the first poll, and even if that poll fails because
        // the grant lapsed. Keeps the widget on the usage view instead of a
        // full-screen sign-in wall whenever real numbers were ever fetched.
        if let seeded = UsageSnapshotStore.load() {
            liveUsage = seeded
            await oauth.seed(seeded)
        }
        // Start the OAuth usage poll FIRST, before the potentially slow 7-day
        // transcript backfill below. The server number is the primary display,
        // and it must not wait on transcript scanning (which can take many
        // seconds with large sessions open). This is what the iPhone app does:
        // poll the endpoint straight away, independent of any local machinery.
        oauthTask = Task { [weak self] in
            // Prime immediately, then refresh every 60s — the client itself
            // enforces the 6-min TTL + 429 backoff internally.
            while !Task.isCancelled {
                await self?.refreshOAuthUsage()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }

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
        if let snap {
            syncTierFromLiveUsage(snap)
            // Only persist a genuine reading. A `needsLogin`/`unavailable` snapshot
            // carries placeholder numbers (or a preserved-but-stale copy); writing
            // it would clobber the last-known-good usage on disk.
            if snap.status == .live || snap.status == .rateLimited {
                writeUsageCache(snap)
                UsageSnapshotStore.save(snap)
            }
        }
    }

    /// Corrects the stored plan tier from the live API. The usage endpoint only
    /// returns a per-model weekly window on Max plans, so it can tell Pro from
    /// Max but not Max 5x from Max 20x — the Max sub-tier is left as the user
    /// set it. Only runs on a live response; a stale or unavailable snapshot
    /// must never overwrite the setting.
    private func syncTierFromLiveUsage(_ snap: OAuthUsageSnapshot) {
        guard snap.status == .live, let settings else { return }
        let isMax = snap.sevenDayOpus != nil
        if isMax, settings.tier == .pro {
            settings.tier = .max5x
        } else if !isMax, settings.tier != .pro {
            settings.tier = .pro
        }
    }

    private func writeUsageCache(_ snap: OAuthUsageSnapshot) {
        let fh = snap.fiveHour
        let mins = Int(fh.resetsAt.timeIntervalSinceNow / 60)
        let fmt = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "percent": fh.utilization / 100.0,
            "utilization_pct": fh.utilization,
            "resets_at": fmt.string(from: fh.resetsAt),
            "minutes_until_reset": max(0, mins),
            "source": "visualizer",
            "updated_at": fmt.string(from: snap.fetchedAt),
        ]
        let wk = snap.sevenDay
        if wk.resetsAt != .distantFuture {
            let wkMins = Int(wk.resetsAt.timeIntervalSinceNow / 60)
            dict["weekly_percent"] = wk.utilization / 100.0
            dict["weekly_utilization_pct"] = wk.utilization
            dict["weekly_resets_at"] = fmt.string(from: wk.resetsAt)
            dict["weekly_minutes_until_reset"] = max(0, wkMins)
        }
        // Plan detection: Max plan users have a separate per-model weekly budget;
        // Pro users have sevenDayOpus == nil.
        if snap.sevenDayOpus != nil {
            dict["plan_name"] = "Max"
            dict["plan_price"] = "$100+/mo"
        } else if snap.status == .live || snap.status == .rateLimited {
            dict["plan_name"] = "Pro"
            dict["plan_price"] = "$20/mo"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usage_cache.json")
        try? data.write(to: url)
    }

    func refreshNow() async {
        let snap = await oauth.forceRefresh()
        liveUsage = snap
        await recompute()
    }

    /// Called every time the popover opens. Fetches the latest usage right away
    /// (opportunistically pulling Claude Code's keychain token if the OS lets us
    /// read it silently). Never prompts — so opening the widget always shows the
    /// freshest number it can get without interrupting the user.
    func refreshOnAppear() async {
        let snap = await oauth.refreshOnAppear()
        liveUsage = snap
        await recompute()
    }

    /// Manual-refresh path. Tries a normal fetch first; if that doesn't yield a
    /// live server reading (no token yet, or the stored one expired), it adopts
    /// Claude Code's own keychain token — raising the laptop password prompt —
    /// and fetches again. This replaces the browser sign-in routine entirely.
    func refreshFromKeychain() async {
        var snap = await oauth.forceRefresh()
        if snap?.status != .live && snap?.status != .rateLimited {
            snap = await oauth.adoptClaudeCodeTokenAndRefresh()
        }
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
        // Signed out of Claude -> dead "XO". A missing/dead token surfaces as a
        // needsLogin/unauthorized live status.
        if let live = liveUsage, live.status == .needsLogin || live.status == .unauthorized {
            return .dead
        }

        // Prefer live Anthropic utilization if we have it.
        let ratio: Double
        if let live = liveUsage, live.status == .live || live.status == .rateLimited {
            ratio = live.fiveHour.utilization / 100.0
        } else if let block = snap.currentBlock {
            ratio = Double(block.messageCount) / Double(max(tier.messagesPerBlock, 1))
        } else {
            return snap.sessions.contains(where: { $0.isRunning }) ? .chill : .offline
        }

        // Budget fully spent (100%) -> dead "XO", unless usage credits are enabled
        // (pay-as-you-go past the cap keeps the session alive).
        let creditsEnabled = UserDefaults.standard.bool(forKey: "usageCreditsEnabled")
        if ratio >= 1.0 && !creditsEnabled { return .dead }

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
