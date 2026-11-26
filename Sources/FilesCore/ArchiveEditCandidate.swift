import Foundation
import Darwin
import CryptoKit

struct ArchiveEditFileProof: Codable, Sendable, Equatable {
    let device: Int32, inode: UInt64, size: Int64, mode: UInt16, owner: UInt32, group: UInt32, links: UInt16
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    let sha256: String
    private init(_ value: stat, digest: String) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size; mode = value.st_mode
        owner = value.st_uid; group = value.st_gid; links = value.st_nlink
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec); sha256 = digest
    }
    static func capture(_ fd: Int32, check: () throws -> Void) throws -> Self {
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0, before.st_size <= 8_000_000_000 else { throw SevenZipWorkerError.worker("source-changed") }
        var hash = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < before.st_size {
            try check()
            let count = pread(fd, &buffer, Int(min(Int64(buffer.count), before.st_size - offset)), offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SevenZipWorkerError.worker("source-changed") }
            hash.update(data: buffer.prefix(count)); offset += Int64(count)
        }
        var after = stat(); guard fstat(fd, &after) == 0 else { throw SevenZipWorkerError.ioFailure }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let proof = Self(before, digest: digest)
        guard proof == Self(after, digest: digest) else { throw SevenZipWorkerError.worker("source-changed") }
        try check(); return proof
    }
    static func capture(_ url: URL, check: () throws -> Void) throws -> Self {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw SevenZipWorkerError.invalidConfiguration }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SevenZipWorkerError.worker("source-changed") }; defer { Darwin.close(fd) }
        let proof = try capture(fd, check: check)
        var named = stat()
        guard lstat(url.path, &named) == 0, Self(named, digest: proof.sha256) == proof else { throw SevenZipWorkerError.worker("source-changed") }
        return proof
    }
}

/// An internal verification result, not authorization to replace a pathname without a transaction.
struct ArchiveEditCandidate: Sendable {
    let source: ArchiveEditFileProof, candidate: ArchiveEditFileProof
    let entries: [ArchiveEntryDescriptor]
}
