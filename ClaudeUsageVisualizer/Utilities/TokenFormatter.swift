import Foundation

enum TokenFormatter {
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func tokensPerMinute(_ tpm: Double) -> String {
        if tpm >= 1_000 {
            return String(format: "%.1fk/m", tpm / 1_000)
        }
        return String(format: "%.0f/m", tpm)
    }

    static func usd(_ amount: Double) -> String {
        if amount >= 100 {
            return String(format: "$%.0f", amount)
        }
        if amount >= 10 {
            return String(format: "$%.1f", amount)
        }
        return String(format: "$%.2f", amount)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
