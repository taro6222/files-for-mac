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

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SMB_VOLUME"), "Requires an integration fixture"))
func mountedSMBCopyMoveUndoRoundTrip() async throws {
    guard let path = ProcessInfo.processInfo.environment["FILES_TEST_SMB_VOLUME"] else { Issue.record("Integration fixture is incomplete"); return }
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
    let local = fm.temporaryDirectory.appendingPathComponent("FilesM2-SMB-source-\(UUID().uuidString)", isDirectory: true)
    let journal = local.appendingPathComponent("journal", isDirectory: true)
    defer { try? fm.removeItem(at: root); try? fm.removeItem(at: local) }
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try fm.createDirectory(at: local, withIntermediateDirectories: true)

    let filesystem = LocalFileSystem()
    func visibleNames(in directory: URL) async throws -> Set<String> {
        Set(try await filesystem.contents(of: directory, showHidden: false).map(\.name))
    }
    #expect(try await visibleNames(in: destination).isEmpty)

    let copySource = local.appendingPathComponent("복사-é-📁", isDirectory: true)
    try fm.createDirectory(at: copySource, withIntermediateDirectories: true)
    let payload = Data(repeating: 0x5A, count: 512 * 1024)
    try payload.write(to: copySource.appendingPathComponent("payload.bin"))
    let copy = await CopyEngine.run(sources: [copySource], destination: destination,
                                    journalDirectory: journal, cancellation: CopyCancellation())
    if copy.state != "completed" {
        #expect(try Data(contentsOf: copySource.appendingPathComponent("payload.bin")) == payload)
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        print(smbCopyDiagnostic(source: copySource, destination: root))
    }
    try #require(copy.state == "completed", Comment(rawValue: copy.items.first?.message ?? ""))
    #expect(try await visibleNames(in: destination) == [copySource.lastPathComponent])
    let copiedFolder = destination.appendingPathComponent(copySource.lastPathComponent)
    #expect(try await visibleNames(in: copiedFolder) == ["payload.bin"])
    #expect(try Data(contentsOf: destination.appendingPathComponent("복사-é-📁/payload.bin")) == payload)
    let copyUndo = try #require(CopyEngine.latestUndoCopy(journalDirectory: journal))
    #expect(await CopyEngine.undoCopy(copyUndo, journalDirectory: journal).state == "completed")
    #expect(try await visibleNames(in: destination).isEmpty)

    let external = destination.appendingPathComponent("external.txt")
    let renamed = destination.appendingPathComponent("renamed.txt")
    try Data("external".utf8).write(to: external)
    #expect(try await visibleNames(in: destination) == ["external.txt"])
    try fm.moveItem(at: external, to: renamed)
    #expect(try await visibleNames(in: destination) == ["renamed.txt"])
    try fm.removeItem(at: renamed)
    #expect(try await visibleNames(in: destination).isEmpty)

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
    try await verifyMountedVolumeReplacementCancellation(local: local, destination: destination, journal: journal)
    try await verifyMountedVolumeChangedBackupCancellation(local: local, destination: destination, journal: journal)
    try await verifyCrossVolumeMovePreservesReplacedDestination(local: local, destination: destination, journal: journal)
}

private func smbCopyDiagnostic(source: URL, destination: URL) -> String {
    let fm = FileManager.default
    let workspace = destination.appendingPathComponent(".files-smb-diagnostic-\(UUID().uuidString)", isDirectory: true)
    let copy = workspace.appendingPathComponent("payload", isDirectory: true)
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
            return "\(entry), xattrs=\(attributes)"
        }
        return (["SMB diagnostic: Foundation copy \(original.filesystemType) → \(duplicate.filesystemType)"] + paths.map { path in
            "\(path.isEmpty ? "." : path) source=[\(describe(original, path: path))] staged=[\(describe(duplicate, path: path))]"
        }).joined(separator: "\n")
    } catch {
        return "SMB diagnostic could not inspect a separate Foundation copy: \(error.localizedDescription)"
    }
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
