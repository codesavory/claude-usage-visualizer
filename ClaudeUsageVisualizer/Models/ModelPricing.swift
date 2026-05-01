import SwiftUI

struct ModelPricing: Sendable, Hashable {
    let inputPerM: Double
    let outputPerM: Double
    let cacheReadPerM: Double
    let cacheWrite5mPerM: Double
    let cacheWrite1hPerM: Double

    func cost(input: Int, output: Int, cacheRead: Int, cacheCreation: Int) -> Double {
        let i = Double(input) / 1_000_000 * inputPerM
        let o = Double(output) / 1_000_000 * outputPerM
        let cr = Double(cacheRead) / 1_000_000 * cacheReadPerM
        let cc = Double(cacheCreation) / 1_000_000 * cacheWrite5mPerM
        return i + o + cr + cc
    }
}

enum ClaudeModel: String, Codable, Sendable, CaseIterable, Hashable {
    case opus47, sonnet46, haiku45, unknown

    init(rawAPIName: String) {
        let n = rawAPIName.lowercased()
        if n.contains("opus-4-7") || n.contains("opus-4.7") { self = .opus47; return }
        if n.contains("sonnet-4-6") || n.contains("sonnet-4.6") { self = .sonnet46; return }
        if n.contains("haiku-4-5") || n.contains("haiku-4.5") { self = .haiku45; return }
        if n.contains("opus") { self = .opus47; return }
        if n.contains("sonnet") { self = .sonnet46; return }
        if n.contains("haiku") { self = .haiku45; return }
        self = .unknown
    }

    var displayName: String {
        switch self {
        case .opus47: return "Opus 4.7"
        case .sonnet46: return "Sonnet 4.6"
        case .haiku45: return "Haiku 4.5"
        case .unknown: return "Unknown"
        }
    }

    var shortName: String {
        switch self {
        case .opus47: return "Opus"
        case .sonnet46: return "Sonnet"
        case .haiku45: return "Haiku"
        case .unknown: return "?"
        }
    }

    var accentColor: Color {
        switch self {
        case .opus47: return Color(red: 0.64, green: 0.40, blue: 0.98)
        case .sonnet46: return Color(red: 0.20, green: 0.72, blue: 0.70)
        case .haiku45: return Color(red: 0.98, green: 0.66, blue: 0.24)
        case .unknown: return .gray
        }
    }

    var pricing: ModelPricing {
        switch self {
        case .opus47:
            return ModelPricing(inputPerM: 5, outputPerM: 25, cacheReadPerM: 0.50, cacheWrite5mPerM: 6.25, cacheWrite1hPerM: 10)
        case .sonnet46:
            return ModelPricing(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.30, cacheWrite5mPerM: 3.75, cacheWrite1hPerM: 6)
        case .haiku45:
            return ModelPricing(inputPerM: 1, outputPerM: 5, cacheReadPerM: 0.10, cacheWrite5mPerM: 1.25, cacheWrite1hPerM: 2)
        case .unknown:
            return ModelPricing(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.30, cacheWrite5mPerM: 3.75, cacheWrite1hPerM: 6)
        }
    }
}

enum UsageTier: String, Codable, Sendable, CaseIterable {
    case max5x, max20x

    var displayName: String {
        switch self {
        case .max5x: return "Max 5x"
        case .max20x: return "Max 20x"
        }
    }

    var messagesPerBlock: Int {
        switch self {
        case .max5x: return 225
        case .max20x: return 900
        }
    }
}
