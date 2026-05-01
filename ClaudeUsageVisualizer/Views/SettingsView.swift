import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            thresholdsTab
                .tabItem { Label("Thresholds", systemImage: "gauge.with.dots.needle.67percent") }
        }
        .frame(width: 440, height: 260)
    }

    private var generalTab: some View {
        Form {
            Picker("Plan tier", selection: Binding(
                get: { settings.tier },
                set: { settings.tier = $0 }
            )) {
                ForEach(UsageTier.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }

            Toggle("Show burn indicator next to menu bar icon", isOn: $settings.showTokensInMenuBar)
            Toggle("Enable break nudges", isOn: $settings.nudgesEnabled)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            HStack {
                Text("Refresh interval")
                Slider(value: $settings.refreshIntervalSeconds, in: 1...30, step: 1)
                Text("\(Int(settings.refreshIntervalSeconds))s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var thresholdsTab: some View {
        Form {
            thresholdSlider("Warm (yellow) starts at", value: $settings.burnWarmThreshold, range: 500...5_000, step: 100)
            thresholdSlider("Hot (orange) starts at", value: $settings.burnHotThreshold, range: 4_000...15_000, step: 500)
            thresholdSlider("Critical (red) starts at", value: $settings.burnCriticalThreshold, range: 10_000...40_000, step: 1_000)
            Text("Units: tokens/minute. Adjust to match your typical working pace.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func thresholdSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .frame(width: 160, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(TokenFormatter.tokensPerMinute(value.wrappedValue))
                .frame(width: 72, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
