import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @AppStorage("tier") private var tierRaw: String = UsageTier.max5x.rawValue
    @AppStorage("nudgesEnabled") var nudgesEnabled: Bool = true
    @AppStorage("showTokensInMenuBar") var showTokensInMenuBar: Bool = true
    @AppStorage("burnWarmThreshold") var burnWarmThreshold: Double = 2_000
    @AppStorage("burnHotThreshold") var burnHotThreshold: Double = 8_000
    @AppStorage("burnCriticalThreshold") var burnCriticalThreshold: Double = 20_000
    @AppStorage("refreshIntervalSeconds") var refreshIntervalSeconds: Double = 3

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = true {
        didSet { updateLaunchAtLogin() }
    }

    init() {
        // Register on first launch (AppStorage default = true, but didSet doesn't fire for defaults).
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    var tier: UsageTier {
        get { UsageTier(rawValue: tierRaw) ?? .max5x }
        set { tierRaw = newValue.rawValue }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }
}
