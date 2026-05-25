import Testing
import Foundation
@testable import ClaudeUsageVisualizer

@Suite("SessionRegistry.deduplicate")
struct SessionRegistryDedupeTests {

    private func session(
        id: String,
        pid: Int32,
        startedAt: Date,
        isRunning: Bool
    ) -> SessionRegistry.RawSession {
        SessionRegistry.RawSession(
            pid: pid,
            sessionId: id,
            cwd: "/tmp",
            startedAt: startedAt,
            kind: "claude_code",
            entrypoint: nil,
            name: nil,
            isRunning: isRunning
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)

    @Test func empty_input() {
        #expect(SessionRegistry.deduplicate([]).isEmpty)
    }

    @Test func single_session_passes_through() {
        let s = session(id: "abc", pid: 1, startedAt: t0, isRunning: true)
        let result = SessionRegistry.deduplicate([s])
        #expect(result.count == 1)
        #expect(result[0].pid == 1)
    }

    @Test func running_wins_over_dead_regardless_of_start_time() {
        // dead but newer should lose to running but older
        let dead = session(id: "abc", pid: 1, startedAt: t2, isRunning: false)
        let alive = session(id: "abc", pid: 2, startedAt: t0, isRunning: true)
        let result = SessionRegistry.deduplicate([dead, alive])
        #expect(result.count == 1)
        #expect(result[0].pid == 2)  // alive wins
    }

    @Test func most_recent_wins_when_both_running() {
        let older = session(id: "abc", pid: 1, startedAt: t0, isRunning: true)
        let newer = session(id: "abc", pid: 2, startedAt: t1, isRunning: true)
        let result = SessionRegistry.deduplicate([older, newer])
        #expect(result.count == 1)
        #expect(result[0].pid == 2)
    }

    @Test func most_recent_wins_when_both_dead() {
        let older = session(id: "abc", pid: 1, startedAt: t0, isRunning: false)
        let newer = session(id: "abc", pid: 2, startedAt: t1, isRunning: false)
        let result = SessionRegistry.deduplicate([older, newer])
        #expect(result.count == 1)
        #expect(result[0].pid == 2)
    }

    @Test func distinct_session_ids_all_kept() {
        let a = session(id: "aaa", pid: 1, startedAt: t0, isRunning: true)
        let b = session(id: "bbb", pid: 2, startedAt: t1, isRunning: true)
        let c = session(id: "ccc", pid: 3, startedAt: t2, isRunning: false)
        #expect(SessionRegistry.deduplicate([a, b, c]).count == 3)
    }

    @Test func output_sorted_most_recent_first() {
        let a = session(id: "aaa", pid: 1, startedAt: t2, isRunning: true)
        let b = session(id: "bbb", pid: 2, startedAt: t0, isRunning: true)
        let c = session(id: "ccc", pid: 3, startedAt: t1, isRunning: true)
        let result = SessionRegistry.deduplicate([a, b, c])
        #expect(result[0].sessionId == "aaa")
        #expect(result[1].sessionId == "ccc")
        #expect(result[2].sessionId == "bbb")
    }

    @Test func three_files_same_session_running_instance_wins() {
        let dead1 = session(id: "x", pid: 10, startedAt: t0, isRunning: false)
        let dead2 = session(id: "x", pid: 11, startedAt: t1, isRunning: false)
        let alive = session(id: "x", pid: 12, startedAt: t0, isRunning: true)
        let result = SessionRegistry.deduplicate([dead1, dead2, alive])
        #expect(result.count == 1)
        #expect(result[0].pid == 12)
    }
}
