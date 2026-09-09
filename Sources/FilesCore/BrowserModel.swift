import Foundation

@MainActor
public final class BrowserModel {
    public private(set) var history = NavigationHistory()
    public private(set) var items: [FileItem] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    public var showHidden = false
    public var sortOrder = SortOrder()
    public var onChange: (() -> Void)?
    private let loader: any DirectoryLoading
    private var generation = 0
    private var loadedLocation: URL?
    private var task: Task<Void, Never>?
    public init(loader: any DirectoryLoading = LocalFileSystem()) { self.loader = loader }
    public var location: URL? { history.current.url }
    public func savePosition(selection: Set<String>, scrollOffset: Double) {
        history.save(selection: selection, scrollOffset: scrollOffset)
    }
    public func navigate(_ url: URL?) {
        history.visit(url?.standardizedFileURL); reload()
    }
    public func back() { history.goBack(); reload() }
    public func forward() { history.goForward(); reload() }
    public func reload() {
        generation += 1
        let request = generation
        task?.cancel(); error = nil
        let previousItems = loadedLocation == location ? items : []
        if loadedLocation != location { items = [] }
        guard let url = location else { items = []; loadedLocation = nil; isLoading = false; onChange?(); return }
        isLoading = true; onChange?()
        let hidden = showHidden
        task = Task { [weak self, loader] in
            do {
                let result: [FileItem]
                if let streaming = loader as? any DirectoryStreaming {
                    var collected: [FileItem] = []
                    for try await batch in streaming.batches(of: url, showHidden: hidden) {
                        guard let self, self.generation == request, !Task.isCancelled else { return }
                        collected.append(contentsOf: batch)
                        if previousItems.isEmpty {
                            self.items = self.sortOrder.sorted(collected)
                            self.onChange?()
                        }
                    }
                    result = collected
                } else {
                    result = try await loader.contents(of: url, showHidden: hidden)
                }
                let items = result
                guard let self, self.generation == request, !Task.isCancelled else { return }
                let selection = SelectionRestoration.restore(self.history.current.selection, from: previousItems, to: items)
                self.history.save(selection: selection, scrollOffset: self.history.current.scrollOffset)
                self.loadedLocation = url
                self.items = self.sortOrder.sorted(items); self.isLoading = false; self.onChange?()
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.items = []; self.error = error.localizedDescription
                self.isLoading = false; self.onChange?()
            }
        }
    }
    public func sort(_ order: SortOrder) {
        sortOrder = order; items = order.sorted(items); onChange?()
    }
}
