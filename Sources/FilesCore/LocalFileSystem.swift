import Foundation

public protocol DirectoryLoading: Sendable {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem]
}

public struct LocalFileSystem: DirectoryLoading {
    public init() {}
    public func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        let worker = Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: Array(keys), options: showHidden ? [] : [.skipsHiddenFiles])
            var result: [FileItem] = []
            result.reserveCapacity(urls.count)
            for child in urls {
                try Task.checkCancellation()
                // A concurrent deletion is omitted; other metadata failures remain visible.
                do {
                    let v = try child.resourceValues(forKeys: keys)
                    result.append(FileItem(url: child, name: child.lastPathComponent,
                        isDirectory: v.isDirectory ?? false, isPackage: v.isPackage ?? false,
                        isSymbolicLink: v.isSymbolicLink ?? false, isHidden: v.isHidden ?? false,
                        size: v.fileSize.map(Int64.init), modified: v.contentModificationDate,
                        kind: v.isDirectory == true ? "Folder" : (child.pathExtension.isEmpty ? "File" : child.pathExtension.uppercased())))
                } catch {
                    let e = error as NSError
                    if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { continue }
                    result.append(FileItem(url: child, name: child.lastPathComponent, isDirectory: false,
                        kind: "—"))
                }
            }
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
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
