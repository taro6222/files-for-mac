import Darwin
import Foundation
import Testing
@testable import FilesCore

@Test func moveUndoInterruptionWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["FILES_UNDO_INTERRUPTION_ROOT"],
          let phase = environment["FILES_UNDO_INTERRUPTION_PHASE"] else { return }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let destination = root.appendingPathComponent("mount", isDirectory: true)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    let source = root.appendingPathComponent("item.txt")
    let target = destination.appendingPathComponent("item.txt")
    let fm = FileManager.default

    switch phase {
    case "interrupt":
        try Data("new".utf8).write(to: source, options: .withoutOverwriting)
        try Data("old".utf8).write(to: target, options: .withoutOverwriting)
        let move = try await EntryOperations.move([source], to: destination,
            conflictPolicy: .replace, journalDirectory: journal)
        try #require(move.state == "completed")
        let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        try #require(record.items.first?.crossVolume == true)
        let outcome = await EntryOperations.undoMove(record, journalDirectory: journal,
            afterCopyPublication: {
                try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("copy-published"), options: .atomic)
                if kill(getpid(), SIGKILL) != 0 { throw POSIXError(.EPERM) }
            }, beforeBackupRestore: { _ in })
        Issue.record("Worker returned instead of terminating: \(outcome.state)")
    case "resume":
        let record = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let worker = try String(contentsOf: root.appendingPathComponent("copy-published"), encoding: .utf8)
        #expect(Int32(worker) != getpid())
        #expect(!fm.fileExists(atPath: journal.appendingPathComponent("undo-result-\(record.operationId).json").path))
        let item = try #require(record.items.first)
        let backup = try #require(item.backup)
        #expect(item.restoredCopyIdentity != nil)
        #expect(item.backupRestorePending != true)
        #expect(try Data(contentsOf: source) == Data("new".utf8))
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(try Data(contentsOf: backup) == Data("old".utf8))
        let resumed = await EntryOperations.undoMove(record, journalDirectory: journal)
        #expect(resumed.state == "completed")
        #expect(resumed.journalError == nil)
        #expect(try Data(contentsOf: source) == Data("new".utf8))
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
    default:
        Issue.record("Unexpected interruption test phase: \(phase)")
    }
}
