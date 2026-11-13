import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct FileProperties: Sendable, Equatable {
    public let url: URL
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let logicalSize: Int64?
    public let allocatedSize: Int64?
    public let created: Date?
    public let modified: Date?
    public let added: Date?
    public let owner: String?
    public let group: String?
    public let posixPermissions: Int?
    public let typeIdentifier: String?
    public let tags: [String]
    public let volumeName: String?
    public let isReadable: Bool
    public let isWritable: Bool
    public let isExecutable: Bool
}

public enum FileHashError: Error, Equatable {
    case directoryUnsupported
}

public struct FilePropertiesInspector: Sendable {
    public init() {}
    public func inspect(_ url: URL) async throws -> FileProperties {
        try await Task.detached(priority: .userInitiated) {
            let standardized = url.standardizedFileURL
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey,
                .addedToDirectoryDateKey, .contentTypeKey, .tagNamesKey, .volumeNameKey,
                .isReadableKey, .isWritableKey, .isExecutableKey]
            let values = try standardized.resourceValues(forKeys: keys)
            let attributes = try FileManager.default.attributesOfItem(atPath: standardized.path)
            return FileProperties(url: standardized, isDirectory: values.isDirectory ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false,
                logicalSize: values.fileSize.map(Int64.init), allocatedSize: values.totalFileAllocatedSize.map(Int64.init),
                created: values.creationDate, modified: values.contentModificationDate, added: values.addedToDirectoryDate,
                owner: attributes[.ownerAccountName] as? String, group: attributes[.groupOwnerAccountName] as? String,
                posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
                typeIdentifier: values.contentType?.identifier, tags: values.tagNames ?? [], volumeName: values.volumeName,
                isReadable: values.isReadable ?? false, isWritable: values.isWritable ?? false,
                isExecutable: values.isExecutable ?? false)
        }.value
    }

    public func sha256(_ url: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        try await Task.detached(priority: .utility) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { throw FileHashError.directoryUnsupported }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var hash = SHA256(), processed: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
                hash.update(data: data); processed += Int64(data.count); progress?(processed)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
