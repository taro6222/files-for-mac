import Foundation
import Testing
@testable import FilesCore

@Test func mergeSelectionAccumulatesMissingRootsAndActionsWithoutCountingPreservedConflicts() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing")
    try Data("one".utf8).write(to: missing)
    try Data("two22".utf8).write(to: f.source.appendingPathComponent("a"))
    try Data("three33".utf8).write(to: f.source.appendingPathComponent("b"))
    try Data(repeating: 1, count: 8192).write(to: f.source.appendingPathComponent("conflict"))
    try Data("preserved".utf8).write(to: f.target.appendingPathComponent("conflict"))
    let events = MergeSelectionEvents()
    let report = await CopyMergeBatch.run(sources: [missing,f.source], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { events.append($0) }
    #expect(report.items.map(\.state) == ["completed", "merged"])
    #expect(report.selectionTransfer?.bytes == 15 && report.selectionTransfer?.totalBytes == 15)
    let samples = events.values.compactMap(\.selectionTransfer)
    #expect(samples.contains { $0.bytes == 3 && $0.totalBytes == 15 })
    #expect(samples.contains { $0.bytes == 8 && $0.totalBytes == 15 })
    #expect(zip(samples,samples.dropFirst()).allSatisfy { pair in pair.0.bytes <= pair.1.bytes && pair.0.sequence < pair.1.sequence })
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    legacy.removeValue(forKey: "selectionTransfer")
    #expect(try JSONDecoder().decode(CopyMergeBatchReport.self, from: JSONSerialization.data(withJSONObject: legacy)).selectionTransfer == nil)
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(undo.items.count == 3)
    #expect(await CopyEngine.undoCopy(undo, journalDirectory: f.journal).state == "completed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.path) == ["conflict"])
    #expect(try String(contentsOf: f.target.appendingPathComponent("conflict"), encoding: .utf8) == "preserved")
}

@Test func mergeSelectionUnknownSourceKeepsTotalUnknownAndStillCopiesValidSource() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing")
    try Data("one".utf8).write(to: missing)
    let report = await CopyMergeBatch.run(sources: [missing,f.root.appendingPathComponent("absent")], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    #expect(report.items.map(\.state) == ["completed", "failed"])
    #expect(report.selectionTransfer?.bytes == 3 && report.selectionTransfer?.totalBytes == nil)
}

@Test func mergeSelectionPreflightCancellationDoesNotPublishAnyRoot() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing")
    try Data("one".utf8).write(to: missing)
    let cancellation = CopyCancellation()
    let report = await CopyMergeBatch.run(sources: [missing,f.source], destination: f.destination,
        journalDirectory: f.journal, cancellation: cancellation) { update in
        if update.state == "sizing" { cancellation.cancel() }
    }
    #expect(report.state == "cancelled")
    #expect(report.items.allSatisfy { $0.state == "cancelled" })
    #expect(report.selectionTransfer?.bytes == 0)
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("missing").path))
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

@Test func mergeSelectionNewRootConflictCorrectsDenominatorAndPreservesExternalFile() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing"), target = f.destination.appendingPathComponent("missing")
    try Data("one".utf8).write(to: missing)
    let report = await CopyMergeBatch.run(sources: [missing], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.state == "planning" {
            do { try Data("external".utf8).write(to: target) } catch { Issue.record(error) }
        }
    }
    #expect(report.items.first?.state == "conflict")
    #expect(report.selectionTransfer?.bytes == 0 && report.selectionTransfer?.totalBytes == 0)
    #expect(try String(contentsOf: target, encoding: .utf8) == "external")
}

@Test func mergeActionPublicationConflictRetainsAttemptedDataInsteadOfClaimingSuccessfulCopy() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    try Data("original".utf8).write(to: f.source.appendingPathComponent("a"))
    let target = f.target.appendingPathComponent("a")
    let plan = try CopyMergePlanner.plan(source: f.source, target: f.target)
    let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.phase == "committing" {
            do { try Data("external".utf8).write(to: target) } catch { Issue.record(error) }
        }
    }
    #expect(report.items.first?.state == "conflict")
    #expect(report.selectionTransfer?.bytes == 8 && report.selectionTransfer?.totalBytes == 8)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
    #expect(try String(contentsOf: target, encoding: .utf8) == "external")
}

@Test func mergePlannerHonorsCancellationAndRejectsSelfOrDescendantBeforeMutation() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let cancellation = CopyCancellation(); cancellation.cancel()
    #expect(throws: CancellationError.self) { try CopyMergePlanner.plan(source: f.source, target: f.target, cancellation: cancellation) }
    #expect(throws: (any Error).self) { try CopyMergePlanner.plan(source: f.source, target: f.source) }
    let child = f.source.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try CopyMergePlanner.plan(source: f.source, target: child) }
    let report = await CopyMergeBatch.run(sources: [f.source], destination: child,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    #expect(report.items.first?.state == "failed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
}

@Test func mergeSelectionSameNamedRootsStillMergeNestedContentsAndPreserveOverlappingUndoSafely() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let first = f.root.appendingPathComponent("first/shared"), second = f.root.appendingPathComponent("second/shared")
    for folder in [first,second] { try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true) }
    try Data("first".utf8).write(to: first.appendingPathComponent("common"))
    try Data("a".utf8).write(to: first.appendingPathComponent("sub/a"))
    try Data("second".utf8).write(to: second.appendingPathComponent("common"))
    try Data("bb".utf8).write(to: second.appendingPathComponent("sub/b"))
    let report = await CopyMergeBatch.run(sources: [first,second], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    let target = f.destination.appendingPathComponent("shared")
    #expect(report.items.map(\.state) == ["completed", "merged"])
    #expect(try String(contentsOf: target.appendingPathComponent("common"), encoding: .utf8) == "first")
    #expect(try String(contentsOf: target.appendingPathComponent("sub/a"), encoding: .utf8) == "a")
    #expect(try String(contentsOf: target.appendingPathComponent("sub/b"), encoding: .utf8) == "bb")
    #expect(report.selectionTransfer?.bytes == 8 && report.selectionTransfer?.totalBytes == 8)
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    let result = await CopyEngine.undoCopy(undo, journalDirectory: f.journal)
    // Known existing limitation: nested undo changes the ancestor's date; strict metadata checks preserve it.
    #expect(result.state == "partiallyCompleted")
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("sub/b").path))
    #expect(try String(contentsOf: target.appendingPathComponent("sub/a"), encoding: .utf8) == "a")
}

@Test func mergeSelectionPreparedFutureSourceMutationRejectsPublication() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing"), later = f.source.appendingPathComponent("later")
    try Data("one".utf8).write(to: missing)
    try Data("first".utf8).write(to: later)
    let report = await CopyMergeBatch.run(sources: [missing,f.source], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.index == 0 && (update.liveTransfer?.bytes ?? 0) > 0 {
            do { try Data("other".utf8).write(to: later) } catch { Issue.record(error) }
        }
    }
    #expect(report.items.map(\.state) == ["completed", "failed"])
    #expect(!FileManager.default.fileExists(atPath: f.target.appendingPathComponent("later").path))
    #expect(report.selectionTransfer?.bytes == 8 && report.selectionTransfer?.totalBytes == 8)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal)?.items.count == 1)
}

@Test func mergeSelectionDestinationReplacementAfterPreparationRejectsWrites() async throws {
    let f = try MergeSelectionFixture(); defer { f.clean() }
    let missing = f.root.appendingPathComponent("missing")
    try Data("one".utf8).write(to: missing)
    let displaced = f.root.appendingPathComponent("original-destination")
    let report = await CopyMergeBatch.run(sources: [missing], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.state == "planning" {
            do {
                try FileManager.default.moveItem(at: f.destination, to: displaced)
                try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: true)
                try Data("external".utf8).write(to: f.destination.appendingPathComponent("keep"))
            } catch { Issue.record(error) }
        }
    }
    #expect(report.items.first?.state == "failed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path) == ["keep"])
    #expect(!FileManager.default.fileExists(atPath: displaced.appendingPathComponent("missing").path))
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

private final class MergeSelectionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CopyMergeBatchProgress] = []
    func append(_ event: CopyMergeBatchProgress) { lock.withLock { storage.append(event) } }
    var values: [CopyMergeBatchProgress] { lock.withLock { storage } }
}
private struct MergeSelectionFixture {
    let root: URL, source: URL, destination: URL, target: URL, journal: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-selection-\(UUID())")
        source = root.appendingPathComponent("source/folder"); destination = root.appendingPathComponent("destination")
        target = destination.appendingPathComponent("folder"); journal = root.appendingPathComponent("journals")
        for url in [source,target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
