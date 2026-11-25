import Foundation
import Darwin
import Testing
@testable import FilesCore

private final class EntryReadGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let ended = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var timely = true
    func block(_ url: URL) {
        lock.withLock { active += 1; peak = max(peak, active) }
        started.signal()
        let result = resume.wait(timeout: .now() + 10)
        lock.withLock { active -= 1; timely = timely && result == .success }
        ended.signal()
    }
    var maximum: Int { lock.withLock { peak } }
    var isBlocked: Bool { lock.withLock { active > 0 } }
    var resumed: Bool { lock.withLock { timely } }
}

@Test func directoryMetadataBatchPreservesAllResourceFieldsAndHiddenPolicy() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("directory-metadata-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    for name in ["file #?.txt", "pct%2F.txt", "NFC-é.txt", "NFD-e\u{301}.txt", ".hidden", "flag-hidden.txt"] {
        try Data(name.utf8).write(to: root.appendingPathComponent(name))
    }
    let hidden = root.appendingPathComponent("flag-hidden.txt")
    try #require(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
    let tagged = root.appendingPathComponent("file #?.txt")
    try (tagged as NSURL).setResourceValue(["Review", "한글"], forKey: .tagNamesKey)
    try fm.createDirectory(at: root.appendingPathComponent("Bundle.app"), withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: tagged)
    try fm.linkItem(at: tagged, to: root.appendingPathComponent("hard-link.txt"))
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey, .tagNamesKey, .isUbiquitousItemKey]
    let files = try await LocalFileSystem().contents(of: root, showHidden: true)
    #expect(files.count == 9)
    #expect(Set(files.map(\.id)).count == files.count)
    for item in files {
        let expected = try URL(fileURLWithPath: item.url.path).resourceValues(forKeys: keys)
        #expect(item.name == item.url.lastPathComponent)
        #expect(item.isDirectory == (expected.isDirectory ?? false))
        #expect(item.isPackage == (expected.isPackage ?? false))
        #expect(item.isSymbolicLink == (expected.isSymbolicLink ?? false))
        #expect(item.isHidden == (expected.isHidden ?? false))
        #expect(item.size == expected.fileSize.map(Int64.init))
        #expect(item.created == expected.creationDate && item.modified == expected.contentModificationDate)
        // A new URL's tag query can transiently return [] even after successful enumeration.
        // Compare assigned tags against fixture truth, not another independently cached query.
        let assignedTags: Set<String> = ["Review", "한글"]
        if item.name == tagged.lastPathComponent || item.name == "hard-link.txt" {
            #expect(Set(item.tags) == assignedTags)
        } else if item.isSymbolicLink {
            // No tags were assigned to the link itself; native resolution may expose its target's tags.
            #expect(item.tags.isEmpty || Set(item.tags) == assignedTags)
        } else { #expect(item.tags.isEmpty) }
        #expect(item.identity == LocalEntryIdentity.read(item.url))
        #expect(item.cloudState == (expected.isUbiquitousItem == true ? .readUbiquitousState(at: item.url) : nil))
    }
    let visible = try await LocalFileSystem().contents(of: root, showHidden: false)
    #expect(!visible.contains { $0.name == ".hidden" || $0.name == "flag-hidden.txt" })
    #expect(visible.count == 7)
}

@Test func directoryMetadataBatchRetainsStreamingBoundariesWithoutLostOrDuplicateEntries() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("directory-batches-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    for index in 0..<2300 { fm.createFile(atPath: root.appendingPathComponent("item-\(index).txt").path, contents: Data()) }
    var counts: [Int] = [], names: [String] = []
    for try await batch in LocalFileSystem().batches(of: root, showHidden: true) {
        counts.append(batch.count); names.append(contentsOf: batch.map(\.name))
    }
    #expect(counts == [128, 1024, 1024, 124])
    #expect(names.count == 2300 && Set(names).count == 2300)
}

@Test func directoryMetadataCancellationReturnsWhileBoundedReadersAreStillBlocked() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("directory-read-cancel-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    for index in 0..<32 { try Data("keep".utf8).write(to: root.appendingPathComponent("item-\(index).txt")) }
    let gate = EntryReadGate()
    defer { for _ in 0..<64 { gate.resume.signal() } }
    let reader = LocalFileSystem(beforeReading: {}, beforeEntryReading: { gate.block($0) }, metadataWorkers: 99)
    let task = Task { try await reader.contents(of: root, showHidden: true) }
    let started = await withCheckedContinuation { continuation in
        DispatchQueue(label: "FilesCore.Tests.EntryReadObserver").async {
            continuation.resume(returning: gate.started.wait(timeout: .now() + 10) == .success)
        }
    }
    #expect(started)
    task.cancel()
    do { #expect(try await task.value.isEmpty) } catch { #expect(error is CancellationError) }
    #expect(gate.isBlocked && gate.maximum <= 4)
    for _ in 0..<64 { gate.resume.signal() }
    let ended = await withCheckedContinuation { continuation in
        DispatchQueue(label: "FilesCore.Tests.EntryReadCompletion").async {
            continuation.resume(returning: gate.ended.wait(timeout: .now() + 10) == .success)
        }
    }
    #expect(ended && gate.resumed)
    #expect(try Data(contentsOf: root.appendingPathComponent("item-0.txt")) == Data("keep".utf8))
}
