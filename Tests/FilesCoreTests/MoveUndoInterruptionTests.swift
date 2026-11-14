import Darwin
import Foundation
import Testing
@testable import FilesCore

@Test func moveUndoInterruptionWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["FILES_UNDO_INTERRUPTION_ROOT"],
          let phase = environment["FILES_UNDO_INTERRUPTION_PHASE"] else { return }
    let checkpoint = environment["FILES_UNDO_INTERRUPTION_CHECKPOINT"] ?? "copy-published"
    try #require(["copy-published", "backup-pending"].contains(checkpoint))
    let parent = URL(fileURLWithPath: path, isDirectory: true)
    let root = parent.appendingPathComponent(checkpoint, isDirectory: true)
    let destination = parent.appendingPathComponent("mount/\(checkpoint)", isDirectory: true)
    let marker = root.appendingPathComponent("worker-pid")
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    let source = root.appendingPathComponent("item.txt")
    let target = destination.appendingPathComponent("item.txt")
    let fm = FileManager.default

    switch phase {
    case "interrupt":
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source, options: .withoutOverwriting)
        try Data("old".utf8).write(to: target, options: .withoutOverwriting)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: source.path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_060)], ofItemAtPath: target.path)
        let move = try await EntryOperations.move([source], to: destination,
            conflictPolicy: .replace, journalDirectory: journal)
        try #require(move.state == "completed")
        let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        try #require(record.items.first?.crossVolume == true)
        let outcome = await EntryOperations.undoMove(record, journalDirectory: journal,
            afterCopyPublication: {
                guard checkpoint == "copy-published" else { return }
                try Data(String(getpid()).utf8).write(to: marker, options: .atomic)
                if kill(getpid(), SIGKILL) != 0 { throw POSIXError(.EPERM) }
            }, beforeBackupRestore: { _ in
                guard checkpoint == "backup-pending" else { return }
                do {
                    try Data(String(getpid()).utf8).write(to: marker, options: .atomic)
                    if kill(getpid(), SIGKILL) != 0 { throw POSIXError(.EPERM) }
                } catch { Issue.record(error) }
            })
        Issue.record("Worker returned instead of terminating: \(outcome.state)")
    case "resume":
        let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let worker = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        #expect(worker != getpid())
        #expect(!fm.fileExists(atPath: journal.appendingPathComponent("undo-result-\(record.operationId).json").path))
        let item = try #require(record.items.first)
        let backup = try #require(item.backup)
        #expect(item.restoredCopyIdentity != nil)
        #expect(item.restoredCopyMetadata != nil)
        #expect((item.backupRestorePending == true) == (checkpoint == "backup-pending"))
        #expect(try Data(contentsOf: source) == Data("new".utf8))
        #expect(try Data(contentsOf: backup) == Data("old".utf8))

        if checkpoint == "backup-pending" {
            #expect(!fm.fileExists(atPath: target.path))
            try Data("external".utf8).write(to: target, options: .withoutOverwriting)
            let blocked = await EntryOperations.undoMove(record, journalDirectory: journal)
            #expect(blocked.items.map(\.state) == ["conflict"])
            #expect(try Data(contentsOf: target) == Data("external".utf8))
            #expect(try Data(contentsOf: backup) == Data("old".utf8))
            try fm.removeItem(at: target)
        } else {
            #expect(try Data(contentsOf: target) == Data("new".utf8))
            // A metadata-only edit after the checkpoint must prevent source deletion.
            let attribute = "com.filesmac.interruption-test"
            let value: UInt8 = 42
            try #require(withUnsafePointer(to: value) { setxattr(source.path, attribute, $0, 1, 0, 0) } == 0)
            let blocked = await EntryOperations.undoMove(record, journalDirectory: journal)
            #expect(blocked.items.map(\.state) == ["conflict"])
            #expect(try Data(contentsOf: source) == Data("new".utf8))
            #expect(try Data(contentsOf: target) == Data("new".utf8))
            #expect(try Data(contentsOf: backup) == Data("old".utf8))
            #expect(getxattr(source.path, attribute, nil, 0, 0, 0) == 1)
            try #require(removexattr(source.path, attribute, 0) == 0)
        }

        let retry = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let resumed = await EntryOperations.undoMove(retry, journalDirectory: journal)
        #expect(resumed.state == "completed")
        #expect(resumed.journalError == nil)
        #expect(try Data(contentsOf: source) == Data("new".utf8))
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(try fm.attributesOfItem(atPath: source.path)[.creationDate] as? Date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(try fm.attributesOfItem(atPath: target.path)[.creationDate] as? Date == Date(timeIntervalSince1970: 1_600_000_060))
        #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
    default:
        Issue.record("Unexpected interruption test phase: \(phase)")
    }
}
