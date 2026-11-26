import Foundation
import Darwin

/// The broker keeps one search-only directory FD and opens one source at a time.
/// The decoder receives read-only FDs, never archive paths to open itself.
final class SevenZipReadSource {
    struct Record {
        let name: String
        let proof: stat
        var request: [String: Any] {
            ["device": String(UInt64(bitPattern: Int64(proof.st_dev))), "inode": String(proof.st_ino), "size": proof.st_size,
             "mode": UInt32(proof.st_mode), "modifiedSeconds": proof.st_mtimespec.tv_sec,
             "modifiedNanos": proof.st_mtimespec.tv_nsec, "changedSeconds": proof.st_ctimespec.tv_sec,
             "changedNanos": proof.st_ctimespec.tv_nsec]
        }
    }
    let split: Bool
    let records: [Record]
    private let parent: URL, directoryFD: Int32, parentProof: stat
    init(archive: URL, check: () throws -> Void) throws {
        let paths: [URL]
        if let volumes = try SevenZipVolumes.paths(for: archive, check: check) { paths = volumes; split = true }
        else {
            guard let actual = realpath(archive.path, nil) else { throw SevenZipWorkerError.worker("source-open") }
            defer { free(actual) }
            paths = [URL(fileURLWithPath: String(cString: actual))]; split = false
        }
        let parent = try sevenZipCanonicalDirectory(paths[0].deletingLastPathComponent())
        let fd = open(parent.path, O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw SevenZipWorkerError.worker("source-open") }
        var adopted = false
        defer { if !adopted { Darwin.close(fd) } }
        var parentProof = stat(), captured: [Record] = []
        guard fstat(fd, &parentProof) == 0 else { throw SevenZipWorkerError.ioFailure }
        for path in paths {
            try check()
            // The volume locator supplies a single directory. Never follow an entry link.
            guard try sevenZipCanonicalDirectory(path.deletingLastPathComponent()) == parent else { throw SevenZipWorkerError.worker("source-changed") }
            let source = openat(fd, path.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard source >= 0 else { throw SevenZipWorkerError.worker("source-open") }
            defer { Darwin.close(source) }
            var info = stat()
            guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw SevenZipWorkerError.worker("source-open") }
            captured.append(Record(name: path.lastPathComponent, proof: info))
        }
        self.parent = parent; directoryFD = fd; self.parentProof = parentProof; records = captured; adopted = true
    }
    deinit { Darwin.close(directoryFD) }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func verify(check: () throws -> Void) throws {
        var current = stat()
        guard lstat(parent.path, &current) == 0, current.st_dev == parentProof.st_dev, current.st_ino == parentProof.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else { throw SevenZipWorkerError.worker("source-changed") }
        for record in records {
            try check()
            guard fstatat(directoryFD, record.name, &current, AT_SYMLINK_NOFOLLOW) == 0, Self.same(current, record.proof) else { throw SevenZipWorkerError.worker("source-changed") }
        }
    }
    func withDescriptor(_ index: Int, _ body: (Int32) throws -> Void) throws {
        let record = records[index]
        let fd = openat(directoryFD, record.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SevenZipWorkerError.worker("source-changed") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.same(info, record.proof) else { throw SevenZipWorkerError.worker("source-changed") }
        try body(fd)
    }
}
