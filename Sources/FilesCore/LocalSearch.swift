import Foundation

public enum SearchScope: String, CaseIterable, Sendable { case currentFolder, descendants }
public enum SearchItemKind: String, CaseIterable, Sendable { case any, files, folders }
public enum SearchMethod: String, CaseIterable, Sendable { case fileName, spotlightContent }
public enum SearchSizeUnit: String, CaseIterable, Sendable {
    case bytes = "B", kilobytes = "KB", megabytes = "MB", gigabytes = "GB"
    public var multiplier: Double {
        switch self { case .bytes: 1; case .kilobytes: 1_000; case .megabytes: 1_000_000; case .gigabytes: 1_000_000_000 }
    }
    public func byteCount(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0, value <= Double(Int64.max) / multiplier else { return nil }
        return Int64((value * multiplier).rounded())
    }
}

public struct FileSearchQuery: Sendable, Equatable {
    public var text: String
    public var scope: SearchScope
    public var kind: SearchItemKind
    public var showHidden: Bool
    public var tagText: String
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var method: SearchMethod
    public init(text: String, scope: SearchScope = .descendants, kind: SearchItemKind = .any, showHidden: Bool = false,
                tagText: String = "", minimumSize: Int64? = nil, maximumSize: Int64? = nil,
                modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, method: SearchMethod = .fileName) {
        self.text = text; self.scope = scope; self.kind = kind; self.showHidden = showHidden
        self.tagText = tagText; self.minimumSize = minimumSize; self.maximumSize = maximumSize
        self.modifiedAfter = modifiedAfter; self.modifiedBefore = modifiedBefore
        self.method = method
    }
}

public struct FileSearchBatch: Sendable {
    public let items: [FileItem]
    public let skippedLocations: Int
    public init(items: [FileItem], skippedLocations: Int) { self.items = items; self.skippedLocations = skippedLocations }
}

public protocol FileSearching: Sendable {
    func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error>
}

public struct SearchRouter: FileSearching {
    private let local: any FileSearching
    private let spotlight: any FileSearching
    public init(local: any FileSearching = LocalFileSearch(), spotlight: any FileSearching) {
        self.local = local; self.spotlight = spotlight
    }
    public func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error> {
        switch query.method {
        case .fileName: local.batches(in: root, query: query)
        case .spotlightContent: spotlight.batches(in: root, query: query)
        }
    }
}

public struct LocalFileSearch: FileSearching {
    public init() {}
    public func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw POSIXError(.ENOTDIR) }
                    let terms = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .split(whereSeparator: \.isWhitespace).map(String.init)
                    let tagTerms = query.tagText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .split(whereSeparator: \.isWhitespace).map(String.init)
                    guard !terms.isEmpty || !tagTerms.isEmpty else { continuation.finish(); return }
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .tagNamesKey]
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
                            let size = v.fileSize.map(Int64.init)
                            if let minimum = query.minimumSize, size == nil || size! < minimum { continue }
                            if let maximum = query.maximumSize, size == nil || size! > maximum { continue }
                            if let after = query.modifiedAfter, v.contentModificationDate == nil || v.contentModificationDate! < after { continue }
                            if let before = query.modifiedBefore, v.contentModificationDate == nil || v.contentModificationDate! > before { continue }
                            let searchableTags = (v.tagNames ?? []).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                            guard tagTerms.allSatisfy(searchableTags.contains) else { continue }
                            batch.append(FileItem(url: url, name: name, isDirectory: isDirectory,
                                isPackage: v.isPackage ?? false, isSymbolicLink: v.isSymbolicLink ?? false,
                                isHidden: v.isHidden ?? false, size: size, created: v.creationDate, modified: v.contentModificationDate,
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
