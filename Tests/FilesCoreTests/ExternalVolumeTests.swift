import Foundation
import Darwin
import Testing
@testable import FilesCore

func hasIntegrationFixture(_ keys: String...) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return keys.contains { environment[$0] != nil }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_APFS_VOLUME", "FILES_TEST_APFSX_VOLUME", "FILES_TEST_EXFAT_VOLUME"), "Requires an integration fixture"))
func mountedVolumeProviderDiscoversRealMatrix() throws {
    let environment = ProcessInfo.processInfo.environment
    let keys = ["FILES_TEST_APFS_VOLUME", "FILES_TEST_APFSX_VOLUME", "FILES_TEST_EXFAT_VOLUME"]
    guard keys.allSatisfy({ environment[$0] != nil }) else { Issue.record("Integration fixture is incomplete"); return }
    let discovered = MountedVolumeProvider().mountedVolumes()
    for key in keys {
        let expected = URL(fileURLWithPath: environment[key]!, isDirectory: true).standardizedFileURL
        let volume = try #require(discovered.first { $0.url == expected }, "Mounted volume provider did not return \(expected.path)")
        #expect(volume.totalCapacity != nil); #expect(volume.availableCapacity != nil)
        #expect(volume.formatDescription?.isEmpty == false); #expect(volume.isLocal == true)
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_APFSX_VOLUME"), "Requires an integration fixture"))
func mountedVolumeRetriesFailedCrossVolumeMoveBeforePublication() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["FILES_TEST_APFSX_VOLUME"])
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("FilesMac-Retry-\(UUID())", isDirectory: true)
    let destination = URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: destination) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let source = root.appendingPathComponent("retry.txt")
    let target = destination.appendingPathComponent(source.lastPathComponent)
    let data = Data("original file".utf8)
    try data.write(to: source)
    let destinationEntry = try #require(ShelfEntry(destination))
    let original = try await EntryOperations.move([source], to: destination, journalDirectory: journal) { progress in
        guard progress.phase == "verifying" else { return }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            let stage = try #require(names.first { $0.hasPrefix(".files-move-") })
            try Data("incorrect staged bytes".utf8).write(
                to: destination.appendingPathComponent(stage).appendingPathComponent("payload"))
        } catch {
            Issue.record(Comment(rawValue: "Could not modify the test staging file: \(error)"))
        }
    }
    try #require(original.items.first?.state == "failed")
    let retrySource = try #require(original.items.first?.retrySource)
    #expect(try Data(contentsOf: source) == data)
    #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)

    let external = Data("external destination".utf8)
    try external.write(to: target)
    let conflict = try await EntryOperations.retryMove([retrySource], to: destinationEntry,
        journalDirectory: journal, cancellation: CopyCancellation())
    #expect(conflict.items.first?.state == "conflict")
    #expect(try Data(contentsOf: target) == external)
    #expect(try Data(contentsOf: source) == data)

    try fm.removeItem(at: target)
    let retried = try await EntryOperations.retryMove([retrySource], to: destinationEntry,
        journalDirectory: journal, cancellation: CopyCancellation())
    try #require(retried.state == "completed",
                 Comment(rawValue: retried.items.first?.message ?? "Cross-volume retry failed"))
    #expect(try Data(contentsOf: target) == data)
    #expect(!fm.fileExists(atPath: source.path))
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(await EntryOperations.undoMove(undo, journalDirectory: journal).state == "completed")
    #expect(try Data(contentsOf: source) == data)
    #expect(!fm.fileExists(atPath: target.path))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_APFSX_VOLUME"), "Requires an integration fixture"))
func mountedVolumeAPFSPreservesFileMetadataThroughCopyMoveAndUndo() async throws {
    guard let path = ProcessInfo.processInfo.environment["FILES_TEST_APFSX_VOLUME"] else { Issue.record("Integration fixture is incomplete"); return }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("FilesMac-Metadata-\(UUID())", isDirectory: true)
    let destination = URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: destination) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)

    let name = "-한글 é 📁\nfixture.txt"
    let source = root.appendingPathComponent(name)
    let target = destination.appendingPathComponent(name)
    let payload = Data("data fork".utf8)
    let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    let creationDate = Date(timeIntervalSince1970: 1_600_000_000)
    let accessSeconds = 1_650_000_000
    let xattrs = [
        "com.filesmac.fixture": Data("extended attribute".utf8),
        "com.apple.ResourceFork": Data("resource fork".utf8),
        "com.apple.metadata:_kMDItemUserTags": try PropertyListSerialization.data(
            fromPropertyList: ["FilesMac Fixture\n6"], format: .binary, options: 0)
    ]
    try payload.write(to: source)
    for (key, value) in xattrs {
        let status = value.withUnsafeBytes { setxattr(source.path, key, $0.baseAddress, $0.count, 0, 0) }
        try #require(status == 0, "Unable to set \(key): \(errno)")
    }
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "everyone allow readattr", source.path]
    try chmod.run()
    chmod.waitUntilExit()
    try #require(chmod.terminationStatus == 0)
    try fm.setAttributes([.posixPermissions: 0o750, .modificationDate: modificationDate,
                          .creationDate: creationDate], ofItemAtPath: source.path)

    func aclText(_ file: URL) throws -> String {
        let acl = try #require(acl_get_file(file.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let text = try #require(acl_to_text(acl, nil))
        defer { acl_free(text) }
        return String(cString: text)
    }
    let expectedACL = try aclText(source)
    func setAccessTime(_ file: URL) throws {
        var dates = [timespec(tv_sec: accessSeconds, tv_nsec: 0),
                     timespec(tv_sec: Int(modificationDate.timeIntervalSince1970), tv_nsec: 0)]
        try #require(utimensat(AT_FDCWD, file.path, &dates, AT_SYMLINK_NOFOLLOW) == 0)
    }
    func verifyAccessTime(_ file: URL) throws {
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        #expect(info.st_atimespec.tv_sec == accessSeconds)
        #expect(info.st_atimespec.tv_nsec == 0)
    }
    func verify(_ file: URL) throws {
        #expect(try Data(contentsOf: file) == payload)
        let attrs = try fm.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o750)
        #expect(attrs[.modificationDate] as? Date == modificationDate)
        #expect(attrs[.creationDate] as? Date == creationDate)
        #expect(try aclText(file) == expectedACL)
        for (key, expected) in xattrs {
            var actual = Data(count: expected.count)
            let count = actual.withUnsafeMutableBytes { getxattr(file.path, key, $0.baseAddress, $0.count, 0, 0) }
            #expect(count == expected.count && actual == expected, "Metadata mismatch for \(key)")
        }
    }

    try setAccessTime(source)
    let copy = await CopyEngine.run(sources: [source], destination: destination,
        journalDirectory: journal, cancellation: CopyCancellation())
    try #require(copy.items.first?.state == "completed")
    try verifyAccessTime(target)
    try verify(source)
    try verify(target)
    let copyUndo = try #require(CopyEngine.latestUndoCopy(journalDirectory: journal))
    #expect(await CopyEngine.undoCopy(copyUndo, journalDirectory: journal).state == "completed")
    #expect(!fm.fileExists(atPath: target.path))
    try setAccessTime(source)
    let move = try await EntryOperations.move([source], to: destination, journalDirectory: journal)
    try #require(move.items.first?.state == "completed")
    #expect(!fm.fileExists(atPath: source.path))
    try verifyAccessTime(target)
    try verify(target)
    let moveUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(moveUndo.items.first?.crossVolume == true)
    try setAccessTime(target)
    #expect(await EntryOperations.undoMove(moveUndo, journalDirectory: journal).state == "completed")
    try verifyAccessTime(source)
    try verify(source)
    #expect(!fm.fileExists(atPath: target.path))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_APFSX_VOLUME", "FILES_TEST_EXFAT_VOLUME",
                                         "FILES_TEST_FAT32_VOLUME", "FILES_TEST_HFS_VOLUME"),
               "Requires the mounted volume matrix"), arguments: [
    ("FILES_TEST_APFSX_VOLUME", 0.000001),
    ("FILES_TEST_EXFAT_VOLUME", 1.0),
    ("FILES_TEST_FAT32_VOLUME", 2.0),
    ("FILES_TEST_HFS_VOLUME", 1.0)
])
func mountedVolumePreservesNestedCreationTimes(volumeKey: String, tolerance: TimeInterval) async throws {
    guard let path = ProcessInfo.processInfo.environment[volumeKey] else { Issue.record("Missing fixture: \(volumeKey)"); return }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("FilesMac-FolderDates-\(UUID())", isDirectory: true)
    let destination = URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    let source = root.appendingPathComponent("folder", isDirectory: true)
    let target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: destination) }
    try fm.createDirectory(at: source.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let file = source.appendingPathComponent("nested/file.txt")
    try Data("creation time".utf8).write(to: file)
    let rootDate = Date(timeIntervalSince1970: 1_600_000_001.987)
    let nestedDate = rootDate.addingTimeInterval(60)
    let fileDate = nestedDate.addingTimeInterval(60)
    try fm.setAttributes([.creationDate: rootDate], ofItemAtPath: source.path)
    try fm.setAttributes([.creationDate: nestedDate], ofItemAtPath: source.appendingPathComponent("nested").path)
    try fm.setAttributes([.creationDate: fileDate], ofItemAtPath: file.path)
    let accessSeconds = 1_650_000_001
    let checkAccessTime = volumeKey == "FILES_TEST_APFSX_VOLUME" || volumeKey == "FILES_TEST_EXFAT_VOLUME"
    func setAccessTime(_ entry: URL) throws {
        var times = [timespec(tv_sec: accessSeconds, tv_nsec: 987_000_000),
                     timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
        try #require(utimensat(AT_FDCWD, entry.path, &times, AT_SYMLINK_NOFOLLOW) == 0)
    }
    func verifyAccessTime(_ folder: URL) throws {
        guard checkAccessTime else { return }
        let isExFAT = volumeKey == "FILES_TEST_EXFAT_VOLUME"
        for entry in [folder, folder.appendingPathComponent("nested"), folder.appendingPathComponent("nested/file.txt")] {
            var info = stat()
            try #require(lstat(entry.path, &info) == 0)
            #expect(info.st_atimespec.tv_sec == (isExFAT ? accessSeconds - 1 : accessSeconds))
            #expect(info.st_atimespec.tv_nsec == (isExFAT ? 0 : 987_000_000))
        }
    }
    func prepareAccessTimes() throws {
        guard checkAccessTime else { return }
        try setAccessTime(source)
        try setAccessTime(source.appendingPathComponent("nested"))
        try setAccessTime(file)
    }
    func dates(in folder: URL) throws -> [Date] {
        try [folder, folder.appendingPathComponent("nested"), folder.appendingPathComponent("nested/file.txt")].map {
            try #require(try fm.attributesOfItem(atPath: $0.path)[.creationDate] as? Date)
        }
    }
    func verify(_ folder: URL) throws -> [Date] {
        let actual = try dates(in: folder)
        for (date, expected) in zip(actual, [rootDate, nestedDate, fileDate]) {
            #expect(abs(date.timeIntervalSince(expected)) < tolerance)
        }
        return actual
    }
    try prepareAccessTimes()
    let copy = await CopyEngine.run(sources: [source], destination: destination,
                                    journalDirectory: journal, cancellation: CopyCancellation())
    try #require(copy.state == "completed", Comment(rawValue: copy.items.first?.message ?? ""))
    try verifyAccessTime(target)
    _ = try verify(target)
    let copyUndo = try #require(CopyEngine.latestUndoCopy(journalDirectory: journal))
    try #require(await CopyEngine.undoCopy(copyUndo, journalDirectory: journal).state == "completed")
    try prepareAccessTimes()
    let move = try await EntryOperations.move([source], to: destination, journalDirectory: journal)
    try #require(move.state == "completed", Comment(rawValue: move.items.first?.message ?? ""))
    try verifyAccessTime(target)
    let movedDates = try verify(target)
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    try #require(await EntryOperations.undoMove(undo, journalDirectory: journal).state == "completed")
    if checkAccessTime {
        let isExFAT = volumeKey == "FILES_TEST_EXFAT_VOLUME"
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        #expect(info.st_atimespec.tv_sec == (isExFAT ? accessSeconds - 1 : accessSeconds))
        #expect(info.st_atimespec.tv_nsec == (isExFAT ? 0 : 987_000_000))
    }
    let restoredDates = try dates(in: source)
    for (restored, moved) in zip(restoredDates, movedDates) {
        #expect(abs(restored.timeIntervalSince(moved)) < 0.000001)
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_APFS_VOLUME", "FILES_TEST_APFSX_VOLUME", "FILES_TEST_EXFAT_VOLUME"), "Requires an integration fixture"))
func mountedVolumeCopyMoveUndoAndCaseSemantics() async throws {
    let environment = ProcessInfo.processInfo.environment
    let configurations: [(String, Bool)] = [
        ("FILES_TEST_APFS_VOLUME", false),
        ("FILES_TEST_APFSX_VOLUME", true),
        ("FILES_TEST_EXFAT_VOLUME", false)
    ]
    guard configurations.allSatisfy({ environment[$0.0] != nil }) else { Issue.record("Integration fixture is incomplete"); return }
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
        let modified = Date(timeIntervalSince1970: 1_700_000_000.123)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: moveSource.path)
        let move = try await EntryOperations.move([moveSource], to: destination,
            conflictPolicy: .skip, journalDirectory: journal)
        #expect(move.state == "completed")
        #expect(!FileManager.default.fileExists(atPath: moveSource.path))
        let moved = destination.appendingPathComponent("move-source.txt")
        #expect(try Data(contentsOf: moved) == Data(repeating: 0xA5, count: 256 * 1024))
        let movedDate = try #require(try FileManager.default.attributesOfItem(atPath: moved.path)[.modificationDate] as? Date)
        #expect(abs(movedDate.timeIntervalSince(modified)) < 0.01)
        let moveUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let moveUndoResult = await EntryOperations.undoMove(moveUndo, journalDirectory: journal)
        #expect(moveUndoResult.state == "completed")
        #expect(try Data(contentsOf: moveSource) == Data(repeating: 0xA5, count: 256 * 1024))
        #expect(try FileManager.default.attributesOfItem(atPath: moveSource.path)[.modificationDate] as? Date == movedDate)
        let redo = try #require(moveUndoResult.redo)
        #expect(await EntryOperations.redoMove(redo, journalDirectory: journal).first?.state == "completed")
        #expect(!FileManager.default.fileExists(atPath: moveSource.path))
        #expect(try Data(contentsOf: moved) == Data(repeating: 0xA5, count: 256 * 1024))

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

        try await verifyMountedVolumeReplacementCancellation(local: local, destination: destination, journal: journal)
        try await verifyMountedVolumeChangedBackupCancellation(local: local, destination: destination, journal: journal)
        try await verifyCrossVolumeMovePreservesReplacedDestination(local: local, destination: destination, journal: journal)
        let folder = root.appendingPathComponent("same-volume-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let existingFolder = destination.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: false)
        let existingChild = existingFolder.appendingPathComponent("child.txt")
        try Data("existing".utf8).write(to: existingChild)
        let cancellation = CopyCancellation()
        let cancelledMove = try await EntryOperations.move([folder], to: destination,
            conflictPolicy: .replace, journalDirectory: journal, cancellation: cancellation) { progress in
            if progress.phase == "verifyingUndo" { cancellation.cancel() }
        }
        #expect(cancelledMove.items.map(\.state) == ["cancelled"])
        #expect(try String(contentsOf: folder.appendingPathComponent("child.txt"), encoding: .utf8) == "original")
        #expect(try String(contentsOf: existingChild, encoding: .utf8) == "existing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
            !$0.hasPrefix(".files-move-backup-")
        })
        let cancelledJournal = try Data(contentsOf: journal.appendingPathComponent("move-\(cancelledMove.id).json"))
        let recorded = try #require(JSONSerialization.jsonObject(with: cancelledJournal) as? [String: Any])
        let recordedItems = try #require(recorded["items"] as? [[String: Any]])
        #expect(recordedItems.first?["backup"] == nil)
        try FileManager.default.removeItem(at: existingFolder)
        let folderMove = try await EntryOperations.move([folder], to: destination, journalDirectory: journal)
        #expect(folderMove.items.map(\.state) == ["completed"])
        let folderUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        #expect(folderUndo.operationId == folderMove.id)
        #expect(folderUndo.items.first?.crossVolume == false)
        let movedChild = destination.appendingPathComponent(folder.lastPathComponent).appendingPathComponent("child.txt")
        try Data("external edit".utf8).write(to: movedChild)
        let folderUndoResult = await EntryOperations.undoMove(folderUndo, journalDirectory: journal)
        #expect(folderUndoResult.items.map(\.state) == ["changed"])
        #expect(try String(contentsOf: movedChild, encoding: .utf8) == "external edit")
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let entries = try await LocalFileSystem().contents(of: destination, showHidden: true)
        let identity = try #require(entries.first { $0.name == replaceTarget.lastPathComponent }?.identity)
        let occupied = destination.appendingPathComponent("occupied.txt")
        try Data("keep".utf8).write(to: occupied)
        await #expect(throws: EntryOperationError.self) {
            try await EntryOperations.rename(replaceTarget, to: occupied.lastPathComponent,
                expectedIdentity: identity, journalDirectory: journal)
        }
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep")
        let renamed = try await EntryOperations.rename(replaceTarget, to: "renamed.txt",
            expectedIdentity: identity, journalDirectory: journal)
        #expect(try String(contentsOf: renamed.target, encoding: .utf8) == "old")

        let swap = try await EntryOperations.batchRename([
            .init(source: renamed.target, name: occupied.lastPathComponent),
            .init(source: occupied, name: renamed.target.lastPathComponent),
        ], journalDirectory: journal)
        #expect(swap.state == "completed", "Batch swap failed on \(key): \(swap.items.map(\.message))")
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "old")
        #expect(try String(contentsOf: renamed.target, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
            !$0.hasPrefix(".files-rename-")
        })
        if !caseSensitive {
            let partial = try await EntryOperations.batchRename([
                .init(source: occupied, name: "Output.txt"),
                .init(source: renamed.target, name: "output.txt"),
            ], journalDirectory: journal)
            #expect(partial.state == "failed")
            #expect(partial.items.map(\.state) == ["completed", "failed"])
            #expect(try String(contentsOf: destination.appendingPathComponent("Output.txt"), encoding: .utf8) == "old")
            #expect(try String(contentsOf: renamed.target, encoding: .utf8) == "keep")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
                !$0.hasPrefix(".files-rename-")
            })
        }

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

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_EXFAT_VOLUME"), "Requires an integration fixture"))
func mountedVolumeExFATMoveKeepsSourceWhenACLDoesNotTransfer() async throws {
    guard let path = ProcessInfo.processInfo.environment["FILES_TEST_EXFAT_VOLUME"] else { Issue.record("Integration fixture is incomplete"); return }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("FilesMac-ACL-\(UUID())", isDirectory: true)
    let destination = URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: destination) }
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let source = root.appendingPathComponent("access.txt")
    let target = destination.appendingPathComponent(source.lastPathComponent)
    let payload = Data("ACL transfer check".utf8)
    try payload.write(to: source)
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "everyone allow readattr", source.path]
    try chmod.run()
    chmod.waitUntilExit()
    try #require(chmod.terminationStatus == 0)

    let report = try await EntryOperations.move([source], to: destination,
        journalDirectory: root.appendingPathComponent("journal"))
    #expect(report.items.first?.state == "failed")
    #expect(report.items.first?.message == CopyEngine.TransferMismatch.accessControlList.localizedDescription)
    #expect(try Data(contentsOf: source) == payload)
    let acl = try #require(acl_get_file(source.path, ACL_TYPE_EXTENDED))
    acl_free(UnsafeMutableRawPointer(acl))
    #expect(!fm.fileExists(atPath: target.path))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SYSTEM_TRASH"), "Requires an integration fixture"))
func systemTrashMoveAndRestoreRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["FILES_TEST_SYSTEM_TRASH"] == "1" else { Issue.record("Integration fixture is incomplete"); return }
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

private func smbFixture(_ key: String) throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment[key])
    let volume = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var fileSystem = statfs()
    try #require(statfs(volume.path, &fileSystem) == 0, "Cannot inspect the SMB fixture mount")
    let type = withUnsafePointer(to: &fileSystem.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
    }
    try #require(type == "smbfs", "\(key) must be on smbfs")
    return volume
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_VOLUME"), "Requires an integration fixture"))
func mountedSMBCopyMoveUndoRoundTrip() async throws {
    let fm = FileManager.default
    let volume = try smbFixture("FILES_TEST_SMB_VOLUME")
    let root = volume.appendingPathComponent("FilesM2-SMB-\(UUID().uuidString)", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    let local = fm.temporaryDirectory.appendingPathComponent("FilesM2-SMB-source-\(UUID().uuidString)", isDirectory: true)
    let journal = local.appendingPathComponent("journal", isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: local) }
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try fm.createDirectory(at: local, withIntermediateDirectories: true)

    let filesystem = LocalFileSystem()
    func visibleNames(in directory: URL) async throws -> Set<String> {
        Set(try await filesystem.contents(of: directory, showHidden: false).map(\.name))
    }
    let copyDestination = root.appendingPathComponent("copy", isDirectory: true)
    let listingDestination = root.appendingPathComponent("listing", isDirectory: true)
    for directory in [copyDestination, listingDestination] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    do { print(try smbRenameIdentityDiagnostic(in: root)) }
    catch { print("SMB rename identity probe failed: \(error.localizedDescription)") }
    #expect(try await visibleNames(in: listingDestination).isEmpty)

    let copySource = local.appendingPathComponent("복사-é-📁", isDirectory: true)
    try fm.createDirectory(at: copySource, withIntermediateDirectories: true)
    let payload = Data(repeating: 0x5A, count: 512 * 1024)
    try payload.write(to: copySource.appendingPathComponent("payload.bin"))
    let copy = await CopyEngine.run(sources: [copySource], destination: copyDestination,
                                    journalDirectory: journal, cancellation: CopyCancellation())
    if copy.state != "completed" {
        #expect(try Data(contentsOf: copySource.appendingPathComponent("payload.bin")) == payload)
        #expect(try fm.contentsOfDirectory(atPath: copyDestination.path).isEmpty)
        print(smbCopyDiagnostic(source: copySource, destination: root))
        Issue.record(Comment(rawValue: copy.items.first?.message ?? "SMB copy did not complete"))
    } else {
        #expect(try await visibleNames(in: copyDestination) == [copySource.lastPathComponent])
        let copiedFolder = copyDestination.appendingPathComponent(copySource.lastPathComponent)
        #expect(try await visibleNames(in: copiedFolder) == ["payload.bin"])
        #expect(try Data(contentsOf: copiedFolder.appendingPathComponent("payload.bin")) == payload)
        if let copyUndo = CopyEngine.latestUndoCopy(journalDirectory: journal) {
            let undo = await CopyEngine.undoCopy(copyUndo, journalDirectory: journal)
            if undo.state != "completed", let item = copyUndo.items.first {
                print(smbUndoCopyDiagnostic(item))
            }
            #expect(undo.state == "completed", Comment(rawValue: undo.items.first?.message ?? "SMB copy undo did not complete"))
            if undo.state == "completed" {
                #expect(try await visibleNames(in: copyDestination).isEmpty)
            } else {
                #expect(try Data(contentsOf: copiedFolder.appendingPathComponent("payload.bin")) == payload)
            }
        } else {
            Issue.record("SMB copy did not record an undo entry")
        }
    }

    let external = listingDestination.appendingPathComponent("external.txt")
    let renamed = listingDestination.appendingPathComponent("renamed.txt")
    try Data("external".utf8).write(to: external)
    #expect(try await visibleNames(in: listingDestination) == ["external.txt"])
    try fm.moveItem(at: external, to: renamed)
    #expect(try await visibleNames(in: listingDestination) == ["renamed.txt"])
    try fm.removeItem(at: renamed)
    #expect(try await visibleNames(in: listingDestination).isEmpty)

    let moveSource = local.appendingPathComponent("move.txt")
    try Data("network-move".utf8).write(to: moveSource)
    let move = try await EntryOperations.move([moveSource], to: destination,
        conflictPolicy: .skip, journalDirectory: journal)
    if move.state != "completed" {
        #expect(try String(contentsOf: moveSource, encoding: .utf8) == "network-move")
        print(smbCopyDiagnostic(source: moveSource, destination: root))
    }
    try #require(move.state == "completed", Comment(rawValue: move.items.first?.message ?? "SMB move did not complete"))
    let moveUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(await EntryOperations.undoMove(moveUndo, journalDirectory: journal).state == "completed")
    #expect(try String(contentsOf: moveSource, encoding: .utf8) == "network-move")

    let replacement = local.appendingPathComponent("replace.txt")
    let existing = destination.appendingPathComponent("replace.txt")
    try Data("new".utf8).write(to: replacement)
    try Data("old".utf8).write(to: existing)
    let replace = try await EntryOperations.move([replacement], to: destination,
        conflictPolicy: .replace, journalDirectory: journal)
    if replace.state != "completed" {
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "new")
        let preservedDestination = replace.items.first?.recoveryBackup ?? existing
        #expect(try String(contentsOf: preservedDestination, encoding: .utf8) == "old")
    }
    try #require(replace.state == "completed",
                 Comment(rawValue: replace.items.first?.message ?? replace.journalError ?? "SMB replacement did not complete"))
    let replaceUndo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    #expect(await EntryOperations.undoMove(replaceUndo, journalDirectory: journal).state == "completed")
    #expect(try String(contentsOf: replacement, encoding: .utf8) == "new")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
    try await verifyMountedVolumeReplacementCancellation(local: local, destination: destination, journal: journal)
    try await verifyMountedVolumeChangedBackupCancellation(local: local, destination: destination, journal: journal)
    try await verifyCrossVolumeMovePreservesReplacedDestination(local: local, destination: destination, journal: journal)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_READONLY_VOLUME"), "Requires a read-only SMB integration fixture"))
func mountedSMBReadOnlyRejectsWrites() async throws {
    let volume = try smbFixture("FILES_TEST_SMB_READONLY_VOLUME")
    let fm = FileManager.default
    let target = volume.appendingPathComponent("replace.txt")
    let existingBytes = Data("existing read-only SMB destination".utf8)
    let entries = try await LocalFileSystem().contents(of: volume, showHidden: true)
    try #require(entries.map(\.name) == ["replace.txt"])
    try #require(try Data(contentsOf: target) == existingBytes)

    let probe = volume.appendingPathComponent(".files-smb-write-probe-\(UUID().uuidString)")
    let descriptor = open(probe.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o600))
    let writeError = errno
    if descriptor >= 0 {
        close(descriptor)
        try fm.removeItem(at: probe)
        Issue.record("The read-only fixture allowed file creation")
        return
    }
    try #require([EACCES, EPERM, EROFS].contains(writeError), "Write probe was not denied by permissions")

    let local = fm.temporaryDirectory.appendingPathComponent("Files-SMB-readonly-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: local, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: local) }
    let journal = local.appendingPathComponent("journal", isDirectory: true)
    let copySource = local.appendingPathComponent("copy.txt")
    let moveSource = local.appendingPathComponent(target.lastPathComponent)
    let copyBytes = Data("local copy source".utf8)
    let moveBytes = Data("local move source".utf8)
    try copyBytes.write(to: copySource)
    try moveBytes.write(to: moveSource)

    let copy = await CopyEngine.run(sources: [copySource], destination: volume,
                                    journalDirectory: journal, cancellation: CopyCancellation())
    #expect(copy.items.map(\.state) == ["failed"])
    #expect(copy.items.first?.message?.isEmpty == false)
    #expect(copy.journalError == nil)
    #expect(CopyEngine.latestUndoCopy(journalDirectory: journal) == nil)

    let move = try await EntryOperations.move([moveSource], to: volume, conflictPolicy: .replace, journalDirectory: journal)
    #expect(move.items.map(\.state) == ["failed"])
    #expect(move.items.first?.message?.isEmpty == false)
    #expect(move.items.first?.recoveryBackup == nil)
    #expect(move.journalError == nil)
    #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)

    #expect(try Data(contentsOf: copySource) == copyBytes)
    #expect(try Data(contentsOf: moveSource) == moveBytes)
    #expect(try Data(contentsOf: target) == existingBytes)
    #expect(try fm.contentsOfDirectory(atPath: volume.path) == ["replace.txt"])
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_VOLUME"), "Requires an integration fixture"))
func mountedSMBTransferTimestamps() async throws {
    let fm = FileManager.default
    let volume = try smbFixture("FILES_TEST_SMB_VOLUME")
    let root = fm.temporaryDirectory.appendingPathComponent("Files-SMB-times-\(UUID().uuidString)", isDirectory: true)
    let destination = volume.appendingPathComponent(root.lastPathComponent, isDirectory: true)
    defer { try? fm.removeItem(at: destination); try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let payload = Data("SMB timestamp fixture".utf8)
    let source = root.appendingPathComponent("times.txt")
    let creation = Date(timeIntervalSince1970: 1_600_000_000)
    let modification = Date(timeIntervalSince1970: 1_700_000_000)
    let access = timespec(tv_sec: 1_650_000_000, tv_nsec: 123_456_700)
    try payload.write(to: source)
    try fm.setAttributes([.creationDate: creation, .modificationDate: modification], ofItemAtPath: source.path)
    var timestamps = [access, timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
    try #require(utimensat(AT_FDCWD, source.path, &timestamps, AT_SYMLINK_NOFOLLOW) == 0)

    func sample(_ file: URL, phase: String) throws -> stat {
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        func format(_ time: timespec) -> String {
            String(format: "%lld.%09ld", Int64(time.tv_sec), time.tv_nsec)
        }
        print("SMB timestamps \(phase): birth=\(format(info.st_birthtimespec)) access=\(format(info.st_atimespec)) modified=\(format(info.st_mtimespec))")
        return info
    }
    let original = try sample(source, phase: "APFS source")
    try #require(original.st_birthtimespec.tv_sec == Int(creation.timeIntervalSince1970))
    try #require(original.st_atimespec.tv_sec == access.tv_sec && original.st_atimespec.tv_nsec == access.tv_nsec)

    let journal = root.appendingPathComponent("journal", isDirectory: true)
    let report = await CopyEngine.run(sources: [source], destination: destination,
                                      journalDirectory: journal, cancellation: CopyCancellation())
    try #require(report.items.first?.state == "completed",
                 Comment(rawValue: report.items.first?.message ?? "SMB timestamp copy failed"))
    let target = destination.appendingPathComponent(source.lastPathComponent)
    let copied = try sample(target, phase: "SMB published copy")
    #expect(copied.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec)
    #expect(copied.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec)
    #expect(copied.st_atimespec.tv_sec == access.tv_sec)
    #expect(copied.st_atimespec.tv_nsec == access.tv_nsec)
    #expect(copied.st_mtimespec.tv_sec == Int(modification.timeIntervalSince1970))
    #expect(try Data(contentsOf: target) == payload)

    let moveDestination = destination.appendingPathComponent("move", isDirectory: true)
    try fm.createDirectory(at: moveDestination, withIntermediateDirectories: false)
    // Copying may advance the source's access time. Set a sub-tick
    // value for the next operation and check the exact time rounded by SMB.
    timestamps[0].tv_nsec += 42
    try #require(utimensat(AT_FDCWD, source.path, &timestamps, AT_SYMLINK_NOFOLLOW) == 0)
    let move = try await EntryOperations.move([source], to: moveDestination, journalDirectory: journal)
    try #require(move.state == "completed",
                 Comment(rawValue: move.items.first?.message ?? "SMB timestamp move failed"))
    let moveTarget = moveDestination.appendingPathComponent(source.lastPathComponent)
    let moved = try sample(moveTarget, phase: "SMB published move")
    #expect(moved.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec)
    #expect(moved.st_atimespec.tv_sec == access.tv_sec)
    #expect(moved.st_atimespec.tv_nsec == access.tv_nsec)
    #expect(!fm.fileExists(atPath: source.path))
    let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
    let restored = await EntryOperations.undoMove(undo, journalDirectory: journal)
    try #require(restored.state == "completed",
                 Comment(rawValue: restored.items.first?.message ?? "SMB timestamp move undo failed"))
    let returned = try sample(source, phase: "APFS restored by Undo")
    #expect(returned.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec)
    #expect(returned.st_atimespec.tv_sec == access.tv_sec)
    #expect(returned.st_atimespec.tv_nsec == access.tv_nsec)
    #expect(!fm.fileExists(atPath: moveTarget.path))
    #expect(try Data(contentsOf: source) == payload)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_RECONNECT_VOLUME"), "Requires a reconnected SMB integration fixture"))
func mountedSMBReconnectSeesServerChanges() async throws {
    let volume = try smbFixture("FILES_TEST_SMB_RECONNECT_VOLUME")
    let entries = try await LocalFileSystem().contents(of: volume, showHidden: false)
    let current = try #require(entries.first { $0.name == "reconnect-after.txt" })
    #expect(!entries.contains { $0.name == "reconnect-before.txt" })
    #expect(try Data(contentsOf: current.url) == Data("after Samba disconnect".utf8))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_CONTROL"), "Requires a disposable loopback Samba server"))
func mountedSMBReconnectDuringReplacementMove() async throws {
    let environment = ProcessInfo.processInfo.environment
    let control = try #require(environment["FILES_TEST_SMB_CONTROL"])
    let config = try #require(environment["FILES_TEST_SMB_CONFIG"])
    let volume = try smbFixture("FILES_TEST_SMB_RECONNECT_VOLUME")
    let fm = FileManager.default
    let local = fm.temporaryDirectory.appendingPathComponent("Files-SMB-session-\(UUID().uuidString)", isDirectory: true)
    let remote = volume.appendingPathComponent(local.lastPathComponent, isDirectory: true)
    defer { try? fm.removeItem(at: remote); try? fm.removeItem(at: local) }
    try fm.createDirectory(at: local, withIntermediateDirectories: false)
    try fm.createDirectory(at: remote, withIntermediateDirectories: false)
    let journal = local.appendingPathComponent("journal", isDirectory: true)
    let source = local.appendingPathComponent("replace.txt")
    let target = remote.appendingPathComponent(source.lastPathComponent)
    let oldBytes = Data("original SMB destination".utf8)
    let newBytes = Data(repeating: 0xA5, count: 512 * 1024)
    try newBytes.write(to: source)
    try oldBytes.write(to: target)

    let before = try smbReconnectCount(volume)
    let device = try #require(try fm.attributesOfItem(atPath: volume.path)[.systemNumber] as? NSNumber)
    let cancellation = CopyCancellation()
    let move = try await EntryOperations.move([source], to: remote, conflictPolicy: .replace,
        journalDirectory: journal, cancellation: cancellation) { progress in
            guard progress.phase == "removingSource" else { return }
            do {
                // At this point the new file is published and the source still exists.
                var sourceInfo = stat()
                try #require(lstat(source.path, &sourceInfo) == 0)
                try #require(try Data(contentsOf: target) == newBytes)
                print("SMB fault: cutting session before source removal")
                try disconnectSMBFixture(control: control, config: config)
                let deadline = ContinuousClock.now + .seconds(15)
                var reconnected = false
                repeat {
                    // Force a request on the existing mount while the move is suspended.
                    if (try? Data(contentsOf: target)) == newBytes, (try? smbReconnectCount(volume)).map({ $0 > before }) == true {
                        reconnected = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                } while ContinuousClock.now < deadline
                try #require(reconnected, "The interrupted transfer did not reconnect at the commit boundary")
            } catch {
                Issue.record(Comment(rawValue: "Could not inject SMB disconnect: \(error)"))
                cancellation.cancel()
            }
        }

    let after = try smbReconnectCount(volume)
    print("SMB fault: reconnect count \(before) -> \(after), move state \(move.state)")
    try #require(after > before, "The active transfer did not cross an SMB reconnect")
    #expect(try fm.attributesOfItem(atPath: volume.path)[.systemNumber] as? NSNumber == device)
    let item = try #require(move.items.first)
    if item.state == "completed" {
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: target) == newBytes)
        let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let restored = await EntryOperations.undoMove(undo, journalDirectory: journal)
        try #require(restored.state == "completed", Comment(rawValue: restored.items.first?.message ?? "SMB undo failed"))
        #expect(try Data(contentsOf: target) == oldBytes)
    } else {
        let originalDestination = item.recoveryBackup ?? target
        #expect(try Data(contentsOf: originalDestination) == oldBytes)
        #expect(item.message?.isEmpty == false)
        #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
    }
    #expect(try Data(contentsOf: source) == newBytes)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_SERVER_SHARE"), "Requires access to the loopback Samba backing directory"))
func mountedSMBReconnectDuringPayloadWrite() async throws {
    let environment = ProcessInfo.processInfo.environment
    let control = try #require(environment["FILES_TEST_SMB_CONTROL"])
    let config = try #require(environment["FILES_TEST_SMB_CONFIG"])
    let share = URL(fileURLWithPath: try #require(environment["FILES_TEST_SMB_SERVER_SHARE"]), isDirectory: true)
    let volume = try smbFixture("FILES_TEST_SMB_RECONNECT_VOLUME")
    let fm = FileManager.default
    let local = fm.temporaryDirectory.appendingPathComponent("Files-SMB-write-\(UUID().uuidString)", isDirectory: true)
    let destination = volume.appendingPathComponent(local.lastPathComponent, isDirectory: true)
    let serverDirectory = share.appendingPathComponent(local.lastPathComponent, isDirectory: true)
    let source = local.appendingPathComponent("payload.bin")
    let target = destination.appendingPathComponent(source.lastPathComponent)
    let journal = local.appendingPathComponent("journal", isDirectory: true)
    defer { try? fm.removeItem(at: destination); try? fm.removeItem(at: local) }
    try fm.createDirectory(at: local, withIntermediateDirectories: false)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)

    let marker: UInt8 = 0x5C
    let block = Data(repeating: marker, count: 1024 * 1024)
    let blockCount = 384
    let fullSize = Int64(block.count * blockCount)
    try Data().write(to: source)
    let writer = try FileHandle(forWritingTo: source)
    do {
        defer { try? writer.close() }
        for _ in 0..<blockCount { try writer.write(contentsOf: block) }
    }
    let original = try CopyEngine.makeSnapshot(source, cancellation: CopyCancellation())
    let device = try #require(try fm.attributesOfItem(atPath: volume.path)[.systemNumber] as? NSNumber)
    let before = try smbReconnectCount(volume)
    let fault = Task.detached {
        let serverFiles = FileManager()
        let deadline = ContinuousClock.now + .seconds(30)
        while !Task.isCancelled && ContinuousClock.now < deadline {
            // Observe Samba's local file instead of trusting cached SMB attributes.
            let stages = try serverFiles.contentsOfDirectory(at: serverDirectory, includingPropertiesForKeys: nil)
            for stage in stages where stage.lastPathComponent.hasPrefix(".files-move-") {
                let payload = stage.appendingPathComponent("payload")
                let descriptor = open(payload.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                var first: UInt8 = 0
                var last: UInt8 = 0
                guard pread(descriptor, &first, 1, 0) == 1, first == marker else { continue }
                let tail = pread(descriptor, &last, 1, fullSize - 1)
                guard tail == 0 || (tail == 1 && last == 0) else { continue }
                try disconnectSMBFixture(control: control, config: config)
                let tailAfterRequest = pread(descriptor, &last, 1, fullSize - 1)
                let tailStillUnwritten = tailAfterRequest == 0 || (tailAfterRequest == 1 && last == 0)
                try #require(tailStillUnwritten, "The payload tail did not remain observable and unwritten after the disconnect request")
                print("SMB fault: staged file tail remained unwritten when the disconnect request returned")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("The Samba backing file was never observed partially written")
    }
    defer { fault.cancel() }
    let move = try await EntryOperations.move([source], to: destination, journalDirectory: journal)
    try await fault.value

    // Force a request on the original mount; a failed write may have returned before reconnect.
    _ = try fm.contentsOfDirectory(atPath: destination.path)
    let after = try smbReconnectCount(volume)
    print("SMB fault: staged write reconnect count \(before) -> \(after), move state \(move.state)")
    try #require(after > before)
    #expect(try fm.attributesOfItem(atPath: volume.path)[.systemNumber] as? NSNumber == device)
    let item = try #require(move.items.first)
    if item.state == "completed" {
        #expect(!fm.fileExists(atPath: source.path))
        let copied = try CopyEngine.makeSnapshot(target, cancellation: CopyCancellation())
        #expect(copied.content == original.content)
        let undo = try #require(EntryOperations.latestUndoMove(journalDirectory: journal))
        let restored = await EntryOperations.undoMove(undo, journalDirectory: journal)
        try #require(restored.state == "completed", Comment(rawValue: restored.items.first?.message ?? "SMB undo failed"))
    } else {
        #expect(item.state == "failed")
        #expect(EntryOperations.latestUndoMove(journalDirectory: journal) == nil)
    }
    #expect(!fm.fileExists(atPath: target.path))
    let returned = try CopyEngine.makeSnapshot(source, cancellation: CopyCancellation())
    #expect(returned.content == original.content)
    #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
}

private func disconnectSMBFixture(control: String, config: String) throws {
    _ = try smbFixtureCommand("/usr/bin/sudo", ["-n", control, "--configfile", config,
                                               "smbd", "kill-client-ip", "127.0.0.1"])
}

private func smbReconnectCount(_ volume: URL) throws -> Int {
    let output = try smbFixtureCommand("/usr/bin/smbutil", ["statshares", "-m", volume.path])
    for line in output.split(separator: "\n") {
        let columns = line.split { $0.isWhitespace }
        if columns.count == 2, columns[0] == "SESSION_RECONNECT_COUNT", let count = Int(columns[1]) {
            return count
        }
    }
    throw CocoaError(.fileReadCorruptFile)
}

private func smbFixtureCommand(_ executable: String, _ arguments: [String]) throws -> String {
    let child = Process()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    child.standardOutput = output
    try child.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    try #require(child.terminationStatus == 0, "SMB fixture command failed: \(executable)")
    return String(decoding: data, as: UTF8.self)
}

private func smbCopyDiagnostic(source: URL, destination: URL) -> String {
    let fm = FileManager.default
    let workspace = destination.appendingPathComponent(".files-smb-diagnostic-\(UUID().uuidString)", isDirectory: true)
    let copy = workspace.appendingPathComponent("payload")
    defer { try? fm.removeItem(at: workspace) }
    do {
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        try fm.copyItem(at: source, to: copy)
        let original = try CopyEngine.makeSnapshot(source, cancellation: CopyCancellation())
        let duplicate = try CopyEngine.makeSnapshot(copy, cancellation: CopyCancellation())
        let paths = Set(original.content.keys).union(duplicate.content.keys).sorted()
        func describe(_ snapshot: CopyEngine.VerificationSnapshot, path: String) -> String {
            let entry = snapshot.withPermissions[path] ?? "missing"
            let attributes = (snapshot.metadata.extendedAttributes[path] ?? [:]).keys
                .map { String(decoding: $0, as: UTF8.self) }.sorted()
            let modified = snapshot.metadata.modificationDates[path]
                .map { String(format: "%.9f", $0.timeIntervalSince1970) } ?? "missing"
            return "\(entry), xattrs=\(attributes), modified=\(modified)"
        }
        return (["SMB diagnostic: Foundation copy \(original.filesystemType) → \(duplicate.filesystemType)"] + paths.map { path in
            let delta = original.metadata.modificationDates[path].flatMap { expected in
                duplicate.metadata.modificationDates[path].map { $0.timeIntervalSince(expected) }
            }.map { String(format: "%+.9f", $0) } ?? "missing"
            return "\(path.isEmpty ? "." : path) source=[\(describe(original, path: path))] staged=[\(describe(duplicate, path: path))] modificationDeltaSeconds=\(delta)"
        }).joined(separator: "\n")
    } catch {
        return "SMB diagnostic could not inspect a separate Foundation copy: \(error.localizedDescription)"
    }
}

private func smbUndoCopyDiagnostic(_ item: CopyUndoItem) -> String {
    do {
        let actual = try CopyEngine.makeSnapshot(item.target, cancellation: CopyCancellation())
        guard let recorded = item.targetMetadata else { return "SMB undo diagnostic: no recorded metadata" }
        let paths = Set(item.targetSnapshot.keys).union(actual.withPermissions.keys).sorted()
        var info = stat()
        let currentIdentity = lstat(item.target.path, &info) == 0 ? "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)" : "missing"
        let identity = "recordedIdentity=\(item.targetIdentity) publishedIdentity=\(currentIdentity)"
        return (["SMB undo diagnostic: recorded stage compared with published copy", identity] + paths.map { path in
            let originalDate = recorded.modificationDates[path]
            let currentDate = actual.metadata.modificationDates[path]
            let delta = originalDate.flatMap { expected in
                currentDate.map { String(format: "%+.9f", $0.timeIntervalSince(expected)) }
            } ?? "missing"
            let contentsMatch = actual.withPermissions[path] == item.targetSnapshot[path]
            let attributesMatch = actual.metadata.extendedAttributes[path] == recorded.extendedAttributes[path]
            let aclMatches = actual.metadata.accessControlLists[path] == recorded.accessControlLists[path]
            let creationMatches = actual.metadata.creationDates?[path] == recorded.creationDates?[path]
            return "\(path.isEmpty ? "." : path) contentsAndModeMatch=\(contentsMatch) xattrsMatch=\(attributesMatch) aclMatches=\(aclMatches) creationTimeMatches=\(creationMatches) modificationDeltaSeconds=\(delta)"
        }).joined(separator: "\n")
    } catch {
        return "SMB undo diagnostic could not inspect the published copy: \(error.localizedDescription)"
    }
}

private func smbRenameIdentityDiagnostic(in root: URL) throws -> String {
    let original = root.appendingPathComponent(".rename-identity-original")
    let published = root.appendingPathComponent(".rename-identity-published")
    let fm = FileManager.default
    try Data("identity probe".utf8).write(to: original)
    defer {
        try? fm.removeItem(at: original)
        try? fm.removeItem(at: published)
    }
    let fd = open(original.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var before = stat(), after = stat(), handleBefore = stat(), handleAfter = stat()
    guard lstat(original.path, &before) == 0, fstat(fd, &handleBefore) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try fm.moveItem(at: original, to: published)
    guard lstat(published.path, &after) == 0, fstat(fd, &handleAfter) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return "SMB rename identity: path \(before.st_dev):\(before.st_ino) → \(after.st_dev):\(after.st_ino); open handle \(handleBefore.st_dev):\(handleBefore.st_ino) → \(handleAfter.st_dev):\(handleAfter.st_ino)"
}

private func verifyCrossVolumeMovePreservesReplacedDestination(local: URL, destination: URL, journal: URL) async throws {
    let source = local.appendingPathComponent("replaced-after-publish.txt")
    let target = destination.appendingPathComponent(source.lastPathComponent)
    let originalPublication = destination.appendingPathComponent("original-publication.txt")
    let contents = Data("identical contents".utf8)
    try contents.write(to: source)
    let report = try await EntryOperations.move([source], to: destination,
        conflictPolicy: .skip, journalDirectory: journal) { progress in
        guard progress.phase == "removingSource" else { return }
        do {
            try FileManager.default.moveItem(at: target, to: originalPublication)
            try contents.write(to: target)
        } catch { Issue.record(error) }
    }
    #expect(report.items.map(\.state) == ["failed"])
    #expect(report.items.first?.retrySource == nil)
    #expect(try Data(contentsOf: source) == contents)
    #expect(try Data(contentsOf: target) == contents)
    #expect(try Data(contentsOf: originalPublication) == contents)
}

private func verifyMountedVolumeChangedBackupCancellation(local: URL, destination: URL, journal: URL) async throws {
    let fm = FileManager.default
    let source = local.appendingPathComponent("changed-backup-folder", isDirectory: true)
    let target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: false)
    try fm.createDirectory(at: target, withIntermediateDirectories: false)
    let sourceChild = source.appendingPathComponent("child.txt")
    try Data("source".utf8).write(to: sourceChild)
    try Data("old".utf8).write(to: target.appendingPathComponent("child.txt"))

    let cancellation = CopyCancellation()
    let move = try await EntryOperations.move([source], to: destination,
        conflictPolicy: .replace, journalDirectory: journal, cancellation: cancellation) { progress in
        guard progress.phase == "verifying" else { return }
        defer { cancellation.cancel() }
        do {
            let children = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            let backup = try #require(children.first { $0.lastPathComponent.hasPrefix(".files-move-backup-") })
            try Data("edited".utf8).write(to: backup.appendingPathComponent("child.txt"))
        } catch { Issue.record(error) }
    }

    #expect(move.items.map(\.state) == ["cancelled"])
    let backup = try #require(move.items.first?.recoveryBackup)
    #expect(try String(contentsOf: sourceChild, encoding: .utf8) == "source")
    #expect(try String(contentsOf: backup.appendingPathComponent("child.txt"), encoding: .utf8) == "edited")
    #expect(!fm.fileExists(atPath: target.path))
    let data = try Data(contentsOf: journal.appendingPathComponent("move-\(move.id).json"))
    let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try #require(record["items"] as? [[String: Any]])
    #expect(items.first?["backup"] as? String == backup.absoluteString)
    try fm.removeItem(at: backup)
}

private func verifyMountedVolumeReplacementCancellation(local: URL, destination: URL, journal: URL) async throws {
    let source = local.appendingPathComponent("cancel-replace.txt")
    let target = destination.appendingPathComponent(source.lastPathComponent)
    let original = Data(repeating: 0x41, count: 1024 * 1024)
    let existing = Data("existing destination".utf8)
    try original.write(to: source)
    try existing.write(to: target)
    let namesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: destination.path))
    let cancellation = CopyCancellation()

    let report = try await EntryOperations.move([source], to: destination, conflictPolicy: .replace,
        journalDirectory: journal, cancellation: cancellation) { progress in
        if progress.phase == "verifying" { cancellation.cancel() }
    }
    #expect(cancellation.isCancelled, "The transfer did not reach cross-volume verification")
    #expect(report.state == "cancelled")
    #expect(report.items.map(\.state) == ["cancelled"])
    #expect(report.journalError == nil)
    #expect(try Data(contentsOf: source) == original)
    #expect(try Data(contentsOf: target) == existing)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)) == namesBefore)
}
