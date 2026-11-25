import Foundation
import Darwin
import Testing
@testable import FilesCore

private final class TransferSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LiveTransferProgress] = []
    func append(_ value: LiveTransferProgress) { lock.withLock { values.append(value) } }
    var samples: [LiveTransferProgress] { lock.withLock { values } }
}

private struct NativeCopyFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-copy-\(UUID())")
    var source: URL { root.appendingPathComponent("source") }
    var target: URL { root.appendingPathComponent("target") }
    init() throws { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func populate() throws -> Int64 {
        let fm = FileManager.default
        let nested = source.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data(repeating: 41, count: 3 * 1024 * 1024).write(to: source.appendingPathComponent("a"))
        try Data(repeating: 42, count: 2 * 1024 * 1024).write(to: nested.appendingPathComponent("b"))
        try Data().write(to: nested.appendingPathComponent("zero"))
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data(repeating: 99, count: 1024).write(to: outside.appendingPathComponent("never-follow"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("external-link"), withDestinationURL: outside)
        return 5 * 1024 * 1024
    }
}

@Test(arguments: [false, true]) func nativeCopyReportsLogicalBytesWithoutFollowingLinks(allowClone: Bool) throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let total = try f.populate(), samples = TransferSamples()
    let before = try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation())
    try NativeFileCopy.run(from: f.source, to: f.target, totalBytes: total,
                           cancellation: CopyCancellation(), allowClone: allowClone, progress: samples.append)
    let values = samples.samples
    #expect(values.first?.bytes == 0 && values.last?.bytes == total)
    #expect(values.allSatisfy { $0.totalBytes == total && $0.seconds >= 0 })
    #expect(zip(values, values.dropFirst()).allSatisfy { $0.bytes <= $1.bytes && $0.seconds <= $1.seconds })
    if !allowClone { #expect(values.contains { $0.bytes > 0 && $0.bytes < total }) }
    for path in ["a", "nested/b", "nested/zero"] {
        #expect(try Data(contentsOf: f.target.appendingPathComponent(path)) == Data(contentsOf: f.source.appendingPathComponent(path)))
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.target.appendingPathComponent("external-link").path)
            == f.root.appendingPathComponent("outside").path)
    try before.restoreCreationTimes(in: f.target, cancellation: CopyCancellation())
    try before.restoreDirectoryModificationTimes(in: f.target, cancellation: CopyCancellation())
    let after = try CopyEngine.makeSnapshot(f.target, cancellation: CopyCancellation())
    for (path, date) in before.metadata.modificationDates {
        let copied = try #require(after.metadata.modificationDates[path])
        #expect(abs(copied.timeIntervalSince(date)) <= 0.000001, "Relative path: \(path), source: \(date.timeIntervalSince1970), copy: \(copied.timeIntervalSince1970)")
    }
}

@Test func nativeCopyCancelsAtDataCallbackBeforeFinishingCurrentFile() throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("large")
    let original = Data(repeating: 71, count: 8 * 1024 * 1024)
    try original.write(to: source)
    let cancellation = CopyCancellation(), samples = TransferSamples()
    #expect(throws: CancellationError.self) {
        try NativeFileCopy.run(from: source, to: f.target, totalBytes: Int64(original.count),
                               cancellation: cancellation, allowClone: false) { value in
            samples.append(value)
            if value.bytes > 0 { cancellation.cancel() }
        }
    }
    let last = try #require(samples.samples.last)
    #expect(last.bytes > 0 && last.bytes < original.count)
    #expect(try Data(contentsOf: source) == original)
    // copyfile may remove the unfinished current file when a callback aborts it.
    if FileManager.default.fileExists(atPath: f.target.path) {
        #expect(try FileManager.default.attributesOfItem(atPath: f.target.path)[.size] as? Int64 == last.bytes)
    }
}

@Test func nativeCopyNeverReplacesExistingDestinationAndHonorsEarlyCancellation() throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("file")
    try Data("source".utf8).write(to: source)
    try Data("existing".utf8).write(to: f.target)
    #expect(throws: (any Error).self) {
        try NativeFileCopy.run(from: source, to: f.target, totalBytes: 6, cancellation: CopyCancellation()) { _ in }
    }
    #expect(try String(contentsOf: f.target, encoding: .utf8) == "existing")
    let cancellation = CopyCancellation(); cancellation.cancel()
    let absent = f.root.appendingPathComponent("absent")
    #expect(throws: CancellationError.self) {
        try NativeFileCopy.run(from: source, to: absent, totalBytes: 6, cancellation: cancellation) { _ in
            Issue.record("Cancelled copy must not emit progress")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: absent.path))
}

@Test func copyEngineLiveFolderProgressPreservesVerificationAndUndo() async throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let total = try f.populate(), samples = TransferSamples()
    try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: false)
    let journal = f.root.appendingPathComponent("journal")
    let report = await CopyEngine.run(sources: [f.source], destination: f.target, journalDirectory: journal,
                                      cancellation: CopyCancellation()) { value in
        if let live = value.liveTransfer { samples.append(live) }
    }
    #expect(report.state == "completed" && report.journalError == nil, "\(report)")
    #expect(samples.samples.last?.bytes == total && samples.samples.last?.totalBytes == total)
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: journal))
    let result = await CopyEngine.undoCopy(undo, journalDirectory: journal)
    #expect(result.state == "completed")
    #expect(!FileManager.default.fileExists(atPath: f.target.appendingPathComponent("source").path))
    #expect(try Data(contentsOf: f.source.appendingPathComponent("a")).count == 3 * 1024 * 1024)
}

@Test func copyEngineCancellationFromLiveBytesCleansStageAndPreservesSource() async throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let total = try f.populate()
    try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: false)
    let cancellation = CopyCancellation(), samples = TransferSamples()
    let report = await CopyEngine.run(sources: [f.source], destination: f.target,
                                      journalDirectory: f.root.appendingPathComponent("journal"), cancellation: cancellation) { value in
        if let live = value.liveTransfer {
            samples.append(live)
            if live.bytes > 0 { cancellation.cancel() }
        }
    }
    #expect(report.state == "cancelled" && report.items.map(\.state) == ["cancelled"])
    #expect(report.journalError == nil && report.items.first?.temporary == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path).isEmpty)
    #expect(samples.samples.contains { $0.bytes > 0 })
    #expect(try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation()).logicalDataBytes == total)
}

@Test func stagedDirectoryTimeRestorationRejectsSymlinkedRoot() throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    _ = try f.populate()
    let snapshot = try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation())
    let outside = f.root.appendingPathComponent("outside")
    let before = try FileManager.default.attributesOfItem(atPath: outside.path)[.modificationDate] as? Date
    try FileManager.default.createSymbolicLink(at: f.target, withDestinationURL: outside)
    #expect(throws: CopyEngine.TransferMismatch.modificationTime) {
        try snapshot.restoreDirectoryModificationTimes(in: f.target, cancellation: CopyCancellation())
    }
    #expect(try FileManager.default.attributesOfItem(atPath: outside.path)[.modificationDate] as? Date == before)
}

@Test func nativeCopyDropsStaleTotalAndCancelsBeforeStartingFromInitialProgress() throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let file = f.source.appendingPathComponent("file")
    try Data(repeating: 31, count: 2 * 1024 * 1024).write(to: file)
    let samples = TransferSamples()
    try NativeFileCopy.run(from: file, to: f.target, totalBytes: 1,
                           cancellation: CopyCancellation(), allowClone: false, progress: samples.append)
    let last = try #require(samples.samples.last)
    let expected: Int64 = 2 * 1024 * 1024
    #expect(last.bytes == expected)
    #expect(last.totalBytes == nil)
    let cancelledTarget = f.root.appendingPathComponent("cancelled-target")
    let cancellation = CopyCancellation()
    #expect(throws: CancellationError.self) {
        try NativeFileCopy.run(from: file, to: cancelledTarget, totalBytes: nil, cancellation: cancellation) { _ in
            cancellation.cancel()
        }
    }
    #expect(!FileManager.default.fileExists(atPath: cancelledTarget.path))
}

@Test func nativeCopyFallbackPreservesSparseAllocationAndLogicalProgress() throws {
    let f = try NativeCopyFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("sparse")
    let length: Int64 = 64 * 1024 * 1024
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(length))
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data("first".utf8))
    try handle.seek(toOffset: UInt64(length - 4))
    try handle.write(contentsOf: Data("last".utf8)); try handle.close()
    var original = stat(), copied = stat()
    let originalStatus = lstat(source.path, &original)
    try #require(originalStatus == 0 && original.st_blocks * 512 < length / 2)
    try #require(original.st_size == length)
    let samples = TransferSamples()
    try NativeFileCopy.run(from: source, to: f.target, totalBytes: length,
                           cancellation: CopyCancellation(), allowClone: false, progress: samples.append)
    let copiedStatus = lstat(f.target.path, &copied)
    #expect(copiedStatus == 0)
    #expect(copied.st_size == length)
    #expect(copied.st_blocks * 512 < length / 2)
    #expect(try Data(contentsOf: f.target) == Data(contentsOf: source))
    let last = try #require(samples.samples.last)
    #expect(last.bytes == length)
    #expect(last.totalBytes == length)
}
