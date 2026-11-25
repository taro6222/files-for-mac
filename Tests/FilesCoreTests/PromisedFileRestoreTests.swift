import Foundation
import Darwin
import Testing
@testable import FilesCore

private struct RestoreFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promise-restore-\(UUID())")
    let storage: URL
    let journals: URL
    let trash: URL
    let copies: URL
    let intake: PromisedFileIntake
    init() throws {
        storage = root.appendingPathComponent("intakes"); journals = root.appendingPathComponent("operations")
        trash = root.appendingPathComponent("fixture-trash"); copies = root.appendingPathComponent("copies")
        intake = try PromisedFileIntake(storageDirectory: storage)
        for directory in [trash, copies] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func prepare(interrupted: Bool = false) async throws -> PromisedFileCleanupRecovery {
        let source = intake.receivingDirectory.appendingPathComponent("received.txt")
        try Data("retained original".utf8).write(to: source); try intake.registerReceivedFile(source)
        let copied = await CopyEngine.run(sources: [source], destination: copies, journalDirectory: journals,
                                         cancellation: CopyCancellation(), sourceIntakes: [intake])
        #expect(copied.state == "completed")
        let result = try intake.moveVerifiedCopiesToTrash(journalDirectory: journals) { original in
            let moved = trash.appendingPathComponent(original.lastPathComponent)
            try FileManager.default.moveItem(at: original, to: moved); return moved
        }
        #expect(result.state == "trashed")
        if interrupted {
            var checkpoint = result; checkpoint.state = "movedToTrash"
            try JSONEncoder().encode(checkpoint).write(to: result.journal, options: .atomic)
        }
        return try #require(try PromisedFileCleanupRecovery.discover(in: journals, storage: storage).first)
    }
}

@Test func promisedRestoreRechecksPayloadWithoutRequiringCopyAndKeepsImmutableHistory() async throws {
    let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare(interrupted: true)
    #expect(row.recordedState == "movedToTrash")
    let before = try Data(contentsOf: row.journal), identity = LocalEntryIdentity.read(try #require(row.location))
    try FileManager.default.removeItem(at: f.copies.appendingPathComponent("received.txt"))
    #expect(row.canRestore)
    let result = try row.restore(storage: f.storage)
    #expect(result.state == "restored" && result.retainedAt == f.intake.directoryURL)
    #expect(LocalEntryIdentity.read(f.intake.directoryURL) == identity)
    #expect(try f.intake.verifiedSources().count == 1)
    #expect(try Data(contentsOf: row.journal) == before)
    let records = try PromisedFileCleanupRecovery.discover(in: f.journals, storage: f.storage)
    #expect(records.count == 2 && records.allSatisfy { $0.status == .atOriginal && !$0.canRestore })
    #expect(records.contains { $0.isRestoreRecord && $0.recordedState == "restored" })
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.journals.path).filter { $0.hasPrefix("promise-cleanup-") }.count == 3)
}

@Test func promisedRestoreNeverOverwritesAnOccupiedOriginalPath() async throws {
    let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
    try FileManager.default.createDirectory(at: f.intake.directoryURL, withIntermediateDirectories: false)
    let foreign = f.intake.directoryURL.appendingPathComponent("foreign.txt"); try Data("new occupant".utf8).write(to: foreign)
    #expect(throws: PromisedFileRestoreFailure.conflict) { try row.restore(storage: f.storage) }
    #expect(try Data(contentsOf: foreign) == Data("new occupant".utf8))
    #expect(FileManager.default.fileExists(atPath: try #require(row.location).path))
}

@Test func promisedRestoreRejectsChangedPayloadAdditionalFilesAndReceipt() async throws {
    for mutation in ["payload", "additional", "receipt"] {
        let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare(); let location = try #require(row.location)
        let changed: URL
        switch mutation {
        case "payload": changed = location.appendingPathComponent("Files/received.txt")
        case "additional": changed = location.appendingPathComponent("unknown.txt")
        default: changed = try #require(try FileManager.default.contentsOfDirectory(at: location.appendingPathComponent("Receipts"), includingPropertiesForKeys: nil).first)
        }
        try Data("preserve this changed data".utf8).write(to: changed)
        #expect(throws: (any Error).self) { try row.restore(storage: f.storage) }
        #expect(try Data(contentsOf: changed) == Data("preserve this changed data".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.intake.directoryURL.path))
    }
}

@Test func promisedRestoreProtectsConflictingArrivalAfterIntent() async throws {
    let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
    let result = try row.restore(storage: f.storage, cancellation: CopyCancellation()) {
        try FileManager.default.createDirectory(at: f.intake.directoryURL, withIntermediateDirectories: false)
        try Data("concurrent arrival".utf8).write(to: f.intake.directoryURL.appendingPathComponent("foreign.txt"))
    }
    #expect(result.state == "needsReview" && result.retainedAt == row.location)
    #expect(result.restoreFailure == .conflict)
    #expect(try Data(contentsOf: f.intake.directoryURL.appendingPathComponent("foreign.txt")) == Data("concurrent arrival".utf8))
    #expect(FileManager.default.fileExists(atPath: try #require(row.location).appendingPathComponent("Files/received.txt").path))
}

@Test func promisedRestoreCancellationAndChangedJournalKeepRetainedPayload() async throws {
    let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
    let cancelled = CopyCancellation(); cancelled.cancel()
    #expect(throws: CancellationError.self) { try row.restore(storage: f.storage, cancellation: cancelled) }
    let during = CopyCancellation()
    let stopped = try row.restore(storage: f.storage, cancellation: during) { during.cancel() }
    #expect(stopped.state == "needsReview" && stopped.retainedAt == row.location)
    #expect(stopped.restoreFailure == .cancelled)
    let replacement = Data("manually changed record".utf8)
    try replacement.write(to: row.journal, options: .atomic)
    #expect(throws: PromisedFileIntakeError.changedRoot) { try row.restore(storage: f.storage) }
    #expect(try Data(contentsOf: row.journal) == replacement)
    #expect(!FileManager.default.fileExists(atPath: f.intake.directoryURL.path))
}

@Test func promisedRestoreRechecksDestinationAndSourceParents() async throws {
    for parent in ["storage", "trash"] {
        let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
        let changed = parent == "storage" ? f.storage : f.trash
        let renamed = f.root.appendingPathComponent("preserved-parent")
        let result = try row.restore(storage: f.storage, cancellation: CopyCancellation()) {
            try FileManager.default.moveItem(at: changed, to: renamed)
            try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
            try Data("replacement parent".utf8).write(to: changed.appendingPathComponent("foreign.txt"))
        }
        #expect(result.state == "needsReview")
        #expect(try Data(contentsOf: changed.appendingPathComponent("foreign.txt")) == Data("replacement parent".utf8))
        let actual = parent == "trash" ? renamed.appendingPathComponent(f.intake.directoryURL.lastPathComponent) : try #require(row.location)
        #expect(result.retainedAt?.standardizedFileURL.path == actual.standardizedFileURL.path)
        #expect(LocalEntryIdentity.read(try #require(result.retainedAt)) == LocalEntryIdentity.read(actual))
        #expect(try Data(contentsOf: actual.appendingPathComponent("Files/received.txt")) == Data("retained original".utf8))
    }
}

@Test func promisedRestoreRetainsIntentWhenJournalParentChanges() async throws {
    let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
    let moved = f.root.appendingPathComponent("preserved-records")
    let result = try row.restore(storage: f.storage, cancellation: CopyCancellation()) {
        try FileManager.default.moveItem(at: f.journals, to: moved)
        try FileManager.default.createDirectory(at: f.journals, withIntermediateDirectories: false)
        try Data("foreign record".utf8).write(to: f.journals.appendingPathComponent("foreign.json"))
    }
    #expect(result.state == "needsReview" && result.retainedAt == row.location)
    #expect(result.journal.deletingLastPathComponent().standardizedFileURL == moved.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: result.journal.path))
    #expect(try Data(contentsOf: f.journals.appendingPathComponent("foreign.json")) == Data("foreign record".utf8))
}

@Test func promisedRestoreKeepsLegacyProofVisibleWithoutAdoptingItForRestore() async throws {
    let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
    var legacy = try JSONDecoder().decode(PromisedFileCleanupResult.self, from: Data(contentsOf: row.journal))
    legacy.storageIdentity = nil; legacy.retainedFingerprint = nil
    try JSONEncoder().encode(legacy).write(to: row.journal, options: .atomic)
    let records = try PromisedFileCleanupRecovery.discover(in: f.journals, storage: f.storage)
    let found = try #require(records.first)
    #expect(found.status == .retainedElsewhere && !found.canRestore && found.location == row.location)
    #expect(throws: PromisedFileIntakeError.invalidLocation) { try found.restore(storage: f.storage) }
    #expect(FileManager.default.fileExists(atPath: try #require(row.location).appendingPathComponent("Files/received.txt").path))
}

@Test func promisedRestorePreservesPublishedDirectoryWhenPostMoveVerificationStops() async throws {
    for change in ["payload", "additional", "cancel", "parent"] {
        let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
        let cancellation = CopyCancellation(), movedParent = f.root.appendingPathComponent("relocated-storage")
        let result = try row.restore(storage: f.storage, cancellation: cancellation, beforeMove: {}, afterMove: {
            switch change {
            case "payload": try Data("edited during publication".utf8).write(to: f.intake.receivingDirectory.appendingPathComponent("received.txt"))
            case "additional": try Data("additional user data".utf8).write(to: f.intake.directoryURL.appendingPathComponent("new.txt"))
            case "cancel": cancellation.cancel()
            default:
                try FileManager.default.moveItem(at: f.storage, to: movedParent)
                try FileManager.default.createDirectory(at: f.storage, withIntermediateDirectories: false)
                try Data("foreign parent".utf8).write(to: f.storage.appendingPathComponent("foreign.txt"))
            }
        })
        #expect(result.state == "needsReview")
        let actual = change == "parent" ? movedParent.appendingPathComponent(f.intake.directoryURL.lastPathComponent) : f.intake.directoryURL
        let retained = try #require(result.retainedAt)
        #expect(LocalEntryIdentity.read(retained) == LocalEntryIdentity.read(actual))
        #expect(result.restoreFailure == (change == "cancel" ? .cancelled : .changed))
        let bytes = try Data(contentsOf: actual.appendingPathComponent("Files/received.txt"))
        #expect(bytes == Data((change == "payload" ? "edited during publication" : "retained original").utf8))
        if change == "additional" { #expect(try Data(contentsOf: actual.appendingPathComponent("new.txt")) == Data("additional user data".utf8)) }
        if change == "parent" { #expect(try Data(contentsOf: f.storage.appendingPathComponent("foreign.txt")) == Data("foreign parent".utf8)) }
    }
}

@Test func promisedRestoreRejectsReplacedLinkedAndMetadataChangedSources() async throws {
    for mutation in ["identity", "symlink", "mode", "xattr"] {
        let f = try RestoreFixture(); defer { f.remove() }; let row = try await f.prepare()
        let location = try #require(row.location), preserved = f.root.appendingPathComponent("preserved-original")
        let payload = location.appendingPathComponent("Files/received.txt")
        if mutation == "identity" || mutation == "symlink" {
            try FileManager.default.moveItem(at: location, to: preserved)
            if mutation == "identity" { try FileManager.default.copyItem(at: preserved, to: location) }
            else { try FileManager.default.createSymbolicLink(at: location, withDestinationURL: preserved) }
        } else if mutation == "mode" {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        } else {
            let value = Data("changed metadata".utf8)
            let status = value.withUnsafeBytes { setxattr(payload.path, "org.files-mac.restore-qa", $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
            #expect(status == 0)
        }
        #expect(throws: (any Error).self) { try row.restore(storage: f.storage) }
        #expect(!FileManager.default.fileExists(atPath: f.intake.directoryURL.path))
        #expect(try Data(contentsOf: payload) == Data("retained original".utf8))
        if mutation == "identity" || mutation == "symlink" {
            #expect(try Data(contentsOf: preserved.appendingPathComponent("Files/received.txt")) == Data("retained original".utf8))
        }
    }
}
