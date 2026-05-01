import Foundation

struct BreakNudge: Sendable, Identifiable, Hashable {
    enum Mood: String, Sendable, Hashable, CaseIterable {
        case coffee, walk, stretch, coolDown
        case gym, meditate, journal, sleep, water

        var emoji: String {
            switch self {
            case .coffee: return "☕"
            case .walk: return "🚶"
            case .stretch: return "🧘"
            case .coolDown: return "🧊"
            case .gym: return "🏋️"
            case .meditate: return "🪷"
            case .journal: return "📓"
            case .sleep: return "😴"
            case .water: return "💧"
            }
        }

        var icon: String {
            switch self {
            case .coffee: return "cup.and.saucer.fill"
            case .walk: return "figure.walk"
            case .stretch: return "figure.cooldown"
            case .coolDown: return "snowflake"
            case .gym: return "dumbbell.fill"
            case .meditate: return "brain.head.profile"
            case .journal: return "book.closed.fill"
            case .sleep: return "moon.stars.fill"
            case .water: return "drop.fill"
            }
        }
    }

    let id: UUID
    let mood: Mood
    let headline: String
    let body: String
    let minutesSuggested: Int

    init(id: UUID = UUID(), mood: Mood, headline: String, body: String, minutesSuggested: Int) {
        self.id = id
        self.mood = mood
        self.headline = headline
        self.body = body
        self.minutesSuggested = minutesSuggested
    }
}
