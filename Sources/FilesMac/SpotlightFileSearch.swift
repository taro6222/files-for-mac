import Foundation
import FilesCore

struct SpotlightFileSearch: FileSearching {
    func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task { @MainActor in
                let session = SpotlightSearchSession(root: root, request: query, continuation: continuation)
                session.start()
                while !session.isFinished && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled { session.cancel() }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}

@MainActor
private final class SpotlightSearchSession: NSObject {
    private let root: URL
    private let request: FileSearchQuery
    private let continuation: AsyncThrowingStream<FileSearchBatch, Error>.Continuation
    private let metadataQuery = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private(set) var isFinished = false

    init(root: URL, request: FileSearchQuery, continuation: AsyncThrowingStream<FileSearchBatch, Error>.Continuation) {
        self.root = root.standardizedFileURL; self.request = request; self.continuation = continuation
    }

    func start() {
        metadataQuery.searchScopes = [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
        metadataQuery.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemTextContentKey, "*\(request.text)*")
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishGathering() }
        }
        guard metadataQuery.start() else {
            finish(throwing: CocoaError(.featureUnsupported)); return
        }
    }

    func cancel() { finish(throwing: CancellationError()) }

    private func finishGathering() {
        metadataQuery.disableUpdates()
        defer { metadataQuery.enableUpdates() }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .tagNamesKey]
        let nameTerms = request.method == .spotlightContent ? [] : foldedTerms(request.text)
        let tagTerms = foldedTerms(request.tagText)
        var items: [FileItem] = [], skipped = 0, seen = Set<String>()
        for case let result as NSMetadataItem in metadataQuery.results {
            let url = (result.value(forAttribute: NSMetadataItemURLKey) as? URL)
                ?? (result.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
            guard let url else { skipped += 1; continue }
            let normalized = url.standardizedFileURL
            guard normalized.path != root.path, normalized.path.hasPrefix(root.path + "/") else { continue }
            if request.scope == .currentFolder && normalized.deletingLastPathComponent() != root { continue }
            guard seen.insert(normalized.path).inserted else { continue }
            do {
                let values = try normalized.resourceValues(forKeys: keys), isDirectory = values.isDirectory ?? false
                guard request.showHidden || values.isHidden != true else { continue }
                guard request.kind == .any || (request.kind == .folders && isDirectory) || (request.kind == .files && !isDirectory) else { continue }
                let searchableName = normalized.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard nameTerms.allSatisfy(searchableName.contains) else { continue }
                let searchableTags = (values.tagNames ?? []).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard tagTerms.allSatisfy(searchableTags.contains) else { continue }
                let size = values.fileSize.map(Int64.init)
                if let minimum = request.minimumSize, size == nil || size! < minimum { continue }
                if let maximum = request.maximumSize, size == nil || size! > maximum { continue }
                if let after = request.modifiedAfter, values.contentModificationDate == nil || values.contentModificationDate! < after { continue }
                if let before = request.modifiedBefore, values.contentModificationDate == nil || values.contentModificationDate! > before { continue }
                items.append(FileItem(url: normalized, name: normalized.lastPathComponent, isDirectory: isDirectory,
                    isPackage: values.isPackage ?? false, isSymbolicLink: values.isSymbolicLink ?? false,
                    isHidden: values.isHidden ?? false, size: size, modified: values.contentModificationDate,
                    kind: isDirectory ? "Folder" : (normalized.pathExtension.isEmpty ? "File" : normalized.pathExtension.uppercased())))
                if items.count == 128 { continuation.yield(FileSearchBatch(items: items, skippedLocations: skipped)); items.removeAll(keepingCapacity: true) }
            } catch { skipped += 1 }
        }
        if !items.isEmpty || skipped > 0 { continuation.yield(FileSearchBatch(items: items, skippedLocations: skipped)) }
        finish()
    }

    private func foldedTerms(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func finish(throwing error: Error? = nil) {
        guard !isFinished else { return }
        isFinished = true; metadataQuery.stop()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
