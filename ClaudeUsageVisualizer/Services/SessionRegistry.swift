import Foundation

/// Scans ~/.claude/sessions/*.json every few seconds, checks PID liveness.
/// Emits the full list only on change.
actor SessionRegistry {
    private let sessionsDir: URL
    private var lastSnapshot: [RawSession] = []
    private var continuation: AsyncStream<[RawSession]>.Continuation?
    private var pollTask: Task<Void, Never>?

    struct RawSession: Sendable, Hashable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let startedAt: Date
        let kind: String
        let entrypoint: String?
        let name: String?
        let isRunning: Bool
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDir = home.appendingPathComponent(".claude/sessions")
    }

    func start() -> AsyncStream<[RawSession]> {
        let (stream, cont) = AsyncStream<[RawSession]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        return stream
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func tick() {
        let current = scanOnce()
        if current != lastSnapshot {
            lastSnapshot = current
            continuation?.yield(current)
        }
    }

    private func scanOnce() -> [RawSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [RawSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let pid = Int32((obj["pid"] as? Int) ?? 0)
            guard let sessionId = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String else { continue }

            let startedAtMillis = (obj["startedAt"] as? Double) ?? 0
            let startedAt = Date(timeIntervalSince1970: startedAtMillis / 1000.0)
            let kind = (obj["kind"] as? String) ?? "unknown"
            let entrypoint = obj["entrypoint"] as? String
            let name = obj["name"] as? String
            let alive = ProcessLiveness.isAlive(pid)

            sessions.append(RawSession(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                startedAt: startedAt,
                kind: kind,
                entrypoint: entrypoint,
                name: name,
                isRunning: alive
            ))
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }
}
