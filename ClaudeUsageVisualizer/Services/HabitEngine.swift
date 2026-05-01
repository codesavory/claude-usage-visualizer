import Foundation

/// Analyzes daily usage patterns and suggests healthy habits.
/// All analysis is local and deterministic — no external calls.
actor HabitEngine {

    struct HabitSuggestion: Sendable, Identifiable {
        let id = UUID()
        let mood: BreakNudge.Mood
        let headline: String
        let rationale: String
        let urgency: Int // 1 = gentle, 2 = moderate, 3 = urgent
    }

    struct BehavioralProfile: Sendable {
        let peakHour: Int?           // hour-of-day with highest avg utilization
        let lightHour: Int?          // hour-of-day with lowest avg utilization
        let avgDailyMessages: Double
        let todayMessages: Int
        let continuousHoursToday: Double
        let isNightOwl: Bool         // majority of heavy blocks after 9pm
        let isMorningCoder: Bool     // majority of heavy blocks before noon
        let avgPeakUtilization: Double
        let streak: Int              // consecutive days with heavy usage (>60% avg)
    }

    func analyze(_ snapshot: UsageSnapshot, liveUsage: OAuthUsageSnapshot?) -> HabitSuggestion? {
        let profile = buildProfile(snapshot: snapshot, liveUsage: liveUsage)
        return suggest(profile: profile, snapshot: snapshot, liveUsage: liveUsage)
    }

    func buildProfile(snapshot: UsageSnapshot, liveUsage: OAuthUsageSnapshot?) -> BehavioralProfile {
        let blocks = snapshot.previousBlocks
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        // Hour-of-day average utilization (message count normalized to max seen)
        let maxMsg = max(1, blocks.map(\.messageCount).max() ?? 1)
        var hourBuckets: [Int: [Double]] = [:]
        for block in blocks {
            let hour = cal.component(.hour, from: block.startedAt)
            hourBuckets[hour, default: []].append(Double(block.messageCount) / Double(maxMsg))
        }
        let avgByHour = hourBuckets.mapValues { $0.reduce(0, +) / Double($0.count) }

        let peakHour = avgByHour.max(by: { $0.value < $1.value })?.key
        let lightHour = avgByHour.filter { $0.value > 0 }.min(by: { $0.value < $1.value })?.key

        // Daily message totals
        let todayBlocks = blocks.filter { $0.startedAt >= today }
        let todayMessages = todayBlocks.reduce(0) { $0 + $1.messageCount }
        let currentBlockMsgs = snapshot.currentBlock?.messageCount ?? 0
        let totalTodayMessages = todayMessages + currentBlockMsgs

        let daysWithData = max(1.0, Double(Set(blocks.map {
            cal.startOfDay(for: $0.startedAt)
        }).count))
        let avgDailyMessages = Double(blocks.reduce(0) { $0 + $1.messageCount }) / daysWithData

        // Continuous hours today — union of [block.startedAt, min(block.endsAt, now)] ranges
        let todayRanges = (todayBlocks + [snapshot.currentBlock].compactMap { $0 })
            .map { ($0.startedAt, min($0.endsAt, now)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }

        let continuousHours: Double = {
            var covered: TimeInterval = 0
            var cursor = today
            for (start, end) in todayRanges {
                let s = max(start, cursor)
                if s < end {
                    covered += end.timeIntervalSince(s)
                    cursor = end
                }
            }
            return covered / 3600
        }()

        // Night owl: peak usage after 9pm
        let eveningHours: Set<Int> = [21, 22, 23, 0, 1, 2, 3]
        let eveningUtilSum = eveningHours.compactMap { avgByHour[$0] }.reduce(0, +)
        let dayUtilSum = avgByHour.filter { !eveningHours.contains($0.key) }.values.reduce(0, +)
        let isNightOwl = eveningUtilSum > dayUtilSum * 0.6 && blocks.count >= 5

        // Morning coder: peak usage before noon
        let morningHours: Set<Int> = [6, 7, 8, 9, 10, 11]
        let morningUtilSum = morningHours.compactMap { avgByHour[$0] }.reduce(0, +)
        let isMorningCoder = morningUtilSum > 0 && morningUtilSum > eveningUtilSum

        // Avg peak utilization
        let avgPeakUtil = avgByHour.values.max() ?? 0

        // Streak — consecutive calendar days that had at least one block
        let datesWithBlocks = Set(blocks.map { cal.startOfDay(for: $0.startedAt) }).sorted(by: >)
        var streak = 0
        var checkDate = today
        for date in datesWithBlocks {
            if cal.isDate(date, inSameDayAs: checkDate) || date == today {
                streak += 1
                checkDate = cal.date(byAdding: .day, value: -1, to: date) ?? date
            } else {
                break
            }
        }

        return BehavioralProfile(
            peakHour: peakHour,
            lightHour: lightHour,
            avgDailyMessages: avgDailyMessages,
            todayMessages: totalTodayMessages,
            continuousHoursToday: continuousHours,
            isNightOwl: isNightOwl,
            isMorningCoder: isMorningCoder,
            avgPeakUtilization: avgPeakUtil,
            streak: streak
        )
    }

    private func suggest(
        profile: BehavioralProfile,
        snapshot: UsageSnapshot,
        liveUsage: OAuthUsageSnapshot?
    ) -> HabitSuggestion? {
        let hour = Calendar.current.component(.hour, from: Date())
        let liveRatio: Double = {
            if let live = liveUsage, live.status == .live || live.status == .rateLimited {
                return live.fiveHour.utilization / 100.0
            }
            return 0
        }()

        // Urgency 3: Late night heavy usage — sleep wins
        if hour >= 23 || hour < 3 {
            if liveRatio > 0.5 || profile.continuousHoursToday > 2 {
                return HabitSuggestion(
                    mood: .sleep,
                    headline: UsagePersonality.nudgeHeadline(mood: .sleep, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                    rationale: UsagePersonality.habitRationale(activity: .sleep, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                    urgency: 3
                )
            }
        }

        // Urgency 3: Very long session
        if profile.continuousHoursToday > 5 {
            return HabitSuggestion(
                mood: .walk,
                headline: UsagePersonality.nudgeHeadline(mood: .walk, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                rationale: UsagePersonality.habitRationale(activity: .walk, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                urgency: 3
            )
        }

        // Urgency 2: Gym time — afternoon or before evening peak
        if let peak = profile.peakHour, (hour == peak - 1 || hour == peak - 2) && hour >= 14 && hour <= 18 {
            return HabitSuggestion(
                mood: .gym,
                headline: UsagePersonality.nudgeHeadline(mood: .gym, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                rationale: UsagePersonality.habitRationale(activity: .gym, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                urgency: 2
            )
        }

        // Urgency 2: Meditation — afternoon slump or mid-session burn
        if (hour >= 13 && hour <= 16) && liveRatio > 0.5 && profile.continuousHoursToday > 2 {
            return HabitSuggestion(
                mood: .meditate,
                headline: UsagePersonality.nudgeHeadline(mood: .meditate, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                rationale: UsagePersonality.habitRationale(activity: .meditate, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                urgency: 2
            )
        }

        // Urgency 1: Journal — morning or end of heavy day
        if (hour >= 6 && hour <= 9) && profile.isMorningCoder {
            return HabitSuggestion(
                mood: .journal,
                headline: UsagePersonality.nudgeHeadline(mood: .journal, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                rationale: UsagePersonality.habitRationale(activity: .journal, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                urgency: 1
            )
        }

        // Urgency 1: Walk — session > 2h
        if profile.continuousHoursToday > 2 {
            return HabitSuggestion(
                mood: .walk,
                headline: UsagePersonality.nudgeHeadline(mood: .walk, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                rationale: UsagePersonality.habitRationale(activity: .walk, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                urgency: 1
            )
        }

        // Urgency 1: Water reminder every few hours
        if profile.continuousHoursToday > 1.5 && (hour % 3 == 0 || hour % 3 == 1) {
            return HabitSuggestion(
                mood: .water,
                headline: UsagePersonality.nudgeHeadline(mood: .water, continuousHours: profile.continuousHoursToday, ratio: liveRatio),
                rationale: UsagePersonality.habitRationale(activity: .water, continuousHours: profile.continuousHoursToday, peakHour: profile.peakHour, avgUtil: profile.avgPeakUtilization),
                urgency: 1
            )
        }

        return nil
    }
}
