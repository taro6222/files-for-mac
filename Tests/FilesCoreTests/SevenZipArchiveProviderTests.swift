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
    var reached: Bool { lock.withLock { started } }
    func pause(_ progress: ArchiveProgress) {
        guard progress.phase == .publishing else { return }
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 5)
    }
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
    #expect(provider.library.path == bundle.appendingPathComponent("Contents/Frameworks/7z.so").path)
    let fixture = try await sdkFixture(root: root, password: "QA-349-한글-🔑")
    #expect(try await provider.entries(at: fixture.archive, password: "QA-349-한글-🔑").count == 3)
    let destination = root.appendingPathComponent("resolved-result")
    let report = try await provider.extractToNewDirectory(fixture.archive, at: destination, password: "QA-349-한글-🔑")
    #expect(report.entries == 3)
    for (name, data) in fixture.payloads { #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == data) }
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
