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

        // Each session file is named by PID; the same sessionId can appear in
        // multiple files when a session is resumed across restarts. Collect all,
        // then deduplicate below.
        var all: [RawSession] = []
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

            all.append(RawSession(
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

        // Deduplicate by sessionId. For each group keep the running instance
        // (if any) or the most recently started one. This collapses resumed
        // sessions and sub-agent PID files that share a parent sessionId into
        // a single row.
        var best: [String: RawSession] = [:]
        for s in all {
            guard let existing = best[s.sessionId] else { best[s.sessionId] = s; continue }
            let prefer: Bool
            if s.isRunning != existing.isRunning {
                prefer = s.isRunning          // running always wins over dead
            } else {
                prefer = s.startedAt > existing.startedAt  // most recent wins
            }
            if prefer { best[s.sessionId] = s }
        }

        return best.values.sorted { $0.startedAt > $1.startedAt }
    }
}
