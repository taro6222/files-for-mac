import Foundation
import Testing
import CryptoKit
import Darwin
@testable import FilesCore

private func sdkRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevenzip-client-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func sdkMock(_ body: String, root: URL, timeout: TimeInterval = 2,
                     maximumPhysicalFootprintBytes: UInt64 = SevenZipArchiveProvider.defaultMaximumPhysicalFootprintBytes) throws -> SevenZipArchiveProvider {
    // Mock decoders exercise framing, while the real broker still requires real regular inputs.
    for name in ["archive.7z", "a.7z"] where !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
        try Data("zip".utf8).write(to: root.appendingPathComponent(name))
    }
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
    return SevenZipArchiveProvider(executable: script, library: root.appendingPathComponent("pid"), timeout: timeout,
                                  maximumPhysicalFootprintBytes: maximumPhysicalFootprintBytes)
}

@Test func sevenZipSDKMemoryBudgetKillsAndReapsWithoutPublishing() async throws {
    for operation in ["list", "extract", "create", "split"] {
        let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), sentinel = root.appendingPathComponent("existing.txt")
        try Data("source stays".utf8).write(to: source)
        try Data("existing stays".utf8).write(to: sentinel)
        let listing = sdkEmptyReply.replacingOccurrences(of: "[]", with: #"[{"index":0,"path":"payload","kind":"regularFile","size":1,"encrypted":false}]"#)
        let beforeAllocation = operation == "extract" ? "reply('\(listing)'); request();" : ""
        let provider = try sdkMock("""
        request(); \(beforeAllocation)
        open(my $pid,'>',$ARGV[0]) or die; print $pid $$; close($pid);
        my $megabytes=length($ARGV[0]) ? 64 : 0;
        my $bytes='x' x ($megabytes*1024*1024); sleep 10;
        """, root: root, timeout: 3, maximumPhysicalFootprintBytes: 32 << 20)
        await #expect(throws: SevenZipWorkerError.memoryLimitExceeded) {
            switch operation {
            case "list": _ = try await provider.entries(at: root.appendingPathComponent("archive.7z"))
            case "extract": _ = try await provider.extractToNewDirectory(root.appendingPathComponent("archive.7z"), at: root.appendingPathComponent("result"))
            case "split": _ = try await provider.createSplit(from: [source], at: root.appendingPathComponent("result.7z"), volumeBytes: 1024,
                                                              journalDirectory: root.appendingPathComponent("journals"))
            default: _ = try await provider.create(from: [source], at: root.appendingPathComponent("result.7z"))
            }
        }
        let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try Data(contentsOf: source) == Data("source stays".utf8))
        #expect(try Data(contentsOf: sentinel) == Data("existing stays".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0 == "result" || $0.hasPrefix("result.7z") || $0.hasPrefix(".files-") })
    }
}

@Test func sevenZipSDKRejectsZeroMemoryBudgetBeforeLaunching() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let provider = try sdkMock("open(my $pid,'>',$ARGV[0]); print $pid $$; close($pid);", root: root,
                               maximumPhysicalFootprintBytes: 0)
    await #expect(throws: SevenZipWorkerError.invalidConfiguration) { try await provider.entries(at: root.appendingPathComponent("archive.7z")) }
    await #expect(throws: SevenZipWorkerError.invalidConfiguration) { try await SevenZipArchiveProvider.bundled(in: root, maximumPhysicalFootprintBytes: 0) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pid").path))
    #expect(SevenZipArchiveProvider.defaultMaximumPhysicalFootprintBytes == max(256 << 20, ProcessInfo.processInfo.physicalMemory / 2))
}

private let sdkEmptyReply = #"{"version":1,"ok":true,"session":"5BC9424B-FAE6-4A89-9DD5-AC627611EFD3","source":{"device":"1","inode":"2","size":3},"items":[]}"#

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_LARGE_LIST") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires large SDK listing fixture"))
func sevenZipSDKLargePagedListing() async throws {
    let archive = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_LARGE_LIST"]))
    let before = try Data(contentsOf: archive)
    let entries = try await sdkRealProvider().entries(at: archive)
    #expect(entries.count == 35000)
    for (index, entry) in entries.enumerated() {
        #expect(entry.path == "entry-\(index)-" + String(repeating: "a", count: 80))
        #expect(entry.kind == .regularFile && entry.uncompressedSize == 0)
    }
    #expect(try Data(contentsOf: archive) == before)
}

@Test func sevenZipSDKRejectsMalformedListingPages() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let base = try #require(JSONSerialization.jsonObject(with: Data(sdkEmptyReply.utf8)) as? [String: Any])
    for mutation in 0..<11 {
        var first = base, second = base
        first["offset"] = 0; first["total"] = 2
        first["items"] = [["index": 0, "path": "first", "kind": "regularFile", "size": 0, "encrypted": false]]
        second["offset"] = 1; second["total"] = 2
        second["items"] = [["index": 1, "path": "second", "kind": "regularFile", "size": 0, "encrypted": false]]
        switch mutation {
        case 0: second["offset"] = 0
        case 1: second["total"] = 3
        case 2: second["session"] = UUID().uuidString
        case 3: second["source"] = ["device": "1", "inode": "999", "size": 3]
        case 4: second["items"] = []
        case 5: second["items"] = [["index": 0, "path": "first", "kind": "regularFile", "size": 0, "encrypted": false]]
        case 6: first["offset"] = 1
        case 7: first["total"] = -1
        case 8: first["total"] = 100001
        case 9: first.removeValue(forKey: "total")
        default: first["offset"] = true
        }
        let one = String(decoding: try JSONSerialization.data(withJSONObject: first), as: UTF8.self)
        let two = String(decoding: try JSONSerialization.data(withJSONObject: second), as: UTF8.self)
        let provider = try sdkMock("request(); reply('\(one)'); request(); reply('\(two)');", root: root)
        await #expect(throws: SevenZipWorkerError.invalidResponse) { try await provider.entries(at: root.appendingPathComponent("archive.7z")) }
    }
}

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

@Test func sevenZipSDKEOFOnDiagnosticPipeIsNotDiagnosticData() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let provider = try sdkMock("""
    request(); close STDERR; select(undef,undef,undef,0.05); reply('\(sdkEmptyReply)');
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
    let environment = ProcessInfo.processInfo.environment
    let binary = URL(fileURLWithPath: try #require(environment["FILES_TEST_SEVENZIP_WORKER"]))
    let library = environment["FILES_TEST_SEVENZIP_LIBRARY"].map { URL(fileURLWithPath: $0) } ?? binary.deletingLastPathComponent().appendingPathComponent("7z.so")
    return SevenZipArchiveProvider(executable: binary, library: library, timeout: 20)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
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

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
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

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
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
    private let afterItem: Bool
    init(afterItem: Bool = false) { self.afterItem = afterItem }
    var reached: Bool { lock.withLock { started } }
    func pause(_ progress: ArchiveProgress) {
        guard progress.phase == .publishing, !afterItem || progress.currentPath != nil else { return }
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 5)
    }
}

private final class SDKMergeMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var applied = false, failure = false
    let root: URL, destination: URL, secondName: String, replaceFirst: Bool
    init(root: URL, destination: URL, secondName: String, replaceFirst: Bool) {
        self.root = root; self.destination = destination; self.secondName = secondName; self.replaceFirst = replaceFirst
    }
    func apply(_ update: ArchiveProgress) {
        guard update.phase == .publishing, let firstName = update.currentPath else { return }
        lock.lock(); defer { lock.unlock() }; guard !applied else { return }; applied = true
        do {
            if replaceFirst {
                let first = destination.appendingPathComponent(firstName)
                try FileManager.default.moveItem(at: first, to: root.appendingPathComponent("held-owned-folder"))
                try Data("foreign replacement".utf8).write(to: first)
            } else { try Data("foreign collision".utf8).write(to: destination.appendingPathComponent(secondName)) }
        } catch { failure = true }
    }
    var succeeded: Bool { lock.withLock { applied && !failure } }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKExistingDirectoryExtractionPreservesUnrelatedItems() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root, password: "QA-350-한글-🔑"), provider = try sdkRealProvider()
    let destination = root.appendingPathComponent("destination"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let keep = destination.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: keep)
    let before = try Data(contentsOf: fixture.archive)
    let report = try await provider.extract(fixture.archive, to: destination, password: "QA-350-한글-🔑")
    #expect(report.entries == 3 && report.publishedURLs.count == 2)
    for (name, data) in fixture.payloads { #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == data) }
    #expect(try Data(contentsOf: keep) == Data("keep".utf8)); #expect(try Data(contentsOf: fixture.archive) == before)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: destination.path)).contains { $0.hasPrefix(".files-7z-") })
    await #expect(throws: (any Error).self) { try await provider.extract(fixture.archive, to: destination, password: "QA-350-한글-🔑") }
    #expect(try Data(contentsOf: keep) == Data("keep".utf8))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKExistingDirectoryConflictRollsBackOwnedPublication() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider()
    let destination = root.appendingPathComponent("destination"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let second = try #require(fixture.payloads.keys.first { !$0.hasPrefix("folder/") })
    let mutation = SDKMergeMutation(root: root, destination: destination, secondName: second, replaceFirst: false)
    await #expect(throws: ZipArchiveError.destinationConflict(second)) { try await provider.extract(fixture.archive, to: destination, progress: mutation.apply) }
    #expect(mutation.succeeded)
    #expect(try String(contentsOf: destination.appendingPathComponent(second), encoding: .utf8) == "foreign collision")
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [second])
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKExistingDirectoryChangedPublicationIsPreserved() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider()
    let destination = root.appendingPathComponent("destination"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let second = try #require(fixture.payloads.keys.first { !$0.hasPrefix("folder/") })
    let mutation = SDKMergeMutation(root: root, destination: destination, secondName: second, replaceFirst: true)
    do { _ = try await provider.extract(fixture.archive, to: destination, progress: mutation.apply); Issue.record("Changed publication was accepted") }
    catch SevenZipWorkerError.publicationRecovery(let staging, let published) {
        #expect(published.map(\.lastPathComponent) == ["folder"])
        #expect(try Data(contentsOf: staging.appendingPathComponent(second)) == fixture.payloads[second])
    }
    #expect(mutation.succeeded)
    #expect(try String(contentsOf: destination.appendingPathComponent("folder"), encoding: .utf8) == "foreign replacement")
    #expect(try Data(contentsOf: root.appendingPathComponent("held-owned-folder/large.bin")) == fixture.payloads["folder/large.bin"])
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKExistingDirectoryCancellationRollsBackPublication() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), gate = SDKPublicationGate(afterItem: true)
    let destination = root.appendingPathComponent("destination"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    defer { gate.release.signal() }
    let task = Task { try await provider.extract(fixture.archive, to: destination, progress: gate.pause) }
    let deadline = ContinuousClock.now + .seconds(4)
    while !gate.reached, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(gate.reached); task.cancel(); gate.release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires the pinned native SDK worker and reference"))
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

private func sdkBundleCopy(root: URL, name: String = "Copied Files.app") throws -> URL {
    let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_APP_BUNDLE"]))
    let copy = root.appendingPathComponent(name)
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
}

private func sdkResignOuter(_ bundle: URL, root: URL, identifier: String? = nil) async throws {
    let log = root.appendingPathComponent("sign-\(UUID()).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--timestamp=none", "--sign", "-"] + (identifier.map { ["--identifier", $0] } ?? []) + [bundle.path]
    process.standardOutput = output; process.standardError = output
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
    let deadline = ContinuousClock.now + .seconds(10)
    while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard !process.isRunning, process.terminationStatus == 0 else { throw SevenZipWorkerError.unexpectedExit }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_APP_BUNDLE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE"), "Requires the signed packaged SDK and reference"))
func sevenZipSDKBundleResolutionAndUse() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try sdkBundleCopy(root: root), provider = try await SevenZipArchiveProvider.bundled(in: bundle)
    #expect(throws: SevenZipBundleError.invalidSignature) { try SevenZipBundleVerifier.checkRunningHost(against: provider.executable) }
    #expect(provider.executable.path == bundle.appendingPathComponent("Contents/Helpers/SevenZipWorker").path)
    #expect(provider.library.path == bundle.appendingPathComponent("Contents/Helpers/7z.so").path)
    let fixture = try await sdkFixture(root: root, password: "QA-349-한글-🔑")
    #expect(try await provider.entries(at: fixture.archive, password: "QA-349-한글-🔑").count == 3)
    let destination = root.appendingPathComponent("resolved-result")
    let report = try await provider.extractToNewDirectory(fixture.archive, at: destination, password: "QA-349-한글-🔑")
    #expect(report.entries == 3)
    for (name, data) in fixture.payloads { #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == data) }
    let created = root.appendingPathComponent("bundled-created.7z")
    _ = try await provider.create(from: [destination], at: created, compressionLevel: .fast, password: "bundled-한글-🔑")
    let restored = root.appendingPathComponent("bundled-created-restored")
    _ = try await provider.extractToNewDirectory(created, at: restored, password: "bundled-한글-🔑")
    for (name, data) in fixture.payloads { #expect(try Data(contentsOf: restored.appendingPathComponent(destination.lastPathComponent).appendingPathComponent(name)) == data) }
    // Mutation after resolution must be checked again before the next worker is spawned.
    try Data("changed after resolution".utf8).write(to: bundle.appendingPathComponent(SevenZipBundleVerifier.resource + "/BUILD.md"))
    do { _ = try await provider.entries(at: fixture.archive, password: "QA-349-한글-🔑"); Issue.record("Modified resolved bundle executed") }
    catch let error as SevenZipBundleError { #expect(error == .invalidSignature || error == .changedBundle) }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_APP_BUNDLE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE"), "Requires the signed packaged SDK and reference"))
func sevenZipSDKBundleRejectsResealedHashMismatch() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try sdkBundleCopy(root: root)
    try Data("changed resource".utf8).write(to: bundle.appendingPathComponent(SevenZipBundleVerifier.resource + "/BUILD.md"))
    try await sdkResignOuter(bundle, root: root)
    await #expect(throws: SevenZipBundleError.changedBundle) { try await SevenZipArchiveProvider.bundled(in: bundle) }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_APP_BUNDLE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE"), "Requires the signed packaged SDK and reference"))
func sevenZipSDKBundleRejectsAdhocStableAndWrongIdentity() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let stable = try sdkBundleCopy(root: root, name: "Stable.app"), plist = stable.appendingPathComponent("Contents/Info.plist")
    var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
    info["FilesReleaseChannel"] = "stable"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
    try await sdkResignOuter(stable, root: root)
    await #expect(throws: SevenZipBundleError.invalidSignature) { try await SevenZipArchiveProvider.bundled(in: stable) }
    let wrong = try sdkBundleCopy(root: root, name: "Wrong identity.app"), worker = wrong.appendingPathComponent("Contents/Helpers/SevenZipWorker")
    // Keep a valid standalone helper signature while changing its identity, then reseal the parent.
    try await sdkResignOuter(worker, root: root, identifier: "org.taro6222.files-for-mac.unexpected-worker")
    try await sdkResignOuter(wrong, root: root)
    let workerSignature = await CodeSignatureInspector.inspect(worker), parentSignature = await CodeSignatureInspector.inspect(wrong)
    #expect(workerSignature.state == .valid && workerSignature.identifier == "org.taro6222.files-for-mac.unexpected-worker")
    #expect(parentSignature.state == .valid)
    await #expect(throws: SevenZipBundleError.invalidSignature) { try await SevenZipArchiveProvider.bundled(in: wrong) }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_APP_BUNDLE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE"), "Requires the signed packaged SDK and reference"))
func sevenZipSDKBundleRejectsResealedSourcePinAndExtraFile() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try sdkBundleCopy(root: root), resource = bundle.appendingPathComponent(SevenZipBundleVerifier.resource)
    let archive = resource.appendingPathComponent("7z2606-src.tar.xz")
    try Data("changed source archive".utf8).write(to: archive)
    let manifestURL = resource.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var hashes = try #require(manifest["filesSHA256"] as? [String: String])
    hashes[SevenZipBundleVerifier.resource + "/7z2606-src.tar.xz"] = try await FilePropertiesInspector().sha256(archive)
    manifest["filesSHA256"] = hashes
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    try await sdkResignOuter(bundle, root: root)
    await #expect(throws: SevenZipBundleError.changedBundle) { try await SevenZipArchiveProvider.bundled(in: bundle) }
    let extra = try sdkBundleCopy(root: root, name: "Extra.app")
    let foreign = extra.appendingPathComponent(SevenZipBundleVerifier.resource + "/foreign.txt")
    try Data("preserve foreign file".utf8).write(to: foreign); try await sdkResignOuter(extra, root: root)
    await #expect(throws: SevenZipBundleError.invalidLayout) { try await SevenZipArchiveProvider.bundled(in: extra) }
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "preserve foreign file")
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_APP_BUNDLE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE"), "Requires the signed packaged SDK and reference"))
func sevenZipSDKBundlePinsSelectedRevisionAcrossResigning() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try sdkBundleCopy(root: root), original = try await SevenZipArchiveProvider.bundled(in: bundle)
    let resource = bundle.appendingPathComponent(SevenZipBundleVerifier.resource), document = resource.appendingPathComponent("BUILD.md")
    try Data("valid updated documentation".utf8).write(to: document)
    let manifestURL = resource.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var hashes = try #require(manifest["filesSHA256"] as? [String: String])
    hashes[SevenZipBundleVerifier.resource + "/BUILD.md"] = try await FilePropertiesInspector().sha256(document)
    manifest["filesSHA256"] = hashes
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    try await sdkResignOuter(bundle, root: root)
    // The replacement is independently valid, but an existing operation must not switch revisions.
    _ = try await SevenZipArchiveProvider.bundled(in: bundle)
    await #expect(throws: SevenZipBundleError.changedBundle) { try await original.entries(at: root.appendingPathComponent("not-opened.7z")) }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKCreationLevelsPasswordAndIndependentExtraction() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("소스-📁"), empty = folder.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("한글-é\nfile.txt"), bytes = Data(String(repeating: "SDK creation payload 한글\n", count: 2000).utf8)
    try bytes.write(to: source)
    let provider = try sdkRealProvider(), reference = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    for (index, level) in ArchiveCompressionLevel.allCases.enumerated() {
        let archive = root.appendingPathComponent("level-\(level.rawValue).7z"), password: String? = index == 2 ? nil : "QA-351-한글-🔑"
        let header = index % 2 == 0
        _ = try await provider.create(from: [folder], at: archive, compressionLevel: level, password: password, encryptHeader: header)
        let entries = try await provider.entries(at: archive, password: password)
        #expect(entries.count == 3 && entries.filter { $0.kind == .regularFile }.allSatisfy { $0.isEncrypted == (password != nil) })
        if header && password != nil {
            await #expect(throws: SevenZipWorkerError.worker("password-required")) { try await provider.entries(at: archive) }
        } else { #expect(try await provider.entries(at: archive).count == 3) }
        let out = root.appendingPathComponent("restored-\(index)")
        let process = Process(), input = Pipe()
        process.executableURL = reference; process.arguments = ["x", "-y", "-o" + out.path, archive.path]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(15)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: out.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(source.lastPathComponent)) == bytes)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(folder.lastPathComponent).appendingPathComponent("empty").path))
        if let password {
            await #expect(throws: (any Error).self) {
                try await provider.extractToNewDirectory(archive, at: root.appendingPathComponent("wrong-\(index)"), password: password + "wrong")
            }
        }
    }
    #expect(try Data(contentsOf: source) == bytes)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-create-") })
}

@Test func sevenZipSDKCreationPlanRejectsLinksAndDuplicatePaths() throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), link = root.appendingPathComponent("link")
    try Data("keep".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let destination = root.appendingPathComponent("out.7z")
    #expect(throws: (any Error).self) { try SevenZipCreationPlan(sources: [link], destination: destination, check: {}) }
    #expect(throws: (any Error).self) { try SevenZipCreationPlan(sources: [source, source], destination: destination, check: {}) }
    let folder = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try SevenZipCreationPlan(sources: [folder], destination: folder.appendingPathComponent("self.7z"), check: {}) }
    let nested = folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: source)
    #expect(throws: (any Error).self) { try SevenZipCreationPlan(sources: [folder], destination: destination, check: {}) }
}

private final class SDKCreationMutation: @unchecked Sendable {
    let source: URL, target: URL, changeSource: Bool
    init(source: URL, target: URL, changeSource: Bool) { self.source = source; self.target = target; self.changeSource = changeSource }
    func apply(_ update: ArchiveProgress) {
        guard update.phase == .publishing else { return }
        try? Data("foreign change".utf8).write(to: changeSource ? source : target)
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKCreationSourceChangeAndDestinationRacePreserveData() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), provider = try sdkRealProvider()
    for changeSource in [true, false] {
        try Data("original".utf8).write(to: source)
        let target = root.appendingPathComponent("out-\(changeSource).7z")
        let mutation = SDKCreationMutation(source: source, target: target, changeSource: changeSource)
        await #expect(throws: (any Error).self) {
            try await provider.create(from: [source], at: target, compressionLevel: .store, password: "pw", progress: mutation.apply)
        }
        if changeSource { #expect(!FileManager.default.fileExists(atPath: target.path)); #expect(try String(contentsOf: source, encoding: .utf8) == "foreign change") }
        else {
            #expect(try String(contentsOf: target, encoding: .utf8) == "foreign change")
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        }
    }
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-create-") })
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKCreationCancellationBeforePublicationDiscardsOutput() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("cancelled.7z")
    try Data("keep original".utf8).write(to: source)
    let provider = try sdkRealProvider(), gate = SDKPublicationGate()
    let task = Task { try await provider.create(from: [source], at: target, compressionLevel: .store, progress: gate.pause) }
    let deadline = ContinuousClock.now + .seconds(10)
    while !gate.reached, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(gate.reached); task.cancel(); gate.release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try String(contentsOf: source, encoding: .utf8) == "keep original")
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-create-") })
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKAdvancedOptionsChangeDictionaryAndRestorePayload() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("dictionary-payload.bin"), bytes = Data(repeating: 0x5b, count: 3 << 20)
    try bytes.write(to: source)
    let provider = try sdkRealProvider(), reference = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    for (index, values) in [(65536, 8, 1, 16), (262144, 273, 4, 18), (1048576, 64, 2, 20)].enumerated() {
        let options = SevenZipCompressionOptions(dictionarySize: values.0, wordSize: values.1, threadCount: values.2)
        let archive = root.appendingPathComponent("advanced-\(index).7z"), output = root.appendingPathComponent("advanced-out-\(index)")
        _ = try await provider.create(from: [source], at: archive, options: options)
        let infoFile = root.appendingPathComponent("reference-\(index).log")
        #expect(FileManager.default.createFile(atPath: infoFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: infoFile); defer { try? handle.close() }
        let process = Process(); process.executableURL = reference; process.arguments = ["l", "-slt", archive.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        try process.run(); defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let deadline = ContinuousClock.now + .seconds(15)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
        #expect(process.terminationStatus == 0)
        let listing = try String(contentsOf: infoFile, encoding: .utf8)
        #expect(listing.contains("Method = LZMA2:\(values.3)"))
        _ = try await provider.extractToNewDirectory(archive, at: output)
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == bytes)
    }
    for options in [SevenZipCompressionOptions(dictionarySize: 128 << 10), .init(wordSize: 7), .init(threadCount: 0), .init(threadCount: 513)] {
        await #expect(throws: SevenZipWorkerError.invalidConfiguration) {
            try await provider.create(from: [source], at: root.appendingPathComponent("invalid.7z"), options: options)
        }
    }
    #expect(try Data(contentsOf: source) == bytes)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0 == "invalid.7z" || $0.hasPrefix(".files-create-") })
}

@Test @MainActor func sevenZipOptionsAndCreationFormatPersistAndImportTransactionally() throws {
    let suite = "FilesCore.SevenZipOptions.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    let options = SevenZipCompressionOptions(dictionarySize: 1 << 20, wordSize: 273, threadCount: 4)
    preferences.setArchiveCreationFormat(.sevenZip); preferences.setArchiveSevenZipOptions(options)
    let restored = BrowserPreferences(defaults: defaults)
    #expect(restored.archiveCreationFormat == .sevenZip && restored.archiveSevenZipOptions == options)
    let data = try preferences.exportData()
    preferences.setArchiveCreationFormat(.zip); preferences.setArchiveSevenZipOptions(.init())
    try preferences.importData(data)
    #expect(preferences.archiveCreationFormat == .sevenZip && preferences.archiveSevenZipOptions == options)
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let before = try preferences.exportData()
    for invalid in ["rar", "unknown"] {
        document["archiveCreationFormat"] = invalid
        #expect(throws: BrowserPreferencesArchiveError.invalidValue) { try preferences.importData(JSONSerialization.data(withJSONObject: document)) }
        #expect(try preferences.exportData() == before)
    }
    document["archiveCreationFormat"] = "7z"
    for invalid in [["dictionarySize": 0, "wordSize": 7, "threadCount": 2], ["dictionarySize": 3, "wordSize": 32, "threadCount": 2], ["dictionarySize": 0, "wordSize": 32, "threadCount": 513]] {
        document["archiveSevenZipOptions"] = invalid
        #expect(throws: BrowserPreferencesArchiveError.invalidValue) { try preferences.importData(JSONSerialization.data(withJSONObject: document)) }
        #expect(try preferences.exportData() == before)
    }
    document.removeValue(forKey: "archiveSevenZipOptions"); document.removeValue(forKey: "archiveCreationFormat")
    try preferences.importData(JSONSerialization.data(withJSONObject: document))
    #expect(preferences.archiveCreationFormat == .zip)
    #expect(preferences.archiveSevenZipOptions == .init(threadCount: SevenZipCompressionOptions.hostThreadCount))
    defaults.set("rar", forKey: "archiveCreationFormat"); defaults.set(Data("{}".utf8), forKey: "archiveSevenZipOptions")
    let recovered = BrowserPreferences(defaults: defaults)
    #expect(recovered.archiveCreationFormat == .zip && recovered.archiveSevenZipOptions.isValid)
}

@Test func sevenZipMemoryEstimateHandlesStoreAndMaximumChoices() throws {
    let options = SevenZipCompressionOptions(dictionarySize: 1 << 30, wordSize: 273, threadCount: 512)
    let estimate = try #require(options.estimatedMemoryBytes(for: .ultra))
    #expect(estimate > UInt64(1 << 30) && estimate < UInt64.max)
    #expect(options.estimatedMemoryBytes(for: .store) == 1 << 20)
    #expect(SevenZipCompressionOptions(threadCount: Int.max).estimatedMemoryBytes(for: .normal) == nil)
    if let available = SevenZipCompressionOptions.availableMemoryEstimate() { #expect(available <= ProcessInfo.processInfo.physicalMemory) }
}

private func sdkSplitFixture(root: URL, password: String? = nil, tiny: Bool = false) async throws -> (parts: [URL], name: String, bytes: Data) {
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    let input = root.appendingPathComponent("split-input"), archive = root.appendingPathComponent("분할-é.7z")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let name = "한글-🔑\nvolume.bin", bytes = Data((0..<(tiny ? 4096 : 524288)).map { UInt8($0 % 251) })
    try bytes.write(to: input.appendingPathComponent(name))
    let process = Process(), pipe = Pipe(), log = root.appendingPathComponent("split-reference.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
    process.executableURL = binary; process.currentDirectoryURL = input
    process.arguments = ["a", "-t7z", "-mx=0", tiny ? "-v16b" : "-v64k", "-y", archive.path, "."] + (password == nil ? [] : ["-mhe=on", "-p"])
    process.standardInput = pipe; process.standardOutput = output; process.standardError = output
    try process.run(); defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
    if let password { try pipe.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
    try pipe.fileHandleForWriting.close()
    let deadline = ContinuousClock.now + .seconds(20)
    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
    #expect(process.terminationStatus == 0)
    let parts = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { SevenZipVolumes.index(of: $0) != nil }.sorted { SevenZipVolumes.index(of: $0)! < SevenZipVolumes.index(of: $1)! }
    #expect(parts.count > 2)
    return (parts, name, bytes)
}

@Test func sevenZipVolumeNamesDetectionAndSelectionNormalization() throws {
    for (name, number) in [("한글.7z.001", 1), ("자료.7Z.002", 2), ("large.7z.1000", 1000)] {
        let url = URL(fileURLWithPath: "/tmp/" + name)
        #expect(SevenZipVolumes.index(of: url) == number && ArchiveFormat.detect(url) == .sevenZip)
        #expect(SevenZipVolumes.index(of: SevenZipVolumes.firstVolumeURL(for: url)) == 1)
    }
    for name in ["file.001", "file.zip.001", "file.7z.000", "file.7z.01", "file.7z.0001", "file.7z.0a1"] {
        #expect(SevenZipVolumes.index(of: URL(fileURLWithPath: "/tmp/" + name)) == nil)
    }
    let first = URL(fileURLWithPath: "/tmp/資料.7z.001"), second = URL(fileURLWithPath: "/tmp/資料.7z.002"), zip = URL(fileURLWithPath: "/tmp/other.zip")
    #expect(SevenZipVolumes.uniqueArchives([second, first, zip, second]) == [first, zip])
    #expect(archiveChildFolderBaseName(second) == "資料")
    #expect(throws: SevenZipVolumeError.sdkRequired) { try ZipArchiveProvider().entries(at: first) }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKSplitVolumesRoundTripFromAnyPartAndAcrossTinyHeaders() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let provider = try sdkRealProvider()
    var before = rlimit(); #expect(getrlimit(RLIMIT_NOFILE, &before) == 0)
    for index in 0..<3 {
        let folder = root.appendingPathComponent("case-\(index)"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let password: String? = index == 1 ? "QA-353-한글-🔑" : nil
        let fixture = try await sdkSplitFixture(root: folder, password: password, tiny: index == 2)
        if index == 2 { #expect(fixture.parts.count > 256) }
        let snapshots = try fixture.parts.map { try Data(contentsOf: $0) }
        let entries = try await provider.entries(at: fixture.parts[1], password: password)
        #expect(entries.count == 1 && entries[0].path == fixture.name)
        #expect(entries[0].isEncrypted == (password != nil))
        let report = try await provider.extractToNewDirectory(fixture.parts.last!, at: folder.appendingPathComponent("out"), password: password)
        #expect(report.entries == 1 && report.extractedBytes == fixture.bytes.count)
        #expect(try Data(contentsOf: folder.appendingPathComponent("out").appendingPathComponent(fixture.name)) == fixture.bytes)
        for (part, snapshot) in zip(fixture.parts, snapshots) { #expect(try Data(contentsOf: part) == snapshot) }
        if password != nil {
            await #expect(throws: SevenZipWorkerError.worker("password-required")) { try await provider.entries(at: fixture.parts[0]) }
            await #expect(throws: SevenZipWorkerError.worker("password-or-corrupt")) { try await provider.entries(at: fixture.parts[0], password: "wrong") }
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".files-") })
    }
    var after = rlimit(); #expect(getrlimit(RLIMIT_NOFILE, &after) == 0)
    #expect(after.rlim_cur == before.rlim_cur && after.rlim_max == before.rlim_max)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKSplitMissingTruncatedAndLinkedPartsNeverPublish() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkSplitFixture(root: root), provider = try sdkRealProvider()
    let missing = fixture.parts[1], held = root.appendingPathComponent("held-part")
    try FileManager.default.moveItem(at: missing, to: held)
    await #expect(throws: SevenZipVolumeError.missingPart(2)) { try await provider.extractToNewDirectory(fixture.parts[0], at: root.appendingPathComponent("missing")) }
    try FileManager.default.createSymbolicLink(at: missing, withDestinationURL: held)
    let linkedPart = try sevenZipCanonicalDirectory(root).appendingPathComponent(missing.lastPathComponent)
    await #expect(throws: SevenZipVolumeError.invalidPart(linkedPart)) { try await provider.extractToNewDirectory(fixture.parts[0], at: root.appendingPathComponent("linked")) }
    try FileManager.default.removeItem(at: missing); try FileManager.default.moveItem(at: held, to: missing)
    let last = fixture.parts.last!, lastBytes = try Data(contentsOf: last)
    try FileManager.default.removeItem(at: last)
    await #expect(throws: SevenZipWorkerError.worker("missing-volume")) { try await provider.extractToNewDirectory(fixture.parts[0], at: root.appendingPathComponent("last-missing")) }
    try lastBytes.dropLast().write(to: last)
    await #expect(throws: SevenZipWorkerError.worker("missing-volume")) { try await provider.extractToNewDirectory(fixture.parts[0], at: root.appendingPathComponent("truncated")) }
    try lastBytes.write(to: last)
    let extraneous = root.appendingPathComponent("分割.7z.1025")
    try Data("different archive".utf8).write(to: extraneous)
    #expect(try await provider.entries(at: fixture.parts[0]).count == 1)
    let ownExtra = fixture.parts[0].deletingPathExtension().appendingPathExtension("1025")
    try Data("too many".utf8).write(to: ownExtra)
    await #expect(throws: SevenZipVolumeError.tooManyParts) { try await provider.entries(at: fixture.parts[0]) }
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-") || ["missing", "linked", "last-missing", "truncated"].contains($0) })
    let source = root.appendingPathComponent("split-input").appendingPathComponent(fixture.name)
    let invalidCreation = root.appendingPathComponent("unsplit-write.7z.001")
    await #expect(throws: SevenZipWorkerError.invalidConfiguration) { try await provider.create(from: [source], at: invalidCreation) }
    await #expect(throws: ZipArchiveError.invalidSource(invalidCreation.path)) { try await ZipArchiveProvider().create(from: [source], at: invalidCreation) }
    #expect(!FileManager.default.fileExists(atPath: invalidCreation.path))
    #expect(try Data(contentsOf: source) == fixture.bytes)
}

private func sdkSplitCreationInput(_ root: URL) throws -> (URL, Data) {
    let url = root.appendingPathComponent("원본-🔑\nsource.bin"), bytes = Data((0..<163840).map { UInt8($0 % 251) })
    try bytes.write(to: url); return (url, bytes)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKSplitCreationAndCommittedJournal() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (source, bytes) = try sdkSplitCreationInput(root), provider = try sdkRealProvider()
    for index in 0..<2 {
        let target = root.appendingPathComponent("created-\(index).7z"), journals = root.appendingPathComponent("journals-\(index)")
        let password: String? = index == 0 ? nil : "QA-354-한글-🔑"
        let report = try await provider.createSplit(from: [source], at: target, volumeBytes: index == 0 ? 65536 : SevenZipVolumes.maximumSplitVolumeBytes, journalDirectory: journals, compressionLevel: .store, password: password)
        #expect(report.publishedURLs.count == (index == 0 ? 3 : 1) && report.retainedStaging == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let destination = root.appendingPathComponent("restored-\(index)")
        _ = try await provider.extractToNewDirectory(report.publishedURLs.last!, at: destination, password: password)
        #expect(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == bytes)
        let official = root.appendingPathComponent("official-\(index)"), reference = Process(), input = Pipe()
        reference.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
        reference.arguments = ["x", "-y", "-o" + official.path, report.publishedURLs[0].path]
        reference.standardInput = input; reference.standardOutput = FileHandle.nullDevice; reference.standardError = FileHandle.nullDevice
        try reference.run(); defer { if reference.isRunning { kill(reference.processIdentifier, SIGKILL); reference.waitUntilExit() } }
        if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(15)
        while reference.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !reference.isRunning else { throw SevenZipWorkerError.timedOut }
        #expect(reference.terminationStatus == 0)
        #expect(try Data(contentsOf: official.appendingPathComponent(source.lastPathComponent)) == bytes)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report.journal)) as? [String: Any])
        let encodedPayload = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encodedPayload))
        let saved = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(saved["state"] as? String == "committed" && saved["stagingRemoved"] as? Bool == true)
        if let password { #expect(!String(decoding: payload, as: UTF8.self).contains(password)) }
        #expect(try Data(contentsOf: source) == bytes)
        // Completed history must never undo later user changes to an archive.
        try Data("user change after success".utf8).write(to: report.publishedURLs[0])
        guard case .committed = try await SevenZipArchiveProvider.recoverSplitCreation(journal: report.journal, journalDirectory: journals) else { Issue.record("Committed operation was rolled back"); return }
        #expect(try String(contentsOf: report.publishedURLs[0], encoding: .utf8) == "user change after success")
    }
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-split-") })
}

private final class SDKSplitMutation: @unchecked Sendable {
    let parent: URL, base: String, changeFirst: Bool, renameFirst: Bool
    private let lock = NSLock(); private var done = false
    init(parent: URL, base: String, changeFirst: Bool, renameFirst: Bool = false) { self.parent = parent; self.base = base; self.changeFirst = changeFirst; self.renameFirst = renameFirst }
    func apply(_ progress: ArchiveProgress) {
        guard progress.phase == .publishing, let name = progress.currentPath else { return }
        lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true
        if renameFirst { try? FileManager.default.moveItem(at: parent.appendingPathComponent(name), to: parent.appendingPathComponent(name.uppercased())) }
        else { try? Data("foreign preserved".utf8).write(to: parent.appendingPathComponent(changeFirst ? name : base + ".002")) }
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKSplitConflictsChangesAndCancellationPreserveData() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (source, bytes) = try sdkSplitCreationInput(root), provider = try sdkRealProvider(), journals = root.appendingPathComponent("journals")
    let target = root.appendingPathComponent("conflict.7z"), mutation = SDKSplitMutation(parent: root, base: "conflict.7z", changeFirst: false)
    await #expect(throws: ZipArchiveError.destinationConflict("conflict.7z.002")) {
        try await provider.createSplit(from: [source], at: target, volumeBytes: 65536, journalDirectory: journals, compressionLevel: .store, progress: mutation.apply)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("conflict.7z.001").path))
    #expect(try String(contentsOf: root.appendingPathComponent("conflict.7z.002"), encoding: .utf8) == "foreign preserved")
    let gate = SDKPublicationGate(afterItem: true), cancelled = root.appendingPathComponent("cancelled.7z")
    let task = Task { try await provider.createSplit(from: [source], at: cancelled, volumeBytes: 65536, journalDirectory: journals, compressionLevel: .store, progress: gate.pause) }
    let deadline = ContinuousClock.now + .seconds(8)
    while !gate.reached && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(gate.reached); task.cancel(); gate.release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix("cancelled.7z.") || $0.hasPrefix(".files-split-") })
    let changed = root.appendingPathComponent("changed.7z"), change = SDKSplitMutation(parent: root, base: "changed.7z", changeFirst: true)
    do {
        _ = try await provider.createSplit(from: [source], at: changed, volumeBytes: 65536, journalDirectory: journals, compressionLevel: .store, progress: change.apply)
        Issue.record("Changed published volume was accepted")
    } catch SevenZipSplitError.recoveryRequired(let journal, let staging, let outputs) {
        #expect(FileManager.default.fileExists(atPath: staging.path) && !outputs.isEmpty)
        await #expect(throws: (any Error).self) { try await SevenZipArchiveProvider.recoverSplitCreation(journal: journal, journalDirectory: journals) }
    }
    #expect(try String(contentsOf: root.appendingPathComponent("changed.7z.001"), encoding: .utf8) == "foreign preserved")
    let renamed = SDKSplitMutation(parent: root, base: "rename-case.7z", changeFirst: false, renameFirst: true)
    await #expect(throws: (any Error).self) {
        try await provider.createSplit(from: [source], at: root.appendingPathComponent("rename-case.7z"), volumeBytes: 65536, journalDirectory: journals, compressionLevel: .store, progress: renamed.apply)
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).contains("RENAME-CASE.7Z.001"))
    #expect(try Data(contentsOf: source) == bytes)
}

private func sdkRunSplitProbe(_ config: [String: Any], root: URL, name: String) async throws -> (Int32, String) {
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SPLIT_PROBE"]))
    let process = Process(), pipe = Pipe(), log = root.appendingPathComponent(name + ".log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    process.executableURL = binary; process.standardInput = pipe; process.standardOutput = handle; process.standardError = handle
    try process.run(); defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
    try pipe.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: config)); try pipe.fileHandleForWriting.close()
    let deadline = ContinuousClock.now + .seconds(15)
    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
    return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER") && hasIntegrationFixture("FILES_TEST_SPLIT_PROBE"), "Requires the native SDK and process-restart probe"))
func sevenZipSDKSplitProcessRestartRecoveryAndAmbiguousIntent() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (source, bytes) = try sdkSplitCreationInput(root), provider = try sdkRealProvider()
    for mode in ["crash-prepared", "crash-published", "ambiguous", "corrupt"] {
        let folder = root.appendingPathComponent(mode); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let target = folder.appendingPathComponent("archive.7z"), journals = folder.appendingPathComponent("journals")
        let config: [String: Any] = ["mode": mode == "crash-prepared" ? mode : "crash-published", "source": source.path, "destination": target.path,
                                     "journalDirectory": journals.path, "worker": provider.executable.path, "library": provider.library.path]
        let crashed = try await sdkRunSplitProbe(config, root: folder, name: "crash")
        #expect(crashed.0 == 75, "Probe did not reach crash boundary: \(crashed.1)")
        let registry = try sevenZipCanonicalDirectory(journals.appendingPathComponent("archive-splits"))
        let journal = try #require(FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        if mode == "ambiguous" || mode == "corrupt" {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
            let encodedPayload = try #require(envelope["payload"] as? String)
            let data = try #require(Data(base64Encoded: encodedPayload))
            var state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); state["intent"] = 1
            let updated = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]); envelope["payload"] = updated.base64EncodedString()
            if mode == "ambiguous" { envelope["checksum"] = SHA256.hash(data: updated).map { String(format: "%02x", $0) }.joined() }
            try JSONSerialization.data(withJSONObject: envelope).write(to: journal, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        }
        let recovered = try await sdkRunSplitProbe(["mode": "recover", "journalDirectory": journals.path, "journal": journal.path], root: folder, name: "recover")
        if mode == "ambiguous" || mode == "corrupt" {
            #expect(recovered.0 == 1)
            #expect(FileManager.default.fileExists(atPath: target.appendingPathExtension("001").path))
            #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".files-split-") })
        } else {
            #expect(recovered.0 == 0 && recovered.1.contains("rolledBack"), "Recovery failed: \(recovered.1)")
            #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".files-split-") || $0.hasPrefix("archive.7z.") })
        }
    }
    #expect(try Data(contentsOf: source) == bytes)
}

private func splitWire(_ type: UInt8, _ offset: UInt64, _ data: Data = Data(), count: UInt64? = nil) -> Data {
    var result = Data([type]), offset = offset.bigEndian, size = (count ?? UInt64(data.count)).bigEndian
    withUnsafeBytes(of: &offset) { result.append(contentsOf: $0) }; withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
    result.append(data); return result
}
@Test func sevenZipSplitFrameValidationAndForeignStagingPreservation() throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let registry = root.appendingPathComponent("journals")
    for (index, packet) in [splitWire(0, 8_000_000_001, Data([1])), splitWire(0, 0, count: 65537), splitWire(3, 0), splitWire(2, 32)].enumerated() {
        let stage = try SevenZipSplitStaging(destination: root.appendingPathComponent("bad-\(index).7z"), volumeBytes: 65536, journalDirectory: registry)
        #expect(throws: SevenZipWorkerError.invalidResponse) { try stage.consume(packet, check: {}) }
        try stage.rollback()
        #expect(!FileManager.default.fileExists(atPath: stage.staging.path))
    }
    let fixture = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/libarchive-empty.7z"))
    let stage = try SevenZipSplitStaging(destination: root.appendingPathComponent("fragmented.7z"), volumeBytes: 16, journalDirectory: registry)
    for byte in splitWire(0, 0, fixture) + splitWire(2, UInt64(fixture.count)) { try stage.consume(Data([byte]), check: {}) }
    #expect(stage.ended); try stage.prepare(check: {})
    let foreign = stage.staging.appendingPathComponent("foreign.txt"); try Data("foreign preserved".utf8).write(to: foreign)
    #expect(throws: (any Error).self) { try stage.rollback() }
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "foreign preserved")
    let occupied = root.appendingPathComponent("occupied.7z.005"); try Data("existing last volume".utf8).write(to: occupied)
    #expect(throws: ZipArchiveError.destinationConflict("occupied.7z.005")) {
        try SevenZipSplitStaging(destination: root.appendingPathComponent("occupied.7z"), volumeBytes: 65536, journalDirectory: registry)
    }
    #expect(try String(contentsOf: occupied, encoding: .utf8) == "existing last volume")
}

@Test @MainActor func sevenZipSplitPreferencesPersistAndImportTransactionally() throws {
    let suite = "FilesCore.SplitPreferences.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.archiveSplitSize == .none)
    for size in ArchiveSplitSize.allCases {
        preferences.setArchiveSplitSize(size)
        #expect(BrowserPreferences(defaults: defaults).archiveSplitSize == size)
    }
    #expect(preferences.archiveSplitSize.volumeBytes == SevenZipVolumes.maximumSplitVolumeBytes)
    let data = try preferences.exportData()
    preferences.setArchiveSplitSize(.none); preferences.setArchiveCreationFormat(.zip)
    try preferences.importData(data)
    #expect(preferences.archiveSplitSize == .bluray23040)
    let before = try preferences.exportData()
    var document = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    for invalid in [-1, 1, 999, 23041] {
        document["archiveSplitSizeMiB"] = invalid; document["archiveCreationFormat"] = "7z"
        #expect(throws: BrowserPreferencesArchiveError.invalidValue) { try preferences.importData(JSONSerialization.data(withJSONObject: document)) }
        #expect(try preferences.exportData() == before)
    }
    document.removeValue(forKey: "archiveSplitSizeMiB")
    try preferences.importData(JSONSerialization.data(withJSONObject: document))
    #expect(preferences.archiveSplitSize == .none)
    defaults.set(123, forKey: "archiveSplitSizeMiB")
    #expect(BrowserPreferences(defaults: defaults).archiveSplitSize == .none)
}

@Test func sevenZipSplitHistoryPreservesInvalidAndOfflineRecords() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("journals"), registry = directory.appendingPathComponent("archive-splits")
    let empty = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: directory)
    #expect(empty.isEmpty && !FileManager.default.fileExists(atPath: directory.path))
    let parent = root.appendingPathComponent("output"), offline = root.appendingPathComponent("disconnected")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let canonicalParent = try sevenZipCanonicalDirectory(parent)
    var stage: SevenZipSplitStaging? = try SevenZipSplitStaging(destination: parent.appendingPathComponent("history.7z"), volumeBytes: 65536, journalDirectory: directory)
    let fixture = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/libarchive-empty.7z"))
    try stage!.consume(splitWire(0, 0, fixture) + splitWire(2, UInt64(fixture.count)), check: {})
    try stage!.prepare(check: {})
    let journal = stage!.journalURL
    let first = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: directory)
    #expect(first.count == 1 && first[0].canAttemptRecovery && first[0].phase == "prepared")
    await #expect(throws: SevenZipSplitError.busy) { try await SevenZipArchiveProvider.recoverSplitCreation(journal: journal, journalDirectory: directory) }
    try FileManager.default.moveItem(at: parent, to: offline)
    let detached = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: directory)
    #expect(detached.first?.destination == canonicalParent.appendingPathComponent("history.7z"))
    await #expect(throws: SevenZipSplitError.invalidJournal) { try await SevenZipArchiveProvider.recoverSplitCreation(journal: journal, journalDirectory: directory) }
    #expect(FileManager.default.fileExists(atPath: offline.path))
    try FileManager.default.moveItem(at: offline, to: parent)
    #expect(stage?.journalURL == journal)
    stage = nil
    _ = try await SevenZipArchiveProvider.recoverSplitCreation(journal: journal, journalDirectory: directory)
    let completed = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: directory)
    #expect(completed.first?.phase == "rolledBack" && completed.first?.isUnfinished == false && completed.first?.canAttemptRecovery == false)
    let foreign = root.appendingPathComponent("foreign.txt"), corrupt = registry.appendingPathComponent(UUID().uuidString + ".json"), linked = registry.appendingPathComponent(UUID().uuidString + ".json")
    let secret = Data("preserve external content".utf8); try secret.write(to: foreign)
    try Data("{}".utf8).write(to: corrupt); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: foreign)
    let unsafe = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: directory)
    #expect(unsafe.count == 3 && unsafe.filter { $0.phase == "unreadable" && $0.isUnfinished && !$0.canAttemptRecovery && $0.destination == nil }.count == 2)
    #expect(try Data(contentsOf: foreign) == secret)
    #expect(try Data(contentsOf: corrupt) == Data("{}".utf8))
}

@Test func sevenZipReadBrokerPinsDirectoryAndRejectsChangedNames() throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("selected"), moved = root.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let source = parent.appendingPathComponent("input.7z"), bytes = Data("approved archive bytes".utf8)
    try bytes.write(to: source)
    let broker = try SevenZipReadSource(archive: source, check: {})
    try broker.verify(check: {})
    try FileManager.default.moveItem(at: parent, to: moved)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try Data("replacement must not be read".utf8).write(to: source)
    try broker.withDescriptor(0) { fd in
        #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
        var data = Data(count: bytes.count)
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        #expect(count == bytes.count && data == bytes)
    }
    #expect(throws: SevenZipWorkerError.worker("source-changed")) { try broker.verify(check: {}) }
    #expect(try Data(contentsOf: source) == Data("replacement must not be read".utf8))
    // Foundation.path preserves an encoded NUL; validate the fully decoded URI path.
    let truncated = URL(fileURLWithPath: source.path + "\0-ignored.7z")
    #expect(throws: SevenZipWorkerError.invalidConfiguration) { try SevenZipReadSource(archive: truncated, check: {}) }
    let remoteURL = try #require(URL(string: "https://example.invalid" + source.path))
    #expect(throws: SevenZipWorkerError.invalidConfiguration) { try SevenZipReadSource(archive: remoteURL, check: {}) }
    let literalPercent = parent.appendingPathComponent("literal%00.7z")
    try Data("literal percent filename".utf8).write(to: literalPercent)
    let literalBroker = try SevenZipReadSource(archive: literalPercent, check: {})
    try literalBroker.verify(check: {})
    var negativeDevice = stat(); negativeDevice.st_dev = -1
    #expect(SevenZipReadSource.Record(name: "input.7z", proof: negativeDevice).request["device"] as? String == String(UInt64.max))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKReadBrokerHandlesSymlinkAndSearchOnlyDirectory() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root, password: "QA-347-한글-🔑"), provider = try sdkRealProvider()
    let alias = root.appendingPathComponent("alias.7z")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.archive)
    #expect(try await provider.entries(at: alias, password: "QA-347-한글-🔑").count == 3)
    let directory = root.appendingPathComponent("search-only")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let target = directory.appendingPathComponent("archive.7z")
    try FileManager.default.copyItem(at: fixture.archive, to: target)
    guard chmod(directory.path, 0o100) == 0 else { throw SevenZipWorkerError.ioFailure }
    defer { _ = chmod(directory.path, 0o700) }
    #expect(try await provider.entries(at: target, password: "QA-347-한글-🔑").count == 3)
}

@Test func sevenZipCreationBrokerKeepsPlannedIdentityAndReadOnlyAccess() throws {
    let root = try sevenZipCanonicalDirectory(sdkRoot()); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin"), foreign = root.appendingPathComponent("foreign.bin")
    let bytes = Data("planned source".utf8); try bytes.write(to: source); try Data("foreign preserved".utf8).write(to: foreign)
    let plan = try SevenZipCreationPlan(sources: [source], destination: root.appendingPathComponent("out.7z"), check: {})
    try plan.items[0].withDescriptor { fd in
        #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
        var actual = Data(count: bytes.count)
        let count = actual.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        #expect(count == bytes.count && actual == bytes)
    }
    #expect(plan.items[0].brokerRequest["source"] == nil)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: foreign)
    #expect(throws: ZipArchiveError.invalidSource(source.path)) { try plan.items[0].withDescriptor { _ in Issue.record("Changed source opened") } }
    #expect(try Data(contentsOf: foreign) == Data("foreign preserved".utf8))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKCreationBrokerManyInputsAndPreflightPreserveSources() async throws {
    let root = try sevenZipCanonicalDirectory(sdkRoot()); defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("inputs"), archive = root.appendingPathComponent("broker-created.7z")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
    let count = 4000
    func name(_ index: Int) -> String { "file-\(index)-한글-\n" + String(repeating: "a", count: 60) + ".txt" }
    for index in 0..<count { try Data("value \(index)".utf8).write(to: input.appendingPathComponent(name(index))) }
    let plan = try SevenZipCreationPlan(sources: [input], destination: archive, check: {})
    #expect(try JSONSerialization.data(withJSONObject: plan.items.map(\.brokerRequest)).count > 1_048_576)
    let provider = try sdkRealProvider()
    let before = try FileManager.default.attributesOfItem(atPath: input.path)
    await #expect(throws: ZipArchiveError.invalidSource(input.appendingPathComponent("inside.7z").path)) {
        try await provider.create(from: [input], at: input.appendingPathComponent("inside.7z"), compressionLevel: .store)
    }
    let after = try FileManager.default.attributesOfItem(atPath: input.path)
    #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    #expect(try FileManager.default.contentsOfDirectory(atPath: input.path).count == count)
    var limitBefore = rlimit(), limitAfter = rlimit()
    #expect(getrlimit(RLIMIT_NOFILE, &limitBefore) == 0)
    _ = try await provider.create(from: [input], at: archive, compressionLevel: .store)
    #expect(getrlimit(RLIMIT_NOFILE, &limitAfter) == 0 && limitBefore.rlim_cur == limitAfter.rlim_cur && limitBefore.rlim_max == limitAfter.rlim_max)
    let restored = root.appendingPathComponent("restored")
    _ = try await provider.extractToNewDirectory(archive, at: restored)
    for index in 0..<count {
        #expect(try Data(contentsOf: restored.appendingPathComponent("inputs").appendingPathComponent(name(index))) == Data("value \(index)".utf8))
    }
    let official = root.appendingPathComponent("official"), process = Process()
    process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    process.arguments = ["x", "-y", "-o" + official.path, archive.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
    let deadline = ContinuousClock.now + .seconds(15)
    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
    #expect(process.terminationStatus == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: official.appendingPathComponent("inputs").path).count == count)
    for index in 0..<count {
        #expect(try Data(contentsOf: official.appendingPathComponent("inputs").appendingPathComponent(name(index))) == Data("value \(index)".utf8))
    }
}

@Test func sevenZipCreationBrokerRejectsInvalidAndTruncatedRequests() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin"), bytes = Data("source preserved".utf8)
    try bytes.write(to: source)
    for (index, request) in ["pack('CN',0x43,4294967295)", "pack('CN',0x58,0)", "pack('CC',0x43,0)"].enumerated() {
        let provider = try sdkMock("""
        request(); reply('{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000001","accepted":0}');
        request(); reply('{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000001","accepted":1}');
        request(); open(my $output,'>&=3') or die; print $output 'unfinished'; close($output);
        open(my $socket,'+<&=4') or die; syswrite($socket,\(request)); close($socket);
        reply('{"version":1,"ok":true,"closed":true}');
        """, root: root)
        let target = root.appendingPathComponent("rejected-\(index).7z")
        await #expect(throws: SevenZipWorkerError.invalidResponse) { try await provider.create(from: [source], at: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-create-") })
    }
}

@Test func sevenZipCreationUploadRejectsIncorrectAcknowledgments() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin"), bytes = Data("source preserved".utf8)
    try bytes.write(to: source)
    for (index, acknowledgment) in [
        #"{"version":1,"ok":true,"upload":"not-a-token","accepted":0}"#,
        #"{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000001","accepted":1}"#,
        #"{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000001","accepted":0,"closed":true}"#,
    ].enumerated() {
        let provider = try sdkMock("request(); reply('\(acknowledgment)');", root: root)
        let target = root.appendingPathComponent("bad-ack-\(index).7z")
        await #expect(throws: SevenZipWorkerError.invalidResponse) { try await provider.create(from: [source], at: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-create-") })
    }
    for (index, acknowledgment) in [
        #"{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000001","accepted":0}"#,
        #"{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000002","accepted":1}"#,
    ].enumerated() {
        let provider = try sdkMock("""
        request(); reply('{"version":1,"ok":true,"upload":"00000000-0000-0000-0000-000000000001","accepted":0}');
        request(); reply('\(acknowledgment)');
        """, root: root)
        let target = root.appendingPathComponent("bad-chunk-ack-\(index).7z")
        await #expect(throws: SevenZipWorkerError.invalidResponse) { try await provider.create(from: [source], at: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-create-") })
    }
}

private func sdkMetadataStat(_ path: URL) throws -> stat {
    var info = stat()
    try #require(lstat(path.path, &info) == 0)
    return info
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKRestoresFileAndDirectoryTimesAndPermissions() async throws {
    let root = try sdkRoot(), source = root.appendingPathComponent("metadata"), nested = source.appendingPathComponent("nested")
    defer {
        for parent in [root.appendingPathComponent("new/metadata"), root.appendingPathComponent("existing/metadata"), source] { _ = chmod(parent.path, 0o700) }
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let executable = nested.appendingPathComponent("tool.sh"), readOnly = nested.appendingPathComponent("read-only")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try Data("read only".utf8).write(to: readOnly)
    for (path, mode, seconds, nanos) in [(executable, 0o4751, Int64(-123_456_789), 987_654_300), (readOnly, 0o440, Int64(1_700_000_123), 456_789_100),
                                       (nested, 0o750, Int64(1_600_000_000), 123_456_700), (source, 0o500, Int64(1_500_000_000), 765_432_100)] {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0); defer { close(fd) }
        var times = [timespec(tv_sec: Int(seconds), tv_nsec: nanos), timespec(tv_sec: Int(seconds), tv_nsec: nanos)]
        try #require(futimens(fd, &times) == 0)
        try #require(fchmod(fd, mode_t(mode)) == 0)
    }
    let provider = try sdkRealProvider(), archive = root.appendingPathComponent("metadata.7z")
    _ = try await provider.create(from: [source], at: archive, compressionLevel: .store)
    let before = try Data(contentsOf: archive)
    for existing in [false, true] {
        let destination = root.appendingPathComponent(existing ? "existing" : "new")
        if existing {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: destination.appendingPathComponent("unrelated"))
            _ = try await provider.extract(archive, to: destination)
            #expect(try Data(contentsOf: destination.appendingPathComponent("unrelated")) == Data("keep".utf8))
        } else { _ = try await provider.extractToNewDirectory(archive, at: destination) }
        for relative in ["", "nested", "nested/tool.sh", "nested/read-only"] {
            let original = try sdkMetadataStat(relative.isEmpty ? source : source.appendingPathComponent(relative))
            let restored = try sdkMetadataStat(relative.isEmpty ? destination.appendingPathComponent("metadata") : destination.appendingPathComponent("metadata/" + relative))
            #expect(restored.st_mode & 0o7777 == original.st_mode & 0o777)
            #expect(restored.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
            #expect(restored.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("metadata/nested/tool.sh")) == Data(contentsOf: executable))
    }
    #expect(try Data(contentsOf: archive) == before)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-") })
}

@Test func sevenZipSDKRestrictiveDirectoryMetadataFinishesAfterChildren() async throws {
    for existing in [false, true] {
        let root = try sdkRoot(), destination = root.appendingPathComponent("result"), locked = destination.appendingPathComponent("locked"), inner = locked.appendingPathComponent("inner")
        defer {
            _ = chmod(locked.path, 0o700); _ = chmod(inner.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let meta: [String: Any] = ["permissions": 0, "modifiedSeconds": 1_600_000_123, "modifiedNanos": 456_789_100]
        var innerMeta = meta; innerMeta["permissions"] = 0o111
        let entries: [[String: Any]] = [
            ["index": 0, "path": "locked", "kind": "directory", "size": 0, "encrypted": false, "metadata": meta],
            ["index": 1, "path": "locked/inner", "kind": "directory", "size": 0, "encrypted": false, "metadata": innerMeta],
            ["index": 2, "path": "locked/inner/tool", "kind": "regularFile", "size": 1, "encrypted": false, "metadata": meta]
        ]
        let entriesJSON = String(data: try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]), encoding: .utf8)!
        let listing = sdkEmptyReply.replacingOccurrences(of: "[]", with: entriesJSON)
        let provider = try sdkMock("""
        request(); reply('\(listing)'); request();
        open(my $out,'>&=3') or die; print $out 'x'; close($out);
        reply('{"version":1,"ok":true,"session":"5BC9424B-FAE6-4A89-9DD5-AC627611EFD3","written":1}');
        request(); reply('{"version":1,"ok":true,"closed":true}');
        """, root: root)
        if existing {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: destination.appendingPathComponent("unrelated"))
            _ = try await provider.extract(root.appendingPathComponent("archive.7z"), to: destination)
            #expect(try Data(contentsOf: destination.appendingPathComponent("unrelated")) == Data("keep".utf8))
        } else { _ = try await provider.extractToNewDirectory(root.appendingPathComponent("archive.7z"), at: destination) }
        var info = try sdkMetadataStat(locked)
        #expect(info.st_mode & 0o777 == 0 && info.st_mtimespec.tv_sec == 1_600_000_123 && info.st_mtimespec.tv_nsec == 456_789_100)
        try #require(chmod(locked.path, 0o700) == 0)
        info = try sdkMetadataStat(inner)
        #expect(info.st_mode & 0o777 == 0o111 && info.st_mtimespec.tv_nsec == 456_789_100)
        try #require(chmod(inner.path, 0o700) == 0)
        let file = inner.appendingPathComponent("tool"); info = try sdkMetadataStat(file)
        #expect(info.st_mode & 0o777 == 0 && info.st_mtimespec.tv_nsec == 456_789_100)
        try #require(chmod(file.path, 0o600) == 0)
        #expect(try Data(contentsOf: file) == Data("x".utf8))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".files-") })
    }
}

@Test func sevenZipSDKRejectsMalformedMetadataBeforeStaging() async throws {
    let cases: [[String: Any]] = [
        ["permissions": 0o7777], ["permissions": true], ["permissions": "755"],
        ["modifiedSeconds": 1], ["modifiedNanos": 100], ["modifiedSeconds": 0, "modifiedNanos": -1],
        ["modifiedSeconds": 0, "modifiedNanos": 1_000_000_000], ["modifiedSeconds": -11_644_473_601, "modifiedNanos": 0]
    ]
    for metadata in cases {
        let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let entry: [String: Any] = ["index": 0, "path": "payload", "kind": "regularFile", "size": 0, "encrypted": false, "metadata": metadata]
        let entriesJSON = String(data: try JSONSerialization.data(withJSONObject: [entry]), encoding: .utf8)!
        let listing = sdkEmptyReply.replacingOccurrences(of: "[]", with: entriesJSON)
        let provider = try sdkMock("request(); reply('\(listing)'); sleep 10;", root: root)
        await #expect(throws: SevenZipWorkerError.invalidResponse) {
            try await provider.extractToNewDirectory(root.appendingPathComponent("archive.7z"), at: root.appendingPathComponent("result"))
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0 == "result" || $0.hasPrefix(".files-") })
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func sevenZipSDKPublishedDirectoryTimeChangeIsPreserved() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
        _ = try await provider.extract(fixture.archive, to: destination) { update in
            guard update.phase == .publishing, update.currentPath == "folder" else { return }
            let fd = open(destination.appendingPathComponent("folder").path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { return }; defer { close(fd) }
            var times = [timespec(tv_sec: 1_234_567_890, tv_nsec: 123_456_700), timespec(tv_sec: 1_234_567_890, tv_nsec: 123_456_700)]
            _ = futimens(fd, &times)
        }
        Issue.record("Externally changed directory time was overwritten")
    } catch SevenZipWorkerError.publicationRecovery(_, let published) {
        #expect(published.map(\.lastPathComponent) == ["folder"])
    }
    let retained = try sdkMetadataStat(destination.appendingPathComponent("folder"))
    #expect(retained.st_mtimespec.tv_sec == 1_234_567_890 && retained.st_mtimespec.tv_nsec == 123_456_700)
    #expect(try Data(contentsOf: destination.appendingPathComponent("folder/large.bin")) == fixture.payloads["folder/large.bin"])
}

@Test func sevenZipSDKUnrepresentableTimeFailsAndPreservesRestrictedRecovery() async throws {
    for existing in [false, true] {
        let root = try sdkRoot(), destination = root.appendingPathComponent("result")
        var preservedRoot: URL?
        defer {
            if let preservedRoot { _ = chmod(preservedRoot.appendingPathComponent("locked/inner").path, 0o700) }
            try? FileManager.default.removeItem(at: root)
        }
        let entries: [[String: Any]] = [
            ["index": 0, "path": "locked", "kind": "directory", "size": 0, "encrypted": false,
             "metadata": ["permissions": 0o700, "modifiedSeconds": 1_833_029_933_770 as Int64, "modifiedNanos": 0]],
            ["index": 1, "path": "locked/inner", "kind": "directory", "size": 0, "encrypted": false, "metadata": ["permissions": 0]],
            ["index": 2, "path": "locked/inner/payload", "kind": "regularFile", "size": 1, "encrypted": false]
        ]
        let entriesJSON = String(data: try JSONSerialization.data(withJSONObject: entries), encoding: .utf8)!
        let listing = sdkEmptyReply.replacingOccurrences(of: "[]", with: entriesJSON)
        let provider = try sdkMock("""
        request(); reply('\(listing)'); request(); open(my $out,'>&=3') or die; print $out 'x'; close($out);
        reply('{"version":1,"ok":true,"session":"5BC9424B-FAE6-4A89-9DD5-AC627611EFD3","written":1}');
        request(); reply('{"version":1,"ok":true,"closed":true}');
        """, root: root)
        if existing {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: destination.appendingPathComponent("unrelated"))
        }
        do {
            if existing { _ = try await provider.extract(root.appendingPathComponent("archive.7z"), to: destination) }
            else { _ = try await provider.extractToNewDirectory(root.appendingPathComponent("archive.7z"), at: destination) }
            Issue.record("Filesystem-clamped time was reported as restored")
        } catch SevenZipWorkerError.publicationRecovery(let staging, let published) {
            #expect(existing && published.map(\.lastPathComponent) == ["locked"])
            #expect(FileManager.default.fileExists(atPath: staging.path))
            preservedRoot = destination
        } catch SevenZipWorkerError.stagingPreserved(let staging) {
            #expect(!existing && !FileManager.default.fileExists(atPath: destination.path))
            preservedRoot = staging
        }
        let retained = try #require(preservedRoot)
        #expect(try sdkMetadataStat(retained.appendingPathComponent("locked/inner")).st_mode & 0o777 == 0)
        try #require(chmod(retained.appendingPathComponent("locked/inner").path, 0o700) == 0)
        #expect(try Data(contentsOf: retained.appendingPathComponent("locked/inner/payload")) == Data("x".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("archive.7z")) == Data("zip".utf8))
        if existing { #expect(try Data(contentsOf: destination.appendingPathComponent("unrelated")) == Data("keep".utf8)) }
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_APP_BUNDLE"), "Requires the signed packaged SDK"))
func sevenZipSDKBundleRejectsResignedExpandedWorkerAuthority() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let profiles: [[String: Any]] = [[:], ["com.apple.security.app-sandbox": true, "com.apple.security.network.client": true],
                                    ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true],
                                    ["com.apple.security.app-sandbox": true, "com.apple.security.files.user-selected.read-write": true]]
    for (index, profile) in profiles.enumerated() {
        let bundle = try sdkBundleCopy(root: root, name: "Authority-\(index).app"), file = root.appendingPathComponent("profile-\(index).plist")
        try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--timestamp=none", "--sign", "-", "--identifier", "org.taro6222.files-for-mac.sevenzip-worker",
                             "--entitlements", file.path, bundle.appendingPathComponent("Contents/Helpers/SevenZipWorker").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!process.isRunning && process.terminationStatus == 0)
        try await sdkResignOuter(bundle, root: root)
        let workerSignature = await CodeSignatureInspector.inspect(bundle.appendingPathComponent("Contents/Helpers/SevenZipWorker"))
        let parentSignature = await CodeSignatureInspector.inspect(bundle)
        #expect(workerSignature.state == .valid && parentSignature.state == .valid)
        // The parent and worker signatures are valid. Policy rejection must happen before
        // the stale manifest hash, proving that a broader valid signature is insufficient.
        await #expect(throws: SevenZipBundleError.invalidSignature) { try await SevenZipArchiveProvider.bundled(in: bundle) }
    }
}

@Test func archiveEditPlanExpandsDirectoriesAndRejectsConflicts() throws {
    let entries: [ArchiveEntryDescriptor] = [
        .init(path: "folder", kind: .directory), .init(path: "folder/a", kind: .regularFile, uncompressedSize: 3),
        .init(path: "folder-more/a", kind: .regularFile, uncompressedSize: 5), .init(path: "opaque-link", kind: .symbolicLink, uncompressedSize: 6)]
    let archive = URL(fileURLWithPath: "/tmp/plan-only.7z")
    let plan = try ArchiveEditPlan(entries: entries, operations: [.rename(path: "folder", newName: "renamed"), .delete(paths: ["folder-more"]), .createDirectory(path: "새 폴더")], archive: archive, check: {})
    #expect(plan.records.map(\.descriptor.path) == ["renamed", "renamed/a", "opaque-link", "새 폴더"])
    #expect(plan.records.map(\.oldIndex) == [0, 1, 3, nil])
    #expect(plan.records[2].descriptor.kind == .symbolicLink)
    #expect(throws: (any Error).self) { try ArchiveEditPlan(entries: entries, operations: [.rename(path: "folder", newName: "../escape")], archive: archive, check: {}) }
    #expect(throws: (any Error).self) { try ArchiveEditPlan(entries: entries, operations: [.createDirectory(path: "folder/a/child")], archive: archive, check: {}) }
    #expect(throws: (any Error).self) { try ArchiveEditPlan(entries: entries, operations: [.createDirectory(path: "opaque-link/child")], archive: archive, check: {}) }
    #expect(throws: (any Error).self) { try ArchiveEditPlan(entries: entries, operations: [.createDirectory(path: "folder")], archive: archive, check: {}) }
    #expect(throws: (any Error).self) { try ArchiveEditPlan(entries: entries, operations: [.delete(paths: ["absent"])], archive: archive, check: {}) }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditCandidateUsesSandboxedClientAndPreservesOriginal() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let provider = try sdkRealProvider(), reference = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    let folder = root.appendingPathComponent("folder"), added = root.appendingPathComponent("added.txt")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: folder.appendingPathComponent("keep.txt"))
    try Data("remove".utf8).write(to: folder.appendingPathComponent("remove.txt"))
    try Data("new".utf8).write(to: added)
    for (index, format) in ["zip", "7z"].enumerated() {
        for encrypted in [false, true] {
            let password: String? = encrypted ? (index == 0 ? "Archive-Edit-371" : "Archive-Edit-371-한글") : nil
            let archive = root.appendingPathComponent("original-\(format)-\(encrypted).\(format)")
            if format == "zip" { _ = try await ZipArchiveProvider().create(from: [folder], at: archive, password: password) }
            else { _ = try await provider.create(from: [folder], at: archive, password: password) }
            let original = try Data(contentsOf: archive), output = root.appendingPathComponent("candidate-\(format)-\(encrypted).\(format)")
            let fd = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }
            defer { Darwin.close(fd) }
            let verified = try await provider.writeVerifiedEditCandidate(archive, candidate: output, outputFD: fd, operations: [
                .rename(path: "folder", newName: "renamed"), .delete(paths: ["renamed/remove.txt"]),
                .add(sources: [added], directory: "renamed"), .createDirectory(path: "empty")], password: password, encryptNewData: encrypted)
            let entries = verified.entries
            #expect(verified.source.sha256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
            #expect(verified.candidate == (try ArchiveEditFileProof.capture(output, check: {})))
            #expect(Set(entries.map(\.path)) == ["renamed", "renamed/keep.txt", "renamed/added.txt", "empty"])
            #expect(entries.filter { $0.kind == .regularFile }.allSatisfy { $0.isEncrypted == encrypted })
            #expect(try Data(contentsOf: archive) == original)
            let destination = root.appendingPathComponent("restore-\(format)-\(encrypted)")
            let process = Process(), input = Pipe()
            process.executableURL = reference; process.arguments = ["x", "-y", "-o" + destination.path, output.path]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
            if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
            try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(15)
            while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
            #expect(process.terminationStatus == 0)
            #expect(try Data(contentsOf: destination.appendingPathComponent("renamed/keep.txt")) == Data("keep".utf8))
            #expect(try Data(contentsOf: destination.appendingPathComponent("renamed/added.txt")) == Data("new".utf8))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("renamed/remove.txt").path))
        }
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditCandidateRejectsLinksAndUnsafePlansWithoutChangingSource() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider()
    let original = try Data(contentsOf: fixture.archive)
    let link = root.appendingPathComponent("linked.7z")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.archive)
    for (index, archive) in [link, fixture.archive].enumerated() {
        let output = root.appendingPathComponent("rejected-\(index).7z")
        let fd = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }; defer { Darwin.close(fd) }
        await #expect(throws: (any Error).self) { try await provider.writeEditCandidate(archive, outputFD: fd, operations: [.createDirectory(path: "../escape")], password: nil, encryptNewData: false) }
        var info = stat(); #expect(fstat(fd, &info) == 0 && info.st_size == 0)
        #expect(try Data(contentsOf: fixture.archive) == original)
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditVerificationRejectsChangedCandidateAndSource() async throws {
    for changeSource in [false, true] {
        let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await sdkFixture(root: root), real = try sdkRealProvider()
        let original = try Data(contentsOf: fixture.archive)
        let unrelated = root.appendingPathComponent("unrelated.txt"), foreign = root.appendingPathComponent("foreign.7z")
        try Data("independent replacement".utf8).write(to: unrelated)
        _ = try await real.create(from: [unrelated], at: foreign)
        let replacement = try Data(contentsOf: foreign), candidate = root.appendingPathComponent("candidate.7z")
        let target = changeSource ? fixture.archive : candidate
        let payload = try JSONSerialization.data(withJSONObject: [real.executable.path, target.path, foreign.path]).base64EncodedString()
        let wrapper = root.appendingPathComponent("wrapper.pl")
        let body = """
        #!/usr/bin/perl
        use strict; use warnings; use JSON::PP; use MIME::Base64;
        my ($worker,$target,$foreign)=@{decode_json(decode_base64('\(payload)'))};
        if (grep { $_ eq '--inspect-output-fd' } @ARGV) {
          open(my $in,'<',$foreign) or die; binmode $in; local $/; my $data=<$in>; close($in);
          open(my $out,'>',$target) or die; binmode $out; print $out $data; close($out) or die;
        }
        exec {$worker} $worker, @ARGV; die;
        """
        try body.write(to: wrapper, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let provider = SevenZipArchiveProvider(executable: wrapper, library: real.library, timeout: 20)
        let fd = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }; defer { Darwin.close(fd) }
        await #expect(throws: (any Error).self) {
            try await provider.writeVerifiedEditCandidate(fixture.archive, candidate: candidate, outputFD: fd,
                operations: [.createDirectory(path: "empty")], password: nil, encryptNewData: false)
        }
        #expect(try Data(contentsOf: fixture.archive) == (changeSource ? replacement : original))
        #expect(try Data(contentsOf: foreign) == replacement)
        if !changeSource { #expect(try Data(contentsOf: candidate) == replacement) }
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditVerificationKeepsUnicodeZIPMetadataAndAddsEncryptedData() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("한글.txt"), archive = root.appendingPathComponent("unicode.zip"), password = "암호-🔑"
    let bytes = Data("Unicode encrypted data".utf8); try bytes.write(to: source)
    _ = try await ZipArchiveProvider().create(from: [source], at: archive, password: password)
    let original = try Data(contentsOf: archive), provider = try sdkRealProvider()
    for (index, secret) in [password, "wrong", password].enumerated() {
        let candidate = root.appendingPathComponent("candidate-\(index).zip")
        let fd = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }; defer { Darwin.close(fd) }
        let operations: [ArchiveEditOperation] = index == 2 ? [.add(sources: [source], directory: "nested")] : [.rename(path: source.lastPathComponent, newName: "renamed.txt")]
        if index != 1 {
            let receipt = try await provider.writeVerifiedEditCandidate(archive, candidate: candidate, outputFD: fd, operations: operations, password: secret, encryptNewData: true)
            #expect(receipt.entries.count == (index == 0 ? 1 : 2) && receipt.entries.allSatisfy(\.isEncrypted))
            let restored = root.appendingPathComponent("restored-\(index)")
            try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
            _ = try await ZipArchiveProvider().extract(candidate, to: restored, password: secret)
            #expect(try Data(contentsOf: restored.appendingPathComponent(index == 0 ? "renamed.txt" : "nested/한글.txt")) == bytes)
        } else {
            let expected = SevenZipWorkerError.worker("password-or-corrupt")
            await #expect(throws: expected) { try await provider.writeVerifiedEditCandidate(archive, candidate: candidate, outputFD: fd, operations: operations, password: secret, encryptNewData: true) }
            var info = stat(); #expect(fstat(fd, &info) == 0 && info.st_size == 0)
        }
        #expect(try Data(contentsOf: archive) == original)
    }
}

private func archiveEditXattr(_ url: URL, key: String, value: Data) throws {
    let status = value.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
private func archiveEditReadXattr(_ url: URL, key: String) throws -> Data {
    let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
    guard length >= 0 else { throw SevenZipWorkerError.ioFailure }
    var data = Data(count: length)
    let count = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
    guard count == length else { throw SevenZipWorkerError.ioFailure }; return data
}

private func archiveEditACLText(_ url: URL) throws -> String {
    guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { throw SevenZipWorkerError.ioFailure }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var length = 0; guard let text = acl_to_text(acl, &length) else { throw SevenZipWorkerError.ioFailure }
    defer { acl_free(text) }; return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), count: length), as: UTF8.self)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditTransactionPublishesBacksUpAndUndoesWithMetadata() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider()
    let journals = root.appendingPathComponent("journals"), original = try Data(contentsOf: fixture.archive)
    let key = "com.files.tests.archive-edit", attr = Data("archive tag".utf8), fork = Data("resource fork".utf8)
    try archiveEditXattr(fixture.archive, key: key, value: attr)
    try archiveEditXattr(fixture.archive, key: "com.apple.ResourceFork", value: fork)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.archive.path)
    let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "everyone allow readattr", fixture.archive.path]
    chmod.standardOutput = FileHandle.nullDevice; chmod.standardError = FileHandle.nullDevice
    try chmod.run(); defer { if chmod.isRunning { kill(chmod.processIdentifier, SIGKILL); chmod.waitUntilExit() } }
    let deadline = ContinuousClock.now + .seconds(5)
    while chmod.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard !chmod.isRunning, chmod.terminationStatus == 0 else { throw SevenZipWorkerError.timedOut }
    #expect(chflags(fixture.archive.path, UInt32(UF_NODUMP)) == 0)
    let acl = try archiveEditACLText(fixture.archive); #expect(acl.contains("readattr"))
    let result = try await provider.edit(fixture.archive, operations: [.rename(path: "folder", newName: "renamed"), .createDirectory(path: "empty")], encryptNewData: false, journalDirectory: journals)
    let edited = try Data(contentsOf: fixture.archive)
    #expect(edited != original)
    #expect(try Data(contentsOf: result.backup) == original)
    #expect(try archiveEditReadXattr(fixture.archive, key: key) == attr)
    #expect(try archiveEditReadXattr(fixture.archive, key: "com.apple.ResourceFork") == fork)
    #expect(try archiveEditACLText(fixture.archive) == acl)
    var flags = stat(); #expect(lstat(fixture.archive.path, &flags) == 0 && flags.st_flags & UInt32(UF_NODUMP) != 0)
    #expect(((try FileManager.default.attributesOfItem(atPath: fixture.archive.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o640)
    #expect(try await provider.entries(at: fixture.archive).contains { $0.path == "renamed/large.bin" })
    if case .committed = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: result.journal, journalDirectory: journals) {} else { Issue.record("Expected committed recovery") }
    if case .undone = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: result.journal, journalDirectory: journals, undo: true) {} else { Issue.record("Expected undo") }
    #expect(try Data(contentsOf: fixture.archive) == original)
    #expect(try archiveEditACLText(fixture.archive) == acl)
    #expect(try Data(contentsOf: result.backup) == edited)
    #expect(try archiveEditReadXattr(fixture.archive, key: key) == attr)
    #expect(try archiveEditReadXattr(fixture.archive, key: "com.apple.ResourceFork") == fork)
    if case .undone = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: result.journal, journalDirectory: journals, undo: true) {} else { Issue.record("Expected idempotent undo") }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditTransactionPreservesExternalChangesAndBrokenRecords() async throws {
    for change in ["archive", "backup", "metadata", "journal", "checksum"] {
        let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), journals = root.appendingPathComponent("journals")
        let result = try await provider.edit(fixture.archive, operations: [.createDirectory(path: "empty")], encryptNewData: false, journalDirectory: journals)
        if change == "archive" { try Data("external archive".utf8).write(to: fixture.archive) }
        if change == "backup" { try Data("external backup".utf8).write(to: result.backup) }
        if change == "metadata" { try archiveEditXattr(fixture.archive, key: "com.files.tests.changed", value: Data([1])) }
        if change == "journal" { try Data("broken".utf8).write(to: result.journal.appendingPathComponent("00000000.json")) }
        if change == "checksum" {
            let last = try #require(FileManager.default.contentsOfDirectory(at: result.journal, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: last)) as? [String: Any])
            envelope["checksum"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(withJSONObject: envelope).write(to: last)
        }
        let archiveBefore = try Data(contentsOf: fixture.archive), backupBefore = try Data(contentsOf: result.backup)
        await #expect(throws: (any Error).self) { try await SevenZipArchiveProvider.recoverArchiveEdit(journal: result.journal, journalDirectory: journals, undo: true) }
        #expect(try Data(contentsOf: fixture.archive) == archiveBefore)
        #expect(try Data(contentsOf: result.backup) == backupBefore)
        if change == "metadata" { #expect(try archiveEditReadXattr(fixture.archive, key: "com.files.tests.changed") == Data([1])) }
    }
}

@Test func archiveEditTransactionSerializesAndPreservesUnpublishedCandidate() throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("archive.7z"), journals = root.appendingPathComponent("journals")
    try Data("source".utf8).write(to: archive)
    var transaction: ArchiveEditTransaction? = try ArchiveEditTransaction(archive: archive, journalDirectory: journals, check: {})
    #expect(throws: ArchiveEditError.busy) { try ArchiveEditTransaction(archive: archive, journalDirectory: journals, check: {}) }
    let journal = try #require(transaction?.journal), candidate = try #require(transaction?.candidate)
    try Data("owned partial".utf8).write(to: candidate)
    transaction = nil
    if case .unpublished = try ArchiveEditTransaction.recover(journal: journal, directory: journals, undo: false, check: {}) {} else { Issue.record("Expected unpublished") }
    #expect(try Data(contentsOf: archive) == Data("source".utf8))
    #expect(try Data(contentsOf: candidate) == Data("owned partial".utf8))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER") && hasIntegrationFixture("FILES_TEST_SPLIT_PROBE"), "Requires native SDK and process-restart probe"))
func archiveEditTransactionRecoversPublishAndUndoProcessInterruptions() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), original = try Data(contentsOf: fixture.archive)
    for mode in ["edit-crash-prepared", "edit-crash-published", "edit-undo-crash-prepared", "edit-undo-crash-published"] {
        let folder = root.appendingPathComponent(mode); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let archive = folder.appendingPathComponent("archive.7z"), journals = folder.appendingPathComponent("journals")
        try FileManager.default.copyItem(at: fixture.archive, to: archive)
        var configuration: [String: Any] = ["mode": mode, "source": archive.path, "journalDirectory": journals.path, "worker": provider.executable.path, "library": provider.library.path]
        if mode.hasPrefix("edit-undo") {
            let saved = try await provider.edit(archive, operations: [.createDirectory(path: "added-by-process")], encryptNewData: false, journalDirectory: journals)
            configuration["journal"] = saved.journal.path
        }
        let crashed = try await sdkRunSplitProbe(configuration, root: folder, name: "interrupt")
        #expect(crashed.0 == 75, "Requested interrupt not reached: \(crashed.1)")
        let registry = journals.appendingPathComponent("archive-edits")
        let journal = try #require(FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil).first { UUID(uuidString: $0.lastPathComponent) != nil })
        let before = try Data(contentsOf: archive)
        let recovered = try await sdkRunSplitProbe(["mode": "edit-recover", "journal": journal.path, "journalDirectory": journals.path], root: folder, name: "recover")
        #expect(recovered.0 == 0, "Recovery failed: \(recovered.1)")
        #expect(try Data(contentsOf: archive) == before)
        if mode == "edit-crash-prepared" {
            #expect(recovered.1.contains("unpublished")); #expect(before == original)
        } else {
            let wasUndone = mode == "edit-undo-crash-published"
            #expect(recovered.1.contains(wasUndone ? "undone" : "committed"))
            #expect((before == original) == wasUndone)
            let undone = try await sdkRunSplitProbe(["mode": "edit-undo", "journal": journal.path, "journalDirectory": journals.path], root: folder, name: "undo")
            #expect(undone.0 == 0 && undone.1.contains("undone"))
            #expect(try Data(contentsOf: archive) == original)
        }
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditTransactionZIPAndEncrypted7zRoundTrip() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old.txt"), added = root.appendingPathComponent("추가.txt")
    try Data("old payload".utf8).write(to: old); try Data("new payload".utf8).write(to: added)
    let provider = try sdkRealProvider(), reference = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    for (index, format) in ["zip", "zip", "7z"].enumerated() {
        let password: String? = index == 0 ? nil : index == 1 ? "Edit-373-ASCII" : "Edit-373-한글"
        let archive = root.appendingPathComponent("archive-\(index).\(format)"), journals = root.appendingPathComponent("journals-\(index)")
        if format == "zip" { _ = try await ZipArchiveProvider().create(from: [old], at: archive, password: password) }
        else { _ = try await provider.create(from: [old], at: archive, password: password) }
        let before = try Data(contentsOf: archive)
        let result = try await provider.edit(archive, operations: [.rename(path: "old.txt", newName: "renamed.txt"), .add(sources: [added], directory: "nested")], password: password, encryptNewData: password != nil, journalDirectory: journals)
        #expect(try Data(contentsOf: result.backup) == before)
        let destination = root.appendingPathComponent("restore-\(index)")
        let process = Process(), input = Pipe()
        process.executableURL = reference; process.arguments = ["x", "-y", "-o" + destination.path, archive.path]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(15)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: destination.appendingPathComponent("renamed.txt")) == Data("old payload".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("nested/추가.txt")) == Data("new payload".utf8))
        _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: result.journal, journalDirectory: journals, undo: true)
        #expect(try Data(contentsOf: archive) == before)
        let journalBytes = try FileManager.default.contentsOfDirectory(at: result.journal, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try Data(contentsOf: $0) }.reduce(Data(), +)
        if let password { #expect(!String(decoding: journalBytes, as: UTF8.self).contains(password)) }
    }
}

private final class ArchiveEditPublicationGate: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    let release = DispatchSemaphore(value: 0)
    var reached: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func apply(_ update: ArchiveProgress) {
        guard update.phase == .publishing, update.currentPath == nil else { return }
        lock.lock(); value = true; lock.unlock(); _ = release.wait(timeout: .now() + 5)
    }
}
@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditTransactionCancellationBeforeSwapPreservesBothFiles() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), original = try Data(contentsOf: fixture.archive)
    let journals = root.appendingPathComponent("journals"), gate = ArchiveEditPublicationGate()
    let task = Task { try await provider.edit(fixture.archive, operations: [.createDirectory(path: "empty")], encryptNewData: false, journalDirectory: journals, progress: gate.apply) }
    defer { gate.release.signal(); task.cancel() }
    let deadline = ContinuousClock.now + .seconds(5)
    while !gate.reached, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(gate.reached); task.cancel(); gate.release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: fixture.archive) == original)
    let journal = try #require(FileManager.default.contentsOfDirectory(at: journals.appendingPathComponent("archive-edits"), includingPropertiesForKeys: nil).first { UUID(uuidString: $0.lastPathComponent) != nil })
    guard case .unpublished(let report) = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: journal, journalDirectory: journals) else { Issue.record("Cancelled edit was published"); return }
    #expect(try Data(contentsOf: report.backup) != original)
    #expect(try await provider.entries(at: report.backup).contains { $0.path == "empty" })
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditUnicodeZIPLongPasswordsAndNormalizationRemainExact() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("old.txt"), added = root.appendingPathComponent("한글-추가.txt")
    let bytes = Data("new Unicode payload".utf8)
    try Data("old Unicode payload".utf8).write(to: source); try bytes.write(to: added)
    let provider = try sdkRealProvider(), reference = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FILES_TEST_SEVENZIP_REFERENCE"]))
    let passwords = ["한글-🔑-374", String(repeating: "한글-🔑", count: 40), "é-374", "e\u{301}-374", "line\nbreak\t암호"]
    for (index, password) in passwords.enumerated() {
        let archive = root.appendingPathComponent("unicode-\(index).zip"), journals = root.appendingPathComponent("journals-\(index)")
        _ = try await ZipArchiveProvider().create(from: [source], at: archive, password: password)
        let original = try Data(contentsOf: archive)
        let saved = try await provider.edit(archive, operations: [.add(sources: [added], directory: "nested"), .rename(path: "old.txt", newName: "renamed.txt")], password: password, encryptNewData: true, journalDirectory: journals)
        #expect(try Data(contentsOf: saved.backup) == original)
        let output = root.appendingPathComponent("restored-\(index)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        _ = try await ZipArchiveProvider().extract(archive, to: output, password: password)
        #expect(try Data(contentsOf: output.appendingPathComponent("nested/한글-추가.txt")) == bytes)
        if index != 1 && index != 4 {
            let destination = root.appendingPathComponent("official-\(index)")
            let process = Process(), input = Pipe()
            process.executableURL = reference; process.arguments = ["x", "-y", "-o" + destination.path, archive.path]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
            try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)); try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(15)
            while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            guard !process.isRunning else { throw SevenZipWorkerError.timedOut }
            #expect(process.terminationStatus == 0)
            #expect(try Data(contentsOf: destination.appendingPathComponent("nested/한글-추가.txt")) == bytes)
        }
        if index == 2 || index == 3 {
            let wrong = index == 2 ? passwords[3] : passwords[2]
            await #expect(throws: SevenZipWorkerError.worker("password-or-corrupt")) {
                try await provider.edit(archive, operations: [.createDirectory(path: "must-not-appear")], password: wrong, encryptNewData: true, journalDirectory: journals)
            }
        }
        _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, undo: true)
        #expect(try Data(contentsOf: archive) == original)
        let eventData = try FileManager.default.contentsOfDirectory(at: saved.journal, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try Data(contentsOf: $0) }.reduce(Data(), +)
        #expect(!String(decoding: eventData, as: UTF8.self).contains(password))
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditPreservesEmptyEncrypted7zHeaderAndRejectsStaleSelection() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"), archive = root.appendingPathComponent("archive.7z"), journals = root.appendingPathComponent("journals")
    try Data("original".utf8).write(to: source)
    let provider = try sdkRealProvider(), password = "빈-압축-🔑"
    _ = try await provider.create(from: [source], at: archive, password: password)
    let original = try Data(contentsOf: archive), version = try ArchiveEditSourceVersion(at: archive)
    let empty = try await provider.edit(archive, operations: [.delete(paths: [source.lastPathComponent])], password: password, encryptNewData: true, journalDirectory: journals, expectedSource: version)
    #expect(try await provider.entries(at: archive, password: password).isEmpty)
    await #expect(throws: SevenZipWorkerError.worker("password-required")) { try await provider.entries(at: archive) }
    let emptyBytes = try Data(contentsOf: archive)
    await #expect(throws: SevenZipWorkerError.worker("source-changed")) {
        try await provider.edit(archive, operations: [.createDirectory(path: "stale")], password: password, encryptNewData: true, journalDirectory: journals, expectedSource: version)
    }
    #expect(try Data(contentsOf: archive) == emptyBytes)
    let added = try await provider.edit(archive, operations: [.add(sources: [source], directory: "")], password: password, encryptNewData: true, journalDirectory: journals, expectedSource: ArchiveEditSourceVersion(at: archive))
    #expect(try await provider.entries(at: archive, password: password).count == 1)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: added.journal, journalDirectory: journals, undo: true)
    #expect(try Data(contentsOf: archive) == emptyBytes)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: empty.journal, journalDirectory: journals, undo: true)
    #expect(try Data(contentsOf: archive) == original)
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditHistoryAndRedoRequireVerifiedFilesAndKeepUnreadableRecords() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), journals = root.appendingPathComponent("journals")
    #expect(try await SevenZipArchiveProvider.archiveEditHistory(journalDirectory: journals).isEmpty)
    let original = try Data(contentsOf: fixture.archive)
    let saved = try await provider.edit(fixture.archive, operations: [.createDirectory(path: "new")], encryptNewData: false, journalDirectory: journals)
    let edited = try Data(contentsOf: fixture.archive)
    let history = try await SevenZipArchiveProvider.archiveEditHistory(journalDirectory: journals)
    #expect(history.count == 1 && history[0].readable && history[0].recordedState == "committed" && history[0].journal == saved.journal)
    let retainedBeforeDiscard = try Data(contentsOf: saved.backup)
    await #expect(throws: ArchiveEditError.invalidState) { try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .discard) }
    #expect(try Data(contentsOf: saved.backup) == retainedBeforeDiscard)
    #expect(try Data(contentsOf: fixture.archive) == edited)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .undo)
    #expect(try Data(contentsOf: fixture.archive) == original)
    if case .committed = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .redo) {} else { Issue.record("Expected redo") }
    #expect(try Data(contentsOf: fixture.archive) == edited)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .redo)
    #expect(try Data(contentsOf: fixture.archive) == edited)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .undo)
    try Data("external original change".utf8).write(to: fixture.archive)
    let backup = try Data(contentsOf: saved.backup)
    await #expect(throws: (any Error).self) { try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .redo) }
    #expect(try Data(contentsOf: fixture.archive) == Data("external original change".utf8))
    #expect(try Data(contentsOf: saved.backup) == backup)
    let invalid = try sevenZipCanonicalDirectory(journals).appendingPathComponent("archive-edits").appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let broken = invalid.appendingPathComponent("00000000.json")
    try Data("broken".utf8).write(to: broken); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: broken.path)
    let updated = try await SevenZipArchiveProvider.archiveEditHistory(journalDirectory: journals)
    #expect(updated.count == 2 && updated.first { $0.journal.path == invalid.path }?.readable == false, "expected: \(invalid.path); actual: \(updated.map { "\($0.journal.path) readable=\($0.readable)" })")
    #expect(updated.first { $0.journal == saved.journal }?.recordedState == "undone")
    #expect(try Data(contentsOf: broken) == Data("broken".utf8))
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER") && hasIntegrationFixture("FILES_TEST_SPLIT_PROBE"), "Requires native SDK and process restart probe"))
func archiveEditRedoRecoversBothProcessInterruptionBoundaries() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await sdkFixture(root: root), provider = try sdkRealProvider(), original = try Data(contentsOf: fixture.archive)
    for mode in ["edit-redo-crash-prepared", "edit-redo-crash-published"] {
        let folder = root.appendingPathComponent(mode); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let archive = folder.appendingPathComponent("archive.7z"), journals = folder.appendingPathComponent("journals")
        try FileManager.default.copyItem(at: fixture.archive, to: archive)
        let saved = try await provider.edit(archive, operations: [.createDirectory(path: "new")], encryptNewData: false, journalDirectory: journals)
        let edited = try Data(contentsOf: archive)
        _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: saved.journal, journalDirectory: journals, action: .undo)
        let stopped = try await sdkRunSplitProbe(["mode": mode, "journal": saved.journal.path, "journalDirectory": journals.path], root: folder, name: "stop")
        #expect(stopped.0 == 75, "Redo boundary not reached: \(stopped.1)")
        let recovered = try await sdkRunSplitProbe(["mode": "edit-recover", "journal": saved.journal.path, "journalDirectory": journals.path], root: folder, name: "recover")
        #expect(recovered.0 == 0 && recovered.1.contains(mode.hasSuffix("prepared") ? "undone" : "committed"))
        #expect(try Data(contentsOf: archive) == (mode.hasSuffix("prepared") ? original : edited))
        let redone = try await sdkRunSplitProbe(["mode": "edit-redo", "journal": saved.journal.path, "journalDirectory": journals.path], root: folder, name: "redo")
        #expect(redone.0 == 0 && redone.1.contains("committed"))
        #expect(try Data(contentsOf: archive) == edited)
    }
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE") && hasIntegrationFixture("FILES_TEST_SEVENZIP_WORKER"), "Requires native SDK and reference"))
func archiveEditEmptyZIPRequiresExplicitEncryptionAndPreservesUndo() async throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("original.txt"), added = root.appendingPathComponent("한글-added.txt")
    let archive = root.appendingPathComponent("empty-policy.zip"), journals = root.appendingPathComponent("journals")
    let bytes = Data("new encrypted ZIP payload".utf8), password = "ZIP-379-한글-🔑"
    try Data("original encrypted ZIP payload".utf8).write(to: source); try bytes.write(to: added)
    _ = try await ZipArchiveProvider().create(from: [source], at: archive, password: "original-password")
    let original = try Data(contentsOf: archive), provider = try sdkRealProvider()
    let removed = try await provider.edit(archive, operations: [.delete(paths: ["original.txt"])], password: "original-password", encryptNewData: true, journalDirectory: journals)
    let empty = try Data(contentsOf: archive)
    #expect(try ZipArchiveProvider().entries(at: archive).isEmpty)
    await #expect(throws: SevenZipWorkerError.worker("password-required")) {
        try await provider.edit(archive, operations: [.add(sources: [added], directory: "")], encryptNewData: true, journalDirectory: journals)
    }
    #expect(try Data(contentsOf: archive) == empty)
    let protected = try await provider.edit(archive, operations: [.add(sources: [added], directory: "")], password: password, encryptNewData: true, journalDirectory: journals)
    let protectedEntries = try ZipArchiveProvider().entries(at: archive)
    #expect(protectedEntries.count == 1 && protectedEntries.first?.isEncrypted == true)
    let restored = root.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
    _ = try await ZipArchiveProvider().extract(archive, to: restored, password: password)
    #expect(try Data(contentsOf: restored.appendingPathComponent(added.lastPathComponent)) == bytes)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: protected.journal, journalDirectory: journals, action: .undo)
    #expect(try Data(contentsOf: archive) == empty)
    let plain = try await provider.edit(archive, operations: [.add(sources: [added], directory: "")], encryptNewData: false, journalDirectory: journals)
    #expect(try ZipArchiveProvider().entries(at: archive).first?.isEncrypted == false)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: plain.journal, journalDirectory: journals, action: .undo)
    #expect(try Data(contentsOf: archive) == empty)
    _ = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: removed.journal, journalDirectory: journals, action: .undo)
    #expect(try Data(contentsOf: archive) == original)
}

@Test func archiveEditDiscardMovesOnlyUnpublishedOutputAndKeepsRecoveryRecord() throws {
    let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("archive.zip"), journals = root.appendingPathComponent("journals"), trash = root.appendingPathComponent("trash")
    try Data("source".utf8).write(to: archive); try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    var edit: ArchiveEditTransaction? = try ArchiveEditTransaction(archive: archive, journalDirectory: journals, check: {})
    let journal = try #require(edit?.journal), candidate = try #require(edit?.candidate)
    try Data("partial output".utf8).write(to: candidate); edit = nil
    let report = try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {})
    #expect(report.backup.path.hasPrefix(try sevenZipCanonicalDirectory(trash).path + "/")); #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(try Data(contentsOf: archive) == Data("source".utf8)); #expect(try Data(contentsOf: report.backup) == Data("partial output".utf8))
    #expect(FileManager.default.fileExists(atPath: journal.path)); #expect(!report.canDiscardUnpublishedOutput)
    #expect(try ArchiveEditTransaction.history(directory: journals, check: {}).first?.recordedState == "discarded")
    guard case .discarded(let inspected) = try ArchiveEditTransaction.recover(journal: journal, directory: journals, undo: false, check: {}) else { Issue.record("Expected discarded"); return }
    #expect(inspected.backup == report.backup)
    #expect(try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {}).backup == report.backup)
    #expect(throws: (any Error).self) { try ArchiveEditTransaction.recover(journal: journal, directory: journals, undo: true, check: {}) }
}

@Test func archiveEditDiscardPreservesForeignFilesSourceChangesAndHardLinks() throws {
    for change in ["replacement", "source", "hardlink", "extra", "legacy"] {
        let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.zip"), journals = root.appendingPathComponent("journals"), trash = root.appendingPathComponent("trash")
        try Data("source".utf8).write(to: archive); try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        var edit: ArchiveEditTransaction? = try ArchiveEditTransaction(archive: archive, journalDirectory: journals, check: {})
        let journal = try #require(edit?.journal), candidate = try #require(edit?.candidate)
        try Data("partial".utf8).write(to: candidate); edit = nil
        if change == "replacement" { try FileManager.default.moveItem(at: candidate, to: root.appendingPathComponent("owned")); try Data("foreign".utf8).write(to: candidate) }
        if change == "source" { try Data("changed".utf8).write(to: archive) }
        if change == "hardlink" { #expect(link(candidate.path, root.appendingPathComponent("link").path) == 0) }
        if change == "extra" { try Data("foreign sibling".utf8).write(to: candidate.deletingLastPathComponent().appendingPathComponent("extra")) }
        if change == "legacy" {
            let event = journal.appendingPathComponent("00000000.json")
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: event)) as? [String: Any])
            let encodedPayload = try #require(envelope["payload"] as? String)
            let bytes = try #require(Data(base64Encoded: encodedPayload))
            var payload = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var record = try #require(payload["record"] as? [String: Any]); record.removeValue(forKey: "initialOutput"); payload["record"] = record
            let updated = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            envelope["payload"] = updated.base64EncodedString(); envelope["checksum"] = SHA256.hash(data: updated).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: event)
            guard case .unpublished(let report) = try ArchiveEditTransaction.recover(journal: journal, directory: journals, undo: false, check: {}) else { Issue.record("Legacy record unreadable"); return }
            #expect(!report.canDiscardUnpublishedOutput)
        }
        let before = try Data(contentsOf: archive), output = try Data(contentsOf: candidate)
        if change == "extra" {
            _ = try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {})
            #expect(try Data(contentsOf: candidate.deletingLastPathComponent().appendingPathComponent("extra")) == Data("foreign sibling".utf8))
        } else {
            #expect(throws: (any Error).self) { try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {}) }
            #expect(try Data(contentsOf: candidate) == output); #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        }
        #expect(try Data(contentsOf: archive) == before)
    }
}

@Test func archiveEditDiscardResumesDurableIntentBeforeAndAfterMoveWithoutOverwrite() throws {
    for boundary in ["before", "after", "collision"] {
        let root = try sdkRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.zip"), journals = root.appendingPathComponent("journals"), trash = root.appendingPathComponent("trash")
        try Data("source".utf8).write(to: archive); try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        var edit: ArchiveEditTransaction? = try ArchiveEditTransaction(archive: archive, journalDirectory: journals, check: {})
        let journal = try #require(edit?.journal), candidate = try #require(edit?.candidate)
        try Data("partial".utf8).write(to: candidate); edit = nil
        let destination = try sevenZipCanonicalDirectory(trash).appendingPathComponent("Files Archive Edit " + journal.lastPathComponent).appendingPathComponent(archive.lastPathComponent)
        #expect(throws: CancellationError.self) {
            try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {
                if FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) { throw CancellationError() }
            })
        }
        #expect(try Data(contentsOf: candidate) == Data("partial".utf8))
        if boundary == "after" { try FileManager.default.moveItem(at: candidate, to: destination) }
        if boundary == "collision" { try Data("foreign".utf8).write(to: destination) }
        if boundary == "collision" {
            #expect(throws: (any Error).self) { try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {}) }
            #expect(try Data(contentsOf: destination) == Data("foreign".utf8)); #expect(try Data(contentsOf: candidate) == Data("partial".utf8))
        } else {
            let report = try ArchiveEditTransaction.discard(journal: journal, directory: journals, trashDirectory: trash, check: {})
            #expect(report.backup == destination); #expect(try Data(contentsOf: destination) == Data("partial".utf8))
        }
        #expect(try Data(contentsOf: archive) == Data("source".utf8))
    }
}
