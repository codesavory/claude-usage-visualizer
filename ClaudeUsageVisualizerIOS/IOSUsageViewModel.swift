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
    private var iCloudObserver: NSObjectProtocol?

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

        // Adopt a token validated on the Mac (published via the shared iCloud
        // key-value store) whenever it arrives, then refresh. This is what makes
        // "sign in once, both devices work" seamless from the phone's side.
        iCloudObserver = ICloudTokenSync.observe { [weak self] in
            Task { [weak self] in
                // Fires for a new token or a new reading from the Mac.
                await self?.refresh(force: false)
            }
        }

        pollTask = Task { [weak self] in
            guard let self else { return }
            // Adopt any iCloud-shared token BEFORE the first fetch, so a token the
            // Mac validated logs the phone in with no sign-in here.
            await self.credentials.syncFromICloudIfNewer()
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

    func refreshNow() async {
        await credentials.syncFromICloudIfNewer()
        await refresh(force: true)
    }

    private func refresh(force: Bool) async {
        await credentials.syncFromICloudIfNewer()
        let mac = ICloudUsageSync.pull()
        // Ask the endpoint only when the Mac hasn't reported recently, or a little
        // sooner on an explicit pull to refresh.
        let macIsCurrent = UsageSourcePicker.isFresh(mac, within: force ? 60 : UsageSourcePicker.macFreshFor)
        let own: OAuthUsageSnapshot?
        if macIsCurrent {
            own = await oauth.lastKnown()
        } else {
            own = force ? await oauth.forceRefresh() : await oauth.refreshIfNeeded()
        }
        let picked = UsageSourcePicker.pick(own: own, mac: mac)
        liveUsage = picked
        isLoading = false
        if let picked, picked.status == .live || picked.status == .rateLimited {
            UsageSnapshotStore.save(picked)
        }
    }
}
