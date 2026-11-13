import Foundation
import Darwin
import Testing
@testable import FilesCore

@Test func mountedVolumeCopyMoveUndoAndCaseSemantics() async throws {
    let environment = ProcessInfo.processInfo.environment
    let configurations: [(String, Bool)] = [
        ("FILES_TEST_APFS_VOLUME", false),
        ("FILES_TEST_APFSX_VOLUME", true),
        ("FILES_TEST_EXFAT_VOLUME", false)
    ]
    guard configurations.allSatisfy({ environment[$0.0] != nil }) else { return }
    for (key, caseSensitive) in configurations {
        let volume = URL(fileURLWithPath: environment[key]!, isDirectory: true)
        let root = volume.appendingPathComponent("FilesM2-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("FilesM2-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: local) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        let copySource = local.appendingPathComponent("copy-source", isDirectory: true)
        try FileManager.default.createDirectory(at: copySource, withIntermediateDirectories: true)
        try Data("한글-é-📁".utf8).write(to: copySource.appendingPathComponent("payload.txt"))
        let copy = await CopyEngine.run(sources: [copySource], destination: destination,
                                        journalDirectory: journal, cancellation: CopyCancellation())
        #expect(copy.state == "completed")
        let copied = destination.appendingPathComponent("copy-source/payload.txt")
        #expect(try Data(contentsOf: copied) == Data("한글-é-📁".utf8))
        let copyUndo = try #require(CopyEngine.latestUndoCopy(journalDirectory: journal))
        let copyUndoResult = await CopyEngine.undoCopy(copyUndo, journalDirectory: journal)
        #expect(copyUndoResult.state == "completed")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("copy-source").path))

        let moveSource = local.appendingPathComponent("move-source.txt")
        try Data(repeating: 0xA5, count: 256 * 1024).write(to: moveSource)
        let move = try await EntryOperations.move([moveSource], to: destination,
            conflictPolicy: .skip, journalDirectory: journal)
        #expect(move.state == "completed")
        #expect(!FileManager.default.fileExists(atPath: moveSource.path))
        let moved = destination.appendingPathComponent("move-source.txt")
        #expect(try Data(contentsOf: moved) == Data(repeating: 0xA5, count: 256 * 1024))
        let moveUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let moveUndoResult = await EntryOperations.undoMove(moveUndo, journalDirectory: journal)
        #expect(moveUndoResult.state == "completed")
        #expect(try Data(contentsOf: moveSource) == Data(repeating: 0xA5, count: 256 * 1024))

        let replaceSource = local.appendingPathComponent("replace.txt")
        let replaceTarget = destination.appendingPathComponent("replace.txt")
        try Data("new".utf8).write(to: replaceSource)
        try Data("old".utf8).write(to: replaceTarget)
        let replace = try await EntryOperations.move([replaceSource], to: destination,
            conflictPolicy: .replace, journalDirectory: journal)
        #expect(replace.state == "completed")
        #expect(try String(contentsOf: replaceTarget, encoding: .utf8) == "new")
        let replaceUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let replaceUndoResult = await EntryOperations.undoMove(replaceUndo, journalDirectory: journal)
        #expect(replaceUndoResult.state == "completed")
        #expect(try String(contentsOf: replaceSource, encoding: .utf8) == "new")
        #expect(try String(contentsOf: replaceTarget, encoding: .utf8) == "old")

        let first = root.appendingPathComponent("CaseProbe")
        let second = root.appendingPathComponent("caseprobe")
        let firstFD = open(first.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(firstFD >= 0); if firstFD >= 0 { close(firstFD) }
        let secondFD = open(second.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if caseSensitive { #expect(secondFD >= 0) }
        else { #expect(secondFD == -1 && errno == EEXIST) }
        if secondFD >= 0 { close(secondFD) }
    }
}

@Test func systemTrashMoveAndRestoreRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["FILES_TEST_SYSTEM_TRASH"] == "1" else { return }
    let fm = FileManager.default
    let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FilesMac-TrashTest-\(UUID().uuidString)", isDirectory: true)
    let restore = root.appendingPathComponent("restored", isDirectory: true)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    let source = root.appendingPathComponent("휴지통-é-📁.txt")
    var trashed: URL?
    defer {
        if let trashed { try? fm.removeItem(at: trashed) }
        try? fm.removeItem(at: root)
    }
    try fm.createDirectory(at: restore, withIntermediateDirectories: true)
    try Data("trash-round-trip".utf8).write(to: source)

    let trash = try await EntryOperations.moveToTrash([source], journalDirectory: journal)
    trashed = trash.items.first?.trashed
    #expect(trash.state == "completed")
    let trashedURL = try #require(trashed)
    #expect(!fm.fileExists(atPath: source.path))
    #expect(fm.fileExists(atPath: trashedURL.path))

    let restored = try await EntryOperations.restoreFromTrash([trashedURL], to: restore,
                                                               journalDirectory: journal)
    #expect(restored.state == "completed")
    let restoredURL = restore.appendingPathComponent(trashedURL.lastPathComponent)
    #expect(try String(contentsOf: restoredURL, encoding: .utf8) == "trash-round-trip")
    trashed = nil
}

@Test func mountedSMBCopyMoveUndoRoundTrip() async throws {
    guard let path = ProcessInfo.processInfo.environment["FILES_TEST_SMB_VOLUME"] else { return }
    let fm = FileManager.default
    let volume = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var fileSystem = statfs()
    guard statfs(volume.path, &fileSystem) == 0 else {
        Issue.record("Cannot inspect SMB fixture mount: \(String(cString: strerror(errno)))")
        return
    }
    let type = withUnsafePointer(to: &fileSystem.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
    }
    guard type == "smbfs" else {
        Issue.record("FILES_TEST_SMB_VOLUME must be on smbfs, got \(type)")
        return
    }

    let root = volume.appendingPathComponent("FilesM2-SMB-\(UUID().uuidString)", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    let local = fm.temporaryDirectory.appendingPathComponent("FilesM2-SMB-source-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: local) }
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try fm.createDirectory(at: local, withIntermediateDirectories: true)

    let copySource = local.appendingPathComponent("복사-é-📁", isDirectory: true)
    try fm.createDirectory(at: copySource, withIntermediateDirectories: true)
    let payload = Data(repeating: 0x5A, count: 512 * 1024)
    try payload.write(to: copySource.appendingPathComponent("payload.bin"))
    let copy = await CopyEngine.run(sources: [copySource], destination: destination,
                                    journalDirectory: journal, cancellation: CopyCancellation())
    #expect(copy.state == "completed")
    #expect(try Data(contentsOf: destination.appendingPathComponent("복사-é-📁/payload.bin")) == payload)
    let copyUndo = try #require(CopyEngine.latestUndoCopy(journalDirectory: journal))
    #expect(await CopyEngine.undoCopy(copyUndo, journalDirectory: journal).state == "completed")

    let moveSource = local.appendingPathComponent("move.txt")
    try Data("network-move".utf8).write(to: moveSource)
    let move = try await EntryOperations.move([moveSource], to: destination,
        conflictPolicy: .skip, journalDirectory: journal)
    #expect(move.state == "completed")
    let moveUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(await EntryOperations.undoMove(moveUndo, journalDirectory: journal).state == "completed")
    #expect(try String(contentsOf: moveSource, encoding: .utf8) == "network-move")

    let replacement = local.appendingPathComponent("replace.txt")
    let existing = destination.appendingPathComponent("replace.txt")
    try Data("new".utf8).write(to: replacement)
    try Data("old".utf8).write(to: existing)
    let replace = try await EntryOperations.move([replacement], to: destination,
        conflictPolicy: .replace, journalDirectory: journal)
    #expect(replace.state == "completed")
    let replaceUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(await EntryOperations.undoMove(replaceUndo, journalDirectory: journal).state == "completed")
    #expect(try String(contentsOf: replacement, encoding: .utf8) == "new")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
}
