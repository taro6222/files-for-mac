import Foundation
import Darwin
import CryptoKit
import CZlib

/// File-system compression is regenerated from verified logical bytes, never copied
/// from the old archive onto different data. All I/O uses the transaction's pinned FD.
/// decmpfs/resource-fork framing: Apple xnu bsd/sys/decmpfs.h and libarchive's
/// archive_write_disk_posix.c (format reference; independent implementation).
enum ArchiveEditCompression {
    struct Snapshot: Codable, Equatable {
        let method: UInt32
        let attributes: [String: Data]
    }
    private static let compressionName = "com.apple.decmpfs", forkName = "com.apple.ResourceFork"
    private static let blockSize = 65_536
    private static func failure() -> ArchiveEditError { .metadataMismatch("filesystem-compression") }
    private static func readLE(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    private static func put(_ value: UInt64, into data: inout Data, at offset: Int, count: Int, big: Bool = false) {
        for i in 0..<count { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (big ? count - 1 - i : i))) }
    }
    static func capture(_ fd: Int32, size: Int64, check: () throws -> Void) throws -> Snapshot {
        let length = fgetxattr(fd, compressionName, nil, 0, 0, XATTR_SHOWCOMPRESSION)
        guard (16...3802).contains(length) else { throw failure() }
        var header = Data(count: length)
        guard header.withUnsafeMutableBytes({ fgetxattr(fd, compressionName, $0.baseAddress, length, 0, XATTR_SHOWCOMPRESSION) }) == length,
              readLE(header, 0, 4) == 0x636d7066, readLE(header, 8, 8) == UInt64(size) else { throw failure() }
        let method = UInt32(readLE(header, 4, 4))
        guard [1, 3, 4, 7, 8, 9, 10, 11, 12].contains(method) else { throw failure() }
        var attributes = [compressionName: Data(SHA256.hash(data: header))]
        let forkLength = fgetxattr(fd, forkName, nil, 0, 0, XATTR_SHOWCOMPRESSION)
        if forkLength >= 0 {
            // Odd methods use inline storage. An extra hidden fork is ambiguous;
            // preserve the source rather than replace such a fork with codec blocks.
            guard [4, 8, 10, 12].contains(method), forkLength <= Int(UInt32.max) else { throw failure() }
            var digest = SHA256(), buffer = [UInt8](repeating: 0, count: blockSize), position = 0
            while position < forkLength {
                try check(); let amount = min(buffer.count, forkLength - position)
                guard fgetxattr(fd, forkName, &buffer, amount, UInt32(position), XATTR_SHOWCOMPRESSION) == amount else { throw failure() }
                digest.update(data: buffer.prefix(amount)); position += amount
            }
            attributes[forkName] = Data(digest.finalize())
        } else { guard errno == ENOATTR else { throw failure() } }
        if [4, 8, 10, 12].contains(method), forkLength < 0 { throw failure() }
        return Snapshot(method: method, attributes: attributes)
    }
    private static func compressed(_ bytes: [UInt8]) throws -> Data {
        var length = compressBound(uLong(bytes.count)), result = [UInt8](repeating: 0, count: Int(length))
        guard compress2(&result, &length, bytes, uLong(bytes.count), Z_DEFAULT_COMPRESSION) == Z_OK else { throw failure() }
        if length > bytes.count { return Data([0xff]) + Data(bytes) }
        return Data(result.prefix(Int(length)))
    }
    private static func set(_ fd: Int32, name: String, data: Data, position: UInt32 = 0, create: Bool = false) throws {
        let options = XATTR_SHOWCOMPRESSION | (create ? XATTR_CREATE : 0)
        guard data.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, data.count, position, options) }) == 0 else { throw failure() }
    }
    static func encode(_ fd: Int32, check: () throws -> Void, beforeStorageCreation: (() throws -> Void)? = nil) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 8_000_000_000,
              info.st_flags & UInt32(UF_COMPRESSED | UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw failure() }
        for name in [compressionName, forkName] {
            guard fgetxattr(fd, name, nil, 0, 0, XATTR_SHOWCOMPRESSION) < 0, errno == ENOATTR else { throw failure() }
        }
        let before = try ArchiveEditFileProof.capture(fd, check: check)
        // Internal fault-injection boundary; production callers leave this nil.
        try beforeStorageCreation?()
        let blocks = max(1, Int((info.st_size + Int64(blockSize) - 1) / Int64(blockSize)))
        var header = Data(count: 16), table = Data(count: 264 + blocks * 8), position = table.count
        put(0x636d7066, into: &header, at: 0, count: 4); put(UInt64(info.st_size), into: &header, at: 8, count: 8)
        put(UInt64(blocks), into: &table, at: 260, count: 4)
        var inline: Data?
        for index in 0..<blocks {
            try check(); let offset = index * blockSize, amount = min(blockSize, max(0, Int(info.st_size) - offset))
            var bytes = [UInt8](repeating: 0, count: amount), readCount = 0
            while readCount < amount {
                let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: readCount), amount - readCount, off_t(offset + readCount)) }
                if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw failure() }; readCount += n
            }
            let data = try compressed(bytes)
            if blocks == 1, 16 + data.count <= 3802 { inline = data; break }
            if index == 0 { try set(fd, name: forkName, data: table, create: true) }
            guard position <= Int(UInt32.max) - data.count - 50 else { throw failure() }
            put(UInt64(position - 260), into: &table, at: 264 + index * 8, count: 4)
            put(UInt64(data.count), into: &table, at: 268 + index * 8, count: 4)
            try set(fd, name: forkName, data: data, position: UInt32(position)); position += data.count
        }
        if let inline { put(3, into: &header, at: 4, count: 4); header.append(inline) }
        else {
            var footer = Data(count: 50)
            put(28, into: &footer, at: 24, count: 2, big: true); put(50, into: &footer, at: 26, count: 2, big: true)
            footer.replaceSubrange(30..<34, with: Data("cmpf".utf8))
            put(10, into: &footer, at: 36, count: 2, big: true); put(1, into: &footer, at: 38, count: 2, big: true)
            put(0xffff, into: &footer, at: 40, count: 2, big: true)
            try set(fd, name: forkName, data: footer, position: UInt32(position))
            put(256, into: &table, at: 0, count: 4, big: true); put(UInt64(position), into: &table, at: 4, count: 4, big: true)
            put(UInt64(position - 256), into: &table, at: 8, count: 4, big: true); put(50, into: &table, at: 12, count: 4, big: true)
            put(UInt64(position - 260), into: &table, at: 256, count: 4, big: true)
            try set(fd, name: forkName, data: table); put(4, into: &header, at: 4, count: 4)
        }
        // Until this point the original logical data fork remains readable, even on failure.
        let ready = try ArchiveEditFileProof.capture(fd, check: check)
        guard before.device == ready.device, before.inode == ready.inode, before.sha256 == ready.sha256, before.size == ready.size else { throw failure() }
        if inline != nil {
            guard fgetxattr(fd, forkName, nil, 0, 0, XATTR_SHOWCOMPRESSION) < 0, errno == ENOATTR else { throw failure() }
        }
        try set(fd, name: compressionName, data: header, create: true); try check()
        guard fchflags(fd, info.st_flags | UInt32(UF_COMPRESSED)) == 0, fsync(fd) == 0 else { throw failure() }
        let after = try ArchiveEditFileProof.capture(fd, check: check)
        var flags = stat()
        guard before.device == after.device, before.inode == after.inode, before.sha256 == after.sha256, before.size == after.size,
              fstat(fd, &flags) == 0, flags.st_flags == info.st_flags | UInt32(UF_COMPRESSED) else { throw failure() }
    }
}
