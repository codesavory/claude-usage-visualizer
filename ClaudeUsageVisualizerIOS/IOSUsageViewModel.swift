import Combine
import SwiftUI

/// Slim view model for the iOS app: only the OAuth usage pipeline, none of the
/// macOS transcript/session machinery. Polls the usage endpoint, seeds and
/// persists the last-known snapshot so numbers show instantly and survive a
/// lapsed token.
@MainActor
final class IOSUsageViewModel: ObservableObject {
    @Published private(set) var liveUsage: OAuthUsageSnapshot?
    @Published private(set) var isLoading = true

    let loginService: OAuthLoginService
    private let credentials: CredentialsManager
    private let oauth: OAuthUsageClient
    private var pollTask: Task<Void, Never>?

    init() {
        let creds = CredentialsManager()
        credentials = creds
        oauth = OAuthUsageClient(credentials: creds)
        loginService = OAuthLoginService(credentials: creds)
        loginService.onSignedIn = { [weak self] in
            Task { await self?.refreshNow() }
        }
    }

    func start() {
        guard pollTask == nil else { return }
        let seeded = UsageSnapshotStore.load()
        if let seeded { liveUsage = seeded }
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Seed the OAuth client's cache with the last-known snapshot BEFORE
            // the first fetch. If that fetch briefly comes back needsLogin (an
            // expired token being refreshed), performFetch then returns the
            // seeded numbers instead of an empty one — so the UI stays on the
            // usage screen and never flashes the full login screen before the
            // real percentage lands.
            if let seeded { await self.oauth.seed(seeded) }
            while !Task.isCancelled {
                await self.refresh(force: false)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func refreshNow() async { await refresh(force: true) }

    private func refresh(force: Bool) async {
        let snap = force ? await oauth.forceRefresh() : await oauth.refreshIfNeeded()
        liveUsage = snap
        isLoading = false
        if let snap, snap.status == .live || snap.status == .rateLimited {
            UsageSnapshotStore.save(snap)
        }
    }
}
