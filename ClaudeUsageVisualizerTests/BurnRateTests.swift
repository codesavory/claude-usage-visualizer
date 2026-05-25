import Testing
@testable import ClaudeUsageVisualizer

@Suite("BurnRate.severity")
struct BurnRateTests {

    @Test func chill_below_warm_threshold() {
        #expect(BurnRate.severity(forTokensPerMinute: 0) == .chill)
        #expect(BurnRate.severity(forTokensPerMinute: 1_999) == .chill)
    }

    @Test func warm_at_threshold() {
        #expect(BurnRate.severity(forTokensPerMinute: 2_000) == .warm)
        #expect(BurnRate.severity(forTokensPerMinute: 7_999) == .warm)
    }

    @Test func hot_at_threshold() {
        #expect(BurnRate.severity(forTokensPerMinute: 8_000) == .hot)
        #expect(BurnRate.severity(forTokensPerMinute: 19_999) == .hot)
    }

    @Test func critical_at_threshold() {
        #expect(BurnRate.severity(forTokensPerMinute: 20_000) == .critical)
        #expect(BurnRate.severity(forTokensPerMinute: 100_000) == .critical)
    }

    @Test func custom_thresholds() {
        #expect(BurnRate.severity(forTokensPerMinute: 500,
                                  warmThreshold: 1_000,
                                  hotThreshold: 5_000,
                                  criticalThreshold: 10_000) == .chill)
        #expect(BurnRate.severity(forTokensPerMinute: 1_000,
                                  warmThreshold: 1_000,
                                  hotThreshold: 5_000,
                                  criticalThreshold: 10_000) == .warm)
    }
}
