import Foundation

@MainActor
public final class SearchModel {
    public private(set) var root: URL?
    public private(set) var query: FileSearchQuery?
    public private(set) var results: [FileItem] = []
    public private(set) var isSearching = false
    public private(set) var wasCancelled = false
    public private(set) var skippedLocations = 0
    public private(set) var error: String?
    public var onChange: (() -> Void)?
    private let searcher: any FileSearching
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(searcher: any FileSearching = LocalFileSearch()) { self.searcher = searcher }
    public func reset() {
        generation += 1
        task?.cancel()
        task = nil
        root = nil
        query = nil
        results = []
        isSearching = false
        wasCancelled = false
        skippedLocations = 0
        error = nil
        onChange?()
    }
    public func search(in root: URL, query: FileSearchQuery) {
        generation += 1; let request = generation
        task?.cancel(); self.root = root.standardizedFileURL; self.query = query
        results = []; skippedLocations = 0; error = nil; wasCancelled = false
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !query.tagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { isSearching = false; onChange?(); return }
        isSearching = true; onChange?()
        task = Task { [weak self, searcher] in
            do {
                for try await batch in searcher.batches(in: root, query: query) {
                    guard let self, self.generation == request, !Task.isCancelled else { return }
                    self.results.append(contentsOf: batch.items); self.skippedLocations = max(self.skippedLocations, batch.skippedLocations); self.onChange?()
                }
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.isSearching = false; self.onChange?()
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.isSearching = false; self.error = error.localizedDescription; self.onChange?()
            }
        }
    }
    public func cancel() {
        guard isSearching else { return }
        generation += 1; task?.cancel(); task = nil; isSearching = false; wasCancelled = true; onChange?()
    }
}
