import Testing
import Foundation
@testable import ClaudeUsageVisualizer

@Suite("iPhone shows the Mac's numbers without a sign-in")
struct UsageSourcePickerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func snap(_ age: TimeInterval, _ status: OAuthUsageSnapshot.Staleness = .live, pct: Double = 40) -> OAuthUsageSnapshot {
        let w = OAuthUsageWindow(utilization: pct, resetsAt: now.addingTimeInterval(3600))
        return OAuthUsageSnapshot(fiveHour: w, sevenDay: w, sevenDaySonnet: nil, sevenDayOpus: nil,
                                  fetchedAt: now.addingTimeInterval(-age), status: status)
    }

    private func placeholder(_ status: OAuthUsageSnapshot.Staleness) -> OAuthUsageSnapshot {
        let w = OAuthUsageWindow(utilization: 0, resetsAt: .distantFuture)
        return OAuthUsageSnapshot(fiveHour: w, sevenDay: w, sevenDaySonnet: nil, sevenDayOpus: nil, fetchedAt: now, status: status)
    }

    @Test func rejectedToken_stillShowsTheMacReading() {
        // A rejected fetch stamps fetchedAt = now, so comparing dates alone would
        // let the failure beat a real reading.
        let picked = UsageSourcePicker.pick(own: snap(0, .unauthorized, pct: 5), mac: snap(120, pct: 40), now: now)
        #expect(picked?.fiveHour.utilization == 40)
        #expect(picked?.status == .live)
    }

    @Test func newestGenuineReadingWins() {
        #expect(UsageSourcePicker.pick(own: snap(10, pct: 11), mac: snap(100, pct: 22), now: now)?.fiveHour.utilization == 11)
        #expect(UsageSourcePicker.pick(own: snap(100, pct: 11), mac: snap(10, pct: 22), now: now)?.fiveHour.utilization == 22)
    }

    @Test func oldMacReadingIsLabelledStaleButStillShown() {
        let picked = UsageSourcePicker.pick(own: nil, mac: snap(UsageSourcePicker.liveFor + 1), now: now)
        #expect(picked?.status == .stale)
        #expect(picked?.hasRealNumbers == true)
    }

    @Test func noNumbersAnywhere_isNil_soTheWaitingScreenShows() {
        #expect(UsageSourcePicker.pick(own: placeholder(.needsLogin), mac: nil, now: now) == nil)
        #expect(UsageSourcePicker.pick(own: nil, mac: nil, now: now) == nil)
    }

    @Test func lastKnownNumbersSurviveADeadToken() {
        #expect(UsageSourcePicker.pick(own: snap(9000, .needsLogin), mac: nil, now: now)?.status == .stale)
    }

    @Test func freshMacReadingSkipsTheNetwork() {
        #expect(UsageSourcePicker.isFresh(snap(60), now: now))
        #expect(!UsageSourcePicker.isFresh(snap(UsageSourcePicker.macFreshFor + 1), now: now))
        #expect(!UsageSourcePicker.isFresh(nil, now: now))
        #expect(!UsageSourcePicker.isFresh(placeholder(.live), now: now))
    }

    @Test func snapshotSurvivesTheICloudEncoding() throws {
        let data = try JSONEncoder.cuv.encode(snap(0))
        let back = try JSONDecoder.cuv.decode(OAuthUsageSnapshot.self, from: data)
        #expect(back.fiveHour.utilization == 40)
        #expect(back.status == .live)
    }

    private func env(_ token: String, exp: TimeInterval, updated: TimeInterval) -> BiometricCredentialStore.Envelope {
        .init(accessToken: token, refreshToken: "r", expiresAt: now.addingTimeInterval(exp), updatedAt: now.addingTimeInterval(updated))
    }

    @Test func expiredLocalTokenYieldsEvenWhenStampedLater() {
        // The stuck state: the phone's dead token carried a later updatedAt.
        #expect(CredentialsManager.shouldAdopt(remote: env("mac", exp: 3600, updated: -500),
                                               local: env("dead", exp: -10, updated: -1), now: now))
    }

    @Test func validNewerLocalTokenIsKept() {
        #expect(!CredentialsManager.shouldAdopt(remote: env("mac", exp: 3600, updated: -500),
                                                local: env("mine", exp: 7200, updated: -1), now: now))
        #expect(!CredentialsManager.shouldAdopt(remote: env("same", exp: 3600, updated: 0),
                                                local: env("same", exp: 3600, updated: -9), now: now))
    }

    @Test func paceLabelComparesUsageWithTheWeekElapsed() {
        let period = UsageWindowPeriod.weekly
        // Half the week gone.
        let reset = now.addingTimeInterval(period / 2)
        #expect(OAuthUsageWindow(utilization: 50, resetsAt: reset).paceLabel(period: period, now: now) == "on pace")
        #expect(OAuthUsageWindow(utilization: 70, resetsAt: reset).paceLabel(period: period, now: now) == "20% over pace")
        #expect(OAuthUsageWindow(utilization: 30, resetsAt: reset).paceLabel(period: period, now: now) == "20% under pace")
        #expect(OAuthUsageWindow(utilization: 30, resetsAt: .distantFuture).paceLabel(period: period, now: now) == nil)
    }
}
