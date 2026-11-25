import Foundation
import Darwin
import Testing
@testable import FilesCore

private struct StoredTagFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stored-tags-\(UUID())")
    var file: URL { root.appendingPathComponent("tag #?.txt") }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("contents".utf8).write(to: file)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func store(_ data: Data) throws {
        let status = data.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
        try #require(status == 0)
    }
    func tags(_ values: [String], format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        try store(PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0))
    }
}

@Test func storedFinderTagsOverrideStaleResourceValuesAndDecodeColors() throws {
    let f = try StoredTagFixture(); defer { f.clean() }
    for format: PropertyListSerialization.PropertyListFormat in [.binary, .xml] {
        try f.tags(["Review\n0", "한글\n6", "Plain", "inner\nnewline\n7"], format: format)
        let actual = StoredFileTags.names(at: f.file, fallback: ["stale"])
        #expect(actual == ["Review", "한글", "Plain", "inner\nnewline"])
        #expect(try Data(contentsOf: f.file) == Data("contents".utf8))
    }
}

@Test func storedFinderTagsPreserveExplicitEmptyAndFallbackForUnknownStorage() throws {
    let f = try StoredTagFixture(); defer { f.clean() }
    #expect(StoredFileTags.names(at: f.file, fallback: ["provider"]) == ["provider"])
    try f.tags([])
    #expect(StoredFileTags.names(at: f.file, fallback: ["stale"]).isEmpty)
    try f.store(Data("invalid plist".utf8))
    #expect(StoredFileTags.names(at: f.file, fallback: ["provider"]) == ["provider"])
    let invalidShape = try PropertyListSerialization.data(fromPropertyList: ["tag": 1], format: .binary, options: 0)
    try f.store(invalidShape)
    #expect(StoredFileTags.names(at: f.file, fallback: ["provider"]) == ["provider"])
}

@Test func storedFinderTagsDoNotFollowSymbolicLinks() throws {
    let f = try StoredTagFixture(); defer { f.clean() }
    try f.tags(["target\n0"])
    let link = f.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
    #expect(StoredFileTags.names(at: link, fallback: ["native-link"]) == ["native-link"])
    #expect(StoredFileTags.names(at: f.file, fallback: []) == ["target"])
}

@Test func storedFinderTagsStayConsistentAcrossListingSearchPropertiesAndEditing() async throws {
    let f = try StoredTagFixture(); defer { f.clean() }
    try f.tags(["Review\n0", "한글\n6"])
    let service = FileTagService()
    let snapshot = try service.snapshot(f.file)
    #expect(snapshot.tags == ["Review", "한글"])
    let listed = try await LocalFileSystem().contents(of: f.root, showHidden: true)
    #expect(listed.first?.tags == snapshot.tags)
    let properties = try await FilePropertiesInspector().inspect(f.file)
    #expect(properties.tags == snapshot.tags)
    var found: [FileItem] = []
    for try await batch in LocalFileSearch().batches(in: f.root, query: FileSearchQuery(text: "", tagText: "Review 한글")) {
        found += batch.items
    }
    #expect(found.map(\.name) == [f.file.lastPathComponent])
    #expect(found.first?.tags == snapshot.tags)
    let cleared = try service.setTags([], at: f.file, expectedIdentity: snapshot.identity)
    #expect(cleared.tags.isEmpty)
    #expect(try await LocalFileSystem().contents(of: f.root, showHidden: true).first?.tags.isEmpty == true)
}

@Test func repeatedStoredTagChangesNeverUseAnEarlierListingCache() async throws {
    let f = try StoredTagFixture(); defer { f.clean() }
    for i in 0..<10 {
        let expected = ["Review-\(i)", "한글"]
        try f.tags(expected.map { $0 + "\n0" })
        let result = try await LocalFileSystem().contents(of: f.root, showHidden: true)
        #expect(result.first?.tags == expected)
    }
}
