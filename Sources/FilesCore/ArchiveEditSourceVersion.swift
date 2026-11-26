import Foundation
import Darwin

/// Binds an archive-view selection to the file that supplied its listing.
public struct ArchiveEditSourceVersion: Sendable, Equatable {
    private let value: stat
    private init(_ value: stat) { self.value = value }
    public init(at archive: URL) throws {
        guard archive.isFileURL, !archive.path.utf8.contains(0) else { throw SevenZipWorkerError.invalidConfiguration }
        let fd = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SevenZipWorkerError.worker("source-changed") }; defer { Darwin.close(fd) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, held.st_mode & S_IFMT == S_IFREG, lstat(archive.path, &named) == 0,
              Self(held) == Self(named) else { throw SevenZipWorkerError.worker("source-changed") }
        value = held
    }
    public static func == (a: Self, b: Self) -> Bool {
        let x = a.value, y = b.value
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino && x.st_size == y.st_size && x.st_mode == y.st_mode && x.st_uid == y.st_uid && x.st_gid == y.st_gid && x.st_nlink == y.st_nlink && x.st_flags == y.st_flags &&
            x.st_mtimespec.tv_sec == y.st_mtimespec.tv_sec && x.st_mtimespec.tv_nsec == y.st_mtimespec.tv_nsec &&
            x.st_ctimespec.tv_sec == y.st_ctimespec.tv_sec && x.st_ctimespec.tv_nsec == y.st_ctimespec.tv_nsec &&
            x.st_birthtimespec.tv_sec == y.st_birthtimespec.tv_sec && x.st_birthtimespec.tv_nsec == y.st_birthtimespec.tv_nsec
    }
    func verify(_ current: stat) throws { guard self == Self(current) else { throw SevenZipWorkerError.worker("source-changed") } }
}
