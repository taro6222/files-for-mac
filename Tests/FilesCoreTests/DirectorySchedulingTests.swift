import Foundation
import Testing
@testable import FilesCore

private final class BlockedDirectoryRead: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let ended = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var resumedBeforeDeadline = false
    private var finished = false
    func block() {
        started.signal()
        // This is a synchronization watchdog, not an application latency budget.
        let result = resume.wait(timeout: .now() + 10)
        lock.withLock { resumedBeforeDeadline = result == .success; finished = true }
        ended.signal()
    }
    var isWaiting: Bool { lock.withLock { !finished } }
    var resumed: Bool { lock.withLock { resumedBeforeDeadline } }
}

@Test func directoryWaitingForFileSystemAllowsOtherSwiftTasksToResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-forward-progress-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("retained".utf8).write(to: root.appendingPathComponent("file.txt"))
    let blocked = BlockedDirectoryRead()
    let provider = LocalFileSystem(beforeReading: { blocked.block() })
    let listing = Task { try await provider.contents(of: root, showHidden: true) }
    let started = await withCheckedContinuation { continuation in
        // A private observer queue must not wait behind the intentionally blocked I/O queue.
        DispatchQueue(label: "FilesCore.Tests.DirectoryReadObserver").async {
            continuation.resume(returning: blocked.started.wait(timeout: .now() + 10) == .success)
        }
    }
    #expect(started)
    // This Swift task must run while the simulated synchronous filesystem call is waiting.
    blocked.resume.signal()
    let files = try await listing.value
    #expect(blocked.resumed)
    #expect(files.map(\.name) == ["file.txt"])
}

@Test func directoryCancellationWhileFileSystemIsBlockedStopsBeforeFirstBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-cancellation-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("keep".utf8).write(to: root.appendingPathComponent("file.txt"))
    let blocked = BlockedDirectoryRead()
    let stream = LocalFileSystem(beforeReading: { blocked.block() }).batches(of: root, showHidden: true)
    let listing = Task { () throws -> Int in
        var count = 0
        for try await batch in stream { count += batch.count }
        return count
    }
    let started = await withCheckedContinuation { continuation in
        // A private observer queue must not wait behind the intentionally blocked I/O queue.
        DispatchQueue(label: "FilesCore.Tests.DirectoryReadObserver").async {
            continuation.resume(returning: blocked.started.wait(timeout: .now() + 10) == .success)
        }
    }
    #expect(started)
    listing.cancel()
    // The consumer must finish cancelling while the synchronous read is still held.
    // Releasing first races a not-yet-suspended consumer against a buffered batch.
    do { #expect(try await listing.value == 0) } catch { #expect(error is CancellationError) }
    #expect(blocked.isWaiting)
    blocked.resume.signal()
    let ended = await withCheckedContinuation { continuation in
        DispatchQueue(label: "FilesCore.Tests.DirectoryReadEndObserver").async {
            continuation.resume(returning: blocked.ended.wait(timeout: .now() + 10) == .success)
        }
    }
    #expect(ended && blocked.resumed)
    #expect(try Data(contentsOf: root.appendingPathComponent("file.txt")) == Data("keep".utf8))
}

@Test func directoryListingKeepsFreshURLsWithKnownDirectoryHints() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-url-hints-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(component: "한글 folder", directoryHint: .isDirectory)
    let file = root.appending(component: "file #?.txt", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data("old".utf8).write(to: file)
    let items = try await LocalFileSystem().contents(of: root, showHidden: true)
    let directory = try #require(items.first { $0.name == "한글 folder" })
    let regular = try #require(items.first { $0.name == "file #?.txt" })
    #expect(directory.url.hasDirectoryPath && directory.isDirectory)
    #expect(!regular.url.hasDirectoryPath && !regular.isDirectory)
    #expect(regular.url.path == file.path && regular.identity == LocalEntryIdentity.read(file) && regular.size == 3)
    try Data("new larger contents".utf8).write(to: file)
    // The model URL must not retain the enumerator's prefetched size for a later operation.
    #expect(try regular.url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 19)
    #expect(regular.identity == LocalEntryIdentity.read(file))
}
