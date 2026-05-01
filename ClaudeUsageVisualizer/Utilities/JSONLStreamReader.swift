import Foundation

/// Reads complete lines from a file starting at a given byte offset.
/// Returns the new offset (start of any trailing partial line) so callers can resume.
enum JSONLStreamReader {
    struct ReadResult: Sendable {
        let lines: [String]
        let newOffset: UInt64
        let fileSize: UInt64
    }

    static func read(url: URL, fromOffset offset: UInt64) -> ReadResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let endOffset: UInt64
        do {
            endOffset = try handle.seekToEnd()
        } catch {
            return nil
        }

        let startOffset = min(offset, endOffset)
        do { try handle.seek(toOffset: startOffset) } catch { return nil }

        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ReadResult(lines: [], newOffset: startOffset, fileSize: endOffset)
        }

        var lines: [String] = []
        var lastNewlineRelative: Int = -1
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var lineStart = 0
            for i in 0..<data.count {
                if base[i] == 0x0A {
                    let lineLen = i - lineStart
                    if lineLen > 0,
                       let s = String(
                           data: Data(bytes: base + lineStart, count: lineLen),
                           encoding: .utf8
                       ) {
                        lines.append(s)
                    }
                    lineStart = i + 1
                    lastNewlineRelative = i
                }
            }
        }

        let consumedBytes: UInt64
        if lastNewlineRelative >= 0 {
            consumedBytes = UInt64(lastNewlineRelative + 1)
        } else {
            consumedBytes = 0
        }
        let newOffset = startOffset + consumedBytes
        return ReadResult(lines: lines, newOffset: newOffset, fileSize: endOffset)
    }

    static func fileStats(url: URL) -> (inode: UInt64, size: UInt64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(st.st_ino), UInt64(st.st_size))
    }
}
