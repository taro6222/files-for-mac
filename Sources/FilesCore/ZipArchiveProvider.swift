import Foundation
import CLibArchive

public enum ZipArchiveError: Error, Sendable, Equatable {
    case cannotOpen(String)
    case invalidEntry(String)
    case readFailed(String)
    case destinationNotDirectory
    case destinationConflict(String)
    case publishFailed(String)
}

public struct ArchiveExtractionReport: Sendable, Equatable {
    public let entries: Int
    public let extractedBytes: Int64
    public let publishedURLs: [URL]
}

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

    public func extract(_ archiveURL: URL, to destination: URL, limits: ArchiveExtractionLimits = .init()) async throws -> ArchiveExtractionReport {
        try await Task.detached(priority: .userInitiated) { try extractSynchronously(archiveURL, to: destination, limits: limits) }.value
    }
}

private func extractSynchronously(_ archiveURL: URL, to destination: URL, limits: ArchiveExtractionLimits) throws -> ArchiveExtractionReport {
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
                }
                guard written == item.uncompressedSize else { throw ZipArchiveError.readFailed(item.relativePath) }
            default: throw ZipArchiveError.invalidEntry(item.relativePath)
            }
            index += 1
        }
        guard index == validated.count else { throw ZipArchiveError.readFailed("entry count changed") }
    }
    var published: [URL] = []
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
    archive_read_support_filter_all(reader); archive_read_support_format_zip(reader)
    let status = url.withUnsafeFileSystemRepresentation { path in archive_read_open_filename(reader, path, 64 * 1024) }
    guard status == FILES_ARCHIVE_OK else { throw ZipArchiveError.cannotOpen(errorText(reader)) }
    return try body(reader)
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
