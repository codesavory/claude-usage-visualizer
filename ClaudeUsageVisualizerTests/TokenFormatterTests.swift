import Testing
@testable import ClaudeUsageVisualizer

@Suite("TokenFormatter")
struct TokenFormatterTests {

    // MARK: tokens

    @Test func tokens_small() {
        #expect(TokenFormatter.tokens(42) == "42")
    }

    @Test func tokens_thousands() {
        #expect(TokenFormatter.tokens(1_500) == "1.5k")
    }

    @Test func tokens_millions() {
        #expect(TokenFormatter.tokens(2_000_000) == "2.0M")
    }

    @Test func tokens_exact_thousand() {
        #expect(TokenFormatter.tokens(1_000) == "1.0k")
    }

    // MARK: tokensPerMinute

    @Test func tpm_under_thousand() {
        #expect(TokenFormatter.tokensPerMinute(500) == "500/m")
    }

    @Test func tpm_over_thousand() {
        #expect(TokenFormatter.tokensPerMinute(1_500) == "1.5k/m")
    }

    @Test func tpm_zero() {
        #expect(TokenFormatter.tokensPerMinute(0) == "0/m")
    }

    // MARK: usd

    @Test func usd_cents() {
        #expect(TokenFormatter.usd(0.05) == "$0.05")
    }

    @Test func usd_single_digits() {
        #expect(TokenFormatter.usd(9.9) == "$9.90")
    }

    @Test func usd_tens() {
        #expect(TokenFormatter.usd(10.0) == "$10.0")
    }

    @Test func usd_hundreds() {
        #expect(TokenFormatter.usd(100.0) == "$100")
    }

    // MARK: percent

    @Test func percent_half() {
        #expect(TokenFormatter.percent(0.5) == "50%")
    }

    @Test func percent_full() {
        #expect(TokenFormatter.percent(1.0) == "100%")
    }
}
