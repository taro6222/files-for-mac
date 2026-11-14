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
    public init() {}
    public func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        var result: [FileItem] = []
        for try await batch in batches(of: url, showHidden: showHidden) { result.append(contentsOf: batch) }
        return result
    }
    public func batches(of url: URL, showHidden: Bool) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
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
                        includingPropertiesForKeys: Array(keys), options: options,
                        errorHandler: { _, error in rootError = error; return false }) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    var batch: [FileItem] = []
                    var first = true
                    while true {
                        try Task.checkCancellation()
                        var reachedEnd = false
                        let item: FileItem? = autoreleasepool {
                            guard let enumerated = enumerator.nextObject() as? URL else {
                                reachedEnd = true
                                return nil
                            }
                            let child = url.appendingPathComponent(enumerated.lastPathComponent)
                            do {
                                // Use the resource values prefetched by the directory enumerator.
                                // Keep a fresh URL in the model for later operations and refreshes.
                                let v = try enumerated.resourceValues(forKeys: keys)
                                return FileItem(url: child, name: child.lastPathComponent,
                                    isDirectory: v.isDirectory ?? false, identity: LocalEntryIdentity.read(child),
                                    isPackage: v.isPackage ?? false,
                                    isSymbolicLink: v.isSymbolicLink ?? false, isHidden: v.isHidden ?? false,
                                    size: v.fileSize.map(Int64.init), created: v.creationDate, modified: v.contentModificationDate,
                                    kind: v.isDirectory == true ? "Folder" : (child.pathExtension.isEmpty ? "File" : child.pathExtension.uppercased()),
                                    tags: v.tagNames ?? [],
                                    cloudState: v.isUbiquitousItem == true ? .readUbiquitousState(at: child) : nil)
                            } catch {
                                let e = error as NSError
                                if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return nil }
                                return FileItem(url: child, name: child.lastPathComponent, isDirectory: false, kind: "—")
                            }
                        }
                        if reachedEnd { break }
                        guard let item else { continue }
                        batch.append(item)
                        if batch.count >= (first ? 128 : 1024) {
                            continuation.yield(batch); batch.removeAll(keepingCapacity: true); first = false
                        }
                    }
                    if let rootError { throw rootError }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
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
