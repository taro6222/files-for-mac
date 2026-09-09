import Foundation

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
                        .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
                    var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
                    if !showHidden { options.insert(.skipsHiddenFiles) }
                    guard let enumerator = FileManager.default.enumerator(at: url,
                        includingPropertiesForKeys: Array(keys), options: options,
                        errorHandler: { _, error in rootError = error; return false }) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    var batch: [FileItem] = []
                    var first = true
                    while let enumerated = enumerator.nextObject() as? URL {
                        let child = url.appendingPathComponent(enumerated.lastPathComponent)
                        try Task.checkCancellation()
                        do {
                            let v = try child.resourceValues(forKeys: keys)
                            let attributes = try? FileManager.default.attributesOfItem(atPath: child.path)
                            let identity: String?
                            if let device = attributes?[.systemNumber] as? NSNumber,
                               let inode = attributes?[.systemFileNumber] as? NSNumber,
                               let birth = attributes?[.creationDate] as? Date {
                                identity = "\(device):\(inode):\(birth.timeIntervalSince1970)"
                            } else { identity = nil }
                            batch.append(FileItem(url: child, name: child.lastPathComponent,
                                isDirectory: v.isDirectory ?? false, identity: identity, isPackage: v.isPackage ?? false,
                                isSymbolicLink: v.isSymbolicLink ?? false, isHidden: v.isHidden ?? false,
                                size: v.fileSize.map(Int64.init), modified: v.contentModificationDate,
                                kind: v.isDirectory == true ? "Folder" : (child.pathExtension.isEmpty ? "File" : child.pathExtension.uppercased())))
                        } catch {
                            let e = error as NSError
                            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { continue }
                            batch.append(FileItem(url: child, name: child.lastPathComponent, isDirectory: false, kind: "—"))
                        }
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

public struct NavigationEntry: Equatable, Sendable {
    public var url: URL?
    public var selection: Set<String>
    public var scrollOffset: Double
    public init(url: URL?, selection: Set<String> = [], scrollOffset: Double = 0) {
        self.url = url; self.selection = selection; self.scrollOffset = scrollOffset
    }
}

public struct NavigationHistory: Sendable {
    public private(set) var current = NavigationEntry(url: nil)
    public private(set) var back: [NavigationEntry] = []
    public private(set) var forward: [NavigationEntry] = []
    public init() {}
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
