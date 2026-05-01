import SwiftUI

enum Theme {
    static let popoverWidth: CGFloat = 360
    static let popoverHeight: CGFloat = 560
    static let popoverPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 6
    static let cardCornerRadius: CGFloat = 12

    enum Burn {
        static let chill = Color.green
        static let warm = Color.yellow
        static let hot = Color.orange
        static let critical = Color.red

        static func color(_ severity: BurnRate.Severity) -> Color {
            switch severity {
            case .chill: return chill
            case .warm: return warm
            case .hot: return hot
            case .critical: return critical
            }
        }

        static func label(_ severity: BurnRate.Severity) -> String {
            switch severity {
            case .chill: return "CHILL"
            case .warm: return "WARM"
            case .hot: return "HOT"
            case .critical: return "CRITICAL"
            }
        }

        static func icon(_ severity: BurnRate.Severity) -> String {
            switch severity {
            case .chill: return "leaf.fill"
            case .warm: return "sun.max.fill"
            case .hot: return "flame.fill"
            case .critical: return "exclamationmark.triangle.fill"
            }
        }
    }
}
