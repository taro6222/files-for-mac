import Foundation
import Testing
@testable import FilesCore

private final class BlockedDirectoryRead: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var resumedBeforeDeadline = false
    func block() {
        started.signal()
        let result = resume.wait(timeout: .now() + 3)
        lock.withLock { resumedBeforeDeadline = result == .success }
    }
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
        DispatchQueue.global().async { continuation.resume(returning: blocked.started.wait(timeout: .now() + 5) == .success) }
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
        DispatchQueue.global().async { continuation.resume(returning: blocked.started.wait(timeout: .now() + 5) == .success) }
    }
    #expect(started)
    listing.cancel()
    blocked.resume.signal()
    do { #expect(try await listing.value == 0) } catch { #expect(error is CancellationError) }
    #expect(try Data(contentsOf: root.appendingPathComponent("file.txt")) == Data("keep".utf8))
}
