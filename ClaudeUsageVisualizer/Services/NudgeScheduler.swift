import Foundation
import UserNotifications

@MainActor
final class NudgeScheduler {
    private var firedForBlock: Set<String> = []
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func maybeFire(nudge: BreakNudge, blockAnchor: Date?) {
        guard let anchor = blockAnchor else { return }
        let key = "\(anchor.timeIntervalSince1970):\(nudge.mood.rawValue)"
        if firedForBlock.contains(key) { return }
        firedForBlock.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "\(nudge.mood.emoji) \(nudge.headline)"
        content.body = nudge.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        center.add(request)
    }

    func resetForNewBlock() {
        firedForBlock.removeAll()
    }
}
