import Foundation
import Testing
@testable import FilesCore

private final class BlockedMetadata: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waiting = false
    func block() {
        lock.withLock { waiting = true }; started.signal()
        _ = resume.wait(timeout: .now() + 10)
        lock.withLock { waiting = false }; ended.signal()
    }
    var isWaiting: Bool { lock.withLock { waiting } }
    func observe(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "FilesCore.Tests.MetadataObserver").async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success)
            }
        }
    }
}
private func sizingRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizing-scheduling-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("123".utf8).write(to: root.appendingPathComponent("payload.txt")); return root
}

@Test func folderSizingWaitingForFileSystemAllowsOtherSwiftTasksToResume() async throws {
    let root = try sizingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let blocked = BlockedMetadata(); defer { blocked.resume.signal() }
    let item = FileItem(url: root, name: root.lastPathComponent, isDirectory: true, identity: LocalEntryIdentity.read(root))
    let task = Task { try await FolderSizeCalculator(beforeReading: blocked.block).size(of: item) }
    #expect(await blocked.observe(blocked.started))
    // This Swift continuation must run while the synchronous metadata call is still blocked.
    #expect(blocked.isWaiting); blocked.resume.signal()
    #expect(try await task.value == 3)
}

@Test func folderSizingCancellationWhileFileSystemIsBlockedReturnsBeforeIO() async throws {
    let root = try sizingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let blocked = BlockedMetadata(); defer { blocked.resume.signal() }
    let item = FileItem(url: root, name: root.lastPathComponent, isDirectory: true, identity: LocalEntryIdentity.read(root))
    let task = Task { try await FolderSizeCalculator(beforeReading: blocked.block).size(of: item) }
    #expect(await blocked.observe(blocked.started)); task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled size request unexpectedly returned a value") }
    catch { #expect(error is CancellationError) }
    #expect(blocked.isWaiting); blocked.resume.signal(); #expect(await blocked.observe(blocked.ended))
    #expect(try Data(contentsOf: root.appendingPathComponent("payload.txt")) == Data("123".utf8))
}

@Test func folderBulkSizingCancellationDiscardsLateResults() async throws {
    let root = try sizingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let blocked = BlockedMetadata(); defer { blocked.resume.signal() }
    let task = Task { await FolderSizeCalculator(beforeReading: blocked.block).sizes(of: [root]) }
    #expect(await blocked.observe(blocked.started)); task.cancel()
    #expect(await task.value.isEmpty); #expect(blocked.isWaiting)
    blocked.resume.signal(); #expect(await blocked.observe(blocked.ended))
}

@Test func cloudDiscoveryCancellationWhileFileSystemIsBlockedReturnsBeforeIO() async throws {
    let root = try sizingRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let blocked = BlockedMetadata(); defer { blocked.resume.signal() }
    let provider = CloudLocationProvider(home: root)
    let task = Task { await provider.locationsAsync(beforeReading: blocked.block) }
    #expect(await blocked.observe(blocked.started)); task.cancel()
    #expect(await task.value.isEmpty); #expect(blocked.isWaiting)
    blocked.resume.signal(); #expect(await blocked.observe(blocked.ended))
}

@Test func filesystemWorkCancellationRacesDoNotResumeContinuationsTwice() async throws {
    for iteration in 0..<100 {
        let task = Task { try await FileSystemWork.run(qos: .utility) { cancellation in try cancellation.check(); return 42 } }
        if iteration % 2 == 0 { await Task.yield() }
        task.cancel()
        do { #expect(try await task.value == 42) } catch { #expect(error is CancellationError) }
    }
}
