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
    public private(set) var items: [FileItem] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    public private(set) var failure: DirectoryFailure?
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
        task?.cancel(); error = nil; failure = nil
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
                self.failure = DirectoryFailure(error)
                self.isLoading = false; self.onChange?()
            }
        }
    }
    public func sort(_ order: SortOrder) {
        sortOrder = order; items = order.sorted(items); onChange?()
    }
}
