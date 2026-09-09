import Foundation
import Testing
@testable import FilesCore

private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("files-tests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func listingHiddenFilesAndMetadata() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    try Data("hello".utf8).write(to: root.appendingPathComponent("한글.txt"))
    try Data().write(to: root.appendingPathComponent(".secret"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    let provider = LocalFileSystem()
    let visible = try await provider.contents(of: root, showHidden: false)
    #expect(visible.count == 2)
    #expect(visible.first { $0.name == "한글.txt" }?.size == 5)
    #expect(visible.first { $0.name == "folder" }?.isBrowsable == true)
    let all = try await provider.contents(of: root, showHidden: true)
    #expect(all.count == 3)
}

@Test func missingDirectoryThrows() async throws {
    await #expect(throws: (any Error).self) {
        _ = try await LocalFileSystem().contents(of: URL(fileURLWithPath: "/tmp/no-such-\(UUID())"), showHidden: false)
    }
}

@Test func hardLinksRemainSeparateEntries() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    try Data([1]).write(to: a); try FileManager.default.linkItem(at: a, to: b)
    let items = try await LocalFileSystem().contents(of: root, showHidden: true)
    #expect(items.count == 2); #expect(Set(items.map(\.id)).count == 2)
}

@Test func historyPreservesSelectionAndDropsForwardBranch() {
    var h = NavigationHistory()
    let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
    h.visit(a); h.save(selection: ["file"], scrollOffset: 400); h.visit(b)
    h.goBack(); #expect(h.current.url == a); #expect(h.current.selection == ["file"])
    #expect(h.current.scrollOffset == 400)
    h.visit(URL(fileURLWithPath: "/c")); #expect(h.forward.isEmpty)
}

@Test func sortingKeepsFoldersFirstAndNaturalNames() {
    let items = [FileItem(url: URL(fileURLWithPath: "/file10"), name: "file10", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/file2"), name: "file2", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/z"), name: "z", isDirectory: true)]
    #expect(SortOrder().sorted(items).map(\.name) == ["z", "file2", "file10"])
    #expect(SortOrder(ascending: false).sorted(items).map(\.name) == ["z", "file10", "file2"])
}

private struct DelayedLoader: DirectoryLoading {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        // Deliberately ignores caller cancellation: model must reject stale generations.
        await Task.detached {
            try? await Task.sleep(for: url.path == "/slow" ? .milliseconds(150) : .milliseconds(5))
        }.value
        return [FileItem(url: url.appendingPathComponent("child"), name: url.lastPathComponent, isDirectory: false)]
    }
}

@Test @MainActor func staleResultsNeverReplaceNewLocation() async throws {
    let model = BrowserModel(loader: DelayedLoader())
    model.navigate(URL(fileURLWithPath: "/slow"))
    try await Task.sleep(for: .milliseconds(10))
    model.navigate(URL(fileURLWithPath: "/fast"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.items.map(\.name) == ["fast"])
    #expect(!model.isLoading)
    model.navigate(nil); #expect(model.items.isEmpty); #expect(model.error == nil)
}

@Test @MainActor func failedLoadIsNotEmptySuccess() async throws {
    let model = BrowserModel()
    model.navigate(URL(fileURLWithPath: "/tmp/no-such-\(UUID())"))
    for _ in 0..<100 {
        if !model.isLoading { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isLoading); #expect(model.error != nil); #expect(model.items.isEmpty)
}

@Test func tenThousandEntries() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<10_000 { try Data().write(to: root.appendingPathComponent("file-\(i).txt")) }
    let clock = ContinuousClock(); let start = clock.now
    let items = try await LocalFileSystem().contents(of: root, showHidden: false)
    #expect(items.count == 10_000)
    print("10k listing duration: \(start.duration(to: clock.now))")
}
