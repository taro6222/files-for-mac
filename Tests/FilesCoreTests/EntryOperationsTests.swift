import Foundation
import Testing
@testable import FilesCore

private func entryFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-entry-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func entryNamesRejectTraversalAndAllowUnicode() throws {
    for name in ["", " ", ".", "..", "a/b", "a:b", "a\0b"] {
        #expect(throws: EntryOperationError.self) { try EntryOperations.validateName(name) }
    }
    try EntryOperations.validateName("한글 폴더")
    try EntryOperations.validateName(".hidden")
}

@Test func createFolderAndRenamePreserveContentsAndJournal() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let created = try await EntryOperations.createFolder(in: root, name: "새 폴더", journalDirectory: journal)
    try Data("bytes".utf8).write(to: created.target.appendingPathComponent("file"))
    let renamed = try await EntryOperations.rename(created.target, to: "완료", journalDirectory: journal)
    #expect(try String(contentsOf: renamed.target.appendingPathComponent("file"), encoding: .utf8) == "bytes")
    #expect(!FileManager.default.fileExists(atPath: created.target.path))
    #expect(renamed.journalWarning == nil)
    let records = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
    #expect(records.count == 2)
    for url in records {
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(data["state"] as? String == "completed")
    }
}

@Test func entryConflictsNeverReplaceBrokenLinkOrFile() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    try Data("source".utf8).write(to: a)
    try FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: "missing")
    await #expect(throws: EntryOperationError.self) { try await EntryOperations.createFolder(in: root, name: "b", journalDirectory: journal) }
    await #expect(throws: EntryOperationError.self) { try await EntryOperations.rename(a, to: "b", journalDirectory: journal) }
    #expect(try String(contentsOf: a, encoding: .utf8) == "source")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.path) == "missing")
}

@Test func entryRenameRejectsChangedIdentityAndRenamesLinkItself() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
    await #expect(throws: EntryOperationError.self) {
        try await EntryOperations.rename(link, to: "new", expectedIdentity: "stale", journalDirectory: journal)
    }
    let result = try await EntryOperations.rename(link, to: "new", journalDirectory: journal)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: result.target.path) == "missing")
}

@Test func entryJournalFailurePreventsMutation() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    try Data().write(to: journal)
    await #expect(throws: (any Error).self) { try await EntryOperations.createFolder(in: root, name: "new", journalDirectory: journal) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
}

@Test func entryTrashMovesAndReportsPerItem() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let sourceFile = root.appendingPathComponent("source.txt")
    let sourceFolder = root.appendingPathComponent("src")
    try Data("move".utf8).write(to: sourceFile)
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try Data("inner".utf8).write(to: sourceFolder.appendingPathComponent("inner.txt"))
    let missing = root.appendingPathComponent("missing.txt")
    let report = try await EntryOperations.moveToTrash([sourceFile, sourceFolder, missing], journalDirectory: journal)
    #expect(report.state == "partial")
    #expect(report.items.count == 3)
    #expect(report.items[0].state == "completed" || report.items[0].state == "failed")
    #expect(report.items[1].state == "completed" || report.items[1].state == "failed")
    #expect(report.items[2].state == "notFound")
    let journalRecords = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
    #expect(journalRecords.count == 1)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: journalRecords[0])) as! [String: Any]
    #expect(raw["operation"] as? String == "moveToTrash")
    #expect(raw["state"] as? String == "partial")
}

@Test func entryRestoreFromTrashMovesItemsBack() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let source = root.appendingPathComponent("source.txt")
    let restored = root.appendingPathComponent("restore-target")
    try Data("restore".utf8).write(to: source)
    try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
    let trash = try await EntryOperations.moveToTrash([source], journalDirectory: journal)
    let trashed = trash.items.compactMap { $0.trashed }
    #expect(trashed.count == 1)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let result = try await EntryOperations.restoreFromTrash([trashed[0]], to: restored, journalDirectory: journal)
    #expect(result.state == "completed")
    #expect(result.items.count == 1)
    #expect(result.items[0].state == "completed")
    #expect(result.items[0].target.deletingLastPathComponent().path == restored.path)
    #expect(FileManager.default.fileExists(atPath: result.items[0].target.path))
}

@Test func entryRestoreFailsOutsideTrash() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let source = root.appendingPathComponent("not-trashed.txt")
    try Data("noop".utf8).write(to: source)
    let result = try await EntryOperations.restoreFromTrash([source], to: root, journalDirectory: journal)
    #expect(result.state == "partial")
    #expect(result.items[0].state == "failed")
    #expect(result.items[0].message != nil)
}

@Test func entryPermanentDeleteRemovesExistingItemsAndReportsState() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let sourceFile = root.appendingPathComponent("to-delete.txt")
    let sourceFolder = root.appendingPathComponent("to-delete-folder")
    try Data("delete".utf8).write(to: sourceFile)
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: sourceFolder.appendingPathComponent("inside.txt"))
    let result = try await EntryOperations.permanentlyDelete([sourceFile, sourceFolder], journalDirectory: journal)
    #expect(result.state == "completed")
    #expect(!FileManager.default.fileExists(atPath: sourceFile.path))
    #expect(!FileManager.default.fileExists(atPath: sourceFolder.path))
    #expect(result.items.allSatisfy { $0.state == "completed" })
}

@Test func entryPermanentDeleteTracksMissingAndFailed() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let source = root.appendingPathComponent("to-delete.txt")
    let missing = root.appendingPathComponent("not-exists.txt")
    try Data("delete".utf8).write(to: source)
    let result = try await EntryOperations.permanentlyDelete([source, missing], journalDirectory: journal)
    #expect(result.state == "partial")
    #expect(result.items.count == 2)
    #expect(result.items[0].state == "completed")
    #expect(result.items[1].state == "notFound")
    #expect(result.items[1].message != nil)
}

@Test func entryMoveMovesItemsIntoDestination() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("move".utf8).write(to: source)
    let report = try await EntryOperations.move([source], to: destination, conflictPolicy: .skip, journalDirectory: journal)
    let movedPath = destination.appendingPathComponent("move.txt")
    #expect(report.state == "completed")
    #expect(report.items.count == 1)
    #expect(report.items[0].state == "completed")
    #expect(report.items[0].target == movedPath)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: movedPath.path))
}

@Test func entryMoveSkipsConflicts() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("move".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination.appendingPathComponent("move.txt"))
    let report = try await EntryOperations.move([source], to: destination, conflictPolicy: .skip, journalDirectory: journal)
    #expect(report.state == "partial")
    #expect(report.items.count == 1)
    #expect(report.items[0].state == "conflict")
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("move.txt").path))
}

@Test func entryMoveUndoRestoresOriginalLocation() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("move".utf8).write(to: source)
    _ = try await EntryOperations.move([source], to: destination, conflictPolicy: .skip, journalDirectory: journal)
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.state == "completed")
    #expect(undo.items[0].state == "completed")
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("move.txt").path))
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
}

@Test func entryMoveUndoRejectsExternallyChangedTarget() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("move".utf8).write(to: source)
    _ = try await EntryOperations.move([source], to: destination, conflictPolicy: .skip, journalDirectory: journal)
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    try Data(" changed".utf8).append(to: target)
    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.state == "partial")
    #expect(undo.items[0].state == "changed")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: target, encoding: .utf8) == "move changed")
}

@Test func entryMoveReplaceDoesNotOfferUnsafeUndo() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: destination.appendingPathComponent("move.txt"))
    _ = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
}

@Test func entryCrossVolumeMoveCopiesVerifiesThenRemovesSource() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("contents".utf8).write(to: source.appendingPathComponent("file.txt"))
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "file.txt")
    let report = try await EntryOperations.moveAcrossVolumeForTesting(
        [source], to: destination, journalDirectory: journal)
    let target = destination.appendingPathComponent("folder")
    #expect(report.state == "completed")
    #expect(report.items[0].state == "completed")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: target.appendingPathComponent("file.txt"), encoding: .utf8) == "contents")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path) == "file.txt")
    #expect((try FileManager.default.contentsOfDirectory(atPath: destination.path)).allSatisfy { !$0.hasPrefix(".files-move-") })
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
}

@Test func entryCrossVolumeMoveConflictPreservesSourceAndTarget() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    try Data("target".utf8).write(to: target)
    let report = try await EntryOperations.moveAcrossVolumeForTesting(
        [source], to: destination, conflictPolicy: .skip, journalDirectory: journal)
    #expect(report.state == "partial")
    #expect(report.items[0].state == "conflict")
    #expect(try String(contentsOf: source, encoding: .utf8) == "source")
    #expect(try String(contentsOf: target, encoding: .utf8) == "target")
}

@Test func entryCrossVolumeReplaceWaitsForBackupSupport() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    try Data("target".utf8).write(to: target)
    let report = try await EntryOperations.moveAcrossVolumeForTesting(
        [source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    #expect(report.state == "partial")
    #expect(report.items[0].state == "failed")
    #expect(try String(contentsOf: source, encoding: .utf8) == "source")
    #expect(try String(contentsOf: target, encoding: .utf8) == "target")
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
