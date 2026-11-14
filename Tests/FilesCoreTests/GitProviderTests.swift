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

@Test func gitInitializeAndSafeSyncUseTrackedRemoteWithoutForce() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("files-git-sync-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let initialized = root.appendingPathComponent("initialized", isDirectory: true); try fm.createDirectory(at: initialized, withIntermediateDirectories: true)
    let provider = GitProvider(), initializedSnapshot = try await provider.initialize(at: initialized)
    #expect(initializedSnapshot.root == initialized.standardizedFileURL)
    #expect(fm.fileExists(atPath: initialized.appendingPathComponent(".git", isDirectory: true).path))

    let bare = root.appendingPathComponent("remote.git"), seed = root.appendingPathComponent("seed"), local = root.appendingPathComponent("local"), peer = root.appendingPathComponent("peer")
    try runGit(["init", "--bare", "--initial-branch=main", bare.path], at: root)
    try fm.createDirectory(at: seed, withIntermediateDirectories: true); try runGit(["init", "-b", "main"], at: seed); try configureIdentity(seed)
    try Data("one".utf8).write(to: seed.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: seed); try runGit(["commit", "-m", "one"], at: seed)
    try runGit(["remote", "add", "origin", bare.path], at: seed); try runGit(["push", "-u", "origin", "main"], at: seed)
    _ = try await provider.clone(from: bare, to: local); _ = try await provider.clone(from: bare, to: peer); try configureIdentity(local); try configureIdentity(peer)
    try Data("two".utf8).write(to: peer.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: peer); try runGit(["commit", "-m", "two"], at: peer); try runGit(["push"], at: peer)
    let pulled = try await provider.synchronize(at: local)
    #expect(pulled.ahead == 0 && pulled.behind == 0)
    #expect(try String(contentsOf: local.appendingPathComponent("value.txt"), encoding: .utf8) == "two")
    try Data("local".utf8).write(to: local.appendingPathComponent("local.txt")); try runGit(["add", "local.txt"], at: local); try runGit(["commit", "-m", "local"], at: local)
    let pushed = try await provider.synchronize(at: local); #expect(pushed.ahead == 0 && pushed.behind == 0)
    try runGit(["pull", "--ff-only"], at: peer); #expect(fm.fileExists(atPath: peer.appendingPathComponent("local.txt").path))
}

@Test func gitProviderUsesBareRemoteWithoutForceOrReset() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("files-git-remote-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let bare = root.appendingPathComponent("remote.git"), seed = root.appendingPathComponent("seed"), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
    try runGit(["init", "--bare", "--initial-branch=main", bare.path], at: root)
    try fm.createDirectory(at: seed, withIntermediateDirectories: true); try runGit(["init", "-b", "main"], at: seed); try configureIdentity(seed)
    try Data("one".utf8).write(to: seed.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: seed); try runGit(["commit", "-m", "one"], at: seed)
    try runGit(["remote", "add", "origin", bare.path], at: seed); try runGit(["push", "-u", "origin", "main"], at: seed)
    let provider = GitProvider(); _ = try await provider.clone(from: bare, to: first); _ = try await provider.clone(from: bare, to: second)
    #expect(try await provider.branches(at: first) == [GitBranch(name: "main", upstream: "origin/main")])
    #expect(try await provider.remotes(at: first).map(\.name) == ["origin"])
    try configureIdentity(second); try Data("two".utf8).write(to: second.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: second); try runGit(["commit", "-m", "two"], at: second); try runGit(["push"], at: second)
    try await provider.fetch(at: first); let behind = try await provider.snapshot(at: first); #expect(behind.behind == 1); #expect(behind.ahead == 0)
    try await provider.pullFastForwardOnly(at: first); #expect(try String(contentsOf: first.appendingPathComponent("value.txt"), encoding: .utf8) == "two")
    try configureIdentity(first); try Data("three".utf8).write(to: first.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: first); try runGit(["commit", "-m", "three"], at: first)
    try await provider.push(at: first, branch: "main"); try runGit(["pull", "--ff-only"], at: second)
    #expect(try String(contentsOf: second.appendingPathComponent("value.txt"), encoding: .utf8) == "three")
    await #expect(throws: GitBackendError.invalidLocation) { try await provider.push(at: first, remote: "--force") }
}

@Test func gitPullRejectsDivergenceWithoutChangingHeadOrWorkTree() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("files-git-diverged-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let bare = root.appendingPathComponent("remote.git"), seed = root.appendingPathComponent("seed"), local = root.appendingPathComponent("local"), peer = root.appendingPathComponent("peer")
    try runGit(["init", "--bare", "--initial-branch=main", bare.path], at: root); try fm.createDirectory(at: seed, withIntermediateDirectories: true)
    try runGit(["init", "-b", "main"], at: seed); try configureIdentity(seed); try Data("base".utf8).write(to: seed.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: seed); try runGit(["commit", "-m", "base"], at: seed); try runGit(["remote", "add", "origin", bare.path], at: seed); try runGit(["push", "-u", "origin", "main"], at: seed)
    let provider = GitProvider(); _ = try await provider.clone(from: bare, to: local); _ = try await provider.clone(from: bare, to: peer); try configureIdentity(local); try configureIdentity(peer)
    try Data("local".utf8).write(to: local.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: local); try runGit(["commit", "-m", "local"], at: local)
    try Data("peer".utf8).write(to: peer.appendingPathComponent("value.txt")); try runGit(["add", "value.txt"], at: peer); try runGit(["commit", "-m", "peer"], at: peer); try runGit(["push"], at: peer)
    try await provider.fetch(at: local); let diverged = try await provider.snapshot(at: local); #expect(diverged.ahead == 1); #expect(diverged.behind == 1)
    let headBefore = try gitOutput(["rev-parse", "HEAD"], at: local)
    await #expect(throws: GitBackendError.commandFailed(128)) { try await provider.pullFastForwardOnly(at: local) }
    #expect(try gitOutput(["rev-parse", "HEAD"], at: local) == headBefore)
    #expect(try String(contentsOf: local.appendingPathComponent("value.txt"), encoding: .utf8) == "local")
}

@Test func gitCancellationTerminatesProcessAndCleansCloneStaging() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("files-git-cancel-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let sleeper = root.appendingPathComponent("fake-git.sh")
    try Data("#!/bin/sh\nlast=''\nfor arg in \"$@\"; do last=\"$arg\"; done\ncase \"$1\" in clone) mkdir \"$last\" ;; esac\nexec /bin/sleep 5\n".utf8).write(to: sleeper)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
    let provider = GitProvider(executable: sleeper), destination = root.appendingPathComponent("destination")
    let task = Task { try await provider.clone(from: root.appendingPathComponent("source.git"), to: destination) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!fm.fileExists(atPath: destination.path))
    #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".files-git-clone-") })
}

private func runGit(_ arguments: [String], at directory: URL) throws {
    let process = Process(), errors = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", directory.path] + arguments; process.standardError = errors
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)]) }
}

private func configureIdentity(_ repository: URL) throws {
    try runGit(["config", "user.name", "Files Test"], at: repository); try runGit(["config", "user.email", "files@example.invalid"], at: repository)
}

private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", directory.path] + arguments; process.standardOutput = output
    try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
