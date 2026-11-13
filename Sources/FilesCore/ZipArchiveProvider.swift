import Foundation
import CLibArchive

public enum ZipArchiveError: Error, Sendable, Equatable {
    case cannotOpen(String)
    case invalidEntry(String)
    case readFailed(String)
    case destinationNotDirectory
    case destinationConflict(String)
    case publishFailed(String)
    case invalidSource(String)
}

public struct ArchiveExtractionReport: Sendable, Equatable {
    public let entries: Int
    public let extractedBytes: Int64
    public let publishedURLs: [URL]
}

public enum ArchiveProgressPhase: String, Sendable, Equatable { case planning, reading, writing, publishing }

public struct ArchiveProgress: Sendable, Equatable {
    public let phase: ArchiveProgressPhase
    public let completedEntries: Int
    public let totalEntries: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentPath: String?

    public init(phase: ArchiveProgressPhase, completedEntries: Int, totalEntries: Int, completedBytes: Int64, totalBytes: Int64, currentPath: String?) {
        self.phase = phase; self.completedEntries = completedEntries; self.totalEntries = totalEntries
        self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.currentPath = currentPath
    }
}

public typealias ArchiveProgressHandler = @Sendable (ArchiveProgress) -> Void

public struct ZipArchiveProvider: Sendable {
    public init() {}

    public func entries(at archiveURL: URL) throws -> [ArchiveEntryDescriptor] {
        try withReader(archiveURL) { reader in
            var result: [ArchiveEntryDescriptor] = [], entry: OpaquePointer?
            while true {
                let status = archive_read_next_header(reader, &entry)
                if status == FILES_ARCHIVE_EOF { break }
                guard status == FILES_ARCHIVE_OK, let entry else { throw ZipArchiveError.readFailed(errorText(reader)) }
                result.append(try descriptor(entry))
                archive_read_data_skip(reader)
            }
            return result
        }
    }

    public func extract(_ archiveURL: URL, to destination: URL, limits: ArchiveExtractionLimits = .init(), progress: ArchiveProgressHandler? = nil) async throws -> ArchiveExtractionReport {
        try await Task.detached(priority: .userInitiated) { try extractSynchronously(archiveURL, to: destination, limits: limits, progress: progress) }.value
    }

    public func create(from sources: [URL], at archiveURL: URL, progress: ArchiveProgressHandler? = nil) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try createSynchronously(from: sources, at: archiveURL, progress: progress) }.value
    }
}

private struct ZipSourceEntry {
    let url: URL, archivePath: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let permissions: Int
}

private func createSynchronously(from sourceURLs: [URL], at archiveURL: URL, progress: ArchiveProgressHandler?) throws -> URL {
    let fm = FileManager.default, sources = sourceURLs.map(\.standardizedFileURL)
    guard let format = ArchiveFormat.detect(archiveURL), ArchiveCapabilityMatrix.capabilities(for: format).create,
          !sources.isEmpty, Set(sources).count == sources.count, !fm.fileExists(atPath: archiveURL.path) else { throw ZipArchiveError.invalidSource(archiveURL.path) }
    var planned: [ZipSourceEntry] = [], descriptors: [ArchiveEntryDescriptor] = []
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    func append(_ url: URL, path: String) throws {
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ZipArchiveError.invalidSource(url.path) }
        let directory = values.isDirectory == true, size = directory ? 0 : Int64(values.fileSize ?? 0)
        let archivePath = directory ? path + "/" : path
        let permissions = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? (directory ? 0o755 : 0o644)
        planned.append(ZipSourceEntry(url: url, archivePath: archivePath, isDirectory: directory, size: size,
                                      modified: values.contentModificationDate, permissions: permissions))
        descriptors.append(ArchiveEntryDescriptor(path: archivePath, kind: directory ? .directory : .regularFile, uncompressedSize: size))
    }
    for source in sources {
        try append(source, path: source.lastPathComponent)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in false }) else { throw ZipArchiveError.invalidSource(source.path) }
            while let child = enumerator.nextObject() as? URL {
                try Task<Never, Never>.checkCancellation()
                let relative = child.pathComponents.suffix(enumerator.level).joined(separator: "/")
                try append(child, path: source.lastPathComponent + "/" + relative)
            }
        }
    }
    _ = try ArchiveExtractionValidator.validate(descriptors, limits: .init())
    let totalBytes = planned.reduce(Int64(0)) { $0 + $1.size }
    var completedBytes: Int64 = 0, completedEntries = 0
    progress?(ArchiveProgress(phase: .writing, completedEntries: 0, totalEntries: planned.count, completedBytes: 0, totalBytes: totalBytes, currentPath: nil))
    let parent = archiveURL.deletingLastPathComponent(); try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(".files-create-\(UUID().uuidString).\(format.rawValue)")
    defer { try? fm.removeItem(at: staging) }
    try withWriter(staging, format: format) { writer in
        for item in planned {
            try Task<Never, Never>.checkCancellation()
            guard let entry = archive_entry_new() else { throw ZipArchiveError.readFailed("cannot allocate archive entry") }
            defer { archive_entry_free(entry) }
            item.archivePath.withCString { archive_entry_set_pathname_utf8(entry, $0) }
            archive_entry_set_filetype(entry, UInt32(item.isDirectory ? FILES_AE_IFDIR : FILES_AE_IFREG))
            archive_entry_set_perm(entry, mode_t(item.permissions & 0o777)); archive_entry_set_size(entry, item.size)
            if let modified = item.modified { archive_entry_set_mtime(entry, time_t(modified.timeIntervalSince1970), 0) }
            guard archive_write_header(writer, entry) == FILES_ARCHIVE_OK else { throw ZipArchiveError.readFailed(errorText(writer)) }
            if item.isDirectory {
                completedEntries += 1
                progress?(ArchiveProgress(phase: .writing, completedEntries: completedEntries, totalEntries: planned.count, completedBytes: completedBytes, totalBytes: totalBytes, currentPath: item.archivePath))
                continue
            }
            let handle = try FileHandle(forReadingFrom: item.url); defer { try? handle.close() }
            var written: Int64 = 0
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                try Task<Never, Never>.checkCancellation()
                let count = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard count == data.count else { throw ZipArchiveError.readFailed(errorText(writer)) }
                written += Int64(count); completedBytes += Int64(count)
                progress?(ArchiveProgress(phase: .writing, completedEntries: completedEntries, totalEntries: planned.count, completedBytes: completedBytes, totalBytes: totalBytes, currentPath: item.archivePath))
            }
            guard written == item.size else { throw ZipArchiveError.invalidSource(item.url.path) }
            let current = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(current.fileSize ?? -1) == item.size, current.contentModificationDate == item.modified else { throw ZipArchiveError.invalidSource(item.url.path) }
            completedEntries += 1
            progress?(ArchiveProgress(phase: .writing, completedEntries: completedEntries, totalEntries: planned.count, completedBytes: completedBytes, totalBytes: totalBytes, currentPath: item.archivePath))
        }
    }
    guard !fm.fileExists(atPath: archiveURL.path) else { throw ZipArchiveError.destinationConflict(archiveURL.lastPathComponent) }
    progress?(ArchiveProgress(phase: .publishing, completedEntries: completedEntries, totalEntries: planned.count, completedBytes: completedBytes, totalBytes: totalBytes, currentPath: archiveURL.lastPathComponent))
    try fm.moveItem(at: staging, to: archiveURL)
    return archiveURL
}

private func extractSynchronously(_ archiveURL: URL, to destination: URL, limits: ArchiveExtractionLimits, progress: ArchiveProgressHandler?) throws -> ArchiveExtractionReport {
    let fm = FileManager.default
    guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ZipArchiveError.destinationNotDirectory }
    let provider = ZipArchiveProvider(), descriptors = try provider.entries(at: archiveURL)
    let validated = try ArchiveExtractionValidator.validate(descriptors, limits: limits)
    let topLevel = Set(validated.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) }).sorted()
    for name in topLevel where fm.fileExists(atPath: destination.appendingPathComponent(name).path) { throw ZipArchiveError.destinationConflict(name) }
    let staging = destination.appendingPathComponent(".files-extract-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    var actualTotal: Int64 = 0
    let totalBytes = validated.reduce(Int64(0)) { $0 + $1.uncompressedSize }
    progress?(ArchiveProgress(phase: .reading, completedEntries: 0, totalEntries: validated.count, completedBytes: 0, totalBytes: totalBytes, currentPath: nil))
    try withReader(archiveURL) { reader in
        var entry: OpaquePointer?, index = 0
        while true {
            try Task<Never, Never>.checkCancellation()
            let status = archive_read_next_header(reader, &entry)
            if status == FILES_ARCHIVE_EOF { break }
            guard status == FILES_ARCHIVE_OK, entry != nil, validated.indices.contains(index) else { throw ZipArchiveError.readFailed(errorText(reader)) }
            let item = validated[index], output = staging.appendingPathComponent(item.relativePath)
            switch item.kind {
            case .directory:
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
            case .regularFile:
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: output.path, contents: nil) else { throw ZipArchiveError.readFailed(item.relativePath) }
                let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
                var written: Int64 = 0, buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try Task<Never, Never>.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    guard count > 0 else { throw ZipArchiveError.readFailed(errorText(reader)) }
                    written += Int64(count); actualTotal += Int64(count)
                    guard written <= item.uncompressedSize, written <= limits.maximumSingleFileBytes, actualTotal <= limits.maximumTotalBytes else {
                        throw ArchiveValidationError.totalSizeLimit
                    }
                    try handle.write(contentsOf: Data(buffer[0..<Int(count)]))
                    progress?(ArchiveProgress(phase: .reading, completedEntries: index, totalEntries: validated.count, completedBytes: actualTotal, totalBytes: totalBytes, currentPath: item.relativePath))
                }
                guard written == item.uncompressedSize else { throw ZipArchiveError.readFailed(item.relativePath) }
            default: throw ZipArchiveError.invalidEntry(item.relativePath)
            }
            index += 1
            progress?(ArchiveProgress(phase: .reading, completedEntries: index, totalEntries: validated.count, completedBytes: actualTotal, totalBytes: totalBytes, currentPath: item.relativePath))
        }
        guard index == validated.count else { throw ZipArchiveError.readFailed("entry count changed") }
    }
    var published: [URL] = []
    progress?(ArchiveProgress(phase: .publishing, completedEntries: validated.count, totalEntries: validated.count, completedBytes: actualTotal, totalBytes: totalBytes, currentPath: nil))
    do {
        for name in topLevel {
            let source = staging.appendingPathComponent(name), target = destination.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { throw ZipArchiveError.destinationConflict(name) }
            try fm.moveItem(at: source, to: target); published.append(target)
        }
    } catch {
        for target in published.reversed() {
            let rollback = staging.appendingPathComponent(target.lastPathComponent)
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: rollback.path) { try? fm.moveItem(at: target, to: rollback) }
        }
        throw ZipArchiveError.publishFailed(error.localizedDescription)
    }
    return ArchiveExtractionReport(entries: validated.count, extractedBytes: actualTotal, publishedURLs: published)
}

private func withReader<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    guard let reader = archive_read_new() else { throw ZipArchiveError.cannotOpen(url.path) }
    defer { archive_read_close(reader); archive_read_free(reader) }
    archive_read_support_filter_all(reader)
    switch ArchiveFormat.detect(url) {
    case .zip: archive_read_support_format_zip(reader)
    case .sevenZip: archive_read_support_format_7zip(reader)
    case .rar:
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
    case nil: throw ZipArchiveError.cannotOpen("unsupported archive format")
    }
    let status = url.withUnsafeFileSystemRepresentation { path in archive_read_open_filename(reader, path, 64 * 1024) }
    guard status == FILES_ARCHIVE_OK else { throw ZipArchiveError.cannotOpen(errorText(reader)) }
    return try body(reader)
}

private func withWriter<T>(_ url: URL, format: ArchiveFormat, _ body: (OpaquePointer) throws -> T) throws -> T {
    guard let writer = archive_write_new() else { throw ZipArchiveError.cannotOpen(url.path) }
    defer { archive_write_close(writer); archive_write_free(writer) }
    let formatStatus = format == .zip ? archive_write_set_format_zip(writer) : archive_write_set_format_7zip(writer)
    guard formatStatus == FILES_ARCHIVE_OK,
          archive_write_add_filter_none(writer) == FILES_ARCHIVE_OK else { throw ZipArchiveError.cannotOpen(errorText(writer)) }
    let status = url.withUnsafeFileSystemRepresentation { path in archive_write_open_filename(writer, path) }
    guard status == FILES_ARCHIVE_OK else { throw ZipArchiveError.cannotOpen(errorText(writer)) }
    return try body(writer)
}

private func descriptor(_ entry: OpaquePointer) throws -> ArchiveEntryDescriptor {
    guard let pathPointer = archive_entry_pathname_utf8(entry) else { throw ZipArchiveError.invalidEntry("missing UTF-8 path") }
    let path = String(cString: pathPointer), size = archive_entry_size(entry)
    let kind: ArchiveEntryKind
    if archive_entry_symlink_utf8(entry) != nil { kind = .symbolicLink }
    else if archive_entry_hardlink_utf8(entry) != nil { kind = .hardLink }
    else {
        switch Int32(archive_entry_filetype(entry)) {
        case FILES_AE_IFREG: kind = .regularFile
        case FILES_AE_IFDIR: kind = .directory
        case FILES_AE_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
    }
    return ArchiveEntryDescriptor(path: path, kind: kind, uncompressedSize: size)
}

private func errorText(_ reader: OpaquePointer) -> String {
    archive_error_string(reader).map(String.init(cString:)) ?? "libarchive error"
}
