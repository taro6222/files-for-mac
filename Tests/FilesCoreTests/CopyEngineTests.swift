import Foundation
import Darwin
import Testing
@testable import FilesCore

@Test func publishedIdentityRequiresTheOriginalOpenEntry() throws {
    let fixture = try CopyFixture()
    defer { fixture.clean() }
    let staged = fixture.source.appendingPathComponent("staged.txt")
    let target = fixture.destination.appendingPathComponent("published.txt")
    let removed = fixture.destination.appendingPathComponent("other.txt")
    try Data("identical bytes".utf8).write(to: staged)
    let descriptor = open(staged.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let prepared = try CopyEngine.checkedPublicationIdentity(at: staged, descriptor: descriptor) { _ in "staged" }
    #expect(try CopyEngine.matchesRecordedIdentity(at: staged, expected: prepared) { _ in "staged" })
    #expect(throws: (any Error).self) {
        try CopyEngine.checkedPublicationIdentity(at: target, descriptor: descriptor) { _ in "unpublished" }
    }
    try FileManager.default.moveItem(at: staged, to: target)
    let recorded = try CopyEngine.identityAfterPublication(of: target, handle: descriptor, original: "old") { url in
        #expect(url == target)
        return "published"
    }
    #expect(try CopyEngine.matchesRecordedIdentity(at: target, expected: recorded) { _ in "published" })
    #expect(try CopyEngine.matchesRecordedIdentity(at: target, expected: "published") { _ in "published" })
    try FileManager.default.moveItem(at: target, to: removed)
    try Data("identical bytes".utf8).write(to: target)
    #expect(try !CopyEngine.matchesRecordedIdentity(at: target, expected: recorded) { _ in "published" })
    #expect(throws: (any Error).self) {
        try CopyEngine.identityAfterPublication(of: target, handle: descriptor, original: "old") { _ in "replacement" }
    }
}

@Test func smbTransferAcceptsAnEmptyResourceForkWhileProtectingMetadata() throws {
    let emptyFork = ":resource:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let path = "/payload.bin"
    var local = CopyEngine.VerificationSnapshot()
    local.filesystemType = "apfs"
    local.content = ["": "directory", path: "file:data"]
    local.withPermissions = ["": "directory:493", path: "file:420:data"]
    var remote = local
    remote.filesystemType = "smbfs"
    remote.content[path] = "file:data" + emptyFork
    remote.withPermissions[path] = "file:420:data" + emptyFork

    try remote.verifyTransferredContents(of: local)
    try local.verifyTransferredContents(of: remote)
    #expect(!remote.matchesOriginal(local))

    var changed = remote
    changed.withPermissions[path] = "file:384:data" + emptyFork
    #expect(throws: CopyEngine.TransferMismatch.permissions) { try changed.verifyTransferredContents(of: local) }
    changed = remote
    changed.content[path] = "file:data:resource:nonempty"
    #expect(throws: CopyEngine.TransferMismatch.contents) { try changed.verifyTransferredContents(of: local) }
    changed = remote
    changed.filesystemType = "apfs"
    #expect(throws: CopyEngine.TransferMismatch.contents) { try changed.verifyTransferredContents(of: local) }
}

@Test func accessTimeRestorationAcceptsOnlyItsOwnChangeTimeUpdate() throws {
    let mutation = CopyEngine.AccessTimeChange(
        oldChangeTime: timespec(tv_sec: 1_700_000_000, tv_nsec: 100),
        newChangeTime: timespec(tv_sec: 1_700_000_000, tv_nsec: 300))
    let recorded = "device:inode|ctime=1700000000:100"
    #expect(try CopyEngine.identityAfterAccessTimeRestoration(recorded, change: mutation) == "device:inode|ctime=1700000000:300")
    #expect(try CopyEngine.identityAfterAccessTimeRestoration(recorded, change: nil) == recorded)
    #expect(throws: CopyEngine.TransferMismatch.accessTime) {
        try CopyEngine.identityAfterAccessTimeRestoration("device:inode|ctime=1700000000:200", change: mutation)
    }
}

@Test func smbTransferAcceptsFileTimeRoundingOnlyWhenVerifyingTheCopy() throws {
    let path = "/payload.bin"
    let baseline = Date(timeIntervalSinceReferenceDate: 816_404_686)
    let dateStep = baseline.timeIntervalSinceReferenceDate.ulp
    var local = CopyEngine.VerificationSnapshot()
    local.filesystemType = "apfs"
    local.metadata.modificationDates[path] = baseline
    var remote = local
    remote.filesystemType = "smbfs"
    remote.metadata.modificationDates[path] = baseline.addingTimeInterval(-dateStep)

    try remote.verifyTransferredContents(of: local)
    try local.verifyTransferredContents(of: remote)
    #expect(!remote.matchesOriginal(local))
    #expect(!remote.metadata.matchesRecorded(local.metadata))

    var updatedLocal = remote
    updatedLocal.filesystemType = "apfs"
    #expect(throws: CopyEngine.TransferMismatch.modificationTime) {
        try updatedLocal.verifyTransferredContents(of: local)
    }
    remote.metadata.modificationDates[path] = baseline.addingTimeInterval(0.000001)
    #expect(throws: CopyEngine.TransferMismatch.modificationTime) {
        try remote.verifyTransferredContents(of: local)
    }
}

@Test func smbTransferVerifiesCreationTimeWithoutRelaxingUndo() throws {
    let timestamp = Date(timeIntervalSinceReferenceDate: 816_404_686)
    let step = timestamp.timeIntervalSinceReferenceDate.ulp
    var original = CopyEngine.VerificationSnapshot()
    original.filesystemType = "smbfs"
    original.metadata.creationDates = ["": timestamp]
    var copy = original
    copy.metadata.creationDates = ["": timestamp.addingTimeInterval(step)]
    try copy.verifyTransferredContents(of: original)
    #expect(!copy.metadata.matchesRecorded(original.metadata))

    copy.metadata.creationDates = ["": timestamp.addingTimeInterval(step * 4)]
    #expect(throws: CopyEngine.TransferMismatch.creationTime) {
        try copy.verifyTransferredContents(of: original)
    }
}

@Test func copyCreationTimeRestorationRejectsSymlinkedStagedParent() throws {
    let f = try CopyFixture(); defer { f.clean() }
    let fm = FileManager.default
    let nested = f.source.appendingPathComponent("nested", isDirectory: true)
    let staged = f.destination.appendingPathComponent("payload", isDirectory: true)
    let outside = f.root.appendingPathComponent("outside", isDirectory: true)
    for directory in [nested, staged, outside] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let date = Date(timeIntervalSince1970: 1_600_000_000)
    let outsideDate = date.addingTimeInterval(60)
    let outsideFile = outside.appendingPathComponent("file")
    try Data("test".utf8).write(to: nested.appendingPathComponent("file"))
    try Data("outside".utf8).write(to: outsideFile)
    try fm.setAttributes([.creationDate: outsideDate], ofItemAtPath: outsideFile.path)
    try fm.createSymbolicLink(at: staged.appendingPathComponent("nested"), withDestinationURL: outside)
    let cancellation = CopyCancellation()
    let snapshot = try CopyEngine.makeSnapshot(f.source, cancellation: cancellation)
    guard snapshot.filesystemType == "apfs" else { return }
    #expect(throws: CopyEngine.TransferMismatch.creationTime) {
        try snapshot.restoreCreationTimes(in: staged, cancellation: cancellation)
    }
    #expect(try fm.attributesOfItem(atPath: outsideFile.path)[.creationDate] as? Date == outsideDate)
}

private struct CopyFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-copy-tests-\(UUID())")
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        for url in [source, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String, text: String = "original") throws -> URL {
        let url = source.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    func run(_ sources: [URL], policy: CopyConflictPolicy = .skip, cancellation: CopyCancellation = CopyCancellation(),
             progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }) async -> CopyReport {
        await CopyEngine.run(sources: sources, destination: destination, journalDirectory: journal,
                             cancellation: cancellation, conflictPolicy: policy, progress: progress)
    }
    func noTemporaryOutput() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasPrefix(".files-copy-") }
    }
}

@Test func copyTreePreservesBytesModesAndSymlinksAndPersistsJournal() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let file = try f.file("한글.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let link = f.source.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
    let report = await f.run([f.source])
    #expect(report.state == "completed")
    let copied = f.destination.appendingPathComponent("source")
    #expect(try Data(contentsOf: copied.appendingPathComponent("한글.txt")) == Data(contentsOf: file))
    #expect(try FileManager.default.attributesOfItem(atPath: copied.appendingPathComponent("한글.txt").path)[.posixPermissions] as? Int == 0o640)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("link").path) == "missing-target")
    let disk = try JSONDecoder().decode(CopyReport.self, from: Data(contentsOf: f.journal.appendingPathComponent(report.id.uuidString + ".json")))
    #expect(disk.state == "completed"); #expect(disk.items[0].temporary == nil)
    #expect(try f.noTemporaryOutput())
}

@Test func copySkipsExistingAndRacingDestinationsWithoutOverwrite() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let a = try f.file("a"), b = try f.file("b")
    let targetA = f.destination.appendingPathComponent("a"), targetB = f.destination.appendingPathComponent("b")
    try FileManager.default.createSymbolicLink(atPath: targetA.path, withDestinationPath: "absent")
    let report = await f.run([a, b]) { update in
        if update.phase == "committing" { try? Data("external".utf8).write(to: targetB) }
    }
    #expect(report.items.map(\.state) == ["conflict", "conflict"])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: targetA.path) == "absent")
    #expect(try String(contentsOf: targetB, encoding: .utf8) == "external")
    #expect(try f.noTemporaryOutput())
}

@Test func copyRejectsDescendantViaSymlink() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let child = f.source.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let alias = f.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
    let report = await CopyEngine.run(sources: [f.source], destination: alias, journalDirectory: f.journal, cancellation: CopyCancellation())
    #expect(report.items[0].state == "failed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
}

@Test func copyRetryRejectsReplacedDestination() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let source = try f.file("retry.txt")
    let identity = try #require(ShelfEntry(f.destination.resolvingSymlinksInPath()))
    let oldDestination = f.root.appendingPathComponent("old-destination")
    try FileManager.default.moveItem(at: f.destination, to: oldDestination)
    try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)

    let report = await CopyEngine.run(sources: [source], destination: f.destination,
                                      journalDirectory: f.journal, cancellation: CopyCancellation(),
                                      expectedDestination: identity)

    #expect(report.items.map(\.state) == ["failed"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: oldDestination.path).isEmpty)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
}

@Test func copyCancellationRetainsCompletedAndRemovesCurrentStaging() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let a = try f.file("a"), b = try f.file("b"), c = try f.file("c")
    let cancellation = CopyCancellation()
    let report = await f.run([a, b, c], cancellation: cancellation) { update in
        if update.index == 1 && update.phase == "verifying" { cancellation.cancel() }
    }
    #expect(report.state == "cancelled")
    #expect(report.items.map(\.state) == ["completed", "cancelled", "cancelled"])
    #expect(try String(contentsOf: f.destination.appendingPathComponent("a"), encoding: .utf8) == "original")
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("b").path))
    #expect(try f.noTemporaryOutput())
    #expect(try Data(contentsOf: b) == Data("original".utf8))
}

@Test func copyDetectsSourceMutationAndContinuesOtherItems() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let a = try f.file("a"), b = try f.file("b")
    let report = await f.run([a, b]) { update in
        if update.index == 0 && update.phase == "verifying" { try? Data("changed".utf8).write(to: a) }
    }
    #expect(report.state == "partiallyCompleted")
    #expect(report.items.map(\.state) == ["failed", "completed"])
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("a").path))
    #expect(try f.noTemporaryOutput())
}

@Test func copyCannotStartWithoutJournal() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let a = try f.file("a")
    try Data().write(to: f.journal)
    let report = await f.run([a])
    #expect(report.state == "failed"); #expect(report.journalError != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
}

@Test func copyMissingSourceReportsFailureWithoutStoppingValidItem() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let a = try f.file("a")
    let report = await f.run([f.source.appendingPathComponent("missing"), a])
    #expect(report.items.map(\.state) == ["failed", "completed"])
    #expect(report.state == "partiallyCompleted")
}

@Test func keepBothPreservesExistingNamesAndRecordsActualTarget() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let source = try f.file("한글.txt")
    for name in ["한글.txt", "한글 (2).txt"] {
        try Data("existing".utf8).write(to: f.destination.appendingPathComponent(name))
    }
    let report = await f.run([source], policy: .keepBoth)
    #expect(report.state == "completed")
    #expect(report.items[0].target.lastPathComponent == "한글 (3).txt")
    #expect(try String(contentsOf: report.items[0].target, encoding: .utf8) == "original")
    #expect(try String(contentsOf: f.destination.appendingPathComponent("한글.txt"), encoding: .utf8) == "existing")
    let disk = try JSONDecoder().decode(CopyReport.self, from: Data(contentsOf: f.journal.appendingPathComponent(report.id.uuidString + ".json")))
    #expect(disk.items[0].target == report.items[0].target)
}

@Test func keepBothHandlesCommitRaceAndFolderNames() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let folder = f.source.appendingPathComponent("folder.v1")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = f.destination.appendingPathComponent("folder.v1")
    let report = await f.run([folder], policy: .keepBoth) { update in
        if update.phase == "committing" { try? Data("racing file".utf8).write(to: target) }
    }
    #expect(report.state == "completed")
    #expect(report.items[0].target.lastPathComponent == "folder.v1 (2)")
    #expect(try String(contentsOf: target, encoding: .utf8) == "racing file")
    #expect(try f.noTemporaryOutput())
}

@Test func keepBothCopiesWithinSameFolderAndSupportsDotfiles() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let source = try f.file(".config")
    let report = await CopyEngine.run(sources: [source], destination: f.source, journalDirectory: f.journal,
                                      cancellation: CopyCancellation(), conflictPolicy: .keepBoth)
    #expect(report.state == "completed")
    #expect(report.items[0].target.lastPathComponent == ".config (2)")
    #expect(try Data(contentsOf: report.items[0].target) == Data(contentsOf: source))
}

@Test(arguments: [false, true])
func copyUndoRemovesOnlyUnchangedCopiedResults(legacy: Bool) async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let unchanged = try f.file("unchanged", text: "original")
    let changed = try f.file("changed", text: "before")
    let report = await CopyEngine.run(sources: [unchanged, changed], destination: f.destination,
                                      journalDirectory: f.journal, cancellation: CopyCancellation())
    #expect(report.state == "completed")
    let copiedUnchanged = f.destination.appendingPathComponent("unchanged")
    let copiedChanged = f.destination.appendingPathComponent("changed")
    try Data("after".utf8).write(to: copiedChanged)
    if legacy {
        let journal = f.journal.appendingPathComponent("undo-copy-\(report.id.uuidString).json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var items = try #require(json["items"] as? [[String: Any]])
        for index in items.indices { items[index].removeValue(forKey: "targetMetadata") }
        json["items"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: journal)
    }
    let record = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))

    let undo = await CopyEngine.undoCopy(record, journalDirectory: f.journal)

    #expect(!FileManager.default.fileExists(atPath: copiedUnchanged.path))
    #expect(FileManager.default.fileExists(atPath: copiedChanged.path))
    #expect(undo.items.first { $0.target == copiedChanged }?.state == "changed")
    #expect(undo.state == "partiallyCompleted")
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
}

@Test(arguments: [false, true])
func copyUndoPreservesMetadataChangesInCopyAndMerge(merge: Bool) async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let fm = FileManager.default
    let sourceFolder = f.source.appendingPathComponent("folder", isDirectory: true)
    let targetFolder = f.destination.appendingPathComponent("folder", isDirectory: true)
    try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: false)
    let bytes = Data("original".utf8)
    try bytes.write(to: sourceFolder.appendingPathComponent("file"))
    if merge {
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: false)
        let plan = try CopyMergePlanner.plan(source: sourceFolder, target: targetFolder)
        let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal,
                                                 cancellation: CopyCancellation())
        #expect(report.state == "completed")
    } else {
        #expect(await f.run([sourceFolder]).state == "completed")
    }
    let record = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(record.items.first?.targetMetadata != nil)
    let copied = targetFolder.appendingPathComponent("file")
    let attribute = "com.filesmac.undo-test"
    let value: UInt8 = 42
    try #require(withUnsafePointer(to: value) { setxattr(copied.path, attribute, $0, 1, 0, 0) } == 0)
    let undo = await CopyEngine.undoCopy(record, journalDirectory: f.journal)
    #expect(undo.items.first?.state == "changed")
    #expect(try Data(contentsOf: copied) == bytes)
}

@Test func folderMergePlanSeparatesMissingNestedAndTypeConflictsWithoutMutation() throws {
    let f = try CopyFixture(); defer { f.clean() }
    let sourceFolder = f.source.appendingPathComponent("folder")
    let sourceNested = sourceFolder.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: sourceNested, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: sourceNested.appendingPathComponent("missing.txt"))
    try Data("source".utf8).write(to: sourceNested.appendingPathComponent("same.txt"))
    try FileManager.default.createDirectory(at: sourceFolder.appendingPathComponent("mixed"), withIntermediateDirectories: true)
    let targetFolder = f.destination.appendingPathComponent("folder")
    let targetNested = targetFolder.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: targetNested, withIntermediateDirectories: true)
    try Data("target".utf8).write(to: targetNested.appendingPathComponent("same.txt"))
    try Data("target-file".utf8).write(to: targetFolder.appendingPathComponent("mixed"))

    let plan = try CopyMergePlanner.plan(source: sourceFolder, target: targetFolder)

    #expect(plan.actions.map { $0.relativePath + ":" + $0.kind.rawValue } == [
        "mixed:typeConflict",
        "nested:mergeDirectory",
        "nested/missing.txt:copyMissing",
        "nested/same.txt:fileConflict"
    ])
    #expect(plan.conflicts.count == 2)
    #expect(!FileManager.default.fileExists(atPath: targetNested.appendingPathComponent("missing.txt").path))
    #expect(try String(contentsOf: targetNested.appendingPathComponent("same.txt"), encoding: .utf8) == "target")
}

@Test func folderMergeExecutionPublishesOnlyMissingItemsAndSupportsSafeUndo() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let sourceFolder = f.source.appendingPathComponent("folder")
    let sourceNested = sourceFolder.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: sourceNested, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: sourceNested.appendingPathComponent("new.txt"))
    try Data("source".utf8).write(to: sourceNested.appendingPathComponent("existing.txt"))
    let targetFolder = f.destination.appendingPathComponent("folder")
    let targetNested = targetFolder.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: targetNested, withIntermediateDirectories: true)
    try Data("target".utf8).write(to: targetNested.appendingPathComponent("existing.txt"))
    let plan = try CopyMergePlanner.plan(source: sourceFolder, target: targetFolder)

    let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal,
                                              cancellation: CopyCancellation())

    #expect(report.state == "completed")
    #expect(try String(contentsOf: targetNested.appendingPathComponent("new.txt"), encoding: .utf8) == "new")
    #expect(try String(contentsOf: targetNested.appendingPathComponent("existing.txt"), encoding: .utf8) == "target")
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    let undoResult = await CopyEngine.undoCopy(undo, journalDirectory: f.journal)
    #expect(undoResult.state == "completed")
    #expect(!FileManager.default.fileExists(atPath: targetNested.appendingPathComponent("new.txt").path))
    #expect(FileManager.default.fileExists(atPath: targetNested.path))
}

@Test func folderMergeExecutionPreservesDestinationThatAppearsAfterPlanning() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let sourceFolder = f.source.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: sourceFolder.appendingPathComponent("racing.txt"))
    let targetFolder = f.destination.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
    let plan = try CopyMergePlanner.plan(source: sourceFolder, target: targetFolder)
    try Data("external".utf8).write(to: targetFolder.appendingPathComponent("racing.txt"))

    let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal,
                                              cancellation: CopyCancellation())

    #expect(report.items.first?.state == "conflict")
    #expect(try String(contentsOf: targetFolder.appendingPathComponent("racing.txt"), encoding: .utf8) == "external")
}

@Test func folderMergeBatchCombinesMissingMergedAndConflictingItemsIntoOneUndo() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let missing = try f.file("missing.txt", text: "new")
    let mergeSource = f.source.appendingPathComponent("merge")
    try FileManager.default.createDirectory(at: mergeSource, withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: mergeSource.appendingPathComponent("nested.txt"))
    let mergeTarget = f.destination.appendingPathComponent("merge")
    try FileManager.default.createDirectory(at: mergeTarget, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: mergeTarget.appendingPathComponent("keep.txt"))
    let conflicting = try f.file("conflict.txt", text: "source")
    try Data("target".utf8).write(to: f.destination.appendingPathComponent("conflict.txt"))

    let report = await CopyMergeBatch.run(sources: [missing, mergeSource, conflicting],
        destination: f.destination, journalDirectory: f.journal, cancellation: CopyCancellation())

    #expect(report.state == "completed")
    #expect(report.items.map(\.state) == ["completed", "merged", "conflict"])
    #expect(try String(contentsOf: f.destination.appendingPathComponent("conflict.txt"), encoding: .utf8) == "target")
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(undo.operationId == report.id)
    #expect(undo.items.count == 2)
    #expect(undo.items.allSatisfy { $0.targetMetadata != nil })
    let undoResult = await CopyEngine.undoCopy(undo, journalDirectory: f.journal)
    #expect(undoResult.state == "completed")
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("missing.txt").path))
    #expect(!FileManager.default.fileExists(atPath: mergeTarget.appendingPathComponent("nested.txt").path))
    #expect(FileManager.default.fileExists(atPath: mergeTarget.appendingPathComponent("keep.txt").path))
}

@Test func folderMergeBatchCancellationKeepsCompletedItemAndSkipsRemainingItems() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let first = try f.file("first.txt", text: "first")
    let second = try f.file("second.txt", text: "second")
    let cancellation = CopyCancellation()

    let report = await CopyMergeBatch.run(sources: [first, second], destination: f.destination,
        journalDirectory: f.journal, cancellation: cancellation) { update in
        if update.index == 0 { cancellation.cancel() }
    }

    #expect(report.state == "cancelled")
    #expect(report.items.map(\.state) == ["completed", "cancelled"])
    #expect(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("first.txt").path))
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("second.txt").path))
    let undo = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(undo.items.count == 1)
}

@Test func folderMergeBatchJournalFailurePreventsAllMutation() async throws {
    let f = try CopyFixture(); defer { f.clean() }
    let source = try f.file("source.txt", text: "source")
    try Data("not-a-directory".utf8).write(to: f.journal)

    let report = await CopyMergeBatch.run(sources: [source], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation())

    #expect(report.state == "failed")
    #expect(report.journalError != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
}

@Test func templateCreatesNamedCopyAndPreservesOriginalAndExistingTargets() async throws {
    let fixture = try CopyFixture()
    defer { fixture.clean() }
    let template = try fixture.file("Proposal.txt", text: "template")
    let target = fixture.destination.appendingPathComponent("New Proposal.txt")
    let report = try await CopyEngine.instantiateTemplate(template, in: fixture.destination,
                                                          name: "New Proposal.txt", journalDirectory: fixture.journal)
    #expect(report.items.first?.state == "completed")
    #expect(try Data(contentsOf: template) == Data("template".utf8))
    #expect(try Data(contentsOf: target) == Data("template".utf8))
    try Data("existing".utf8).write(to: target)
    let collision = try await CopyEngine.instantiateTemplate(template, in: fixture.destination,
                                                             name: "New Proposal.txt", journalDirectory: fixture.journal)
    #expect(collision.items.first?.state == "conflict")
    #expect(try Data(contentsOf: target) == Data("existing".utf8))
    let link = fixture.source.appendingPathComponent("Link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: template)
    await #expect(throws: EntryOperationError.sourceChanged) {
        try await CopyEngine.instantiateTemplate(link, in: fixture.destination, name: "Other.txt",
                                                journalDirectory: fixture.journal)
    }
}

@Test func promisedItemExportUsesReceiversNameAndPreservesFileMetadata() throws {
    let f = try CopyFixture(); defer { f.clean() }
    let source = try f.file("원본.txt", text: "promised bytes")
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let entry = try #require(ShelfEntry(source))
    let target = f.destination.appendingPathComponent("받은 이름.txt")
    let report = try CopyEngine.exportPromisedItem(entry, to: target, journalDirectory: f.journal)
    #expect(report.state == "completed")
    #expect(report.items.first?.target == target)
    #expect(try Data(contentsOf: target) == Data("promised bytes".utf8))
    #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o640)
    #expect(try Data(contentsOf: source) == Data("promised bytes".utf8))
    #expect(entry.isCurrent)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: f.journal) == nil)
    #expect(try f.noTemporaryOutput())
}

@Test func promisedItemExportProtectsExistingTargetsAndChangedSources() throws {
    let f = try CopyFixture(); defer { f.clean() }
    let source = try f.file("source.txt")
    let entry = try #require(ShelfEntry(source))
    let target = f.destination.appendingPathComponent("existing.txt")
    try Data("existing bytes".utf8).write(to: target)
    let collision = try CopyEngine.exportPromisedItem(entry, to: target, journalDirectory: f.journal)
    #expect(collision.items.first?.state == "conflict")
    #expect(try Data(contentsOf: target) == Data("existing bytes".utf8))
    try FileManager.default.moveItem(at: source, to: f.source.appendingPathComponent("retained.txt"))
    try Data("replacement source".utf8).write(to: source)
    #expect(throws: EntryOperationError.sourceChanged) {
        try CopyEngine.exportPromisedItem(entry, to: f.destination.appendingPathComponent("new.txt"), journalDirectory: f.journal)
    }
    #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("new.txt").path))
    #expect(try Data(contentsOf: source) == Data("replacement source".utf8))
    #expect(try f.noTemporaryOutput())
}

@Test func promisedFolderExportKeepsNestedContentsAndSymbolicLinks() throws {
    let f = try CopyFixture(); defer { f.clean() }
    let folder = f.source.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("nested bytes".utf8).write(to: folder.appendingPathComponent("nested.txt"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                             withDestinationPath: "nested.txt")
    let target = f.destination.appendingPathComponent("Renamed Folder", isDirectory: true)
    let report = try CopyEngine.exportPromisedItem(try #require(ShelfEntry(folder)), to: target, journalDirectory: f.journal)
    #expect(report.state == "completed")
    #expect(try Data(contentsOf: target.appendingPathComponent("nested.txt")) == Data("nested bytes".utf8))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path) == "nested.txt")
    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(try f.noTemporaryOutput())
}
