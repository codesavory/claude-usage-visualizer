import CoreServices
import Foundation

/// Thin Swift wrapper over FSEventStream that emits paths on change.
final class FSEventStream: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.claudeusagevisualizer.fsevents")
    private let handler: @Sendable ([String]) -> Void

    init(paths: [String], handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var out: [String] = []
            out.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                if let s = paths[Int(i)] as? String {
                    out.append(s)
                }
            }
            me.handler(out)
        }

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
        }
    }

    func start() {
        guard let stream else { return }
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
