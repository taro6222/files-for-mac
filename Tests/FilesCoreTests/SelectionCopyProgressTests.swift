import Foundation
import Testing
@testable import FilesCore

@Test func selectionCopyTotalsCombineRootsExcludeSkippedConflictAndRetainUndoAndLegacyDecoding() async throws {
    let f = try SelectionCopyFixture(); defer { f.clean() }
    let first = f.source.appendingPathComponent("first")
    try Data(repeating: 1, count: 11).write(to: first)
    let folder = f.source.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 8192).write(to: folder.appendingPathComponent("data"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "data")
    let skipped = f.source.appendingPathComponent("skip")
    try Data(repeating: 3, count: 65536).write(to: skipped)
    try Data("preserved".utf8).write(to: f.output.appendingPathComponent("skip"))
    let events = SelectionEvents()
    let report = await CopyEngine.run(sources: [first, folder, skipped], destination: f.output,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { events.append($0) }
    #expect(report.items.map(\.state) == ["completed", "completed", "conflict"])
    #expect(report.selectionTransfer?.bytes == 8203)
    #expect(report.selectionTransfer?.totalBytes == 8203)
    #expect(events.values.contains { $0.index == 0 && $0.liveTransfer?.bytes == 11 && $0.selectionTransfer?.bytes == 11 && $0.selectionTransfer?.totalBytes == 8203 })
    #expect(events.values.contains { $0.index == 1 && $0.liveTransfer?.bytes == 8192 && $0.selectionTransfer?.bytes == 8203 })
    let samples = events.values.compactMap(\.selectionTransfer)
    #expect(zip(samples,samples.dropFirst()).allSatisfy { pair in pair.0.sequence < pair.1.sequence && pair.0.bytes <= pair.1.bytes })
    #expect(try String(contentsOf: f.output.appendingPathComponent("skip"), encoding: .utf8) == "preserved")
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    legacy.removeValue(forKey: "selectionTransfer")
    #expect(try JSONDecoder().decode(CopyReport.self, from: JSONSerialization.data(withJSONObject: legacy)).selectionTransfer == nil)
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(undo.items.count == 2)
    #expect(await CopyEngine.undoCopy(undo, journalDirectory: f.journal).state == "completed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.output.path) == ["skip"])
}

@Test func selectionCopyRejectsFutureRootChangedAfterPreflight() async throws {
    let f = try SelectionCopyFixture(); defer { f.clean() }
    let first = f.source.appendingPathComponent("first"), second = f.source.appendingPathComponent("second")
    try Data("first".utf8).write(to: first); try Data("original".utf8).write(to: second)
    let report = await CopyEngine.run(sources: [first,second], destination: f.output,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        if update.index == 0 && (update.liveTransfer?.bytes ?? 0) > 0 {
            do { try Data("modified".utf8).write(to: second) } catch { Issue.record(error) }
        }
    }
    #expect(report.state == "partiallyCompleted")
    #expect(report.items.map(\.state) == ["completed", "failed"])
    #expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("second").path))
    // Staged data is not a success percentage: the second attempt was copied but rejected by verification.
    #expect(report.selectionTransfer?.bytes == 13)
    #expect(report.selectionTransfer?.totalBytes == 13)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal)?.items.count == 1)
}

@Test func selectionCopyUnknownRootDoesNotInventATotalOrPreventOtherCopy() async throws {
    let f = try SelectionCopyFixture(); defer { f.clean() }
    let first = f.source.appendingPathComponent("first")
    try Data("first".utf8).write(to: first)
    let report = await CopyEngine.run(sources: [first,f.source.appendingPathComponent("absent")], destination: f.output,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    #expect(report.items.map(\.state) == ["completed", "failed"])
    #expect(report.selectionTransfer?.bytes == 5)
    #expect(report.selectionTransfer?.totalBytes == nil)
}

@Test func selectionCopyPreflightCancellationPublishesNothing() async throws {
    let f = try SelectionCopyFixture(); defer { f.clean() }
    let first = f.source.appendingPathComponent("first")
    try Data("first".utf8).write(to: first)
    let cancellation = CopyCancellation()
    let report = await CopyEngine.run(sources: [first], destination: f.output,
        journalDirectory: f.journal, cancellation: cancellation) { update in
        if update.phase == "sizing" { cancellation.cancel() }
    }
    #expect(report.state == "cancelled")
    #expect(report.selectionTransfer?.bytes == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

@Test func selectionCopyCorrectsDenominatorWhenDestinationAppearsAfterPreflight() async throws {
    let f = try SelectionCopyFixture(); defer { f.clean() }
    let first = f.source.appendingPathComponent("first"), target = f.output.appendingPathComponent("first")
    try Data("first".utf8).write(to: first)
    let events = SelectionEvents()
    let report = await CopyEngine.run(sources: [first], destination: f.output,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        events.append(update)
        if update.phase == "planning" && update.selectionTransfer?.totalBytes == 5 {
            do { try Data("external".utf8).write(to: target) } catch { Issue.record(error) }
        }
    }
    #expect(report.items.first?.state == "conflict")
    #expect(report.selectionTransfer?.bytes == 0 && report.selectionTransfer?.totalBytes == 0)
    #expect(try String(contentsOf: target, encoding: .utf8) == "external")
    let plans = events.values.compactMap(\.selectionTransfer)
    #expect(plans.first?.totalBytes == 5 && plans.last?.totalBytes == 0)
    #expect(try #require(plans.first).sequence < #require(plans.last).sequence)
}

private final class SelectionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CopyProgress] = []
    func append(_ event: CopyProgress) { lock.withLock { storage.append(event) } }
    var values: [CopyProgress] { lock.withLock { storage } }
}
private struct SelectionCopyFixture {
    let root: URL, source: URL, output: URL, journal: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-copy-\(UUID())")
        source = root.appendingPathComponent("source"); output = root.appendingPathComponent("output"); journal = root.appendingPathComponent("journals")
        for path in [source,output] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
