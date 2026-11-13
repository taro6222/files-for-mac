import Foundation

public enum SearchScope: String, CaseIterable, Sendable { case currentFolder, descendants }
public enum SearchItemKind: String, CaseIterable, Sendable { case any, files, folders }

public struct FileSearchQuery: Sendable, Equatable {
    public var text: String
    public var scope: SearchScope
    public var kind: SearchItemKind
    public var showHidden: Bool
    public init(text: String, scope: SearchScope = .descendants, kind: SearchItemKind = .any, showHidden: Bool = false) {
        self.text = text; self.scope = scope; self.kind = kind; self.showHidden = showHidden
    }
}

public struct FileSearchBatch: Sendable {
    public let items: [FileItem]
    public let skippedLocations: Int
    public init(items: [FileItem], skippedLocations: Int) { self.items = items; self.skippedLocations = skippedLocations }
}

public struct LocalFileSearch: Sendable {
    public init() {}
    public func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw POSIXError(.ENOTDIR) }
                    let terms = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .split(whereSeparator: \.isWhitespace).map(String.init)
                    guard !terms.isEmpty else { continuation.finish(); return }
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
                    var options: FileManager.DirectoryEnumerationOptions = []
                    if query.scope == .currentFolder { options.insert(.skipsSubdirectoryDescendants) }
                    if !query.showHidden { options.insert(.skipsHiddenFiles) }
                    options.insert(.skipsPackageDescendants)
                    var skipped = 0
                    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: options,
                        errorHandler: { _, _ in skipped += 1; return true }) else { throw CocoaError(.fileReadUnknown) }
                    var batch: [FileItem] = []
                    while let url = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        let name = url.lastPathComponent
                        let searchable = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        guard terms.allSatisfy(searchable.contains) else { continue }
                        do {
                            let v = try url.resourceValues(forKeys: keys), isDirectory = v.isDirectory ?? false
                            guard query.kind == .any || (query.kind == .folders && isDirectory) || (query.kind == .files && !isDirectory) else { continue }
                            batch.append(FileItem(url: url, name: name, isDirectory: isDirectory,
                                isPackage: v.isPackage ?? false, isSymbolicLink: v.isSymbolicLink ?? false,
                                isHidden: v.isHidden ?? false, size: v.fileSize.map(Int64.init), modified: v.contentModificationDate,
                                kind: isDirectory ? "Folder" : (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased())))
                        } catch { skipped += 1 }
                        if batch.count >= 128 { continuation.yield(FileSearchBatch(items: batch, skippedLocations: skipped)); batch.removeAll(keepingCapacity: true) }
                    }
                    if !batch.isEmpty || skipped > 0 { continuation.yield(FileSearchBatch(items: batch, skippedLocations: skipped)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
