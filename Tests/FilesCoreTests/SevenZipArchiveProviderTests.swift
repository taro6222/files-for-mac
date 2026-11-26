import Foundation
import Testing
import Darwin
@testable import FilesCore

private func sdkRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevenzip-client-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func sdkMock(_ body: String, root: URL, timeout: TimeInterval = 2) throws -> SevenZipArchiveProvider {
    let script = root.appendingPathComponent("worker.pl")
    let prelude = """
    #!/usr/bin/perl
    use strict; use warnings;
    binmode STDIN; binmode STDOUT; binmode STDERR;
    $| = 1;
    sub request { read(STDIN, my $header, 4) == 4 or exit 1; my $n=unpack('N',$header); read(STDIN,my $body,$n)==$n or exit 1; }
    sub reply { my ($text)=@_; print pack('N',length($text)), $text; }
    """
    try (prelude + "\n" + body + "\n").write(to: script, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return SevenZipArchiveProvider(executable: script, library: root.appendingPathComponent("pid"), timeout: timeout)
}

private let sdkEmptyReply = #"{"version":1,"ok":true,"session":"5BC9424B-FAE6-4A89-9DD5-AC627611EFD3","source":{"device":"1","inode":"2","size":3},"items":[]}"#

@Test func sevenZipSDKFramedClientRejectsMalformedReplies() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bodies = [
        "request(); print pack('N',8388609);",
        "request(); print pack('N',10), '{}';",
        "request(); reply('{\"version\":true,\"ok\":true}');",
        "request(); reply('{\"version\":1,\"ok\":false,\"error\":{\"code\":\"secret text\"}}');",
        "request(); reply('" + sdkEmptyReply.replacingOccurrences(of: "[]", with: #"[{"index":0,"path":"file","kind":"unknown","size":0,"encrypted":false}]"#) + "');",
        "request(); print STDERR 'private diagnostic'; reply('" + sdkEmptyReply + "');"
    ]
    for body in bodies {
        let provider = try sdkMock(body, root: root)
        do { _ = try await provider.entries(at: root.appendingPathComponent("archive.7z")); Issue.record("Malformed worker reply accepted") }
        catch let error as SevenZipWorkerError {
            #expect(error == .invalidResponse || error == .unexpectedExit)
        }
    }
}

@Test func sevenZipSDKFragmentedReplyAndClose() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let provider = try sdkMock("""
    request(); my $frame=pack('N',length('\(sdkEmptyReply)')).'\(sdkEmptyReply)';
    foreach my $c (split //,$frame) { print $c; select(undef,undef,undef,0.001); }
    request(); reply('{"version":1,"ok":true,"closed":true}');
    """, root: root)
    #expect(try await provider.entries(at: root.appendingPathComponent("archive.7z")).isEmpty)
}

@Test func sevenZipSDKTimeoutAndCancellationReapOwnedChild() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let body = #"open(my $pid,'>',$ARGV[0].'.tmp') or die; print $pid $$; close($pid); rename($ARGV[0].'.tmp',$ARGV[0]) or die; request(); sleep 60;"#
    let slow = try sdkMock(body, root: root, timeout: 0.15)
    await #expect(throws: SevenZipWorkerError.timedOut) { try await slow.entries(at: root.appendingPathComponent("a.7z")) }
    let pidURL = root.appendingPathComponent("pid")
    // The short total deadline may expire during interpreter startup, before the marker is written.
    if FileManager.default.fileExists(atPath: pidURL.path) {
        let firstPID = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        #expect(kill(firstPID, 0) == -1 && errno == ESRCH)
        try FileManager.default.removeItem(at: pidURL)
    }
    let cancellable = try sdkMock(body, root: root, timeout: 10)
    let task = Task { try await cancellable.entries(at: root.appendingPathComponent("a.7z")) }
    let deadline = ContinuousClock.now + .seconds(3)
    while !FileManager.default.fileExists(atPath: pidURL.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let secondPID = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(kill(secondPID, 0) == -1 && errno == ESRCH)
}

@Test func sevenZipSDKValidatesPathsBeforeStaging() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    for path in ["../escape", "/tmp/escape", "a/../../escape"] {
        let response = sdkEmptyReply.replacingOccurrences(of: "[]", with: "[{\"index\":0,\"path\":\"\(path)\",\"kind\":\"regularFile\",\"size\":0,\"encrypted\":false}]")
        let provider = try sdkMock("request(); reply('\(response)'); sleep 60;", root: root)
        await #expect(throws: ArchiveValidationError.invalidPath(path)) {
            try await provider.extractToNewDirectory(root.appendingPathComponent("a.7z"), at: root.appendingPathComponent("result"))
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0 == "result" || $0.hasPrefix(".files-7z-") })
    }
}

private func sdkFixture(root: URL, password: String? = nil, link: Bool = false) async throws -> (archive: URL, payloads: [String: Data]) {
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    let input = root.appendingPathComponent("input"), archive = root.appendingPathComponent("archive.7z")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let payloads = ["line\nbreak-한글-🔑.txt": Data("correct Unicode payload".utf8),
                    "folder/large.bin": Data((0..<524288).map { UInt8($0 % 251) })]
    for (name, data) in payloads {
        let path = input.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    if link { try FileManager.default.createSymbolicLink(atPath: input.appendingPathComponent("link").path, withDestinationPath: "folder") }
    let process = Process(), pipe = Pipe(), log = root.appendingPathComponent("reference.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
    process.executableURL = binary; process.currentDirectoryURL = input
    process.arguments = ["a", "-t7z", "-snl", "-mhc=off", "-ms=off", "-y", archive.path, "."] + (password == nil ? [] : ["-mhe=on", "-p"])
    process.standardInput = pipe; process.standardOutput = output; process.standardError = output
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
    if let password { try pipe.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
    try pipe.fileHandleForWriting.close()
    let deadline = ContinuousClock.now + .seconds(20)
    while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
    #expect(process.terminationStatus == 0)
    return (archive, payloads)
}

private func sdkRealProvider() throws -> SevenZipArchiveProvider {
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_WORKER"]))
    return SevenZipArchiveProvider(executable: binary, library: binary.deletingLastPathComponent().appendingPathComponent("7z.so"), timeout: 20)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE", "FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
func sevenZipSDKEncryptedRoundTripAndFailureStaging() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root, password: "QA-347-한글-🔑"), provider = try sdkRealProvider()
    let before = try Data(contentsOf: fixture.archive), destination = root.appendingPathComponent("result")
    let entries = try await provider.entries(at: fixture.archive, password: "QA-347-한글-🔑")
    #expect(entries.count == 3 && entries.filter { $0.kind == .regularFile }.allSatisfy(\.isEncrypted))
    let report = try await provider.extractToNewDirectory(fixture.archive, at: destination, password: "QA-347-한글-🔑")
    #expect(report.entries == 3 && report.extractedBytes == fixture.payloads.values.reduce(0) { $0 + $1.count })
    for (name, data) in fixture.payloads { #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == data) }
    for password in [nil, "wrong"] {
        await #expect(throws: (any Error).self) { try await provider.extractToNewDirectory(fixture.archive, at: root.appendingPathComponent("failed"), password: password) }
    }
    await #expect(throws: ZipArchiveError.destinationConflict("result")) { try await provider.extractToNewDirectory(fixture.archive, at: destination, password: "QA-347-한글-🔑") }
    await #expect(throws: ArchiveValidationError.totalSizeLimit) {
        try await provider.extractToNewDirectory(fixture.archive, at: root.appendingPathComponent("limited"), password: "QA-347-한글-🔑", limits: .init(maximumTotalBytes: 16))
    }
    #expect(try Data(contentsOf: fixture.archive) == before)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0 == "failed" || $0 == "limited" || $0.hasPrefix(".files-7z-") })
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE", "FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
func sevenZipSDKCorruptionAndLinksNeverPublish() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let provider = try sdkRealProvider(), fixture = try await sdkFixture(root: root)
    var bytes = try Data(contentsOf: fixture.archive); bytes[32] ^= 0x80
    let corrupt = root.appendingPathComponent("corrupt.7z"); try bytes.write(to: corrupt)
    #expect(try await provider.entries(at: corrupt).count == 3)
    await #expect(throws: SevenZipWorkerError.worker("corrupt-data")) { try await provider.extractToNewDirectory(corrupt, at: root.appendingPathComponent("corrupt-result")) }
    let linkRoot = root.appendingPathComponent("link-fixture"); try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)
    let linked = try await sdkFixture(root: linkRoot, link: true)
    await #expect(throws: ArchiveValidationError.unsupportedEntry("link")) { try await provider.extractToNewDirectory(linked.archive, at: root.appendingPathComponent("link-result")) }
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasSuffix("result") || $0.hasPrefix(".files-7z-") })
}

private final class SDKPublicationMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var applied = false, failure: String?
    let root: URL, foreignStage: Bool
    init(root: URL, foreignStage: Bool) { self.root = root; self.foreignStage = foreignStage }
    func apply(_ update: ArchiveProgress) {
        guard update.phase == .publishing else { return }
        lock.lock(); defer { lock.unlock() }
        guard !applied else { return }; applied = true
        do {
            let target: URL
            if foreignStage {
                target = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".files-7z-") })
            } else {
                target = root.appendingPathComponent("result")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            try Data("foreign preserved".utf8).write(to: target.appendingPathComponent("foreign.txt"))
        } catch { failure = String(describing: error) }
    }
    var succeeded: Bool { lock.withLock { applied && failure == nil } }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE", "FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
func sevenZipSDKPublicationConflictAndForeignStagingPreservation() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider()
    let conflict = SDKPublicationMutation(root: root, foreignStage: false)
    await #expect(throws: ZipArchiveError.destinationConflict("result")) {
        try await provider.extractToNewDirectory(fixture.archive, at: root.appendingPathComponent("result"), progress: conflict.apply)
    }
    #expect(conflict.succeeded)
    #expect(try String(contentsOf: root.appendingPathComponent("result/foreign.txt"), encoding: .utf8) == "foreign preserved")
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-7z-") })
    let foreign = SDKPublicationMutation(root: root, foreignStage: true)
    do {
        _ = try await provider.extractToNewDirectory(fixture.archive, at: root.appendingPathComponent("other-result"), progress: foreign.apply)
        Issue.record("Foreign staging contents were published")
    } catch SevenZipWorkerError.stagingPreserved(let path) {
        #expect(path.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path && path.lastPathComponent.hasPrefix(".files-7z-"))
    }
    #expect(foreign.succeeded)
    let held = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".files-7z-") })
    #expect(try String(contentsOf: held.appendingPathComponent("foreign.txt"), encoding: .utf8) == "foreign preserved")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other-result").path))
}

private final class SDKPublicationGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    var reached: Bool { lock.withLock { started } }
    func pause(_ progress: ArchiveProgress) {
        guard progress.phase == .publishing else { return }
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 5)
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE", "FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
func sevenZipSDKCancellationBeforePublicationDiscardsStaging() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), gate = SDKPublicationGate()
    defer { gate.release.signal() }
    let task = Task { try await provider.extractToNewDirectory(fixture.archive, at: root.appendingPathComponent("result"), progress: gate.pause) }
    let deadline = ContinuousClock.now + .seconds(4)
    while !gate.reached, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(gate.reached)
    task.cancel(); gate.release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0 == "result" || $0.hasPrefix(".files-7z-") })
}
