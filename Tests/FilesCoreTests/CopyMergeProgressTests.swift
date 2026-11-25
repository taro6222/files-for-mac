import Foundation
import Testing
@testable import FilesCore

@Test func mergeBatchForwardsMissingAndNestedLiveBytesWhilePreservingConflictsAndUndo() async throws {
    let f = try MergeProgressFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing")
    try Data(repeating: 1, count: 11).write(to: missing)
    let nested = f.source.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 8192).write(to: nested.appendingPathComponent("data"))
    try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("link").path, withDestinationPath: "data")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: nested.path)
    try Data("source".utf8).write(to: f.source.appendingPathComponent("conflict"))
    let conflict = f.target.appendingPathComponent("conflict")
    try Data("preserved".utf8).write(to: conflict)
    let events = MergeEvents()
    let report = await CopyMergeBatch.run(sources: [missing, f.source], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { events.append($0) }
    #expect(report.state == "completed")
    #expect(report.items.map(\.state) == ["completed", "merged"])
    let samples = events.values
    #expect(samples.contains { $0.index == 0 && $0.liveTransfer?.bytes == 11 && $0.liveTransfer?.totalBytes == 11 })
    #expect(samples.contains { $0.index == 1 && $0.relativePath == "nested" && $0.liveTransfer?.bytes == 8192 && $0.liveTransfer?.totalBytes == 8192 })
    #expect(try String(contentsOf: conflict, encoding: .utf8) == "preserved")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.target.appendingPathComponent("nested/link").path) == "data")
    #expect(try FileManager.default.attributesOfItem(atPath: f.target.appendingPathComponent("nested").path)[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_600_000_000))
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(await CopyEngine.undoCopy(undo, journalDirectory: f.journal).state == "completed")
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("missing").path))
    #expect(!FileManager.default.fileExists(atPath: f.target.appendingPathComponent("nested").path))
    #expect(try String(contentsOf: conflict, encoding: .utf8) == "preserved")
}

@Test func mergeLiveCancellationCleansStagingWithoutPublishingOrChangingSource() async throws {
    let f = try MergeProgressFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("data")
    let original = Data(repeating: 17, count: 1024 * 1024)
    try original.write(to: source)
    let plan = try CopyMergePlanner.plan(source: f.source, target: f.target)
    let cancellation = CopyCancellation()
    let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal, cancellation: cancellation) { update in
        if (update.liveTransfer?.bytes ?? 0) > 0 { cancellation.cancel() }
    }
    #expect(cancellation.isCancelled)
    #expect(report.state == "cancelled")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path).isEmpty)
    #expect(try Data(contentsOf: source) == original)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

@Test func mergeLiveSourceMutationRejectsPublicationAndRemovesStaging() async throws {
    let f = try MergeProgressFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("data")
    try Data("original".utf8).write(to: source)
    let plan = try CopyMergePlanner.plan(source: f.source, target: f.target)
    let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.liveTransfer?.bytes == 0 {
            do { try Data("modified".utf8).write(to: source) } catch { Issue.record(error) }
        }
    }
    #expect(report.items.first?.state == "failed")
    #expect(try String(contentsOf: source, encoding: .utf8) == "modified")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path).isEmpty)
}

@Test func mergeLiveCommitRacePreservesNewDestinationAndHasNoUndo() async throws {
    let f = try MergeProgressFixture(); defer { f.clean() }
    try Data("source".utf8).write(to: f.source.appendingPathComponent("data"))
    let plan = try CopyMergePlanner.plan(source: f.source, target: f.target)
    let target = f.target.appendingPathComponent("data")
    let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.phase == "committing" {
            do { try Data("external".utf8).write(to: target) } catch { Issue.record(error) }
        }
    }
    #expect(report.items.first?.state == "conflict")
    #expect(try String(contentsOf: target, encoding: .utf8) == "external")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path) == ["data"])
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

@Test func mergeBatchReportsNestedCopyFailureInsteadOfSuccessfulMerge() async throws {
    let f = try MergeProgressFixture(); defer { f.clean() }
    let source = f.source.appendingPathComponent("data")
    try Data("original".utf8).write(to: source)
    let report = await CopyMergeBatch.run(sources: [f.source], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.liveTransfer?.bytes == 0 {
            do { try Data("modified".utf8).write(to: source) } catch { Issue.record(error) }
        }
    }
    #expect(report.state == "partiallyCompleted")
    #expect(report.items.first?.state == "failed")
    #expect(report.items.first?.message?.contains("Source changed") == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path).isEmpty)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

private final class MergeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CopyMergeBatchProgress] = []
    func append(_ value: CopyMergeBatchProgress) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [CopyMergeBatchProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct MergeProgressFixture {
    let root: URL
    let source: URL
    let destination: URL
    let target: URL
    let journal: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-live-\(UUID())")
        source = root.appendingPathComponent("source/folder")
        destination = root.appendingPathComponent("destination")
        target = destination.appendingPathComponent("folder")
        journal = root.appendingPathComponent("journal")
        for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
