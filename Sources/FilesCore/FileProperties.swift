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
    public let isDirectory: Bool
    public let mode: Int
    public let ownerID: uid_t
    public let groupID: gid_t
    public let accessControlList: String?
    fileprivate let aclHeader: String
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
    case invalidAccessControlList
    case unknownACLAccount
    case groupNotApplied
    case ownerNotApplied
}

public struct FolderPermissionResult: Sendable {
    public fileprivate(set) var applied = 0
    public fileprivate(set) var skipped = 0
    public fileprivate(set) var failed = 0
    public fileprivate(set) var cancelled = false
}

public enum FileACLAccountKind: String, Sendable {
    case user, group

    private static let accountEnumerationLock = NSLock()

    public func accountNames(memberGroupsOnly: Bool = false) async -> [String] {
        await Task.detached(priority: .utility) {
            Self.accountEnumerationLock.withLock {
                var names = Set<String>()
                switch self {
                case .user:
                    setpwent()
                    defer { endpwent() }
                    while let entry = getpwent() {
                        if let name = entry.pointee.pw_name { names.insert(String(cString: name)) }
                    }
                case .group:
                    var memberships = Set<gid_t>()
                    if memberGroupsOnly && geteuid() != 0 {
                        memberships.insert(getegid())
                        let count = getgroups(0, nil)
                        if count > 0 {
                            var groups = [gid_t](repeating: 0, count: Int(count))
                            let loaded = getgroups(count, &groups)
                            if loaded > 0 { memberships.formUnion(groups.prefix(Int(loaded))) }
                        }
                    }
                    setgrent()
                    defer { endgrent() }
                    while let entry = getgrent() {
                        if memberships.isEmpty || memberships.contains(entry.pointee.gr_gid),
                           let name = entry.pointee.gr_name {
                            names.insert(String(cString: name))
                        }
                    }
                }
                return names.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        }.value
    }

    public func rule(for name: String, effect: FileACLEffect, access: FileACLAccess) async throws -> String {
        guard !name.isEmpty, !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw FilePermissionError.unknownACLAccount
        }
        return try await Task.detached(priority: .utility) {
            let entry = "\(rawValue)::\(name)::\(effect.rawValue):\(access.rawValue)"
            guard let acl = acl_from_text("!#acl 1\n" + entry + "\n") else {
                throw FilePermissionError.unknownACLAccount
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var length = 0
            guard let text = acl_to_text(acl, &length) else { throw FilePermissionError.unknownACLAccount }
            defer { acl_free(text) }
            guard let canonical = String(cString: text).split(separator: "\n").dropFirst().first,
                  let identifier = canonical.split(separator: ":", omittingEmptySubsequences: false).dropFirst().first,
                  let uuid = UUID(uuidString: String(identifier)), uuid.uuidString != "00000000-0000-0000-0000-000000000000" else {
                throw FilePermissionError.unknownACLAccount
            }
            return String(canonical)
        }.value
    }

}

public enum FileACLEffect: String, Sendable {
    case allow, deny
}

public enum FileACLAccess: String, Sendable {
    case read, write, execute
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
    public static var canChangeOwner: Bool { geteuid() == 0 }
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
                typeIdentifier: values.contentType?.identifier,
                tags: StoredFileTags.names(at: standardized, fallback: values.tagNames ?? []), volumeName: values.volumeName,
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
                try Self.checkPermissionSnapshot(current, expected: expected)
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

    public func setFolderPermissions(_ mode: Int, at url: URL, expected: FilePermissionSnapshot,
                                     cancellation: CopyCancellation? = nil) async throws -> FolderPermissionResult {
        guard (0...0o777).contains(mode) else { throw FilePermissionError.invalidMode }
        return try await Task.detached(priority: .utility) {
            try Self.withPermissionDescriptor(url) { descriptor in
                try Self.updateFolder(descriptor, expected: expected, cancellation: cancellation) { entry, metadata in
                    let requested = (metadata.st_mode & 0o7000) | mode_t(mode)
                    var updated = stat()
                    return fchmod(entry, requested) == 0 && fstat(entry, &updated) == 0
                        && updated.st_mode & 0o7777 == requested
                }
            }
        }.value
    }

    public func setFolderAccessControlList(_ entries: String, at url: URL, expected: FilePermissionSnapshot,
                                     cancellation: CopyCancellation? = nil) async throws -> FolderPermissionResult {
        try await Task.detached(priority: .utility) {
            let acl = try Self.parsePermissionACL(entries, header: expected.aclHeader)
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            let requested = try Self.permissionACLText(acl)
            return try Self.withPermissionDescriptor(url) { descriptor in
                try Self.updateFolder(descriptor, expected: expected, cancellation: cancellation) { entry, _ in
                    guard acl_set_fd_np(entry, acl, ACL_TYPE_EXTENDED) == 0,
                          let updated = try? Self.permissionACL(entry) else { return false }
                    return updated.entries == requested.entries
                        && (updated.header == requested.header || requested.entries == nil)
                }
            }
        }.value
    }

    private static func updateFolder(_ descriptor: Int32, expected: FilePermissionSnapshot,
                                     cancellation: CopyCancellation?,
                                     apply: (Int32, stat) -> Bool) throws -> FolderPermissionResult {
        try checkPermissionSnapshot(permissionSnapshot(descriptor), expected: expected)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw permissionPOSIXError() }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw FilePermissionError.unsupportedFileType }
        var result = FolderPermissionResult()
        visitPermissionTree(descriptor, metadata: metadata, cancellation: cancellation, result: &result, apply: apply)
        return result
    }

    private static func stopPermissionWalk(_ cancellation: CopyCancellation?, result: inout FolderPermissionResult) -> Bool {
        if cancellation?.isCancelled == true { result.cancelled = true }
        return result.cancelled
    }

    private static func visitPermissionTree(_ descriptor: Int32, metadata: stat, cancellation: CopyCancellation?,
                                            result: inout FolderPermissionResult,
                                            apply: (Int32, stat) -> Bool) {
        guard !stopPermissionWalk(cancellation, result: &result) else { return }
        let type = metadata.st_mode & S_IFMT
        if type == S_IFDIR {
            let directory = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { result.failed += 1; return }
            guard let stream = fdopendir(directory) else {
                close(directory)
                result.failed += 1
                return
            }
            defer { closedir(stream) }
            while !stopPermissionWalk(cancellation, result: &result) {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { result.failed += 1; return }
                    break
                }
                let inode = entry.pointee.d_ino
                withUnsafePointer(to: &entry.pointee.d_name) { name in
                    name.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { name in
                        if strcmp(name, ".") == 0 || strcmp(name, "..") == 0 { return }
                        let child = openat(directory, name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else {
                            if errno == ELOOP { result.skipped += 1 } else { result.failed += 1 }
                            return
                        }
                        defer { close(child) }
                        var childMetadata = stat()
                        guard fstat(child, &childMetadata) == 0 else { result.failed += 1; return }
                        guard childMetadata.st_dev == metadata.st_dev, childMetadata.st_ino == inode else {
                            result.skipped += 1
                            return
                        }
                        visitPermissionTree(child, metadata: childMetadata, cancellation: cancellation, result: &result, apply: apply)
                    }
                }
            }
        } else if type != S_IFREG || metadata.st_nlink > 1 {
            // A hard link can refer to the same file outside the selected tree.
            result.skipped += 1
            return
        }
        guard !stopPermissionWalk(cancellation, result: &result) else { return }
        if apply(descriptor, metadata) { result.applied += 1 } else { result.failed += 1 }
    }

    public func setGroup(_ name: String, at url: URL, expected: FilePermissionSnapshot) async throws -> FilePermissionSnapshot {
        try await Task.detached(priority: .utility) {
            let groupID = try Self.ownershipID(name, kind: .group)
            return try Self.withPermissionDescriptor(url) { descriptor in
                let current = try Self.permissionSnapshot(descriptor)
                try Self.checkPermissionSnapshot(current, expected: expected)
                if groupID != current.groupID {
                    guard fchown(descriptor, uid_t.max, groupID) == 0 else { throw Self.permissionPOSIXError() }
                }
                let updated = try Self.permissionSnapshot(descriptor)
                guard updated.groupID == groupID else { throw FilePermissionError.groupNotApplied }
                return updated
            }
        }.value
    }

    public func setOwner(_ name: String, at url: URL, expected: FilePermissionSnapshot) async throws -> FilePermissionSnapshot {
        try await Task.detached(priority: .utility) {
            let ownerID = try Self.ownershipID(name, kind: .user)
            return try Self.withPermissionDescriptor(url) { descriptor in
                let current = try Self.permissionSnapshot(descriptor)
                try Self.checkPermissionSnapshot(current, expected: expected)
                if ownerID != current.ownerID {
                    guard fchown(descriptor, ownerID, gid_t.max) == 0 else { throw Self.permissionPOSIXError() }
                }
                let updated = try Self.permissionSnapshot(descriptor)
                guard updated.ownerID == ownerID else { throw FilePermissionError.ownerNotApplied }
                return updated
            }
        }.value
    }

    public func setFolderOwnership(_ name: String, kind: FileACLAccountKind, at url: URL,
                                   expected: FilePermissionSnapshot, cancellation: CopyCancellation? = nil) async throws -> FolderPermissionResult {
        try await Task.detached(priority: .utility) {
            let id = try Self.ownershipID(name, kind: kind)
            return try Self.withPermissionDescriptor(url) { descriptor in
                try Self.updateFolder(descriptor, expected: expected, cancellation: cancellation) { entry, metadata in
                    if kind == .user ? metadata.st_uid == id : metadata.st_gid == id { return true }
                    let owner = kind == .user ? id : uid_t.max
                    let group = kind == .group ? id : gid_t.max
                    var updated = stat()
                    guard fchown(entry, owner, group) == 0, fstat(entry, &updated) == 0 else { return false }
                    return kind == .user
                        ? updated.st_uid == id && updated.st_gid == metadata.st_gid
                        : updated.st_gid == id && updated.st_uid == metadata.st_uid
                }
            }
        }.value
    }

    private static func ownershipID(_ name: String, kind: FileACLAccountKind) throws -> UInt32 {
        guard !name.isEmpty, !name.utf8.contains(0) else { throw FilePermissionError.unknownACLAccount }
        var buffer = [CChar](repeating: 0, count: 64 * 1024)
        switch kind {
        case .user:
            var record = passwd()
            var found: UnsafeMutablePointer<passwd>?
            guard getpwnam_r(name, &record, &buffer, buffer.count, &found) == 0,
                  found != nil, record.pw_uid != uid_t.max else { throw FilePermissionError.unknownACLAccount }
            return record.pw_uid
        case .group:
            var record = group()
            var found: UnsafeMutablePointer<group>?
            guard getgrnam_r(name, &record, &buffer, buffer.count, &found) == 0,
                  found != nil, record.gr_gid != gid_t.max else { throw FilePermissionError.unknownACLAccount }
            return record.gr_gid
        }
    }

    public func setAccessControlList(_ entries: String, at url: URL, expected: FilePermissionSnapshot) async throws -> FilePermissionSnapshot {
        try await Task.detached(priority: .utility) {
            let acl = try Self.parsePermissionACL(entries, header: expected.aclHeader)
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            return try Self.withPermissionDescriptor(url) { descriptor in
                let current = try Self.permissionSnapshot(descriptor)
                try Self.checkPermissionSnapshot(current, expected: expected)
                guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { throw Self.permissionPOSIXError() }
                return try Self.permissionSnapshot(descriptor)
            }
        }.value
    }

    private static func parsePermissionACL(_ entries: String, header: String) throws -> acl_t {
        let text = entries.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entries.utf8.contains(0), let acl = acl_from_text(header + "\n" + text + "\n") else {
            throw FilePermissionError.invalidAccessControlList
        }
        guard acl_valid(acl) == 0 else {
            acl_free(UnsafeMutableRawPointer(acl))
            throw FilePermissionError.invalidAccessControlList
        }
        return acl
    }

    private static func checkPermissionSnapshot(_ current: FilePermissionSnapshot, expected: FilePermissionSnapshot) throws {
        guard current.device == expected.device, current.inode == expected.inode,
              current.birthSeconds == expected.birthSeconds,
              current.birthNanoseconds == expected.birthNanoseconds else {
            throw FilePermissionError.changedItem
        }
        guard current.ownerID == expected.ownerID, current.groupID == expected.groupID,
              current.mode == expected.mode, current.aclHeader == expected.aclHeader,
              current.accessControlList == expected.accessControlList else {
            throw FilePermissionError.changedPermissions
        }
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
        let acl = try permissionACL(descriptor)
        return FilePermissionSnapshot(
            isDirectory: type == S_IFDIR, mode: Int(metadata.st_mode & 0o7777), ownerID: metadata.st_uid, groupID: metadata.st_gid,
            accessControlList: acl.entries, aclHeader: acl.header,
            device: metadata.st_dev, inode: metadata.st_ino,
            birthSeconds: metadata.st_birthtimespec.tv_sec, birthNanoseconds: metadata.st_birthtimespec.tv_nsec
        )
    }

    private static func permissionACL(_ descriptor: Int32) throws -> (header: String, entries: String?) {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return ("!#acl 1", nil) }
            throw permissionPOSIXError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return try permissionACLText(acl)
    }

    private static func permissionACLText(_ acl: acl_t) throws -> (header: String, entries: String?) {
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw permissionPOSIXError() }
        defer { acl_free(text) }
        let lines = String(cString: text).split(separator: "\n")
        let entries = lines.dropFirst()
        return (lines.first.map(String.init) ?? "!#acl 1", entries.isEmpty ? nil : entries.joined(separator: "\n"))
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
