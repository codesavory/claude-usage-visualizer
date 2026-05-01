import SwiftUI

struct BurnRateGauge: View {
    let burn: BurnRate

    var body: some View {
        let color = Theme.Burn.color(burn.severity)
        let label = Theme.Burn.label(burn.severity)
        let icon = Theme.Burn.icon(burn.severity)
        let fraction = gaugeFraction(tpm: burn.tokensPerMinute)

        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.5), color],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: fraction)
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .imageScale(.medium)
                    Text(TokenFormatter.tokensPerMinute(burn.tokensPerMinute))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
            }
            .frame(width: 72, height: 72)

            Text(label)
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(color)
                .kerning(0.8)
        }
    }

    private func gaugeFraction(tpm: Double) -> CGFloat {
        let maxScale: Double = 25_000
        return CGFloat(min(1.0, tpm / maxScale))
    }
}
