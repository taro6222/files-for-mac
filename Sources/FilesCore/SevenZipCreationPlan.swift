import Foundation
import Darwin

/// Snapshots are passed to the SDK worker; it opens every component without following links.
struct SevenZipCreationPlan: Sendable {
    struct Item: Sendable {
        let url: URL, path: String
        let snapshot: stat
        var directory: Bool { snapshot.st_mode & S_IFMT == S_IFDIR }
        var size: Int64 { directory ? 0 : snapshot.st_size }
        var request: [String: Any] {
            ["source": url.path, "path": path, "device": String(snapshot.st_dev), "inode": String(snapshot.st_ino),
             "size": size, "mode": UInt32(snapshot.st_mode), "directory": directory ? 1 : 0,
             "modifiedSeconds": snapshot.st_mtimespec.tv_sec, "modifiedNanos": snapshot.st_mtimespec.tv_nsec,
             "changedSeconds": snapshot.st_ctimespec.tv_sec, "changedNanos": snapshot.st_ctimespec.tv_nsec]
        }
        func verify() throws {
            var current = stat()
            guard lstat(url.path, &current) == 0, current.st_dev == snapshot.st_dev, current.st_ino == snapshot.st_ino,
                  current.st_mode == snapshot.st_mode, directory || current.st_size == snapshot.st_size,
                  current.st_mtimespec.tv_sec == snapshot.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == snapshot.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == snapshot.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == snapshot.st_ctimespec.tv_nsec else {
                throw ZipArchiveError.invalidSource(url.path)
            }
        }
    }
    let items: [Item]
    let totalBytes: Int64
    init(sources: [URL], destination: URL, check: () throws -> Void) throws {
        guard !sources.isEmpty, destination.isFileURL, ArchiveFormat.detect(destination) == .sevenZip,
              sources.allSatisfy(\.isFileURL), Set(sources.map(\.standardizedFileURL)).count == sources.count else {
            throw SevenZipWorkerError.invalidConfiguration
        }
        let destination = try sevenZipCanonicalDirectory(destination.deletingLastPathComponent()).appendingPathComponent(destination.lastPathComponent)
        var result: [Item] = []
        func append(_ url: URL, path: String) throws {
            try check()
            var snapshot = stat()
            guard lstat(url.path, &snapshot) == 0,
                  [S_IFREG, S_IFDIR].contains(snapshot.st_mode & S_IFMT), snapshot.st_size >= 0 else {
                throw ZipArchiveError.invalidSource(url.path)
            }
            guard result.count < 100_000 else { throw ArchiveValidationError.tooManyEntries }
            result.append(Item(url: url, path: path, snapshot: snapshot))
        }
        for original in sources {
            let source = try sevenZipCanonicalDirectory(original.standardizedFileURL.deletingLastPathComponent()).appendingPathComponent(original.lastPathComponent)
            try append(source, path: source.lastPathComponent)
            if result.last!.directory {
                guard !destination.path.hasPrefix(source.path + "/") else { throw ZipArchiveError.invalidSource(destination.path) }
                var enumerationFailed = false
                guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
                    errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw ZipArchiveError.invalidSource(source.path) }
                while let child = enumerator.nextObject() as? URL {
                    let relative = child.pathComponents.suffix(enumerator.level).joined(separator: "/")
                    try append(child, path: source.lastPathComponent + "/" + relative)
                }
                guard !enumerationFailed else { throw ZipArchiveError.invalidSource(source.path) }
            }
        }
        _ = try ArchiveExtractionValidator.validate(result.map {
            .init(path: $0.path, kind: $0.directory ? .directory : .regularFile, uncompressedSize: $0.size)
        }, limits: .init())
        items = result; totalBytes = result.reduce(0) { $0 + $1.size }
    }
    func verify(check: () throws -> Void) throws { for item in items { try check(); try item.verify() } }
}

// Foundation intentionally preserves some macOS aliases (including /var). The worker's
// component-by-component O_NOFOLLOW walk needs the actual filesystem path instead.
func sevenZipCanonicalDirectory(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw ZipArchiveError.destinationNotDirectory }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
