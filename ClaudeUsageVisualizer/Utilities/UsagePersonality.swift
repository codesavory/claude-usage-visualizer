import Foundation

/// All the fun text in the app lives here. Deterministic selection (no random) so
/// the quip doesn't flicker on every refresh tick — changes only when context changes.
enum UsagePersonality {

    // MARK: - Header quips (shown under the progress bar)

    static func headerQuip(
        ratio: Double,
        tokensPerMinute: Double,
        hour: Int,
        continuousHours: Double,
        blocks: [UsageBlock]
    ) -> String {
        let seed = Int(ratio * 10) + hour

        if ratio > 0.95 {
            return pick(from: nearCapQuips, seed: seed)
        }
        if ratio > 0.75 {
            return pick(from: highUsageQuips, seed: seed)
        }
        if hour >= 0 && hour < 5 {
            return pick(from: lateNightQuips(hour: hour), seed: seed)
        }
        if hour >= 5 && hour < 8 {
            return pick(from: earlyMorningQuips, seed: seed)
        }
        if continuousHours > 4 {
            return pick(from: longSessionQuips(hours: continuousHours), seed: seed)
        }
        if ratio < 0.15 {
            return pick(from: freshBlockQuips, seed: seed)
        }
        if tokensPerMinute > 15_000 {
            return pick(from: blazingBurnQuips, seed: seed)
        }
        return pick(from: normalQuips, seed: seed)
    }

    // MARK: - Nudge & habit copy

    static func nudgeHeadline(mood: BreakNudge.Mood, continuousHours: Double, ratio: Double) -> String {
        switch mood {
        case .walk:
            if continuousHours > 3 { return "You've been sitting for \(Int(continuousHours))h. Touch grass." }
            return "Take a walk. The PR will survive."
        case .gym:
            return "You've pushed tokens. Now push some iron. 🏋️"
        case .meditate:
            if ratio > 0.8 { return "Your nervous system called. It wants 10 minutes back." }
            return "Close the context window. The mental one."
        case .journal:
            return "Brain dump but make it analog. 📓"
        case .sleep:
            return "Even the servers get maintenance windows. You need one too."
        case .water:
            return "You've hydrated your tokens. Now hydrate yourself."
        case .coffee:
            return "A coffee break sounds mathematically correct right now."
        case .stretch:
            return "Your spine is filing a complaint. Stretch it out."
        case .coolDown:
            return "We've both been at this for a while. Cool down time."
        }
    }

    static func nudgeBody(mood: BreakNudge.Mood, tokensUsed: Int, resetMinutes: Int) -> String {
        let tokStr = TokenFormatter.tokens(tokensUsed)
        let resetStr = resetMinutes > 0 ? " Block resets in \(resetMinutes)m anyway." : ""

        switch mood {
        case .walk:
            return "You've generated \(tokStr) tokens today. Step outside. The fresh air is free and has no rate limit.\(resetStr)"
        case .gym:
            return "\(tokStr) tokens burned. Now burn some calories. Your future self will thank both versions of you.\(resetStr)"
        case .meditate:
            return "10 slow breaths. No prompts. No completions. Just you and the absence of a loading spinner.\(resetStr)"
        case .journal:
            return "Write something that isn't a prompt for once. Commit thoughts to paper: zero latency, no rate limits.\(resetStr)"
        case .sleep:
            return "The context will still be there tomorrow. Your REM cycle won't wait.\(resetStr)"
        case .water:
            return "Classic developer dehydration arc. You've sent \(tokStr) tokens and probably zero glasses of water.\(resetStr)"
        case .coffee:
            return "Step away. Make something hot. Return with fresh eyes and a slightly lower burn rate.\(resetStr)"
        case .stretch:
            return "Hips flexors: unhappy. Shoulders: filed a ticket. Let's triage before it becomes a P0.\(resetStr)"
        case .coolDown:
            return "You've used \(tokStr) tokens. It's a lot. Take 15 minutes before the next block so you start fresh.\(resetStr)"
        }
    }

    // MARK: - Habit suggestion copy (shown in the habits section)

    static func habitTitle(activity: BreakNudge.Mood, peakHourDescription: String?) -> String {
        switch activity {
        case .walk:
            return "Time to walk"
        case .gym:
            return "Gym o'clock"
        case .meditate:
            return "Pause & breathe"
        case .journal:
            return "Journal break"
        case .sleep:
            return "Your bed misses you"
        case .water:
            return "Hydration check"
        case .coffee:
            return "Coffee o'clock"
        case .stretch:
            return "Stretch break"
        case .coolDown:
            return "Cool-down window"
        }
    }

    static func habitRationale(
        activity: BreakNudge.Mood,
        continuousHours: Double,
        peakHour: Int?,
        avgUtil: Double
    ) -> String {
        switch activity {
        case .walk:
            let hrs = String(format: "%.1f", continuousHours)
            return "\(hrs)h of coding without moving. Your legs have been patient. Reward them."
        case .gym:
            if let p = peakHour {
                return "Your \(shortHour(p)) block is typically your heaviest. Working out before it keeps you focused."
            }
            return "Compound lifts improve focus and don't have rate limits."
        case .meditate:
            if avgUtil > 0.6 {
                return "Your recent blocks average \(Int(avgUtil * 100))% utilization. Meditation resets your decision-making better than a fresh context window."
            }
            return "10 minutes of meditation now prevents 2 hours of unfocused hacking later."
        case .journal:
            return "Heavy usage days correlate with context-switching. Writing clarifies intent — cheaper than asking Claude to figure it out."
        case .sleep:
            return "Sleep is the original model refresh. Missing it degrades output quality, yours and Claude's."
        case .water:
            return "Dehydration masquerades as decision fatigue. The reason your prompt was confusing might just be water."
        case .coffee:
            return "Coffee is a legal performance-enhancing drug with a 20-minute onset. Use wisely."
        case .stretch:
            return "Posture debt compounds faster than technical debt. Pay it now."
        case .coolDown:
            return "You've been operating at full throttle. Downshift deliberately."
        }
    }

    // MARK: - Pattern descriptions (shown in behavioral section)

    static func patternDescription(peakHour: Int, avgUtil: Double, blockCount: Int) -> String {
        let util = Int(avgUtil * 100)
        let timeDesc = timeOfDayLabel(peakHour)
        let quips = [
            "You're a \(timeDesc) coder. Claude has noticed.",
            "\(timeDesc) sessions average \(util)% — that's your danger zone.",
            "Peak Claude hours: \(shortHour(peakHour))–\(shortHour((peakHour + 5) % 24)). Mark your calendar.",
            "Your \(timeDesc) blocks are consistently spicy at \(util)%.",
        ]
        return pick(from: quips, seed: peakHour + Int(avgUtil * 100))
    }

    static func compareTodayVsAverage(todayMessages: Int, avgMessages: Double) -> String {
        guard avgMessages > 5 else { return "Building up your baseline..." }
        let pct = Int(Double(todayMessages) / avgMessages * 100)
        if pct > 180 {
            return "Today is \(pct)% of your daily average. Peak you."
        }
        if pct > 120 {
            return "Running \(pct - 100)% above your usual pace today."
        }
        if pct < 50 {
            return "Light day — \(pct)% of average. The quota thanks you."
        }
        return "Tracking close to your usual daily pace."
    }

    // MARK: - Quip banks

    private static let nearCapQuips = [
        "At this rate, Artemis II reaches the Moon before your next block. 🚀",
        "You've used more tokens than Dogecoin has transactions. Allegedly.",
        "Your context window is fuller than a Notion doc no one will ever finish.",
        "Final boss energy. Also final message energy.",
        "Only Haiku is brave enough to join you now.",
        "Token budget: critical. Dignity: also critical. Unrelated, probably.",
        "The heat death of this 5h block is nigh.",
        "You've consumed enough tokens to describe the entire history of JavaScript frameworks. Twice.",
        "Apollo 11 ran on 4KB. You've used considerably more. Just saying.",
    ]

    private static let highUsageQuips = [
        "Burning it like you invented it.",
        "Three-quarters in. Like a great novel, but for API calls.",
        "Your burn rate has entered 'Series A runway' territory.",
        "GPUs across three data centers are sweating on your behalf.",
        "The model is starting to know you a little too well.",
        "Hot streak. Both the good kind and the concerning kind.",
        "You're in the percentile of users Anthropic has a graph for.",
    ]

    private static func lateNightQuips(hour: Int) -> [String] {
        [
            "It's \(hour == 0 ? "midnight" : "\(hour)am"). The bugs are tired. You are not.",
            "Night owl hours. Claude doesn't judge. Your future self might.",
            "Building at \(hour)am hits different. So does the standup at 9.",
            "Every great late-night feature ships a morning bug. Science.",
            "The only thing open at this hour: your IDE and your regrets.",
            "\(hour)am commits. Chapeau. Or a wellness check. Hard to say.",
        ]
    }

    private static let earlyMorningQuips = [
        "Pre-coffee coding. Respect. Or concern. Both.",
        "You're coding before most people's alarms go off.",
        "Early bird gets the tokens. Bold strategy.",
        "Morning sessions before the meetings hit — the golden hour.",
    ]

    private static func longSessionQuips(hours: Double) -> [String] {
        let h = Int(hours)
        return [
            "\(h)h session and counting. Your back has opinions.",
            "You've been at this for \(h) hours. The Pomodoro technique is weeping.",
            "\(h) hours deep. The ship is building itself at this point.",
            "Club \(h)-hour. Exclusive membership. Questionable life choices.",
        ]
    }

    private static let freshBlockQuips = [
        "New block, who dis? 🎊",
        "Quota recharged. The vibe has been reset.",
        "Full tank. Destination: productivity. Or chaos. Probably chaos.",
        "Like waking up on January 1st, but for tokens.",
        "Empty quota, limitless potential. Or 225 messages of it.",
        "Fresh start. May your cache hit ratios be ever in your favour.",
    ]

    private static let blazingBurnQuips = [
        "Token velocity: alarming. You absolute menace.",
        "Hot. Very hot. Thermodynamically concerning.",
        "At this burn rate you're solving real problems. Or creating new ones.",
    ]

    private static let normalQuips = [
        "Solid pace. The model appreciates your commitment.",
        "Goldilocks zone: not too spicy, not too mild.",
        "Healthy burn. The quota gods smile upon you.",
        "Cruising altitude. Seat belts optional.",
        "Responsible usage. Your past self would be surprised.",
    ]

    // MARK: - Helpers

    private static func pick<T>(from array: [T], seed: Int) -> T {
        array[abs(seed) % array.count]
    }

    static func shortHour(_ h: Int) -> String {
        switch h {
        case 0: return "12am"
        case 12: return "12pm"
        default:
            let hh = h % 12
            return "\(hh)\(h < 12 ? "am" : "pm")"
        }
    }

    private static func timeOfDayLabel(_ hour: Int) -> String {
        switch hour {
        case 0..<5: return "late-night"
        case 5..<9: return "early-morning"
        case 9..<12: return "morning"
        case 12..<14: return "midday"
        case 14..<18: return "afternoon"
        case 18..<22: return "evening"
        default: return "night"
        }
    }
}
