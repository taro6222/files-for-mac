import CryptoKit
import Darwin
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
    case unsupportedFileType
}

public enum FileHashAlgorithm: String, CaseIterable, Sendable {
    case crc32 = "CRC32"
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha384 = "SHA-384"
    case sha512 = "SHA-512"

    public var hexLength: Int {
        switch self {
        case .crc32: 8
        case .md5: 32
        case .sha1: 40
        case .sha256: 64
        case .sha384: 96
        case .sha512: 128
        }
    }
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
        try await hash(url, algorithm: .sha256, progress: progress)
    }

    public func hash(_ url: URL, algorithm: FileHashAlgorithm, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let type = metadata.st_mode & S_IFMT
            if type == S_IFDIR { throw FileHashError.directoryUnsupported }
            guard type == S_IFREG else { throw FileHashError.unsupportedFileType }
            switch algorithm {
            case .crc32:
                var checksum = UInt32.max
                try Self.readHashChunks(handle, progress: progress) { data in
                    for byte in data {
                        checksum = Self.crcTable[Int((checksum ^ UInt32(byte)) & 0xff)] ^ (checksum >> 8)
                    }
                }
                return String(format: "%08x", checksum ^ UInt32.max)
            case .md5: return try Self.cryptoDigest(Insecure.MD5(), handle: handle, progress: progress)
            case .sha1: return try Self.cryptoDigest(Insecure.SHA1(), handle: handle, progress: progress)
            case .sha256: return try Self.cryptoDigest(SHA256(), handle: handle, progress: progress)
            case .sha384: return try Self.cryptoDigest(SHA384(), handle: handle, progress: progress)
            case .sha512: return try Self.cryptoDigest(SHA512(), handle: handle, progress: progress)
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            let polynomial: UInt32 = value.isMultiple(of: 2) ? 0 : 0xedb88320
            value = (value >> 1) ^ polynomial
        }
        return value
    }

    private static func cryptoDigest<H: HashFunction>(_ initial: H, handle: FileHandle, progress: (@Sendable (Int64) -> Void)?) throws -> String {
        var hasher = initial
        try readHashChunks(handle, progress: progress) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readHashChunks(_ handle: FileHandle, progress: (@Sendable (Int64) -> Void)?, consume: (Data) -> Void) throws {
        var processed: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return }
            consume(data)
            processed += Int64(data.count)
            progress?(processed)
        }
    }
}
