import Testing
@testable import ClaudeUsageVisualizer

@Suite("DurationFormatter")
struct DurationFormatterTests {

    // MARK: compact

    @Test func compact_seconds() {
        #expect(DurationFormatter.compact(45) == "45s")
    }

    @Test func compact_minutes_only() {
        #expect(DurationFormatter.compact(300) == "5m")
    }

    @Test func compact_hours_and_minutes() {
        #expect(DurationFormatter.compact(3_661) == "1h 1m")
    }

    @Test func compact_zero() {
        #expect(DurationFormatter.compact(0) == "0s")
    }

    @Test func compact_negative_clamps_to_zero() {
        #expect(DurationFormatter.compact(-100) == "0s")
    }

    @Test func compact_exactly_one_hour() {
        #expect(DurationFormatter.compact(3_600) == "1h 0m")
    }

    // MARK: daysAndHours

    @Test func daysAndHours_under_one_hour() {
        #expect(DurationFormatter.daysAndHours(1_800) == "30m")
    }

    @Test func daysAndHours_hours_only() {
        #expect(DurationFormatter.daysAndHours(7_200) == "2h 0m")
    }

    @Test func daysAndHours_one_day() {
        #expect(DurationFormatter.daysAndHours(86_400) == "1d 0h")
    }

    @Test func daysAndHours_five_days_twelve_hours() {
        // 132h == 5d 12h
        #expect(DurationFormatter.daysAndHours(132 * 3_600) == "5d 12h")
    }

    @Test func daysAndHours_zero() {
        #expect(DurationFormatter.daysAndHours(0) == "0m")
    }

    // MARK: short

    @Test func short_minutes() {
        #expect(DurationFormatter.short(600) == "10m")
    }

    @Test func short_hours_and_minutes() {
        #expect(DurationFormatter.short(5_400) == "1h30m")
    }
}
