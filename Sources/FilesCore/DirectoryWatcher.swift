import Foundation
import CoreServices
import Darwin

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
    /// False means the caller must reconcile a read that began before registration.
    public let replaysCapturedEvents: Bool
    public struct ReadToken: Sendable {
        fileprivate let path: String
        fileprivate let device: Int32?
        fileprivate let historyUUID: String?
        public let eventID: UInt64
    }
    /// Call before the scan, on a filesystem worker: resolving a path may block.
    public static func captureReadToken(for url: URL) -> ReadToken {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        let internalVolume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == true
        guard internalVolume, stat(path, &info) == 0,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else {
            return ReadToken(path: path, device: nil, historyUUID: nil, eventID: 0)
        }
        let identifier = CFUUIDCreateString(nil, uuid) as String
        return ReadToken(path: path, device: info.st_dev, historyUUID: identifier, eventID: FSEventsGetCurrentEventId())
    }

    public init?(url: URL, readToken: ReadToken? = nil) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream; continuation = pair.continuation
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        // Revalidate the path, device and history epoch captured before the read.
        // Unsupported or changed history retains the SinceNow + reconciliation path.
        if let token = readToken, token.eventID > 0,
           token.eventID != UInt64(kFSEventStreamEventIdSinceNow),
           token.path == path, token.historyUUID != nil {
            let current = Self.captureReadToken(for: url)
            replaysCapturedEvents = token.device == current.device && token.historyUUID == current.historyUUID
                && token.eventID <= current.eventID
        } else { replaysCapturedEvents = false }
        let since = replaysCapturedEvents ? readToken!.eventID : UInt64(kFSEventStreamEventIdSinceNow)
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
            for index in 0..<count {
                switch DirectoryWatcher.disposition(of: flags[index]) {
                case .rescan:
                    context.continuation.yield(()); return
                case .historyBoundary:
                    // Apple's HistoryDone marker has no meaningful path to inspect.
                    continue
                case .path:
                    let entries = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    let path = String(cString: entries[index])
                    if DirectoryWatcher.affectsDirectory(eventPath: path, watchedPath: context.path) {
                        context.continuation.yield(()); return
                    }
                }
            }
        }
        let created = withExtendedLifetime(holder) { FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(since), 0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) }
        guard let stream = created else { pair.continuation.finish(); return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "files.directory-events", qos: .utility))
        if !FSEventStreamStart(stream) { stop(); return nil }
    }
    enum EventDisposition: Equatable { case rescan, historyBoundary, path }
    static func disposition(of flags: FSEventStreamEventFlags) -> EventDisposition {
        let invalidation = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        if flags & invalidation != 0 { return .rescan }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return .historyBoundary }
        return .path
    }
    static func affectsDirectory(eventPath: String, watchedPath: String) -> Bool {
        let url = URL(fileURLWithPath: eventPath)
        // Foundation normalizes /private/tmp differently once the event item is gone.
        // Resolve the surviving parent, rather than relying on the deleted item.
        return url.standardizedFileURL.path == watchedPath
            || url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == watchedPath
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
