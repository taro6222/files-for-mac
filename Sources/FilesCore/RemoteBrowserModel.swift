import Foundation

public enum RemoteBrowserError: Error, Sendable, Equatable {
    case invalidPath
}

@MainActor
public final class RemoteBrowserModel {
    public typealias Loader = @Sendable (_ absolutePath: String) async throws -> [RemoteDirectoryEntry]

    public private(set) var path: String
    public private(set) var entries: [RemoteDirectoryEntry] = []
    public private(set) var isLoading = false
    public private(set) var wasCancelled = false
    public private(set) var error: String?
    public var onChange: (() -> Void)?

    private let loader: Loader
    private var history: [String]
    private var historyIndex = 0
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(path: String = "/", loader: @escaping Loader) throws {
        let normalized = try Self.normalized(path)
        self.path = normalized; self.history = [normalized]; self.loader = loader
    }

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex + 1 < history.count }
    public var canGoUp: Bool { path != "/" }

    public func start() { reload() }
    public func navigate(to path: String) throws {
        let normalized = try Self.normalized(path)
        guard normalized != self.path else { reload(); return }
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(normalized); historyIndex += 1; self.path = normalized; reload()
    }
    public func open(_ entry: RemoteDirectoryEntry) throws {
        guard entry.isDirectory else { return }
        try navigate(to: entry.remotePath)
    }
    public func goBack() { guard canGoBack else { return }; historyIndex -= 1; path = history[historyIndex]; reload() }
    public func goForward() { guard canGoForward else { return }; historyIndex += 1; path = history[historyIndex]; reload() }
    public func goUp() {
        guard canGoUp else { return }
        let parent = (path as NSString).deletingLastPathComponent
        try? navigate(to: parent.isEmpty ? "/" : parent)
    }
    public func cancel() {
        guard isLoading else { return }
        generation += 1; task?.cancel(); task = nil; isLoading = false; wasCancelled = true; onChange?()
    }
    public func reload() {
        generation += 1; let request = generation
        task?.cancel(); entries = []; error = nil; wasCancelled = false; isLoading = true; onChange?()
        let requestedPath = path
        task = Task { [weak self, loader] in
            do {
                let loaded = try await loader(requestedPath)
                guard let self, self.generation == request, self.path == requestedPath, !Task.isCancelled else { return }
                self.entries = loaded.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.isLoading = false; self.onChange?()
            } catch is CancellationError {
                guard let self, self.generation == request else { return }
                self.isLoading = false; self.wasCancelled = true; self.onChange?()
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.entries = []; self.error = error.localizedDescription; self.isLoading = false; self.onChange?()
            }
        }
    }

    public nonisolated static func normalized(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteBrowserError.invalidPath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains("..") else { throw RemoteBrowserError.invalidPath }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}
