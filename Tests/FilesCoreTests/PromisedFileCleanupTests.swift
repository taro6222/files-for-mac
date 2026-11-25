import Foundation
import Testing
@testable import FilesCore

private struct CleanupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promise-cleanup-\(UUID())")
    let intake: PromisedFileIntake
    let target: URL
    let journal: URL
    let trash: URL
    init() throws {
        intake = try PromisedFileIntake(storageDirectory: root.appendingPathComponent("intakes"))
        target = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("operations")
        trash = root.appendingPathComponent("fixture-trash")
        for directory in [target, trash] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func receive(_ name: String = "payload.txt", bytes: String = "received payload") throws -> URL {
        let url = intake.receivingDirectory.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url); try intake.registerReceivedFile(url)
        return url
    }
    func copy(_ source: URL, policy: CopyConflictPolicy = .skip) async -> CopyReport {
        await CopyEngine.run(sources: [source], destination: target, journalDirectory: journal,
                             cancellation: CopyCancellation(), conflictPolicy: policy, sourceIntakes: [intake])
    }
    func moveToFixtureTrash(_ root: URL) throws -> URL {
        let moved = trash.appendingPathComponent(root.lastPathComponent)
        try FileManager.default.moveItem(at: root, to: moved); return moved
    }
}

@Test func promisedCleanupRecordsCopyAndRecoversBeforeMovingVerifiedPayloadToTrash() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive()
    let report = await f.copy(source)
    #expect(report.state == "completed" && report.items.first?.message == nil)
    #expect(f.intake.copiedItemCount == 1)
    let copied = try #require(report.items.first)
    let targetSnapshot = try CopyEngine.makeSnapshot(copied.target, cancellation: CopyCancellation())
    #expect(try CopyEngine.entryIdentity(copied.target) == copied.targetIdentity)
    #expect(targetSnapshot.withPermissions == copied.targetSnapshot)
    #expect(targetSnapshot.metadata == copied.targetMetadata)
    let originalSnapshot = try CopyEngine.makeSnapshot(source, cancellation: CopyCancellation())
    try targetSnapshot.verifyTransferredContents(of: originalSnapshot)
    let recovered = try PromisedFileIntake(recovering: f.intake.directoryURL)
    #expect(recovered.copiedItemCount == 1)
    let result = try recovered.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    #expect(result.state == "trashed")
    let retained = try #require(result.retainedAt)
    #expect(try Data(contentsOf: retained.appendingPathComponent("Files/payload.txt")) == Data("received payload".utf8))
    #expect(try Data(contentsOf: f.target.appendingPathComponent("payload.txt")) == Data("received payload".utf8))
    #expect(!FileManager.default.fileExists(atPath: f.intake.directoryURL.path))
    #expect(FileManager.default.fileExists(atPath: result.journal.path))
}

@Test func promisedCleanupRefusesUncopiedOrConflictedFiles() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive()
    #expect(throws: PromisedFileIntakeError.noVerifiedCopy) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    try Data("existing".utf8).write(to: f.target.appendingPathComponent("payload.txt"))
    let report = await f.copy(source)
    #expect(report.items.first?.state == "conflict" && f.intake.copiedItemCount == 0)
    #expect(throws: PromisedFileIntakeError.noVerifiedCopy) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    #expect(try Data(contentsOf: source) == Data("received payload".utf8))
}

@Test func promisedCleanupProtectsChangedSourceAndTarget() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive()
    #expect(await f.copy(source).state == "completed")
    let target = f.target.appendingPathComponent("payload.txt")
    try Data("edited target".utf8).write(to: target)
    #expect(throws: PromisedFileIntakeError.noVerifiedCopy) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    try Data("edited source".utf8).write(to: source)
    #expect(throws: PromisedFileIntakeError.changedItem) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    #expect(try Data(contentsOf: source) == Data("edited source".utf8))
    #expect(try Data(contentsOf: target) == Data("edited target".utf8))
}

@Test func promisedCleanupProtectsSameBytesAtReplacedTargetIdentity() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let target = f.target.appendingPathComponent("payload.txt")
    try FileManager.default.moveItem(at: target, to: f.root.appendingPathComponent("retained-target"))
    try Data("received payload".utf8).write(to: target)
    #expect(throws: PromisedFileIntakeError.noVerifiedCopy) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func promisedCleanupRefusesUnregisteredPayloadsAndUnknownRootFiles() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let unknown = f.intake.receivingDirectory.appendingPathComponent("unfinished.txt")
    try Data("unique unfinished export".utf8).write(to: unknown)
    #expect(throws: PromisedFileIntakeError.unknownContents) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    try FileManager.default.moveItem(at: unknown, to: f.intake.directoryURL.appendingPathComponent("unknown.txt"))
    #expect(throws: PromisedFileIntakeError.unknownContents) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func promisedCleanupCancellationAndJournalFailurePreventMovement() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let cancel = CopyCancellation(); cancel.cancel()
    #expect(throws: CancellationError.self) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, cancellation: cancel, trash: f.moveToFixtureTrash)
    }
    let blocked = f.root.appendingPathComponent("not-a-directory")
    try Data("retained".utf8).write(to: blocked)
    #expect(throws: (any Error).self) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: blocked, trash: f.moveToFixtureTrash)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func promisedCleanupRestoresWhenPayloadChangesDuringTrashMove() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let result = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal) { root in
        let moved = try f.moveToFixtureTrash(root)
        try Data("changed during cleanup".utf8).write(to: moved.appendingPathComponent("Files/payload.txt"))
        return moved
    }
    #expect(result.state == "restored")
    #expect(result.retainedAt == f.intake.directoryURL)
    #expect(try Data(contentsOf: source) == Data("changed during cleanup".utf8))
}

@Test func promisedCleanupNeverOverwritesReplacementDuringRollback() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let result = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal) { root in
        let moved = try f.moveToFixtureTrash(root)
        try Data("late export".utf8).write(to: moved.appendingPathComponent("Files/late.txt"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: root.appendingPathComponent("sentinel"))
        return moved
    }
    #expect(result.state == "needsReview")
    let retained = try #require(result.retainedAt)
    #expect(try Data(contentsOf: retained.appendingPathComponent("Files/late.txt")) == Data("late export".utf8))
    #expect(try Data(contentsOf: f.intake.directoryURL.appendingPathComponent("sentinel")) == Data("replacement".utf8))
}

@Test func promisedCleanupCanUseAnEarlierStillVerifiedCopyAfterLatestCopyChanges() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let latest = await f.copy(source, policy: .keepBoth)
    let latestTarget = try #require(latest.items.first?.target)
    try Data("edited latest".utf8).write(to: latestTarget)
    let result = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    #expect(result.state == "trashed")
    #expect(try Data(contentsOf: latestTarget) == Data("edited latest".utf8))
}

@Test func promisedCleanupVerifiesFolderAndSymbolicLinkCopyBeforeTrashing() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let folder = f.intake.receivingDirectory.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("nested payload".utf8).write(to: folder.appendingPathComponent("nested.txt"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "nested.txt")
    try f.intake.registerReceivedFile(folder)
    #expect(await f.copy(folder).state == "completed")
    let result = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    #expect(result.state == "trashed")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.target.appendingPathComponent("folder/link").path) == "nested.txt")
}

@Test func promisedCleanupProtectsChangedPermissionsAndTrashServiceFailure() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let target = f.target.appendingPathComponent("payload.txt")
    let mode = try #require(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
    #expect(throws: PromisedFileIntakeError.noVerifiedCopy) {
        try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, trash: f.moveToFixtureTrash)
    }
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    let result = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal) { _ in throw CocoaError(.fileWriteNoPermission) }
    #expect(result.state == "retained")
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func promisedCleanupRestoresCancellationAfterMoveAndReportsUnknownMoveLocation() async throws {
    let f = try CleanupFixture(); defer { f.remove() }
    let source = try f.receive(); #expect(await f.copy(source).state == "completed")
    let cancellation = CopyCancellation()
    let cancelled = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal, cancellation: cancellation) { root in
        let moved = try f.moveToFixtureTrash(root); cancellation.cancel(); return moved
    }
    #expect(cancelled.state == "restored")
    #expect(FileManager.default.fileExists(atPath: source.path))
    let unknown = try f.intake.moveVerifiedCopiesToTrash(journalDirectory: f.journal) { root in
        _ = try f.moveToFixtureTrash(root)
        throw CocoaError(.fileWriteUnknown)
    }
    #expect(unknown.state == "needsReview" && unknown.retainedAt == nil)
    let retained = f.trash.appendingPathComponent(f.intake.directoryURL.lastPathComponent).appendingPathComponent("Files/payload.txt")
    #expect(try Data(contentsOf: retained) == Data("received payload".utf8))
}
