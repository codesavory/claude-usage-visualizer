import Testing
import Foundation
@testable import ClaudeUsageVisualizer

@Suite("OAuthUsageClient parsing")
struct OAuthParsingTests {

    private let fetchedAt = Date(timeIntervalSince1970: 0)

    // MARK: parseDate

    @Test func parseDate_withFractionalSeconds() {
        let d = OAuthUsageClient.parseDate("2025-06-01T12:00:00.000Z")
        #expect(d != nil)
    }

    @Test func parseDate_withoutFractionalSeconds() {
        let d = OAuthUsageClient.parseDate("2025-06-01T12:00:00Z")
        #expect(d != nil)
    }

    @Test func parseDate_invalid_returns_nil() {
        #expect(OAuthUsageClient.parseDate("not-a-date") == nil)
        #expect(OAuthUsageClient.parseDate("") == nil)
    }

    // MARK: parseResponse — happy path

    @Test func parseResponse_snakeCase() throws {
        let json = """
        {
            "five_hour": {"utilization": 42.5, "resets_at": "2025-06-01T12:00:00Z"},
            "seven_day": {"utilization": 10.0, "resets_at": "2025-06-07T00:00:00Z"}
        }
        """.data(using: .utf8)!

        let snap = OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt)
        let s = try #require(snap)
        #expect(s.fiveHour.utilization == 42.5)
        #expect(s.sevenDay.utilization == 10.0)
        #expect(s.status == .live)
    }

    @Test func parseResponse_camelCase() throws {
        let json = """
        {
            "fiveHour": {"utilization": 75, "resetsAt": "2025-06-01T12:00:00Z"},
            "sevenDay": {"utilization": 20, "resetsAt": "2025-06-07T00:00:00Z"}
        }
        """.data(using: .utf8)!

        let snap = OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt)
        let s = try #require(snap)
        #expect(s.fiveHour.utilization == 75)
        #expect(s.sevenDay.utilization == 20)
    }

    @Test func parseResponse_intUtilization() throws {
        // utilization as Int, not Double
        let json = """
        {
            "five_hour": {"utilization": 0, "resets_at": "2025-06-01T12:00:00Z"},
            "seven_day": {"utilization": 100, "resets_at": "2025-06-07T00:00:00Z"}
        }
        """.data(using: .utf8)!

        let snap = OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt)
        let s = try #require(snap)
        #expect(s.fiveHour.utilization == 0)
        #expect(s.sevenDay.utilization == 100)
    }

    @Test func parseResponse_withOptionalModelWindows() throws {
        let json = """
        {
            "five_hour": {"utilization": 50, "resets_at": "2025-06-01T12:00:00Z"},
            "seven_day": {"utilization": 30, "resets_at": "2025-06-07T00:00:00Z"},
            "seven_day_sonnet": {"utilization": 15, "resets_at": "2025-06-07T00:00:00Z"},
            "seven_day_opus": {"utilization": 5, "resets_at": "2025-06-07T00:00:00Z"}
        }
        """.data(using: .utf8)!

        let snap = OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt)
        let s = try #require(snap)
        #expect(s.sevenDaySonnet?.utilization == 15)
        #expect(s.sevenDayOpus?.utilization == 5)
    }

    @Test func parseResponse_missingResetsAt_falls_back_to_distantFuture() throws {
        let json = """
        {
            "five_hour": {"utilization": 10},
            "seven_day": {"utilization": 5}
        }
        """.data(using: .utf8)!

        let snap = OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt)
        let s = try #require(snap)
        #expect(s.fiveHour.resetsAt == .distantFuture)
    }

    // MARK: parseResponse — failure cases

    @Test func parseResponse_missingFiveHour_returns_nil() {
        let json = """
        {"seven_day": {"utilization": 5, "resets_at": "2025-06-07T00:00:00Z"}}
        """.data(using: .utf8)!
        #expect(OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt) == nil)
    }

    @Test func parseResponse_emptyObject_returns_nil() {
        let json = "{}".data(using: .utf8)!
        #expect(OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt) == nil)
    }

    @Test func parseResponse_invalidJSON_returns_nil() {
        let garbage = "not json".data(using: .utf8)!
        #expect(OAuthUsageClient.parseResponse(garbage, fetchedAt: fetchedAt) == nil)
    }

    // MARK: plan inference

    /// A per-model weekly window is only returned on Max plans, so its absence
    /// is the Pro signal used for the plan badge and the usage_cache plan_name.
    @Test func planSignal_proResponse_hasNoOpusWindow() throws {
        let json = """
        {
            "five_hour": {"utilization": 43, "resets_at": "2026-07-23T07:00:00Z"},
            "seven_day": {"utilization": 25, "resets_at": "2026-07-26T02:59:00Z"}
        }
        """.data(using: .utf8)!

        let s = try #require(OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt))
        #expect(s.sevenDayOpus == nil)
        #expect(s.status == .live)
    }

    @Test func planSignal_maxResponse_hasOpusWindow() throws {
        let json = """
        {
            "five_hour": {"utilization": 43, "resets_at": "2026-07-23T07:00:00Z"},
            "seven_day": {"utilization": 25, "resets_at": "2026-07-26T02:59:00Z"},
            "seven_day_opus": {"utilization": 8, "resets_at": "2026-07-26T02:59:00Z"}
        }
        """.data(using: .utf8)!

        let s = try #require(OAuthUsageClient.parseResponse(json, fetchedAt: fetchedAt))
        #expect(s.sevenDayOpus != nil)
    }
}

@Suite("UsageTier")
struct UsageTierTests {

    @Test func pro_isAvailableAndNamed() {
        #expect(UsageTier(rawValue: "pro") == .pro)
        #expect(UsageTier.pro.displayName == "Pro")
        #expect(UsageTier.allCases.contains(.pro))
    }

    /// Max tiers are named for their multiple of the Pro allowance.
    @Test func maxTiers_areMultiplesOfPro() {
        #expect(UsageTier.max5x.messagesPerBlock == UsageTier.pro.messagesPerBlock * 5)
        #expect(UsageTier.max20x.messagesPerBlock == UsageTier.pro.messagesPerBlock * 20)
    }

    @Test func unknownRawValue_isNil() {
        #expect(UsageTier(rawValue: "team") == nil)
    }
}
