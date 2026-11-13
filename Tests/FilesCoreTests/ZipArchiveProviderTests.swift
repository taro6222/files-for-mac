import Foundation
import Testing
@testable import FilesCore

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
