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

public struct FilePermissionSnapshot: Sendable {
    public let mode: Int
    public let accessControlList: String?
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    fileprivate let birthSeconds: Int
    fileprivate let birthNanoseconds: Int
}

public enum FilePermissionError: Error, Equatable {
    case unsupportedFileType
    case changedItem
    case changedPermissions
    case invalidMode
    case modeNotApplied
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

    public func permissions(_ url: URL) async throws -> FilePermissionSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.withPermissionDescriptor(url, Self.permissionSnapshot)
        }.value
    }

    public func setPermissions(_ mode: Int, at url: URL, expected: FilePermissionSnapshot) async throws -> FilePermissionSnapshot {
        guard (0...0o777).contains(mode) else { throw FilePermissionError.invalidMode }
        return try await Task.detached(priority: .utility) {
            try Self.withPermissionDescriptor(url) { descriptor in
                let current = try Self.permissionSnapshot(descriptor)
                guard current.device == expected.device, current.inode == expected.inode,
                      current.birthSeconds == expected.birthSeconds,
                      current.birthNanoseconds == expected.birthNanoseconds else {
                    throw FilePermissionError.changedItem
                }
                guard current.mode == expected.mode, current.accessControlList == expected.accessControlList else {
                    throw FilePermissionError.changedPermissions
                }
                let requested = (current.mode & 0o7000) | mode
                if current.mode != requested {
                    guard fchmod(descriptor, mode_t(requested)) == 0 else { throw Self.permissionPOSIXError() }
                }
                let updated = try Self.permissionSnapshot(descriptor)
                guard updated.mode == requested else { throw FilePermissionError.modeNotApplied }
                return updated
            }
        }.value
    }

    private static func withPermissionDescriptor<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw permissionPOSIXError() }
        defer { close(descriptor) }
        return try body(descriptor)
    }

    private static func permissionSnapshot(_ descriptor: Int32) throws -> FilePermissionSnapshot {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw permissionPOSIXError() }
        let type = metadata.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw FilePermissionError.unsupportedFileType }
        return FilePermissionSnapshot(
            mode: Int(metadata.st_mode & 0o7777), accessControlList: try permissionACL(descriptor),
            device: metadata.st_dev, inode: metadata.st_ino,
            birthSeconds: metadata.st_birthtimespec.tv_sec, birthNanoseconds: metadata.st_birthtimespec.tv_nsec
        )
    }

    private static func permissionACL(_ descriptor: Int32) throws -> String? {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return nil }
            throw permissionPOSIXError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw permissionPOSIXError() }
        defer { acl_free(text) }
        let entries = String(cString: text).split(separator: "\n").dropFirst()
        return entries.isEmpty ? nil : entries.joined(separator: "\n")
    }

    private static func permissionPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
