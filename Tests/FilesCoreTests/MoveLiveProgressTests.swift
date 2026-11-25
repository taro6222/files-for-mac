import Foundation
import Testing
@testable import FilesCore

private final class MoveByteSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LiveTransferProgress] = []
    func append(_ value: LiveTransferProgress) { lock.withLock { values.append(value) } }
    var samples: [LiveTransferProgress] { lock.withLock { values } }
}

private struct MoveByteFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-live-\(UUID())")
    var source: URL { root.appendingPathComponent("source") }
    var destination: URL { root.appendingPathComponent("destination") }
    var journal: URL { root.appendingPathComponent("journal") }
    var target: URL { destination.appendingPathComponent("source") }
    let bytes: Int64 = 4 * 1024 * 1024
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in ["a", "b"] {
            try Data(repeating: 57, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent(name))
        }
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "missing")
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func crossVolumeMoveLiveBytesPreserveVerificationAndUndo() async throws {
    let f = try MoveByteFixture(); defer { f.clean() }
    let before = try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation())
    let samples = MoveByteSamples()
    let report = try await EntryOperations.moveAcrossVolumeForTesting([f.source], to: f.destination,
        journalDirectory: f.journal) { update in
        if let live = update.liveTransfer { samples.append(live) }
    }
    #expect(report.state == "completed" && report.journalError == nil)
    #expect(samples.samples.last?.bytes == f.bytes && samples.samples.last?.totalBytes == f.bytes)
    #expect(zip(samples.samples, samples.samples.dropFirst()).allSatisfy { $0.bytes <= $1.bytes })
    #expect(!FileManager.default.fileExists(atPath: f.source.path))
    try CopyEngine.makeSnapshot(f.target, cancellation: CopyCancellation()).verifyTransferredContents(of: before)
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: f.journal))
    #expect(undo.items.first?.crossVolume == true)
    let restored = await EntryOperations.undoMove(undo, journalDirectory: f.journal)
    #expect(restored.state == "completed")
    try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation()).verifyTransferredContents(of: before)
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
}

@Test func crossVolumeLiveCancellationRestoresReplacementAndKeepsSource() async throws {
    let f = try MoveByteFixture(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: false)
    try Data("old".utf8).write(to: f.target.appendingPathComponent("old"))
    let before = try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation())
    let cancellation = CopyCancellation(), samples = MoveByteSamples()
    let report = try await EntryOperations.moveAcrossVolumeForTesting([f.source], to: f.destination,
        conflictPolicy: .replace, journalDirectory: f.journal, cancellation: cancellation) { update in
        if let live = update.liveTransfer {
            samples.append(live)
            if live.bytes > 0 { cancellation.cancel() }
        }
    }
    #expect(report.state == "cancelled" && samples.samples.contains { $0.bytes > 0 })
    #expect(try String(contentsOf: f.target.appendingPathComponent("old"), encoding: .utf8) == "old")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path) == ["source"])
    #expect(try CopyEngine.makeSnapshot(f.source, cancellation: CopyCancellation()).matchesOriginal(before))
    #expect(EntryOperations.latestUndoMove(journalDirectory: f.journal) == nil)
}

@Test func crossVolumeLiveSourceMutationPreventsPublicationAndDeletion() async throws {
    let f = try MoveByteFixture(); defer { f.clean() }
    let mutated = CopyCancellation()
    let report = try await EntryOperations.moveAcrossVolumeForTesting([f.source], to: f.destination,
        journalDirectory: f.journal) { update in
        if update.liveTransfer?.bytes ?? 0 > 0, !mutated.isCancelled {
            mutated.cancel()
            do { try Data("changed".utf8).write(to: f.source.appendingPathComponent("a")) }
            catch { Issue.record(error) }
        }
    }
    #expect(mutated.isCancelled && report.state == "partial")
    #expect(report.items.map(\.state) == ["failed"])
    #expect(try String(contentsOf: f.source.appendingPathComponent("a"), encoding: .utf8) == "changed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
}

@Test func sameVolumeRenameDoesNotInventByteTransferProgress() async throws {
    let f = try MoveByteFixture(); defer { f.clean() }
    let samples = MoveByteSamples()
    let report = try await EntryOperations.move([f.source], to: f.destination, journalDirectory: f.journal) { update in
        if let live = update.liveTransfer { samples.append(live) }
    }
    #expect(report.state == "completed" && samples.samples.isEmpty)
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: f.journal))
    #expect(undo.items.first?.crossVolume == false)
    #expect(await EntryOperations.undoMove(undo, journalDirectory: f.journal).state == "completed")
}
