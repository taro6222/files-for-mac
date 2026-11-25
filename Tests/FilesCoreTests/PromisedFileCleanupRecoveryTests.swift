import Foundation
import Testing
@testable import FilesCore

private struct CleanupRecoveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-restart-\(UUID())")
    let storage: URL
    let journals: URL
    let intake: PromisedFileIntake
    let journal: URL
    init() throws {
        storage = root.appendingPathComponent("intakes"); journals = root.appendingPathComponent("operations")
        intake = try PromisedFileIntake(storageDirectory: storage)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        journal = journals.appendingPathComponent("promise-cleanup-\(UUID()).json")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func save(state: String = "verified", location: URL? = nil, legacy: Bool = false) throws {
        var result = PromisedFileCleanupResult(original: intake.directoryURL, retainedAt: location ?? intake.directoryURL,
                                              state: state, message: nil, journal: journal)
        if !legacy { result.directoryIdentity = LocalEntryIdentity.read(intake.directoryURL) }
        try JSONEncoder().encode(result).write(to: journal, options: .atomic)
    }
    func discover() throws -> [PromisedFileCleanupRecovery] {
        try PromisedFileCleanupRecovery.discover(in: journals, storage: storage)
    }
}

@Test func promisedCleanupRestartFindsOriginalWithoutMovingOrChangingJournal() throws {
    let f = try CleanupRecoveryFixture(); defer { f.remove() }; try f.save()
    let payload = f.intake.receivingDirectory.appendingPathComponent("retained.txt")
    try Data("original retained payload".utf8).write(to: payload); try f.intake.registerReceivedFile(payload)
    let bytes = try Data(contentsOf: f.journal)
    let rows = try f.discover(); let row = try #require(rows.first)
    #expect(rows.count == 1 && row.status == .atOriginal && row.recordedState == "verified")
    #expect(row.location == f.intake.directoryURL)
    #expect(row.receivedNames == ["retained.txt"])
    #expect(try Data(contentsOf: payload) == Data("original retained payload".utf8))
    #expect(try Data(contentsOf: f.journal) == bytes)
    #expect(FileManager.default.fileExists(atPath: f.intake.directoryURL.path))
}

@Test func promisedCleanupRestartFindsRecordedMovedDirectoryAndRefusesReplacement() throws {
    let f = try CleanupRecoveryFixture(); defer { f.remove() }
    let moved = f.root.appendingPathComponent("fixture-trash"); try f.save(state: "movedToTrash", location: moved)
    try FileManager.default.moveItem(at: f.intake.directoryURL, to: moved)
    let row = try #require(try f.discover().first)
    #expect(row.status == .retainedElsewhere && row.location == moved && row.recordedState == "movedToTrash")
    let elsewhere = f.root.appendingPathComponent("preserved-original")
    try FileManager.default.moveItem(at: moved, to: elsewhere)
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    try Data("replacement must remain".utf8).write(to: moved.appendingPathComponent("foreign.txt"))
    let unknown = try #require(try f.discover().first)
    #expect(unknown.status == .unlocated && unknown.location == nil)
    #expect(try Data(contentsOf: moved.appendingPathComponent("foreign.txt")) == Data("replacement must remain".utf8))
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
}

@Test func promisedCleanupRestartDoesNotGuessTrashWhenMoveWasNotJournaled() throws {
    let f = try CleanupRecoveryFixture(); defer { f.remove() }; try f.save()
    let moved = f.root.appendingPathComponent("unknown-trash-location")
    try FileManager.default.moveItem(at: f.intake.directoryURL, to: moved)
    let row = try #require(try f.discover().first)
    #expect(row.status == .unlocated && row.location == nil)
    #expect(FileManager.default.fileExists(atPath: moved.path))
}

@Test func promisedCleanupRestartPreservesLegacyDamagedAndUnrelatedRecords() throws {
    let f = try CleanupRecoveryFixture(); defer { f.remove() }; try f.save(state: "retained", legacy: true)
    let legacy = try #require(try f.discover().first)
    #expect(legacy.status == .legacy && legacy.location == nil)
    try Data("broken json".utf8).write(to: f.journal)
    let unrelated = f.journals.appendingPathComponent("copy-operation.json")
    try Data("untouched".utf8).write(to: unrelated)
    let rows = try f.discover()
    #expect(rows.count == 1 && rows.first?.status == .invalid && rows.first?.location == nil)
    #expect(try Data(contentsOf: f.journal) == Data("broken json".utf8))
    #expect(try Data(contentsOf: unrelated) == Data("untouched".utf8))
}

@Test func promisedCleanupRestartRejectsJournalAndPayloadSymlinks() throws {
    let f = try CleanupRecoveryFixture(); defer { f.remove() }; try f.save()
    let source = f.root.appendingPathComponent("external-record.json")
    try FileManager.default.moveItem(at: f.journal, to: source)
    try FileManager.default.createSymbolicLink(at: f.journal, withDestinationURL: source)
    #expect(try f.discover().first?.status == .invalid)
    try FileManager.default.removeItem(at: f.journal); try f.save()
    let moved = f.root.appendingPathComponent("outside")
    try FileManager.default.moveItem(at: f.intake.directoryURL, to: moved)
    try FileManager.default.createSymbolicLink(at: f.intake.directoryURL, withDestinationURL: moved)
    #expect(try f.discover().first?.status == .unlocated)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func promisedCleanupRestartRejectsForeignStorageTamperedReceiptAndOversizedJournal() throws {
    let f = try CleanupRecoveryFixture(); defer { f.remove() }; try f.save()
    let foreign = try PromisedFileCleanupRecovery.discover(in: f.journals, storage: f.root.appendingPathComponent("different"))
    #expect(foreign.first?.status == .invalid)
    try Data("invalid receipt".utf8).write(to: f.intake.directoryURL.appendingPathComponent("receipt.json"))
    #expect(try f.discover().first?.status == .unlocated)
    try Data(repeating: 32, count: 1_048_577).write(to: f.journal)
    #expect(try f.discover().first?.status == .invalid)
    #expect(try Data(contentsOf: f.journal).count == 1_048_577)
}
