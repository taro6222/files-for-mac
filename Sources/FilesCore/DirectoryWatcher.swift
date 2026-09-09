import Foundation
import CoreServices

/// FSEvents observes the directory and its direct children without polling metadata
/// on the main thread. Events are hints: the caller always re-enumerates the directory.
public final class DirectoryWatcher: @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        let path: String
        let continuation: AsyncStream<Void>.Continuation
        init(path: String, continuation: AsyncStream<Void>.Continuation) {
            self.path = path; self.continuation = continuation
        }
    }
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<Void>.Continuation
    public let events: AsyncStream<Void>

    public init?(url: URL) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream; continuation = pair.continuation
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let holder = Context(path: path, continuation: pair.continuation)
        let pointer = Unmanaged.passUnretained(holder).toOpaque()
        var context = FSEventStreamContext(version: 0, info: pointer, retain: { pointer in
            guard let pointer else { return nil }
            _ = Unmanaged<Context>.fromOpaque(pointer).retain()
            return pointer
        }, release: { pointer in
            if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let entries = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                let path = URL(fileURLWithPath: String(cString: entries[index])).standardizedFileURL.path
                let needsRescan = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                if needsRescan || path == context.path || (path as NSString).deletingLastPathComponent == context.path {
                    context.continuation.yield(()); break
                }
            }
        }
        let created = withExtendedLifetime(holder) { FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) }
        guard let stream = created else { pair.continuation.finish(); return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "files.directory-events", qos: .utility))
        if !FSEventStreamStart(stream) { stop(); return nil }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }
    deinit { stop() }
}
