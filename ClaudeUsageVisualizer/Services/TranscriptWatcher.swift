import Foundation

/// Watches ~/.claude/projects/**/*.jsonl for new assistant-turn events.
/// Parses JSONL incrementally (per-file byte offsets), dedups at read time,
/// and streams UsageEvents. Backfills the last 7 days on start.
actor TranscriptWatcher {
    private let projectsRoot: URL
    private let supportDir: URL
    private let offsetsFile: URL
    private var offsets: [String: FileOffset] = [:]
    private var eventStream: FSEventStream?
    private var continuation: AsyncStream<UsageEvent>.Continuation?
    private var pollTask: Task<Void, Never>?

    struct FileOffset: Codable, Sendable {
        let inode: UInt64
        let size: UInt64
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsRoot = home.appendingPathComponent(".claude/projects")
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        self.supportDir = appSupport.appendingPathComponent("ClaudeUsageVisualizer")
        self.offsetsFile = supportDir.appendingPathComponent("offsets.json")
        try? FileManager.default.createDirectory(
            at: supportDir, withIntermediateDirectories: true
        )
    }

    func start(backfillSince: Date) -> AsyncStream<UsageEvent> {
        loadOffsets()
        let (stream, cont) = AsyncStream<UsageEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont

        // Cold scan: parse historical events within backfill window and seed offsets.
        Task { [weak self] in
            await self?.coldScan(backfillSince: backfillSince)
            await self?.startWatching()
            await self?.startPolling()
        }

        return stream
    }

    func stop() {
        eventStream?.stop()
        eventStream = nil
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
        saveOffsets()
    }

    // MARK: - Cold scan + backfill

    private func coldScan(backfillSince: Date) async {
        let files = discoverJSONL()
        for file in files {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime < backfillSince {
                // Older than backfill window — seed offset at EOF to skip future reading.
                if let stats = JSONLStreamReader.fileStats(url: file) {
                    offsets[file.path] = FileOffset(inode: stats.inode, size: stats.size)
                }
                continue
            }
            // Always re-read backfill files from byte 0 on launch so the aggregator (which
            // starts empty) receives all historical events. The aggregator deduplicates by
            // requestId, so re-emitting is safe and idempotent.
            offsets.removeValue(forKey: file.path)
            await parseAndEmit(file: file, seedIfNew: true, minTimestamp: backfillSince)
        }
        saveOffsets()
    }

    private func startWatching() {
        let root = projectsRoot.path
        let stream = FSEventStream(paths: [root]) { [weak self] paths in
            Task { [weak self] in await self?.handleFSPaths(paths) }
        }
        stream.start()
        self.eventStream = stream
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await self?.pollAll()
            }
        }
    }

    private func handleFSPaths(_ paths: [String]) async {
        let relevant = paths.filter { $0.hasSuffix(".jsonl") }
        for path in relevant {
            await parseAndEmit(file: URL(fileURLWithPath: path), seedIfNew: false, minTimestamp: nil)
        }
    }

    private func pollAll() async {
        let files = discoverJSONL()
        for file in files {
            await parseAndEmit(file: file, seedIfNew: false, minTimestamp: nil)
        }
    }

    // MARK: - Parse

    private func parseAndEmit(file: URL, seedIfNew: Bool, minTimestamp: Date?) async {
        guard let stats = JSONLStreamReader.fileStats(url: file) else { return }
        var startOffset: UInt64 = 0

        if let prev = offsets[file.path] {
            if prev.inode != stats.inode || stats.size < prev.size {
                startOffset = 0
            } else {
                startOffset = prev.size
            }
        } else if seedIfNew {
            startOffset = 0
        }

        guard let result = JSONLStreamReader.read(url: file, fromOffset: startOffset) else {
            return
        }

        for line in result.lines {
            guard let ev = parseLine(line) else { continue }
            if let minT = minTimestamp, ev.timestamp < minT { continue }
            continuation?.yield(ev)
        }

        offsets[file.path] = FileOffset(inode: stats.inode, size: result.newOffset)
    }

    private func parseLine(_ line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let type = top["type"] as? String, type == "assistant" else { return nil }

        let sessionId = (top["sessionId"] as? String) ?? "unknown"
        let cwd = (top["cwd"] as? String) ?? ""
        let timestampStr = (top["timestamp"] as? String) ?? ""
        let timestamp = Self.parseTimestamp(timestampStr) ?? Date()

        let message = top["message"] as? [String: Any] ?? [:]
        let rawModel = (message["model"] as? String) ?? ""
        let model = ClaudeModel(rawAPIName: rawModel)

        let messageId = (message["id"] as? String) ?? ""
        let requestId = (top["requestId"] as? String) ?? messageId
        let id = requestId.isEmpty ? "\(sessionId):\(timestampStr)" : requestId

        let usage = message["usage"] as? [String: Any] ?? [:]
        let input = usage["input_tokens"] as? Int ?? usage["inputTokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["outputTokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int
            ?? usage["cacheCreationInputTokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int
            ?? usage["cacheReadInputTokens"] as? Int ?? 0

        if input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 {
            return nil
        }

        return UsageEvent(
            id: id,
            timestamp: timestamp,
            sessionId: sessionId,
            cwd: cwd,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead
        )
    }

    // MARK: - Discovery

    private func discoverJSONL() -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) else { return [] }

        var results: [URL] = []
        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let files = try? fm.contentsOfDirectory(
                at: child, includingPropertiesForKeys: nil
            ) {
                results.append(contentsOf: files.filter { $0.pathExtension == "jsonl" })
            }
        }
        return results
    }

    // MARK: - Offsets persistence

    private func loadOffsets() {
        guard let data = try? Data(contentsOf: offsetsFile),
              let decoded = try? JSONDecoder().decode([String: FileOffset].self, from: data)
        else { return }
        offsets = decoded
    }

    private func saveOffsets() {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? data.write(to: offsetsFile)
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        // Each call creates a fresh formatter; cheap enough and avoids Sendable issues.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
