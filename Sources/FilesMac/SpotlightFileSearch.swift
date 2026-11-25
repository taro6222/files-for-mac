import Foundation
import FilesCore

#if DEBUG
extension SpotlightFileSearch {
    @MainActor static func runVerification(output: String) async {
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        do {
            guard let path = ProcessInfo.processInfo.environment["FILES_UI_SPOTLIGHT_ROOT"] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let expected = root.appendingPathComponent("Sources/FilesCore/LocalSearch.swift")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let outside = destination.appendingPathComponent("empty-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            func collect(_ text: String, at root: URL, scope: SearchScope) async throws -> [FileItem] {
                var result: [FileItem] = []
                for try await batch in SpotlightFileSearch().batches(in: root,
                    query: FileSearchQuery(text: text, scope: scope, method: .spotlightContent)) {
                    result.append(contentsOf: batch.items)
                }
                return result
            }
            let descendants = try await collect("SearchRouter", at: root, scope: .descendants)
            let current = try await collect("SearchRouter", at: root, scope: .currentFolder)
            let indexed = try await collect("SearchRouter", at: outside, scope: .indexedLocations)
            let absent = try await collect("files-mac-missing-\(UUID())", at: root, scope: .descendants)
            let checks = [
                "descendantsFindExactSwiftSource": descendants.contains { $0.url == expected },
                "currentFolderExcludesNestedSwiftSource": current.isEmpty,
                "indexedLocationsFindSourceOutsideCurrentFolder": indexed.contains { $0.url == expected },
                "unknownContentHasNoResults": absent.isEmpty,
            ]
            let report: [String: Any] = ["checks": checks, "sourceRoot": root.path,
                "expectedFile": expected.path, "descendantResults": descendants.map { $0.url.path },
                "os": ProcessInfo.processInfo.operatingSystemVersionString]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("report.json"), options: .atomic)
            DispatchQueue.main.async { exit(checks.values.allSatisfy { $0 } ? 0 : 1) }
        } catch {
            fputs("Spotlight verification failed: \(error)\n", stderr)
            DispatchQueue.main.async { exit(1) }
        }
    }
}
#endif

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
        if request.scope == .indexedLocations {
            metadataQuery.searchScopes.append(NSMetadataQueryIndexedNetworkScope)
        }
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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .tagNamesKey]
        let nameTerms = request.method == .spotlightContent ? [] : foldedTerms(request.text)
        let tagTerms = foldedTerms(request.tagText)
        var items: [FileItem] = [], skipped = 0, seen = Set<String>()
        for case let result as NSMetadataItem in metadataQuery.results {
            let url = (result.value(forAttribute: NSMetadataItemURLKey) as? URL)
                ?? (result.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
            guard let url, url.isFileURL else { skipped += 1; continue }
            let normalized = url.standardizedFileURL
            switch request.scope {
            case .indexedLocations: break
            case .currentFolder:
                guard normalized.deletingLastPathComponent().path == root.path, normalized.path != root.path else { continue }
            case .descendants:
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                guard normalized.path != root.path, normalized.path.hasPrefix(prefix) else { continue }
            }
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
                    isHidden: values.isHidden ?? false, size: size, created: values.creationDate, modified: values.contentModificationDate,
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

struct HomeFileTagGroup: Equatable {
    let name: String
    let items: [URL]
}

@MainActor
final class HomeFileTagSearch {
    private static let tagsAttribute = "kMDItemUserTags"
    private let query = NSMetadataQuery()
    private var observation: NSObjectProtocol?
    private var response: CheckedContinuation<[HomeFileTagGroup]?, Never>?
    private var timeout: Task<Void, Never>?

    func load() async -> [HomeFileTagGroup]? {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { response in
                self.response = response
                query.searchScopes = [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
                query.predicate = NSPredicate(format: "%K LIKE %@", Self.tagsAttribute, "*")
                query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
                observation = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                     object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readResults() }
                }
                guard query.start() else { finish(nil); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    private func readResults() {
        query.disableUpdates()
        var itemsByTag: [String: [URL]] = [:]
        var seen = Set<URL>()
        // Home shows a bounded recent sample even when the index contains many tagged files.
        for index in 0..<min(query.resultCount, 1_000) {
            guard let result = query.result(at: index) as? NSMetadataItem else { continue }
            let itemURL = (result.value(forAttribute: NSMetadataItemURLKey) as? URL)
                ?? (result.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
            guard let url = itemURL?.standardizedFileURL,
                  url.isFileURL, !url.lastPathComponent.hasPrefix("."), seen.insert(url).inserted,
                  let tags = result.value(forAttribute: Self.tagsAttribute) as? [String] else { continue }
            for tag in Set(tags) where !tag.isEmpty {
                if itemsByTag[tag, default: []].count < 4 { itemsByTag[tag, default: []].append(url) }
            }
        }
        query.enableUpdates()
        let names = itemsByTag.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        finish(names.prefix(20).compactMap { name in itemsByTag[name].map { HomeFileTagGroup(name: name, items: $0) } })
    }

    private func finish(_ groups: [HomeFileTagGroup]?) {
        guard let response else { return }
        self.response = nil
        timeout?.cancel()
        timeout = nil
        if let observation {
            NotificationCenter.default.removeObserver(observation)
            self.observation = nil
        }
        query.stop()
        response.resume(returning: groups)
    }
}
