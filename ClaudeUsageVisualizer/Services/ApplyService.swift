import AppKit
import Foundation
import SwiftUI

@MainActor
final class ApplyService: ObservableObject {
    @Published var hudMessage: String?
    @Published var pendingPatch: SettingsPatch?

    func apply(_ suggestion: OptimizationSuggestion) {
        switch suggestion.kind {
        case .pasteCommand(let text):
            copyToPasteboard(text)
            showHUD("Copied `\(text)` — paste in your Claude session")
        case .settingsPatch(let patch):
            pendingPatch = patch
        case .openFile(let url):
            openFile(url)
        }
    }

    func confirmPendingPatch() {
        guard let patch = pendingPatch else { return }
        do {
            try writeSettingsPatch(patch)
            showHUD("Settings updated")
        } catch {
            showHUD("Couldn't apply: \(error.localizedDescription)")
        }
        pendingPatch = nil
    }

    func dismissPendingPatch() {
        pendingPatch = nil
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func openFile(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    private func writeSettingsPatch(_ patch: SettingsPatch) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }

        let value: Any
        if let data = patch.newValueJSON.data(using: .utf8),
           let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            value = v
        } else {
            value = patch.newValueJSON
        }

        obj[patch.keyPath] = value
        let updated = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: settingsURL, options: [.atomic])
    }

    private func showHUD(_ message: String) {
        hudMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { [weak self] in
                if self?.hudMessage == message {
                    self?.hudMessage = nil
                }
            }
        }
    }
}
