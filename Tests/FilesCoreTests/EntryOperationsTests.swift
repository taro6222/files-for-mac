import Foundation
import Darwin
import Testing

@Test func flattenMovesNestedEntriesWithoutReplacingAndSupportsUndo() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("root")
    let child = root.appendingPathComponent("child")
    let journals = temporary.appendingPathComponent("journals")
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: root.appendingPathComponent("conflict.txt"))
    try Data("nested".utf8).write(to: child.appendingPathComponent("conflict.txt"))
    try Data("move".utf8).write(to: child.appendingPathComponent("unique.txt"))
    try fm.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: root)
    let plan = try await FolderFlattenPlan.make(for: root)
    #expect(plan.sources.map(\.lastPathComponent) == ["conflict.txt", "loop", "unique.txt"])
    let report = try await EntryOperations.flatten(plan, journalDirectory: journals)
    #expect(report.items.map(\.state) == ["conflict", "completed", "completed"])
    #expect(try Data(contentsOf: root.appendingPathComponent("conflict.txt")) == Data("keep".utf8))
    #expect(try Data(contentsOf: child.appendingPathComponent("conflict.txt")) == Data("nested".utf8))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("unique.txt").path))
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journals))
    let undo = await EntryOperations.undoMove(record, journalDirectory: journals)
    #expect(undo.state == "completed")
    #expect(fm.fileExists(atPath: child.appendingPathComponent("unique.txt").path))
}

@Test func flattenRejectsReplacedSources() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("root")
    let child = root.appendingPathComponent("child")
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    let file = child.appendingPathComponent("file")
    try Data("original".utf8).write(to: file)
    let plan = try await FolderFlattenPlan.make(for: root)
    try fm.moveItem(at: file, to: temporary.appendingPathComponent("original"))
    try Data("replacement".utf8).write(to: file)
    let report = try await EntryOperations.flatten(plan, journalDirectory: temporary.appendingPathComponent("journals"))
    #expect(report.items.first?.state == "failed")
    #expect(try Data(contentsOf: file) == Data("replacement".utf8))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("file").path))
}
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

@Test func createFileIsEmptyJournaledAndNeverReplaces() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let journal = root.appendingPathComponent("journal")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try await EntryOperations.createFile(in: root, name: "새 문서.txt", journalDirectory: journal)
    #expect((try Data(contentsOf: result.target)).isEmpty)
    #expect(result.journalWarning == nil)
    try Data("keep".utf8).write(to: result.target)
    await #expect(throws: EntryOperationError.self) {
        try await EntryOperations.createFile(in: root, name: "새 문서.txt", journalDirectory: journal)
    }
    #expect(try String(contentsOf: result.target, encoding: .utf8) == "keep")
}

@Test func createSymbolicLinkUsesRelativeTargetAndNeverReplaces() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("원본.txt")
    try Data("bytes".utf8).write(to: source)
    let link = try await EntryOperations.createSymbolicLink(to: source, in: root, name: "바로가기.txt")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == source.lastPathComponent)
    #expect(try String(contentsOf: link, encoding: .utf8) == "bytes")
    await #expect(throws: EntryOperationError.self) {
        try await EntryOperations.createSymbolicLink(to: source, in: root, name: "바로가기.txt")
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == source.lastPathComponent)
}

@Test func createSymbolicLinkRejectsInvalidNameAndMissingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: EntryOperationError.self) {
        try await EntryOperations.createSymbolicLink(to: root.appendingPathComponent("missing"), in: root, name: "link")
    }
    await #expect(throws: EntryOperationError.self) {
        try await EntryOperations.createSymbolicLink(to: root, in: root, name: "../link")
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
    let items = try await LocalFileSystem().contents(of: root, showHidden: true)
    let linkIdentity = try #require(items.first(where: { $0.url == link })?.identity)
    await #expect(throws: EntryOperationError.self) {
        try await EntryOperations.rename(link, to: "new", expectedIdentity: "stale", journalDirectory: journal)
    }
    let result = try await EntryOperations.rename(link, to: "new", expectedIdentity: linkIdentity, journalDirectory: journal)
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

@Test func entryMoveReplaceBackupAllowsSafeUndo() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: destination.appendingPathComponent("move.txt"))
    _ = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(record.items[0].backup != nil)
    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.state == "completed")
    #expect(try String(contentsOf: source, encoding: .utf8) == "new")
    #expect(try String(contentsOf: destination.appendingPathComponent("move.txt"), encoding: .utf8) == "old")
}

@Test(arguments: [false, true], [false, true])
func entryMoveUndoPreservesEditsInsideMovedOrBackedUpFolder(crossVolume: Bool, editBackup: Bool) async throws {
    let root = try entryFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("folder")
    let target = destination.appendingPathComponent("folder")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source.appendingPathComponent("child"))
    try Data("old".utf8).write(to: target.appendingPathComponent("child"))

    let move: MoveOperationResult
    if crossVolume {
        move = try await EntryOperations.moveAcrossVolumeForTesting([source], to: destination,
            conflictPolicy: .replace, journalDirectory: journal)
    } else {
        move = try await EntryOperations.move([source], to: destination,
            conflictPolicy: .replace, journalDirectory: journal)
    }
    #expect(move.state == "completed")
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let backup = try #require(record.items.first?.backup)
    let edited = (editBackup ? backup : target).appendingPathComponent("child")
    try Data("edited".utf8).write(to: edited)

    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.items.map(\.state) == ["changed"])
    #expect(!fm.fileExists(atPath: source.path))
    #expect(try String(contentsOf: edited, encoding: .utf8) == "edited")
    #expect(try String(contentsOf: (editBackup ? target : backup).appendingPathComponent("child"), encoding: .utf8)
        == (editBackup ? "new" : "old"))
}

@Test func entrySameVolumeMoveWithFIFOCompletesWithoutUncheckedUndo() async throws {
    let root = try entryFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let source = root.appendingPathComponent("folder")
    let destination = root.appendingPathComponent("dest")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    #expect(mkfifo(source.appendingPathComponent("pipe").path, 0o600) == 0)

    let move = try await EntryOperations.move([source], to: destination, journalDirectory: journal)
    #expect(move.items.map(\.state) == ["completed"])
    #expect(move.items.first?.message != nil)
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
    let moved = destination.appendingPathComponent("folder/pipe")
    var info = stat()
    #expect(lstat(moved.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO)
}

@Test func entryMoveUndoPreservesChangedReplacementBackup() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: target)
    _ = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let backup = try #require(record.items[0].backup)
    try Data(" changed".utf8).append(to: backup)
    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.state == "partial")
    #expect(undo.items[0].state == "changed")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    #expect(try String(contentsOf: backup, encoding: .utf8) == "old changed")
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal)?.items.count == 1)
}

@Test func entryMoveUndoRetriesOnlyPendingBackupRestoration() async throws {
    let root = try entryFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: target)
    let move = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    #expect(move.state == "completed")
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let item = try #require(record.items.first)
    let backup = try #require(item.backup)
    let partial = await EntryOperations.undoMove(record, journalDirectory: journal) { path in
        let checkpoint = EntryOperations.latestUndoMove(journalDirectory: journal)
        #expect(checkpoint?.items.first?.backupRestorePending == true)
        do { try Data("external".utf8).write(to: path, options: .withoutOverwriting) }
        catch { Issue.record(error) }
    }
    #expect(partial.state == "partial")
    #expect(partial.items.map(\.state) == ["conflict"])
    #expect(partial.journalError == nil)
    #expect(try String(contentsOf: source, encoding: .utf8) == "new")

    let retry = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(retry.items.first?.backupRestorePending == true)
    let blocked = await EntryOperations.undoMove(retry, journalDirectory: journal)
    #expect(blocked.items.map(\.state) == ["conflict"])
    #expect(try String(contentsOf: target, encoding: .utf8) == "external")
    #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
    try fm.removeItem(at: target)

    let remaining = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let completed = await EntryOperations.undoMove(remaining, journalDirectory: journal)
    #expect(completed.state == "completed")
    #expect(completed.journalError == nil)
    #expect(try String(contentsOf: source, encoding: .utf8) == "new")
    #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
}

@Test(arguments: [false, true])
func entryMoveUndoRecoversSameVolumeRenameBeforeCheckpoint(occupied: Bool) async throws {
    let root = try entryFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: target)
    let move = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    #expect(move.state == "completed")
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let item = try #require(record.items.first)
    #expect(item.backupRestorePending == nil && !item.crossVolume)
    let backup = try #require(item.backup)

    // Reproduce the filesystem state left by the first rename with the original journal.
    try fm.moveItem(at: target, to: source)
    if occupied {
        try Data("external".utf8).write(to: target)
        let partial = await EntryOperations.undoMove(record, journalDirectory: journal)
        #expect(partial.items.map(\.state) == ["conflict"])
        #expect(try String(contentsOf: target, encoding: .utf8) == "external")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
        try fm.removeItem(at: target)
    }
    let retry = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let result = await EntryOperations.undoMove(retry, journalDirectory: journal)
    #expect(result.state == "completed")
    #expect(result.journalError == nil)
    #expect(try String(contentsOf: source, encoding: .utf8) == "new")
    #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
}

@Test func entryMoveUndoRecognizesBackupPublishedBeforeJournalCompletion() async throws {
    let root = try entryFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent("move.txt")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: source)
    try Data("old".utf8).write(to: target)
    let move = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace, journalDirectory: journal)
    #expect(move.state == "completed")
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let backup = try #require(record.items.first?.backup)

    let interrupted = await EntryOperations.undoMove(record, journalDirectory: journal) { path in
        do { try FileManager.default.moveItem(at: backup, to: path) }
        catch { Issue.record(error) }
    }
    #expect(interrupted.state == "partial")
    let checkpoint = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(checkpoint.items.first?.backupRestorePending == true)
    let resumed = await EntryOperations.undoMove(checkpoint, journalDirectory: journal)
    #expect(resumed.state == "completed")
    #expect(resumed.journalError == nil)
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
    #expect(try String(contentsOf: source, encoding: .utf8) == "new")
    #expect(try String(contentsOf: target, encoding: .utf8) == "old")
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
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(record.items[0].crossVolume)
    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.state == "completed")
    #expect(try String(contentsOf: source.appendingPathComponent("file.txt"), encoding: .utf8) == "contents")
    #expect(!FileManager.default.fileExists(atPath: target.path))
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

@Test func entryCrossVolumeReplaceBacksUpAndRestoresBothItems() async throws {
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
    #expect(report.state == "completed")
    #expect(report.items[0].state == "completed")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: target, encoding: .utf8) == "source")
    let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(record.items[0].crossVolume)
    let undo = await EntryOperations.undoMove(record, journalDirectory: journal)
    #expect(undo.state == "completed")
    #expect(try String(contentsOf: source, encoding: .utf8) == "source")
    #expect(try String(contentsOf: target, encoding: .utf8) == "target")
}

@Test func entryCrossVolumeMoveCancellationPreservesSourceAndCleansStaging() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 1024 * 1024).write(to: source)
    let cancellation = CopyCancellation()
    let report = try await EntryOperations.moveAcrossVolumeForTesting(
        [source], to: destination, journalDirectory: journal, cancellation: cancellation
    ) { update in
        if update.phase == "verifying" { cancellation.cancel() }
    }
    #expect(report.state == "cancelled")
    #expect(report.items[0].state == "cancelled")
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("move.txt").path))
    #expect((try FileManager.default.contentsOfDirectory(atPath: destination.path)).allSatisfy { !$0.hasPrefix(".files-move-") })
}

@Test func entryReplacementCancellationReportsBackupWhenDestinationIsOccupied() async throws {
    let root = try entryFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let destination = root.appendingPathComponent("dest")
    let source = root.appendingPathComponent("move.txt")
    let target = destination.appendingPathComponent(source.lastPathComponent)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    try Data("original target".utf8).write(to: target)
    let cancellation = CopyCancellation()

    let report = try await EntryOperations.moveAcrossVolumeForTesting(
        [source], to: destination, conflictPolicy: .replace, journalDirectory: journal, cancellation: cancellation
    ) { progress in
        if progress.phase == "verifying" {
            try? Data("concurrent target".utf8).write(to: target, options: .withoutOverwriting)
            cancellation.cancel()
        }
    }

    #expect(report.state == "cancelled")
    #expect(try Data(contentsOf: source) == Data("source".utf8))
    #expect(try Data(contentsOf: target) == Data("concurrent target".utf8))
    let backup = destination.appendingPathComponent(".files-move-backup-\(report.id)-0")
    #expect(try Data(contentsOf: backup) == Data("original target".utf8))
    #expect(report.items.first?.recoveryBackup == backup)
    let journalData = try Data(contentsOf: journal.appendingPathComponent("move-\(report.id).json"))
    let record = try #require(JSONSerialization.jsonObject(with: journalData) as? [String: Any])
    let items = try #require(record["items"] as? [[String: Any]])
    #expect(items.first?["backup"] as? String == backup.absoluteString)
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

@Test func batchRenameSupportsCyclicNameSwap() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
    try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b)
    let result = try await EntryOperations.batchRename([
        BatchRenameRequest(source: a, name: "b.txt"), BatchRenameRequest(source: b, name: "a.txt")
    ], journalDirectory: journal)
    #expect(result.state == "completed")
    #expect(try String(contentsOf: a, encoding: .utf8) == "B")
    #expect(try String(contentsOf: b, encoding: .utf8) == "A")
}

@Test func batchRenameRejectsDuplicateAndExternalConflictsBeforeMutation() async throws {
    let root = try entryFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal")
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), occupied = root.appendingPathComponent("occupied")
    try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b); try Data("X".utf8).write(to: occupied)
    let duplicate = try await EntryOperations.batchRename([
        BatchRenameRequest(source: a, name: "same"), BatchRenameRequest(source: b, name: "same")
    ], journalDirectory: journal)
    #expect(duplicate.state == "rejected")
    #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    let external = try await EntryOperations.batchRename([
        BatchRenameRequest(source: a, name: "occupied")
    ], journalDirectory: journal)
    #expect(external.state == "rejected")
    #expect(try String(contentsOf: occupied, encoding: .utf8) == "X")
    #expect(try String(contentsOf: a, encoding: .utf8) == "A")
}

@Test func batchRenamePatternsPreserveExtensionsAndPreviewReplacement() {
    let root = URL(fileURLWithPath: "/tmp")
    let sources = [root.appendingPathComponent("photo-a.jpg"), root.appendingPathComponent("photo-b.png")]
    #expect(BatchRenamePattern.replacing(sources, find: "photo", replacement: "image").map(\.name) == ["image-a.jpg", "image-b.png"])
    #expect(BatchRenamePattern.numbered(sources, base: "Vacation", start: 7).map(\.name) == ["Vacation 7.jpg", "Vacation 8.png"])
}

@Test func batchRenameRegularExpressionSupportsCapturesAndRejectsInvalidPattern() throws {
    let sources = [URL(fileURLWithPath: "/tmp/IMG_0042.jpg"), URL(fileURLWithPath: "/tmp/IMG_0043.jpg")]
    let requests = try BatchRenamePattern.regularExpression(sources, pattern: #"IMG_(\d+)"#, replacement: "Photo-$1")
    #expect(requests.map(\.name) == ["Photo-0042.jpg", "Photo-0043.jpg"])
    #expect(throws: (any Error).self) {
        try BatchRenamePattern.regularExpression(sources, pattern: "(", replacement: "x")
    }
}

@Test func latestTransferUndoUsesOperationOrderAcrossCopyAndMove() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let sources = root.appendingPathComponent("sources"), destination = root.appendingPathComponent("target")
    let journals = root.appendingPathComponent("journals")
    try fm.createDirectory(at: sources, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let moved = sources.appendingPathComponent("move.txt"), copied = sources.appendingPathComponent("copy.txt")
    try Data("move".utf8).write(to: moved)
    try Data("copy".utf8).write(to: copied)
    let move = try await EntryOperations.move([moved], to: destination, journalDirectory: journals)
    let copy = await CopyEngine.run(sources: [copied], destination: destination, journalDirectory: journals, cancellation: CopyCancellation())
    guard case let .copy(first)? = EntryOperations.PendingTransferUndo.latest(in: journals) else {
        Issue.record("The newer copy should be selected first.")
        return
    }
    #expect(first.operationId == copy.id)
    let revertedCopy = await CopyEngine.undoCopy(first, journalDirectory: journals)
    #expect(revertedCopy.state == "completed")
    guard case let .move(second)? = EntryOperations.PendingTransferUndo.latest(in: journals) else {
        Issue.record("The earlier move should remain available.")
        return
    }
    #expect(second.operationId == move.id)
    let revertedMove = await EntryOperations.undoMove(second, journalDirectory: journals)
    #expect(revertedMove.state == "completed")
    #expect(try Data(contentsOf: moved) == Data("move".utf8))
    #expect(EntryOperations.PendingTransferUndo.latest(in: journals) == nil)
}

@Test func redoMoveRechecksRestoredSourceAndPublishesWithoutReplacing() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let sourceFolder = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
    let journals = root.appendingPathComponent("journals")
    try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = sourceFolder.appendingPathComponent("file"), target = destination.appendingPathComponent("file")
    let payload = Data("original".utf8)
    try payload.write(to: source)
    _ = try await EntryOperations.move([source], to: destination, journalDirectory: journals)
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: journals))
    let undone = await EntryOperations.undoMove(undo, journalDirectory: journals)
    let redo = try #require(undone.redo)
    try Data("occupied".utf8).write(to: target)
    #expect(await EntryOperations.redoMove(redo, journalDirectory: journals).first?.state == "conflict")
    #expect(try Data(contentsOf: target) == Data("occupied".utf8))
    try fm.removeItem(at: target)
    #expect(await EntryOperations.redoMove(redo, journalDirectory: journals).first?.state == "completed")
    #expect(try Data(contentsOf: target) == payload)
    #expect(!fm.fileExists(atPath: source.path))
    let secondUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journals))
    let restoredAgain = await EntryOperations.undoMove(secondUndo, journalDirectory: journals)
    let secondRedo = try #require(restoredAgain.redo)
    try Data("changed!".utf8).write(to: source)
    #expect(await EntryOperations.redoMove(secondRedo, journalDirectory: journals).first?.state == "failed")
    #expect(try Data(contentsOf: source) == Data("changed!".utf8))
    #expect(!fm.fileExists(atPath: target.path))
}
