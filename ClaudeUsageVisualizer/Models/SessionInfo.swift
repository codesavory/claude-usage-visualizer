import Foundation

struct SessionInfo: Sendable, Identifiable, Hashable {
    let sessionId: String
    let pid: Int32?
    let cwd: String
    let startedAt: Date
    let kind: String
    let entrypoint: String?
    let name: String?
    var isRunning: Bool
    var lastEventAt: Date?
    var tokensInCurrentBlock: Int
    var costInCurrentBlock: Double
    var tokensPerMinute: Double
    var dominantModel: ClaudeModel

    var id: String { sessionId }

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return (cwd as NSString).lastPathComponent
    }
}
