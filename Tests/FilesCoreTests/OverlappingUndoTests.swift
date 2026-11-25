import Foundation
import Darwin
import Testing
@testable import FilesCore

@Test(arguments: [false,true], ["data", "extra", "mtime", "sub-mtime", "xattr", "permissions", "acl", "group"])
func overlappingUndoPreservesExternalChanges(beforeCapture: Bool, change: String) async throws {
    let f = try OverlapFixture(); defer { f.clean() }
    let report = await CopyMergeBatch.run(sources: [f.first,f.second], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation()) { update in
        let point = beforeCapture ? "planning" : "merged"
        guard update.index == 1 && update.state == point else { return }
        do { try f.change(change) } catch { Issue.record(error) }
    }
    #expect(report.items.allSatisfy { $0.state == "completed" || $0.state == "merged" })
    let record = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(!record.items.contains { $0.targetIdentity.hasPrefix(CopyEngine.consolidatedUndoPrefix) })
    let result = await CopyEngine.undoCopy(record, journalDirectory: f.journal)
    #expect(result.state == "partiallyCompleted")
    #expect(FileManager.default.fileExists(atPath: f.target.path))
    if change == "data" { #expect(try String(contentsOf: f.target.appendingPathComponent("common"), encoding: .utf8) == "other") }
    if change == "extra" { #expect(try String(contentsOf: f.target.appendingPathComponent("external"), encoding: .utf8) == "external") }
    if change == "mtime" { #expect(try FileManager.default.attributesOfItem(atPath: f.target.path)[.modificationDate] as? Date == OverlapFixture.externalDate) }
    if change == "xattr" { #expect(getxattr(f.target.path,"com.filesmac.external",nil,0,0,0) == 1) }
    if change == "permissions" { #expect(try FileManager.default.attributesOfItem(atPath: f.target.path)[.posixPermissions] as? Int == 0o700) }
    if change == "group" { #expect(try FileManager.default.attributesOfItem(atPath: f.target.path)[.groupOwnerAccountID] as? Int == 12) }
    if change == "acl" {
        let metadata = try CopyEngine.makeSnapshot(f.target, cancellation: CopyCancellation()).metadata
        #expect(metadata.accessControlLists[""]?.isEmpty == false)
    }
}

@Test func overlappingUndoThreeRootsConsolidatesNestedOwnershipAndRoundTripsJournal() async throws {
    let f = try OverlapFixture(); defer { f.clean() }
    let third = f.root.appendingPathComponent("third/shared")
    try FileManager.default.createDirectory(at: third.appendingPathComponent("sub/new"), withIntermediateDirectories: true)
    try Data("ccc".utf8).write(to: third.appendingPathComponent("sub/new/c"))
    try FileManager.default.createDirectory(at: f.second.appendingPathComponent("sub/new"), withIntermediateDirectories: true)
    try Data("bb".utf8).write(to: f.second.appendingPathComponent("sub/new/b"))
    let report = await CopyMergeBatch.run(sources: [f.first,f.second,third], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    #expect(report.state == "completed")
    let record = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    #expect(record.items.count == 1)
    let item = try #require(record.items.first)
    #expect(item.targetIdentity.hasPrefix(CopyEngine.consolidatedUndoPrefix))
    #expect(item.descendantIdentities?["/sub/new"] != nil)
    #expect(item.descendantIdentities?["/sub/new/c"] != nil)
    let loaded = try JSONDecoder().decode(CopyUndoRecord.self, from: JSONEncoder().encode(record))
    #expect(await CopyEngine.undoCopy(loaded, journalDirectory: f.journal).state == "completed")
    #expect(!FileManager.default.fileExists(atPath: f.target.path))
    #expect(try String(contentsOf: f.first.appendingPathComponent("common"), encoding: .utf8) == "first")
}

@Test func consolidatedUndoRejectsReplacedChildEvenWithMatchingContentsAndMetadata() async throws {
    let f = try OverlapFixture(); defer { f.clean() }
    _ = await CopyMergeBatch.run(sources: [f.first,f.second], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    let record = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    let item = try #require(record.items.first)
    #expect(record.items.count == 1)
    let child = f.target.appendingPathComponent("sub/b")
    let replacement = f.root.appendingPathComponent("replacement")
    let before = try CopyEngine.makeSnapshot(child, cancellation: CopyCancellation())
    try NativeFileCopy.run(from: child, to: replacement, totalBytes: 2, cancellation: CopyCancellation()) { _ in }
    try before.restoreCreationTimes(in: replacement, cancellation: CopyCancellation())
    try FileManager.default.removeItem(at: child)
    try FileManager.default.moveItem(at: replacement, to: child)
    let metadata = try #require(item.targetMetadata)
    var restore = try CopyEngine.makeSnapshot(f.target, cancellation: CopyCancellation())
    restore.metadata.modificationDates = ["/sub": try #require(metadata.modificationDates["/sub"])]
    try restore.restoreDirectoryModificationTimes(in: f.target, cancellation: CopyCancellation())
    let actual = try CopyEngine.makeSnapshot(f.target, cancellation: CopyCancellation())
    #expect(actual.withPermissions == item.targetSnapshot)
    #expect(actual.metadata.matchesRecorded(metadata))
    #expect(try !CopyEngine.matchesUndoTarget(item))
    #expect(await CopyEngine.undoCopy(record, journalDirectory: f.journal).state == "failed")
    #expect(try Data(contentsOf: child) == Data("bb".utf8))
}

@Test func overlappingUndoMissingMutationProofRetainsStrictOriginalRecords() async throws {
    let f = try OverlapFixture(); defer { f.clean() }
    let first = await CopyEngine.run(sources: [f.first], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation(), recordUndo: false)
    let created = try #require(first.items.first)
    let ancestor = CopyUndoItem(target: created.target, targetIdentity: try #require(created.targetIdentity),
        targetSnapshot: try #require(created.targetSnapshot), targetMetadata: created.targetMetadata)
    let consolidator = MergeUndoConsolidator()
    consolidator.capture(items: [ancestor], touchedTargets: [f.target.appendingPathComponent("sub/b")])
    let plan = try CopyMergePlanner.plan(source: f.second, target: f.target)
    let child = await CopyMergeExecutor.run(plan: plan, journalDirectory: f.journal,
        cancellation: CopyCancellation(), recordUndo: false)
    #expect(child.directoryMutations?.isEmpty == false)
    let additions = child.items.compactMap { entry -> CopyUndoItem? in
        guard entry.state == "completed", let id=entry.targetIdentity, let snapshot=entry.targetSnapshot else { return nil }
        return CopyUndoItem(target: entry.target, targetIdentity: id, targetSnapshot: snapshot, targetMetadata: entry.targetMetadata)
    }
    let result = consolidator.finish(items: [ancestor]+additions, mutations: [:])
    #expect(result.count == 2)
    #expect(!result.contains { $0.targetIdentity.hasPrefix(CopyEngine.consolidatedUndoPrefix) })
}

@Test func consolidatedUndoRequiresBoundarySchemaAndRejectsUnknownIdentityFormats() async throws {
    let f = try OverlapFixture(); defer { f.clean() }
    _ = await CopyMergeBatch.run(sources: [f.first,f.second], destination: f.destination,
        journalDirectory: f.journal, cancellation: CopyCancellation())
    let record = try #require(CopyEngine.latestUndoCopy(journalDirectory: f.journal))
    var item = try #require(record.items.first)
    #expect(try CopyEngine.matchesUndoTarget(item))
    // The previous identity matcher deliberately cannot authorize this new tree record.
    #expect(try !CopyEngine.matchesRecordedIdentity(at: item.target, expected: item.targetIdentity, identity: CopyEngine.entryIdentity))
    item.descendantIdentities = nil
    #expect(try !CopyEngine.matchesUndoTarget(item))
    item.descendantIdentities = ["/../outside": "invalid"]
    #expect(try !CopyEngine.matchesUndoTarget(item))
}

private struct OverlapFixture: Sendable {
    static let externalDate = Date(timeIntervalSince1970: 1_600_000_000)
    let root: URL, first: URL, second: URL, destination: URL, target: URL, journal: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("overlap-undo-\(UUID())")
        first = root.appendingPathComponent("first/shared"); second = root.appendingPathComponent("second/shared")
        destination = root.appendingPathComponent("destination"); target = destination.appendingPathComponent("shared")
        journal = root.appendingPathComponent("journals")
        for url in [first,second] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: first.appendingPathComponent("common"))
        try Data("a".utf8).write(to: first.appendingPathComponent("sub/a"))
        try Data("second".utf8).write(to: second.appendingPathComponent("common"))
        try Data("bb".utf8).write(to: second.appendingPathComponent("sub/b"))
    }
    func change(_ kind: String) throws {
        switch kind {
        case "data": try Data("other".utf8).write(to: target.appendingPathComponent("common"))
        case "extra": try Data("external".utf8).write(to: target.appendingPathComponent("external"))
        case "mtime": try FileManager.default.setAttributes([.modificationDate: Self.externalDate], ofItemAtPath: target.path)
        case "sub-mtime": try FileManager.default.setAttributes([.modificationDate: Self.externalDate], ofItemAtPath: target.appendingPathComponent("sub").path)
        case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        case "xattr":
            var value: UInt8 = 1
            guard setxattr(target.path,"com.filesmac.external",&value,1,0,0) == 0 else { throw POSIXError(.EIO) }
        case "group":
            guard chown(target.path, uid_t.max, 12) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        case "acl":
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a","everyone allow readattr",target.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        default: throw POSIXError(.EINVAL)
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
