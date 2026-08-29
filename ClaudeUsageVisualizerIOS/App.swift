import SwiftUI

/// iPhone companion to the macOS menu-bar widget. It shows the same live Claude
/// usage numbers (5-hour block + weekly) pulled from Anthropic's OAuth usage
/// endpoint. The macOS-only pieces — transcript watching, the menu bar, the
/// keychain — do not exist on iOS, so this is a focused usage viewer.
@main
struct ClaudeUsageIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
