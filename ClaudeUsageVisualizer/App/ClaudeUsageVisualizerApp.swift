import SwiftUI

@main
struct ClaudeUsageVisualizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.usageViewModel)
                .environmentObject(appDelegate.settingsViewModel)
        }
    }
}
