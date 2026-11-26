import Foundation
import Testing
@testable import FilesCore

private final class MoveSelectionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MoveProgress] = []
    func add(_ value: MoveProgress) { lock.withLock { stored.append(value) } }
    var values: [MoveProgress] { lock.withLock { stored } }
}
private struct MoveSelectionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-selection-\(UUID())")
    var destination: URL { root.appendingPathComponent("target") }
    var journal: URL { root.appendingPathComponent("journal") }
    var sources: [URL] { [root.appendingPathComponent("first"), root.appendingPathComponent("second")] }
    init() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(repeating: 31, count: 32768).write(to: sources[0])
        try Data(repeating: 47, count: 65536).write(to: sources[1])
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func moveSelectionTotalsExcludeConflictsPersistFinalAndRoundTripUndo() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let skip = f.root.appendingPathComponent("skip")
    try Data("keep-source".utf8).write(to: skip)
    try Data("keep-target".utf8).write(to: f.destination.appendingPathComponent("skip"))
    let events = MoveSelectionEvents()
    let report = try await EntryOperations.moveAcrossVolumeForTesting(f.sources + [skip], to: f.destination,
        journalDirectory: f.journal) { events.add($0) }
    #expect(report.state == "partial" && report.items.map(\.state) == ["completed", "completed", "conflict"])
    let first = try #require(events.values.first { $0.selectionTransfer != nil }?.selectionTransfer)
    #expect(first.bytes == 0 && first.totalBytes == 98304)
    let final = try #require(report.selectionTransfer)
    #expect(final.bytes == 98304 && final.totalBytes == 98304)
    let samples = events.values.compactMap(\.selectionTransfer)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.bytes <= $1.bytes && $0.sequence < $1.sequence })
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal.appendingPathComponent("move-\(report.id).json"))) as? [String: Any])
    let stored = try #require(json["selectionTransfer"] as? [String: Any])
    #expect(stored["bytes"] as? Int == 98304 && stored["totalBytes"] as? Int == 98304)
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: f.journal))
    #expect(await EntryOperations.undoMove(undo, journalDirectory: f.journal).state == "completed")
    #expect(try Data(contentsOf: f.sources[0]) == Data(repeating: 31, count: 32768))
    #expect(try Data(contentsOf: f.sources[1]) == Data(repeating: 47, count: 65536))
    #expect(try String(contentsOf: skip, encoding: .utf8) == "keep-source")
    #expect(try String(contentsOf: f.destination.appendingPathComponent("skip"), encoding: .utf8) == "keep-target")
}

@Test func moveSelectionSameVolumeRenameHasNoStagedBytes() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let events = MoveSelectionEvents()
    let report = try await EntryOperations.move(f.sources, to: f.destination, journalDirectory: f.journal) { events.add($0) }
    #expect(report.state == "completed")
    #expect(report.selectionTransfer?.bytes == 0 && report.selectionTransfer?.totalBytes == 0)
    #expect(events.values.allSatisfy { $0.liveTransfer == nil && $0.phase != "copying" })
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: f.journal))
    #expect(await EntryOperations.undoMove(undo, journalDirectory: f.journal).state == "completed")
}

@Test func moveSelectionCancellationKeepsUnfinishedSourceAndTotals() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let cancellation = CopyCancellation()
    let report = try await EntryOperations.moveAcrossVolumeForTesting(f.sources, to: f.destination,
        journalDirectory: f.journal, cancellation: cancellation) { update in
        if update.index == 1 && (update.liveTransfer?.bytes ?? 0) > 0 { cancellation.cancel() }
    }
    #expect(report.state == "cancelled" && report.items.map(\.state) == ["completed", "cancelled"])
    #expect(report.selectionTransfer?.bytes == 98304 && report.selectionTransfer?.totalBytes == 98304)
    #expect(try Data(contentsOf: f.sources[1]) == Data(repeating: 47, count: 65536))
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("second").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).allSatisfy { !$0.hasPrefix(".files-move-") })
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: f.journal))
    #expect(await EntryOperations.undoMove(undo, journalDirectory: f.journal).state == "completed")
    #expect(FileManager.default.fileExists(atPath: f.sources[0].path))
}

@Test func moveSelectionRejectsLaterSourceChangedAfterSizing() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let report = try await EntryOperations.moveAcrossVolumeForTesting(f.sources, to: f.destination,
        journalDirectory: f.journal) { update in
        if update.index == 0 && update.phase == "planning" {
            try? Data("outside-change".utf8).write(to: f.sources[1], options: .atomic)
        }
    }
    #expect(report.items.map(\.state) == ["completed", "failed"])
    #expect(report.selectionTransfer?.bytes == 32768 && report.selectionTransfer?.totalBytes == 98304)
    #expect(try String(contentsOf: f.sources[1], encoding: .utf8) == "outside-change")
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("second").path))
}

@Test func moveSelectionSizingCancellationDoesNotMoveAnySource() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let cancellation = CopyCancellation()
    let report = try await EntryOperations.moveAcrossVolumeForTesting(f.sources, to: f.destination,
        journalDirectory: f.journal, cancellation: cancellation) { update in
        if update.phase == "sizing" { cancellation.cancel() }
    }
    #expect(report.state == "cancelled" && report.items.allSatisfy { $0.state == "cancelled" })
    #expect(report.selectionTransfer?.bytes == 0 && report.selectionTransfer?.totalBytes == nil)
    #expect(f.sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
}

@Test func moveSelectionFullStagingDoesNotImplyPublicationSuccess() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let report = try await EntryOperations.moveAcrossVolumeForTesting([f.sources[0]], to: f.destination,
        journalDirectory: f.journal) { update in
        if update.phase == "committing" { try? Data("external".utf8).write(to: f.destination.appendingPathComponent("first")) }
    }
    #expect(report.state == "partial" && report.items.first?.state == "conflict")
    #expect(report.selectionTransfer?.bytes == 32768 && report.selectionTransfer?.totalBytes == 32768)
    #expect(try Data(contentsOf: f.sources[0]) == Data(repeating: 31, count: 32768))
    #expect(try String(contentsOf: f.destination.appendingPathComponent("first"), encoding: .utf8) == "external")
    #expect(EntryOperations.latestUndoMove(journalDirectory: f.journal) == nil)
}

@Test func moveSelectionRejectsSelfDescendantBeforeStaging() async throws {
    let f = try MoveSelectionFixture(); defer { f.clean() }
    let source = f.root.appendingPathComponent("folder")
    let destination = source.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let file = source.appendingPathComponent("original")
    try Data("preserve".utf8).write(to: file)
    let report = try await EntryOperations.moveAcrossVolumeForTesting([source], to: destination, journalDirectory: f.journal)
    #expect(report.items.first?.state == "failed")
    #expect(report.selectionTransfer?.bytes == 0 && report.selectionTransfer?.totalBytes == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == "preserve")
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}
