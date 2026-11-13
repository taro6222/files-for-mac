import Foundation

public enum ArchiveEntryKind: String, Sendable, Equatable { case regularFile, directory, symbolicLink, hardLink, other }

public struct ArchiveEntryDescriptor: Sendable, Equatable {
    public let path: String
    public let kind: ArchiveEntryKind
    public let uncompressedSize: Int64
    public init(path: String, kind: ArchiveEntryKind, uncompressedSize: Int64 = 0) {
        self.path = path; self.kind = kind; self.uncompressedSize = uncompressedSize
    }
}

public struct ArchiveExtractionLimits: Sendable, Equatable {
    public var maximumEntries: Int
    public var maximumTotalBytes: Int64
    public var maximumSingleFileBytes: Int64
    public init(maximumEntries: Int = 100_000, maximumTotalBytes: Int64 = 20_000_000_000,
                maximumSingleFileBytes: Int64 = 8_000_000_000) {
        self.maximumEntries = maximumEntries; self.maximumTotalBytes = maximumTotalBytes
        self.maximumSingleFileBytes = maximumSingleFileBytes
    }
}

public enum ArchiveValidationError: Error, Sendable, Equatable {
    case tooManyEntries
    case invalidPath(String)
    case duplicatePath(String)
    case unsupportedEntry(String)
    case invalidSize(String)
    case singleFileLimit(String)
    case totalSizeLimit
}

public struct ValidatedArchiveEntry: Sendable, Equatable {
    public let relativePath: String
    public let kind: ArchiveEntryKind
    public let uncompressedSize: Int64
}

public enum ArchiveExtractionPlacement: Sendable, Equatable { case here, smart, childFolder }

public func archiveNeedsChildFolder(_ entries: [ArchiveEntryDescriptor], placement: ArchiveExtractionPlacement) throws -> Bool {
    if placement == .childFolder { return true }
    if placement == .here { return false }
    let validated = try ArchiveExtractionValidator.validate(entries)
    let topLevel = Set(validated.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) })
    return topLevel.count > 1
}

public func archiveChildFolderBaseName(_ archiveURL: URL) -> String {
    let name = archiveURL.deletingPathExtension().lastPathComponent
    return name.isEmpty ? "Archive" : name
}

public enum ArchiveExtractionValidator {
    public static func validate(_ entries: [ArchiveEntryDescriptor], limits: ArchiveExtractionLimits = .init()) throws -> [ValidatedArchiveEntry] {
        guard entries.count <= limits.maximumEntries else { throw ArchiveValidationError.tooManyEntries }
        var validated: [ValidatedArchiveEntry] = [], seen = Set<String>(), total: Int64 = 0
        validated.reserveCapacity(entries.count)
        for entry in entries {
            let path = try normalizedPath(entry.path, kind: entry.kind)
            guard entry.kind == .regularFile || entry.kind == .directory else { throw ArchiveValidationError.unsupportedEntry(path) }
            guard entry.uncompressedSize >= 0 else { throw ArchiveValidationError.invalidSize(path) }
            if entry.kind == .regularFile && entry.uncompressedSize > limits.maximumSingleFileBytes { throw ArchiveValidationError.singleFileLimit(path) }
            let (nextTotal, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, nextTotal <= limits.maximumTotalBytes else { throw ArchiveValidationError.totalSizeLimit }
            total = nextTotal
            let identity = path.precomposedStringWithCanonicalMapping
            guard seen.insert(identity).inserted else { throw ArchiveValidationError.duplicatePath(path) }
            validated.append(ValidatedArchiveEntry(relativePath: path, kind: entry.kind, uncompressedSize: entry.uncompressedSize))
        }
        return validated
    }

    private static func normalizedPath(_ raw: String, kind: ArchiveEntryKind) throws -> String {
        guard !raw.isEmpty, !raw.contains("\0"), !raw.contains("\\"), !raw.hasPrefix("/"), !raw.hasPrefix("~") else {
            throw ArchiveValidationError.invalidPath(raw)
        }
        let trimmed = kind == .directory ? raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : raw
        guard !trimmed.isEmpty, !trimmed.hasSuffix("/"), trimmed.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
            throw ArchiveValidationError.invalidPath(raw)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ArchiveValidationError.invalidPath(raw) }
        return components.joined(separator: "/")
    }
}
