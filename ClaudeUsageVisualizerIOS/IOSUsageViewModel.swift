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
        if let seeded = UsageSnapshotStore.load() { liveUsage = seeded }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
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
