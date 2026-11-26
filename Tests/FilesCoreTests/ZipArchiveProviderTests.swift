import Foundation
import Testing
import Darwin
@testable import FilesCore

private func runSevenZipReference(_ binary: URL, arguments: [String], password: String?, root: URL) async throws -> (status: Int32, text: String) {
    let output = root.appendingPathComponent("reference-\(UUID()).log")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let stream = try FileHandle(forWritingTo: output), input = Pipe(), process = Process()
    defer {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? stream.close(); try? input.fileHandleForWriting.close()
    }
    process.executableURL = binary; process.arguments = arguments; process.currentDirectoryURL = root
    process.standardInput = input; process.standardOutput = stream; process.standardError = stream
    process.environment = ProcessInfo.processInfo.environment.merging(["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]) { _, new in new }
    try process.run()
    if let password { try input.fileHandleForWriting.write(contentsOf: Data((password + "\n" + password + "\n").utf8)) }
    try input.fileHandleForWriting.close()
    let start = ContinuousClock.now
    while process.isRunning && start.duration(to: .now) < .seconds(30) { try await Task.sleep(for: .milliseconds(10)) }
    guard !process.isRunning else { throw CocoaError(.executableRuntimeMismatch, userInfo: [NSLocalizedDescriptionKey: "Reference process exceeded 30 seconds"]) }
    let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
    if let password { #expect(!text.contains(password)); #expect(!arguments.contains { $0.contains(password) }) }
    return (process.terminationStatus, text)
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ArchiveProgress] = []
    func append(_ value: ArchiveProgress) { lock.withLock { values.append(value) } }
    var snapshot: [ArchiveProgress] { lock.withLock { values } }

    func waitForBytes() async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline {
            if snapshot.contains(where: { $0.completedBytes > 0 }) { return true }
            try await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private func makeZip(source: URL, archive: URL) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", "--noextattr", source.path, archive.path]
    let errors = Pipe(); process.standardError = errors; try process.run(); process.waitUntilExit()
    if process.terminationStatus != 0 {
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@Test func zipProviderListsAndSafelyExtractsUnicodeTree() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zip-provider-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true), nested = source.appendingPathComponent("nested", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true), archive = root.appendingPathComponent("fixture.zip")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let payload = Data("한글-é-📁 payload".utf8), file = nested.appendingPathComponent("한글-é-📁.txt")
    try payload.write(to: file); try makeZip(source: source, archive: archive)
    let provider = ZipArchiveProvider(), entries = try provider.entries(at: archive)
    #expect(entries.contains { $0.path == "nested/" && $0.kind == .directory })
    #expect(entries.contains { $0.path == "nested/한글-é-📁.txt" && $0.kind == .regularFile && $0.uncompressedSize == payload.count })
    let report = try await provider.extract(archive, to: destination)
    #expect(report.entries == entries.count); #expect(report.extractedBytes == payload.count)
    #expect(try Data(contentsOf: destination.appendingPathComponent("nested/한글-é-📁.txt")) == payload)
}

@Test func zipProviderRejectsConflictAndLinksBeforePublishing() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-provider-security-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true), destination = root.appendingPathComponent("destination", isDirectory: true)
    let archive = root.appendingPathComponent("fixture.zip"); try fm.createDirectory(at: source, withIntermediateDirectories: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: source.appendingPathComponent("item.txt")); try makeZip(source: source, archive: archive)
    try Data("existing".utf8).write(to: destination.appendingPathComponent("item.txt"))
    await #expect(throws: (any Error).self) { try await ZipArchiveProvider().extract(archive, to: destination) }
    #expect(try String(contentsOf: destination.appendingPathComponent("item.txt"), encoding: .utf8) == "existing")
    #expect((try fm.contentsOfDirectory(atPath: destination.path)).allSatisfy { !$0.hasPrefix(".files-extract-") })

    let linkSource = root.appendingPathComponent("links", isDirectory: true), linkArchive = root.appendingPathComponent("links.zip"), emptyDestination = root.appendingPathComponent("empty", isDirectory: true)
    try fm.createDirectory(at: linkSource, withIntermediateDirectories: true); try fm.createDirectory(at: emptyDestination, withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: linkSource.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
    try makeZip(source: linkSource, archive: linkArchive)
    await #expect(throws: (any Error).self) { try await ZipArchiveProvider().extract(linkArchive, to: emptyDestination) }
    #expect(try fm.contentsOfDirectory(atPath: emptyDestination.path).isEmpty)
}

@Test func zipProviderRejectsCorruptArchiveAndDeclaredLimits() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-provider-limits-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let corrupt = root.appendingPathComponent("corrupt.zip"), source = root.appendingPathComponent("source", isDirectory: true), archive = root.appendingPathComponent("valid.zip"), destination = root.appendingPathComponent("destination", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true); try Data("not zip".utf8).write(to: corrupt)
    #expect(throws: (any Error).self) { try ZipArchiveProvider().entries(at: corrupt) }
    try fm.createDirectory(at: source, withIntermediateDirectories: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 32).write(to: source.appendingPathComponent("large.bin")); try makeZip(source: source, archive: archive)
    await #expect(throws: (any Error).self) {
        try await ZipArchiveProvider().extract(archive, to: destination, limits: .init(maximumTotalBytes: 16, maximumSingleFileBytes: 16))
    }
    #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
}

@Test func zipProviderCreatesReopenableArchiveAndRejectsUnsafeSources() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-provider-create-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("자료-é", isDirectory: true), nested = folder.appendingPathComponent("nested", isDirectory: true)
    let standalone = root.appendingPathComponent("단독.txt"), archive = root.appendingPathComponent("created.zip"), destination = root.appendingPathComponent("destination", isDirectory: true)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("nested payload".utf8).write(to: nested.appendingPathComponent("📁.txt")); try Data("standalone".utf8).write(to: standalone)
    let provider = ZipArchiveProvider(); #expect(try await provider.create(from: [folder, standalone], at: archive) == archive)
    let entries = try provider.entries(at: archive)
    let nestedEntry = try #require(entries.first { $0.path.precomposedStringWithCanonicalMapping == "자료-é/nested/📁.txt" })
    let standaloneEntry = try #require(entries.first { $0.path.precomposedStringWithCanonicalMapping == "단독.txt" })
    _ = try await provider.extract(archive, to: destination)
    #expect(try String(contentsOf: destination.appendingPathComponent(nestedEntry.path), encoding: .utf8) == "nested payload")
    #expect(try String(contentsOf: destination.appendingPathComponent(standaloneEntry.path), encoding: .utf8) == "standalone")

    let existing = root.appendingPathComponent("existing.zip"); try Data("existing".utf8).write(to: existing)
    await #expect(throws: (any Error).self) { try await provider.create(from: [standalone], at: existing) }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
    let link = root.appendingPathComponent("link"); try fm.createSymbolicLink(atPath: link.path, withDestinationPath: standalone.path)
    await #expect(throws: (any Error).self) { try await provider.create(from: [link], at: root.appendingPathComponent("link.zip")) }
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("link.zip").path))
    #expect((try fm.contentsOfDirectory(atPath: root.path)).allSatisfy { !$0.hasPrefix(".files-create-") })
}

@Test func zipProviderReportsMonotonicCreateAndExtractProgress() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-progress-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("payload.bin"), archive = root.appendingPathComponent("payload.zip"), destination = root.appendingPathComponent("destination", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data(repeating: 0x5a, count: 256 * 1024).write(to: source)
    let create = ProgressRecorder(), extract = ProgressRecorder(), provider = ZipArchiveProvider()
    _ = try await provider.create(from: [source], at: archive, progress: create.append)
    _ = try await provider.extract(archive, to: destination, progress: extract.append)
    for events in [create.snapshot, extract.snapshot] {
        #expect(!events.isEmpty); #expect(events.last?.phase == .publishing)
        #expect(events.last?.completedEntries == 1); #expect(events.last?.completedBytes == Int64(256 * 1024))
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.completedEntries <= $1.completedEntries && $0.completedBytes <= $1.completedBytes })
    }
}

@Test func libArchiveProviderBrowsesAndSafelyExtractsOfficialSevenZipAndRarFixtures() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("archive-formats-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let provider = ZipArchiveProvider()
    for (resource, extensionName, expectedPath, expectedBytes) in [
        ("libarchive-empty", "7z", "empty", Data()),
        ("libarchive-noeof", "rar", "test.txt", Data("test text document\r\n".utf8))
    ] {
        let archive = try #require(Bundle.module.url(forResource: resource, withExtension: extensionName, subdirectory: "Fixtures"))
        let entries = try provider.entries(at: archive)
        #expect(entries.contains { $0.path == expectedPath && $0.kind == .regularFile && $0.uncompressedSize == expectedBytes.count })
        let destination = root.appendingPathComponent(extensionName, isDirectory: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let report = try await provider.extract(archive, to: destination)
        #expect(report.entries == entries.count)
        #expect(try Data(contentsOf: destination.appendingPathComponent(expectedPath)) == expectedBytes)
    }
}

@Test func libArchiveProviderCreatesReopenableSevenZipArchive() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sevenzip-create-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("자료", isDirectory: true), file = folder.appendingPathComponent("한글-📁.txt")
    let archive = root.appendingPathComponent("created.7z"), destination = root.appendingPathComponent("destination", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("seven zip payload".utf8).write(to: file)
    let provider = ZipArchiveProvider(); #expect(try await provider.create(from: [folder], at: archive) == archive)
    let entries = try provider.entries(at: archive)
    let payload = try #require(entries.first { $0.path.precomposedStringWithCanonicalMapping == "자료/한글-📁.txt" })
    _ = try await provider.extract(archive, to: destination)
    #expect(try String(contentsOf: destination.appendingPathComponent(payload.path), encoding: .utf8) == "seven zip payload")
    #expect((try fm.contentsOfDirectory(atPath: root.path)).allSatisfy { !$0.hasPrefix(".files-create-") })
}

@Test func archiveCancellationPropagatesToWorkersAndRemovesStagingOutputs() async throws {
    let cleanupDeadline = Duration.seconds(5)
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("archive-cancel-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("large.bin"), archive = root.appendingPathComponent("large.7z")
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data(repeating: 0x5a, count: 16 * 1024 * 1024).write(to: source)
    let provider = ZipArchiveProvider(), createProgress = ProgressRecorder()
    let createTask = Task {
        try await provider.create(from: [source], at: archive) { update in
            createProgress.append(update)
            if update.completedBytes > 0 { Thread.sleep(forTimeInterval: 0.05) }
        }
    }
    defer { createTask.cancel() }
    let creationReportedBytes = try await createProgress.waitForBytes()
    try #require(creationReportedBytes, "Archive creation must report written bytes before cancellation")
    let createCancelStart = ContinuousClock.now; createTask.cancel()
    await #expect(throws: CancellationError.self) { try await createTask.value }
    #expect(createCancelStart.duration(to: .now) < cleanupDeadline)
    #expect(!fm.fileExists(atPath: archive.path))
    #expect((try fm.contentsOfDirectory(atPath: root.path)).allSatisfy { !$0.hasPrefix(".files-create-") })

    _ = try await provider.create(from: [source], at: archive)
    let extractProgress = ProgressRecorder()
    let extractTask = Task {
        try await provider.extract(archive, to: destination) { update in
            extractProgress.append(update)
            if update.completedBytes > 0 { Thread.sleep(forTimeInterval: 0.05) }
        }
    }
    defer { extractTask.cancel() }
    let extractionReportedBytes = try await extractProgress.waitForBytes()
    try #require(extractionReportedBytes, "Archive extraction must report written bytes before cancellation")
    let extractCancelStart = ContinuousClock.now; extractTask.cancel()
    await #expect(throws: CancellationError.self) { try await extractTask.value }
    #expect(extractCancelStart.duration(to: .now) < cleanupDeadline)
    #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
    #expect((try fm.contentsOfDirectory(atPath: destination.path)).allSatisfy { !$0.hasPrefix(".files-extract-") })
}

@Test(arguments: [ArchiveFormat.zip, .sevenZip])
func archiveCompressionLevelsRoundTripAndStoreRemainsUncompressed(format: ArchiveFormat) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("archive-levels-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("한글-é.txt")
    let content = Data(String(repeating: "Compression test 한글 0123456789\n", count: 8192).utf8)
    try content.write(to: source)
    let provider = ZipArchiveProvider()
    var sizes: [ArchiveCompressionLevel: Int] = [:]
    for level in ArchiveCompressionLevel.allCases {
        let archive = root.appendingPathComponent("level-\(level.rawValue).\(format.rawValue)")
        _ = try await provider.create(from: [source], at: archive, compressionLevel: level)
        let bytes = try Data(contentsOf: archive)
        sizes[level] = bytes.count
        if format == .zip {
            #expect(bytes.count > 10)
            #expect(bytes[8] == (level == .store ? 0 : 8) && bytes[9] == 0)
        }
        let destination = root.appendingPathComponent("extract-\(level.rawValue)", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        _ = try await provider.extract(archive, to: destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == content)
        #expect(try Data(contentsOf: source) == content)
    }
    let stored = try #require(sizes[.store]), ultra = try #require(sizes[.ultra])
    #expect(stored >= content.count)
    #expect(ultra < stored / 4)
    #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".files-create-") })
}

@Test(arguments: [ArchiveCompressionLevel.store, .ultra])
func encryptedZIPRoundTripsAndRejectsWrongOrMissingPassword(level: ArchiveCompressionLevel) async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-aes-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("한글-é.txt"), archive = root.appendingPathComponent("encrypted.zip")
    let password = "한글-é-🔑-" + UUID().uuidString
    let payload = Data(String(repeating: "secret payload 0123456789\n", count: 8192).utf8)
    try payload.write(to: source)
    let provider = ZipArchiveProvider()
    _ = try await provider.create(from: [source], at: archive, compressionLevel: level, password: password)
    let descriptors = try provider.entries(at: archive)
    #expect(descriptors.count == 1 && descriptors[0].isEncrypted)
    let bytes = try Data(contentsOf: archive)
    // WinZip AES uses ZIP method 99; filenames remain visible in the header.
    #expect(bytes.count > 30 && bytes[8] == 99 && bytes[9] == 0 && bytes[6] & 1 == 1)
    #expect(bytes.range(of: Data(password.utf8)) == nil)
    for wrong in [nil, "wrong-password"] as [String?] {
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            _ = try await provider.extract(archive, to: destination, password: wrong)
            Issue.record("Encrypted data was extracted without the correct password")
        } catch {
            #expect(!String(describing: error).contains(password))
        }
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try Data(contentsOf: archive) == bytes)
    }
    let destination = root.appendingPathComponent("correct", isDirectory: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    _ = try await provider.extract(archive, to: destination, password: password)
    #expect(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == payload)
    #expect(try Data(contentsOf: source) == payload)
    #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".files-create-") })
}

@Test func encryptedZIPInvalidPasswordUnsupportedFormatAndConflictsPreserveFiles() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-aes-protection-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"), archive = root.appendingPathComponent("encrypted.zip")
    let content = Data("preserved source".utf8); try content.write(to: source)
    let provider = ZipArchiveProvider()
    for invalid in ["", "prefix\0suffix"] {
        await #expect(throws: ZipArchiveError.emptyPassword) {
            _ = try await provider.create(from: [source], at: archive, password: invalid)
        }
        #expect(!fm.fileExists(atPath: archive.path))
    }
    let unsupported = root.appendingPathComponent("unsupported.7z")
    await #expect(throws: ZipArchiveError.unsupportedEncryption) {
        _ = try await provider.create(from: [source], at: unsupported, password: "password")
    }
    #expect(!fm.fileExists(atPath: unsupported.path))
    _ = try await provider.create(from: [source], at: archive, password: "password")
    let originalArchive = try Data(contentsOf: archive)
    do { _ = try await provider.create(from: [source], at: archive, password: "password"); Issue.record("Overwrote existing archive") }
    catch { #expect(try Data(contentsOf: archive) == originalArchive) }
    let destination = root.appendingPathComponent("existing", isDirectory: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let target = destination.appendingPathComponent(source.lastPathComponent), existing = Data("existing target".utf8)
    try existing.write(to: target)
    await #expect(throws: ZipArchiveError.destinationConflict(source.lastPathComponent)) {
        _ = try await provider.extract(archive, to: destination, password: "password")
    }
    #expect(try Data(contentsOf: target) == existing)
    #expect(try Data(contentsOf: source) == content)
    #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".files-create-") })
}

@Test func encryptedZIPRejectsModifiedStoredCiphertextWithoutPublishingPlaintext() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-aes-tamper-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("payload.bin"), archive = root.appendingPathComponent("encrypted.zip")
    let content = Data(repeating: 0x61, count: 128 * 1024); try content.write(to: source)
    let provider = ZipArchiveProvider()
    _ = try await provider.create(from: [source], at: archive, compressionLevel: .store, password: "test-password")
    var bytes = try Data(contentsOf: archive)
    func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    // Local ZIP header + name + extra + AES-256 salt (16) + password verifier (2).
    let ciphertext = 30 + word(26) + word(28) + 18
    try #require(bytes.count > ciphertext + 100)
    bytes[ciphertext + 64] ^= 0x80
    let tampered = root.appendingPathComponent("tampered.zip"); try bytes.write(to: tampered)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
        _ = try await provider.extract(tampered, to: destination, password: "test-password")
        Issue.record("Modified encrypted stored data bypassed authentication")
    } catch {
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
    #expect(try Data(contentsOf: source) == content)
    #expect(try Data(contentsOf: tampered) == bytes)
}

@Test func encryptedZIPCancellationAfterWritingRemovesStagingOutput() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("zip-aes-cancel-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("payload.bin"), archive = root.appendingPathComponent("encrypted.zip")
    let content = Data(repeating: 0x61, count: 1024 * 1024); try content.write(to: source)
    await #expect(throws: CancellationError.self) {
        _ = try await ZipArchiveProvider().create(from: [source], at: archive, compressionLevel: .store, password: "test-password") { update in
            if update.completedBytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    #expect(!fm.fileExists(atPath: archive.path))
    #expect(try Data(contentsOf: source) == content)
    #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".files-create-") })
}

@Test(.enabled(if: hasIntegrationFixture("FILES_TEST_SEVENZIP_REFERENCE"), "Requires the pinned official 7-Zip reference"))
func archiveIndependentSevenZipAESInteroperability() async throws {
    let fm = FileManager.default, env = ProcessInfo.processInfo.environment
    let binary = URL(fileURLWithPath: try #require(env["FILES_TEST_SEVENZIP_REFERENCE"]))
#if arch(arm64)
    let expectedHash = "56cf8eb2fdc6f9c0ac5d7a3cd238505814ac8ed6b88a7c64a7e3256036252c60"
#elseif arch(x86_64)
    let expectedHash = "d54aa0864244abeef158772fbde3dd9bac2b93a54c564a76c4334c5a8bcaf35a"
#else
    let expectedHash = "unsupported architecture"
#endif
    let binaryHash = try await FilePropertiesInspector().sha256(binary)
    try #require(binaryHash == expectedHash)
    let root = fm.temporaryDirectory.appendingPathComponent("archive-independent-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("한글-é-📁.txt")
    let payload = Data(String(repeating: "Independent AES payload 한글 0123456789\n", count: 4096).utf8)
    try payload.write(to: source)
    let provider = ZipArchiveProvider(), ascii = "QA-interop-" + UUID().uuidString
    var checks: [String: Bool] = [:]
    let version = try await runSevenZipReference(binary, arguments: ["i"], password: nil, root: root)
    checks["referenceVersion"] = version.status == 0 && version.text.contains("26.06")
    for (encoding, password) in [("ascii", ascii), ("unicode", "한글-é-🔑-" + ascii)] {
        for level in [ArchiveCompressionLevel.store, .ultra] {
            let key = "coreToReference-\(encoding)-\(level.rawValue)"
            let archive = root.appendingPathComponent(key + ".zip"), output = root.appendingPathComponent(key, isDirectory: true)
            _ = try await provider.create(from: [source], at: archive, compressionLevel: level, password: password)
            let original = try Data(contentsOf: archive)
            let result = try await runSevenZipReference(binary, arguments: ["x", "-y", "-sccUTF-8", "-o" + output.path, archive.path], password: password, root: root)
            checks[key] = result.status == 0 && (try? Data(contentsOf: output.appendingPathComponent(source.lastPathComponent))) == payload
            let wrong = try await runSevenZipReference(binary, arguments: ["t", "-sccUTF-8", archive.path], password: "wrong-password", root: root)
            checks[key + "-wrongPassword"] = wrong.status != 0 && (try? Data(contentsOf: archive)) == original
        }
    }
    for level in [ArchiveCompressionLevel.store, .ultra] {
        let key = "referenceToCore-ascii-\(level.rawValue)"
        let archive = root.appendingPathComponent(key + ".zip"), output = root.appendingPathComponent(key, isDirectory: true)
        let result = try await runSevenZipReference(binary, arguments: ["a", "-tzip", "-mem=AES256", "-p", "-y", "-sccUTF-8", "-mx=\(level.rawValue)", archive.path, source.lastPathComponent], password: ascii, root: root)
        try #require(result.status == 0)
        let entries = try provider.entries(at: archive)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        _ = try await provider.extract(archive, to: output, password: ascii)
        checks[key] = entries.count == 1 && entries[0].isEncrypted && (try? Data(contentsOf: output.appendingPathComponent(source.lastPathComponent))) == payload
        let wrongTarget = root.appendingPathComponent(key + "-wrong", isDirectory: true)
        try fm.createDirectory(at: wrongTarget, withIntermediateDirectories: false)
        var rejected = false
        do { _ = try await provider.extract(archive, to: wrongTarget, password: "wrong-password") } catch { rejected = true }
        checks[key + "-wrongPassword"] = rejected && ((try? fm.contentsOfDirectory(atPath: wrongTarget.path))?.isEmpty == true)
    }
    // The pinned official ZIP writer explicitly rejects non-ASCII passwords; keep that boundary visible.
    let unsupported = root.appendingPathComponent("reference-unicode.zip")
    let unicodeCreate = try await runSevenZipReference(binary, arguments: ["a", "-tzip", "-mem=AES256", "-p", "-y", "-sccUTF-8", unsupported.path, source.lastPathComponent], password: "한글-password", root: root)
    checks["referenceNonASCIIZIPCreationRejected"] = unicodeCreate.status != 0 && !fm.fileExists(atPath: unsupported.path)
    checks["originalSourcePreserved"] = (try? Data(contentsOf: source)) == payload
    #expect(checks.values.allSatisfy { $0 })
    if let report = env["FILES_TEST_SEVENZIP_REPORT"] {
        let result: [String: Any] = ["referenceVersion": "26.06", "referenceBinarySHA256": binaryHash, "passwordTransport": "stdin", "checks": checks]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: .atomic)
    }
}
