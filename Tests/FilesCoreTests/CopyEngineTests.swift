import Foundation
import Testing
@testable import FilesCore

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
