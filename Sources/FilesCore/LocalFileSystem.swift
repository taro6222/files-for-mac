import Foundation
import Darwin

enum LocalEntryIdentity {
    static func read(_ url: URL, fileManager: FileManager = .default) -> String? {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let birth = info.st_birthtimespec
        if birth.tv_sec != 0 || birth.tv_nsec != 0 {
            let timestamp = Date(timeIntervalSince1970: Double(birth.tv_sec) + Double(birth.tv_nsec) / 1e9)
            return "\(info.st_dev):\(info.st_ino):\(timestamp.timeIntervalSince1970)"
        }
        // Some volumes do not expose a birth time through stat.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        return "\(device):\(inode):\(created.timeIntervalSince1970)"
    }
}

public protocol DirectoryLoading: Sendable {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem]
}

public protocol DirectoryStreaming: DirectoryLoading {
    func batches(of url: URL, showHidden: Bool) -> AsyncThrowingStream<[FileItem], Error>
}

public struct LocalFileSystem: DirectoryStreaming {
    private let beforeReading: (@Sendable () -> Void)?
    private let beforeEntryReading: (@Sendable (URL) -> Void)?
    private let metadataWorkers: Int
    public init() { beforeReading = nil; beforeEntryReading = nil; metadataWorkers = 4 }
    // Bounded seams for synchronously blocked root and entry metadata calls.
    init(beforeReading: @escaping @Sendable () -> Void,
         beforeEntryReading: (@Sendable (URL) -> Void)? = nil, metadataWorkers: Int = 4) {
        self.beforeReading = beforeReading; self.beforeEntryReading = beforeEntryReading
        self.metadataWorkers = max(1, min(4, metadataWorkers))
    }
    public func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        var result: [FileItem] = []
        for try await batch in batches(of: url, showHidden: showHidden) { result.append(contentsOf: batch) }
        return result
    }
    public func batches(of url: URL, showHidden: Bool) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let cancellation = CopyCancellation()
            // NSURL resource queries may synchronously wait for File Provider or a mounted
            // server. Keep that work off Swift's cooperative executor, including the first read.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try cancellation.check()
                    beforeReading?()
                    try cancellation.check()
                    // Validate the root first; a missing/unreadable directory is never empty success.
                    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                        throw POSIXError(.ENOTDIR)
                    }
                    var rootError: Error?
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                        .isHiddenKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .tagNamesKey, .isUbiquitousItemKey]
                    var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
                    if !showHidden { options.insert(.skipsHiddenFiles) }
                    guard let enumerator = FileManager.default.enumerator(at: url,
                        includingPropertiesForKeys: [.tagNamesKey], options: options,
                        errorHandler: { _, error in rootError = error; return false }) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    // Keep URL traversal serial; full resource lookup can synchronously consult
                    // File Provider even for local files. Read bounded batches on the GCD pool.
                    var first = true
                    var ended = false
                    while !ended {
                        var urls: [URL] = []
                        let limit = first ? 128 : 1024
                        urls.reserveCapacity(limit)
                        while urls.count < limit {
                            try cancellation.check()
                            guard let child = enumerator.nextObject() as? URL else { ended = true; break }
                            urls.append(child)
                        }
                        if let rootError { throw rootError }
                        guard !urls.isEmpty else { break }
                        let batch = DirectoryEntryBatch(count: urls.count)
                        let children = urls
                        let workers = min(metadataWorkers, children.count)
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            for index in stride(from: worker, to: children.count, by: workers) {
                                if cancellation.isCancelled { break }
                                let item: FileItem? = autoreleasepool {
                                    beforeEntryReading?(children[index])
                                    guard !cancellation.isCancelled else { return nil }
                                    // Explicit tag prefetch preserves Finder tag values carried by
                                    // the enumerator while the remaining keys resolve on this worker.
                                    let enumerated = children[index]
                                    let name = enumerated.lastPathComponent
                                    do {
                                        let v = try enumerated.resourceValues(forKeys: keys)
                                        guard !cancellation.isCancelled else { return nil }
                                        let child = url.appending(component: name, directoryHint: v.isDirectory == true ? .isDirectory : .notDirectory)
                                        return FileItem(url: child, name: name,
                                            isDirectory: v.isDirectory ?? false, identity: LocalEntryIdentity.read(child),
                                            isPackage: v.isPackage ?? false,
                                            isSymbolicLink: v.isSymbolicLink ?? false, isHidden: v.isHidden ?? false,
                                            size: v.fileSize.map(Int64.init), created: v.creationDate, modified: v.contentModificationDate,
                                            kind: v.isDirectory == true ? "Folder" : (child.pathExtension.isEmpty ? "File" : child.pathExtension.uppercased()),
                                            tags: StoredFileTags.names(at: child, fallback: v.tagNames ?? []),
                                            cloudState: v.isUbiquitousItem == true ? .readUbiquitousState(at: child) : nil)
                                    } catch {
                                        let error = error as NSError
                                        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
                                        return FileItem(url: url.appending(component: name, directoryHint: .notDirectory), name: name, isDirectory: false, kind: "—")
                                    }
                                }
                                batch.store(item, at: index)
                            }
                        }
                        try cancellation.check()
                        let items = batch.items
                        if !items.isEmpty { continuation.yield(items); first = false }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in cancellation.cancel() }
        }
    }
}

/// Resource reads run concurrently, but a completed batch retains traversal order.
private final class DirectoryEntryBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [FileItem?]
    init(count: Int) { entries = Array(repeating: nil, count: count) }
    func store(_ item: FileItem?, at index: Int) { lock.withLock { entries[index] = item } }
    var items: [FileItem] { lock.withLock { entries.compactMap { $0 } } }
}

public struct NavigationEntry: Codable, Equatable, Sendable {
    public var url: URL?
    public var selection: Set<String>
    public var scrollOffset: Double
    public init(url: URL?, selection: Set<String> = [], scrollOffset: Double = 0) {
        self.url = url; self.selection = selection; self.scrollOffset = scrollOffset
    }
}

public struct NavigationHistory: Codable, Equatable, Sendable {
    public private(set) var current = NavigationEntry(url: nil)
    public private(set) var back: [NavigationEntry] = []
    public private(set) var forward: [NavigationEntry] = []
    public init() {}
    public init(current: NavigationEntry, back: [NavigationEntry] = [], forward: [NavigationEntry] = []) {
        self.current = current; self.back = back; self.forward = forward
    }
    public mutating func save(selection: Set<String>, scrollOffset: Double) {
        current.selection = selection; current.scrollOffset = scrollOffset
    }
    public mutating func visit(_ url: URL?) {
        guard current.url != url else { return }
        back.append(current); current = NavigationEntry(url: url); forward.removeAll()
    }
    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current); current = previous
    }
    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current); current = next
    }
}
