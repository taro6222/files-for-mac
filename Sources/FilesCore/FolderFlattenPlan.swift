import Foundation
import Darwin

public struct FolderFlattenPlan: Sendable {
    public let destination: URL
    public var sources: [URL] { entries.map(\.url) }
    let entries: [ShelfEntry]
    let root: ShelfEntry

    static func canonicalPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }
    static func isDirectoryWithoutLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    public static func make(for folder: URL) async throws -> Self {
        try await Task.detached(priority: .utility) {
            let folder = URL(fileURLWithPath: folder.standardizedFileURL.path, isDirectory: true)
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            guard isDirectoryWithoutLink(folder),
                  values.isPackage != true, let path = canonicalPath(folder) else {
                throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: folder.path])
            }
            let destination = URL(fileURLWithPath: path, isDirectory: true)
            guard let root = ShelfEntry(destination) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: destination.path]) }
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
            var directories = [destination]
            var entries: [ShelfEntry] = []
            while let directory = directories.popLast() {
                guard isDirectoryWithoutLink(directory),
                      let current = canonicalPath(directory),
                      current == path || current.hasPrefix(path + "/") else {
                    throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: directory.path])
                }
                let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for listed in children {
                    let child = directory.appendingPathComponent(listed.lastPathComponent)
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isSymbolicLink != true, values.isDirectory == true, values.isPackage != true {
                        directories.append(child)
                    } else if directory.path != destination.path {
                        guard let entry = ShelfEntry(child) else {
                            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: child.path])
                        }
                        entries.append(entry)
                    }
                }
            }
            guard root.isCurrent else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.url.path]) }
            return Self(destination: destination, entries: entries.sorted { $0.url.path < $1.url.path }, root: root)
        }.value
    }
}
