import Foundation

public enum DirectoryFailure: String, Sendable {
    case permissionDenied, notFound, notDirectory, unavailable, unknown

    public init(_ error: any Error) {
        var current = error as NSError
        // FileManager may wrap a more specific POSIX failure in a generic Cocoa error.
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                switch current.code {
                case Int(EACCES), Int(EPERM): self = .permissionDenied; return
                case Int(ENOENT): self = .notFound; return
                case Int(ENOTDIR): self = .notDirectory; return
                case Int(ENODEV), Int(ENXIO), Int(ENETDOWN), Int(ENETUNREACH), Int(ETIMEDOUT): self = .unavailable; return
                default: break
                }
            } else if current.domain == NSCocoaErrorDomain {
                switch current.code {
                case NSFileReadNoPermissionError: self = .permissionDenied; return
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: self = .notFound; return
                default: break
                }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        self = .unknown
    }

    public func message(korean: Bool) -> String {
        switch self {
        case .permissionDenied:
            return korean ? "이 폴더를 읽을 권한이 없습니다. 접근 권한을 확인한 뒤 새로고침하세요." : "You don't have permission to read this folder. Check its access permissions, then refresh."
        case .notFound:
            return korean ? "폴더를 찾을 수 없습니다. 경로를 확인하거나 상위 폴더로 이동하세요." : "This folder could not be found. Check the path or open the enclosing folder."
        case .notDirectory:
            return korean ? "폴더가 아닌 항목입니다. 폴더 경로를 입력하세요." : "This item is not a folder. Enter a folder path."
        case .unavailable:
            return korean ? "저장 장치 또는 네트워크에 연결할 수 없습니다. 연결을 확인한 뒤 새로고침하세요." : "The drive or network is unavailable. Check the connection, then refresh."
        case .unknown:
            return korean ? "폴더를 읽는 중 오류가 발생했습니다. 경로와 연결 상태를 확인한 뒤 다시 시도하세요." : "An error occurred while reading this folder. Check the path and connection, then try again."
        }
    }
}

@MainActor
public final class BrowserModel {
    public private(set) var history = NavigationHistory()
    private var folderItems: [FileItem] = [] {
        didSet { updateVisibleItems() }
    }
    public private(set) var items: [FileItem] = []
    public var loadedItems: [FileItem] { folderItems }
    public private(set) var nameFilter = ""
    private var filterLocation: URL?
    public private(set) var isLoading = false
    public private(set) var wasCancelled = false
    public private(set) var error: String?
    public private(set) var failure: DirectoryFailure?
    public var showHidden = false
    public var sortOrder = SortOrder()
    public private(set) var viewMode: BrowserViewMode = .details
    public private(set) var grouping = FileGroupOptions()
    public var onChange: (() -> Void)?
    private let loader: any DirectoryLoading
    private var generation = 0
    private var loadedLocation: URL?
    private var task: Task<Void, Never>?
    public init(loader: any DirectoryLoading = LocalFileSystem()) { self.loader = loader }
    public var location: URL? { history.current.url }
    public var snapshot: TabSnapshot {
        TabSnapshot(history: history, sortOrder: sortOrder, showHidden: showHidden, viewMode: viewMode, grouping: grouping)
    }
    public func restore(_ snapshot: TabSnapshot) {
        nameFilter = ""
        filterLocation = nil
        updateVisibleItems()
        history = snapshot.history
        sortOrder = snapshot.sortOrder
        showHidden = snapshot.showHidden
        viewMode = snapshot.viewMode
        grouping = snapshot.grouping
        reload()
    }
    public func savePosition(selection: Set<String>, scrollOffset: Double) {
        history.save(selection: selection, scrollOffset: scrollOffset)
    }
    public func setNameFilter(_ query: String) {
        guard query != nameFilter else { return }
        nameFilter = query
        filterLocation = location
        updateVisibleItems()
        history.save(selection: history.current.selection.intersection(items.map(\.id)), scrollOffset: 0)
        onChange?()
    }
    private func updateVisibleItems() {
        items = nameFilter.isEmpty ? folderItems : folderItems.filter {
            $0.name.localizedStandardContains(nameFilter)
        }
    }
    public func navigate(_ url: URL?) {
        history.visit(url?.standardizedFileURL); reload()
    }
    public func back() { history.goBack(); reload() }
    public func forward() { history.goForward(); reload() }
    public func cancelLoad() {
        guard isLoading else { return }
        generation += 1
        task?.cancel(); task = nil
        isLoading = false; wasCancelled = true
        onChange?()
    }
    public func reload() {
        generation += 1
        let request = generation
        task?.cancel(); error = nil; failure = nil; wasCancelled = false
        if filterLocation != location && !nameFilter.isEmpty {
            nameFilter = ""
            updateVisibleItems()
        }
        let previousItems = loadedLocation == location ? folderItems : []
        if loadedLocation != location { folderItems = [] }
        guard let url = location else { folderItems = []; loadedLocation = nil; isLoading = false; onChange?(); return }
        isLoading = true; onChange?()
        let hidden = showHidden
        task = Task { [weak self, loader] in
            do {
                let result: [FileItem]
                if let streaming = loader as? any DirectoryStreaming {
                    var sortedPrefix: [FileItem] = []
                    var pending: [FileItem] = []
                    var prefixOrder = self?.sortOrder
                    var nextPreviewCount = 1
                    for try await batch in streaming.batches(of: url, showHidden: hidden) {
                        guard let self, self.generation == request, !Task.isCancelled else { return }
                        pending.append(contentsOf: batch)
                        let count = sortedPrefix.count + pending.count
                        if previousItems.isEmpty && count >= nextPreviewCount {
                            nextPreviewCount = count * 2
                            let order = self.sortOrder
                            sortedPrefix = order == prefixOrder
                                ? order.mergeSorted(sortedPrefix, order.sorted(pending))
                                : order.sorted(sortedPrefix + pending)
                            prefixOrder = order
                            pending.removeAll(keepingCapacity: true)
                            self.folderItems = sortedPrefix
                            self.onChange?()
                        }
                    }
                    guard let self, self.generation == request, !Task.isCancelled else { return }
                    let order = self.sortOrder
                    result = order == prefixOrder
                        ? order.mergeSorted(sortedPrefix, order.sorted(pending))
                        : order.sorted(sortedPrefix + pending)
                } else {
                    let items = try await loader.contents(of: url, showHidden: hidden)
                    guard let self, self.generation == request, !Task.isCancelled else { return }
                    result = self.sortOrder.sorted(items)
                }
                let items = result
                guard let self, self.generation == request, !Task.isCancelled else { return }
                let selection = SelectionRestoration.restore(self.history.current.selection, from: previousItems, to: items)
                self.history.save(selection: selection, scrollOffset: self.history.current.scrollOffset)
                self.loadedLocation = url
                self.folderItems = items; self.isLoading = false; self.onChange?()
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.folderItems = []; self.error = error.localizedDescription
                self.failure = DirectoryFailure(error)
                self.isLoading = false; self.onChange?()
            }
        }
    }
    public func sort(_ order: SortOrder) {
        sortOrder = order; folderItems = order.sorted(folderItems); onChange?()
    }
    public func applySharedFolderLayout(_ layout: SharedFolderLayout) {
        guard viewMode != layout.mode || grouping != layout.grouping || sortOrder != layout.sort else { return }
        viewMode = layout.mode
        grouping = layout.grouping
        if sortOrder != layout.sort {
            sortOrder = layout.sort
            folderItems = layout.sort.sorted(folderItems)
        }
        onChange?()
    }
    public func applyDirectorySizes(_ sizes: [URL: Int64], at expectedLocation: URL) {
        guard location?.standardizedFileURL == expectedLocation.standardizedFileURL, !isLoading else { return }
        var changed = false
        let updated = folderItems.map { item -> FileItem in
            guard item.isBrowsable, let size = sizes[item.url.standardizedFileURL], item.size != size else { return item }
            changed = true; return item.replacingSize(size)
        }
        guard changed else { return }
        folderItems = sortOrder.sorted(updated); onChange?()
    }
    public func setViewMode(_ mode: BrowserViewMode) {
        guard viewMode != mode else { return }
        viewMode = mode
        onChange?()
    }
    public func setGrouping(_ options: FileGroupOptions) {
        guard grouping != options else { return }
        grouping = options
        onChange?()
    }
}
