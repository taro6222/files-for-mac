import Foundation
import Darwin

public struct ShelfEntry: Equatable, Sendable {
    public let url: URL
    private let device: dev_t
    private let inode: ino_t
    private let birthSeconds: Int
    private let birthNanoseconds: Int

    public init?(_ source: URL) {
        guard source.isFileURL else { return nil }
        let url = source.standardizedFileURL
        var info = stat()
        guard url.path != "/", lstat(url.path, &info) == 0 else { return nil }
        self.url = url
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
    }

    public var isCurrent: Bool { ShelfEntry(url) == self }
}
