import Foundation
import Testing
@testable import FilesCore

@Test func gitStatusParserReadsBranchRenameAndUnicodePaths() throws {
    let data = Data("# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\01 M. N... 100644 100644 100644 a b 한글 file.txt\02 R. N... 100644 100644 100644 a b R100 new name.txt\0old name.txt\0? untracked file.txt\0".utf8)
    let snapshot = try GitStatusParser().parse(data, root: URL(fileURLWithPath: "/tmp/repo"))
    #expect(snapshot.branch == "main"); #expect(snapshot.upstream == "origin/main"); #expect(snapshot.ahead == 2); #expect(snapshot.behind == 1)
    #expect(snapshot.entries.map(\.path) == ["한글 file.txt", "new name.txt", "untracked file.txt"])
    #expect(snapshot.entries[1].originalPath == "old name.txt"); #expect(snapshot.entries[1].kind == .renamed)
}

@Test func gitStatusParserRejectsMalformedOrAbsolutePaths() {
    #expect(throws: GitBackendError.invalidOutput) { try GitStatusParser().parse(Data("? /absolute\0".utf8), root: URL(fileURLWithPath: "/tmp/repo")) }
    #expect(throws: GitBackendError.invalidOutput) { try GitStatusParser().parse(Data("1 broken\0".utf8), root: URL(fileURLWithPath: "/tmp/repo")) }
}

@Test func gitProviderDiscoversRepositoryAndReadsWorkingTree() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("files-git-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try runGit(["init", "-b", "main"], at: root); try runGit(["config", "user.name", "Files Test"], at: root); try runGit(["config", "user.email", "files@example.invalid"], at: root)
    let tracked = root.appendingPathComponent("tracked.txt"); try Data("initial".utf8).write(to: tracked); try runGit(["add", "tracked.txt"], at: root); try runGit(["commit", "-m", "initial"], at: root)
    try Data("changed".utf8).write(to: tracked); try Data("new".utf8).write(to: root.appendingPathComponent("한글 file.txt"))
    let snapshot = try await GitProvider().snapshot(at: root.appendingPathComponent("nested", isDirectory: true).deletingLastPathComponent())
    #expect(snapshot.root == root.standardizedFileURL); #expect(snapshot.branch == "main")
    #expect(snapshot.entries.contains { $0.path == "tracked.txt" && $0.workTreeStatus == "M" })
    #expect(snapshot.entries.contains { $0.path == "한글 file.txt" && $0.kind == .untracked })
}

private func runGit(_ arguments: [String], at directory: URL) throws {
    let process = Process(), errors = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", directory.path] + arguments; process.standardError = errors
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)]) }
}
