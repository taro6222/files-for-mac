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
        task?.cancel(); items = []; error = nil
        guard let url = location else { isLoading = false; onChange?(); return }
        isLoading = true; onChange?()
        let hidden = showHidden
        task = Task { [weak self, loader] in
            do {
                let items = try await loader.contents(of: url, showHidden: hidden)
                guard let self, self.generation == request, !Task.isCancelled else { return }
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
