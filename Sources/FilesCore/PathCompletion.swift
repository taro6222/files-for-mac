import Foundation

public struct PathCompletion: Sendable {
    private let loader: any DirectoryLoading
    public init(loader: any DirectoryLoading = LocalFileSystem()) { self.loader = loader }
    public func suggestions(for input: String, relativeTo base: URL, showHidden: Bool) async throws -> [String] {
        guard !input.isEmpty else { return [] }
        let expanded = (input as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)
        let trailingSlash = input.hasSuffix("/") || input == "~"
        let parent = trailingSlash ? url : url.deletingLastPathComponent()
        let prefix = trailingSlash ? "" : url.lastPathComponent
        let entries = try await loader.contents(of: parent.standardizedFileURL, showHidden: showHidden || prefix.hasPrefix("."))
        try Task.checkCancellation()
        return entries.filter { $0.isBrowsable && (prefix.isEmpty || $0.name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(30).map { $0.url.path + "/" }
    }
}
