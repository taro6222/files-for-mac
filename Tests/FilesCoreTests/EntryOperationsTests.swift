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
