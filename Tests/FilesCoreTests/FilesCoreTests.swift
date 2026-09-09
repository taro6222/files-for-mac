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
    var count = 0
    for try await batch in LocalFileSystem().batches(of: root, showHidden: false) {
        if count == 0 { print("10k first batch (\(batch.count)): \(start.duration(to: clock.now))") }
        count += batch.count
    }
    #expect(count == 10_000)
    print("10k listing duration: \(start.duration(to: clock.now))")
}

@Test func completionHandlesRelativeUnicodeHiddenAndOnlyDirectories() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    for name in ["문서", "Documents", "Downloads", ".hidden"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("Download.txt"))
    let completion = PathCompletion()
    let paths = try await completion.suggestions(for: "Do", relativeTo: root, showHidden: false)
    #expect(paths.count == 2); #expect(paths.allSatisfy { $0.hasSuffix("/") })
    #expect(paths[0].hasSuffix("Documents/"))
    let unicode = try await completion.suggestions(for: "문", relativeTo: root, showHidden: false)
    #expect(unicode.count == 1)
    let hidden = try await completion.suggestions(for: ".h", relativeTo: root, showHidden: false)
    #expect(hidden.count == 1)
    let all = try await completion.suggestions(for: root.path + "/", relativeTo: root, showHidden: false)
    #expect(all.count == 3)
}

@Test func extensionDisplayNeverChangesIdentityOrDotfiles() {
    let url = URL(fileURLWithPath: "/folder/report.tar.gz")
    let file = FileItem(url: url, name: url.lastPathComponent, isDirectory: false)
    #expect(file.displayName(showExtensions: false) == "report.tar")
    #expect(file.id == url.path)
    let hidden = FileItem(url: URL(fileURLWithPath: "/.env.local"), name: ".env.local", isDirectory: false)
    #expect(hidden.displayName(showExtensions: false) == ".env.local")
    let folder = FileItem(url: URL(fileURLWithPath: "/folder.backup"), name: "folder.backup", isDirectory: true)
    #expect(folder.displayName(showExtensions: false) == "folder.backup")
}

@Test @MainActor func sharedPreferencesPersistOrderAndNotifyAllWindows() {
    let suite = "files-preferences-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [a, b])
    var firstWindow = 0, secondWindow = 0
    let token = preferences.observe { firstWindow += 1 }
    preferences.observe { secondWindow += 1 }
    preferences.moveFavorite(b, by: -1)
    #expect(preferences.favorites == [b, a]); #expect(firstWindow == 1 && secondWindow == 1)
    preferences.removeObserver(token)
    preferences.setShowExtensions(false); preferences.toggleSection(.volumes)
    #expect(firstWindow == 1 && secondWindow == 3)
    let restored = BrowserPreferences(defaults: defaults)
    #expect(restored.favorites == [b, a]); #expect(!restored.showExtensions); #expect(!restored.showHomeVolumes)
}

@Test @MainActor func recentLocationsDeduplicateCapAndClearAcrossReload() {
    let suite = "files-recent-tests-\(UUID())", defaults: UserDefaults
    defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    for i in 0..<12 { preferences.recordVisit(URL(fileURLWithPath: "/\(i)")) }
    preferences.recordVisit(URL(fileURLWithPath: "/9"))
    #expect(preferences.recent.count == 10); #expect(preferences.recent.first?.path == "/9")
    preferences.clearRecent()
    #expect(BrowserPreferences(defaults: defaults).recent.isEmpty)
}

@Test func renameRestoresSelectionButHardLinksAndReplacementsDoNotConfuseIt() {
    func item(_ path: String, _ identity: String) -> FileItem {
        FileItem(url: URL(fileURLWithPath: path), name: path, isDirectory: false, identity: identity)
    }
    #expect(SelectionRestoration.restore(["/a"], from: [item("/a", "1")], to: [item("/b", "1")]) == ["/b"])
    #expect(SelectionRestoration.restore(["/a"], from: [item("/a", "1")], to: [item("/a", "2")]).isEmpty)
    #expect(SelectionRestoration.restore(["/a"], from: [item("/a", "1"), item("/b", "1")], to: [item("/c", "1"), item("/b", "1")]).isEmpty)
}

@Test func localIdentitySurvivesRename() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    try Data([1]).write(to: a)
    let before = try await LocalFileSystem().contents(of: root, showHidden: false)
    try FileManager.default.moveItem(at: a, to: b)
    let after = try await LocalFileSystem().contents(of: root, showHidden: false)
    #expect(before[0].identity != nil); #expect(before[0].identity == after[0].identity)
    #expect(SelectionRestoration.restore([a.path], from: before, to: after) == [b.path])
}

@Test func batchesAreShallowAndArriveBeforeCompleteListing() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: nested.appendingPathComponent("must-not-appear"))
    for i in 0..<300 { try Data().write(to: root.appendingPathComponent("file-\(i)")) }
    var sizes: [Int] = []; var names: [String] = []
    for try await batch in LocalFileSystem().batches(of: root, showHidden: false) {
        sizes.append(batch.count); names.append(contentsOf: batch.map(\.name))
    }
    #expect(sizes.first == 128); #expect(sizes.count == 2)
    #expect(names.count == 301); #expect(!names.contains("must-not-appear"))
}

@Test func watcherReportsExternalChildEditAndStops() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file")
    try Data([1]).write(to: file)
    let watcher = try #require(DirectoryWatcher(url: root))
    defer { watcher.stop() }
    let result = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in watcher.events {
                if (try? Data(contentsOf: file).count) == 3 { return true }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(400))
            try? Data([1,2,3]).write(to: file)
            try? await Task.sleep(for: .seconds(4))
            return false
        }
        let first = await group.next() ?? false
        watcher.stop(); group.cancelAll(); return first
    }
    #expect(result)
}

@Test func openingFileAsDirectoryFails() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file"); try Data().write(to: file)
    await #expect(throws: (any Error).self) {
        _ = try await LocalFileSystem().contents(of: file, showHidden: false)
    }
}

private struct ChunkedLoader: DirectoryStreaming {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { [] }
    func batches(of url: URL, showHidden: Bool) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield([FileItem(url: url.appendingPathComponent("first"), name: "first", isDirectory: false)])
                try? await Task.sleep(for: .milliseconds(150))
                continuation.yield([FileItem(url: url.appendingPathComponent("second"), name: "second", isDirectory: false)])
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Test @MainActor func modelPublishesFirstBatchAndCancelsItOnNavigation() async throws {
    let model = BrowserModel(loader: ChunkedLoader())
    model.navigate(URL(fileURLWithPath: "/chunked"))
    for _ in 0..<50 {
        if !model.items.isEmpty { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.isLoading); #expect(model.items.count == 1)
    model.navigate(nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.items.isEmpty); #expect(!model.isLoading)
}

@Test @MainActor func sidebarSectionsPersistCollapseAndOrderWithoutChangingHome() {
    let suite = "files-sidebar-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    preferences.toggleSidebar(.favorites); preferences.moveSidebar(.locations, by: -1)
    let restored = BrowserPreferences(defaults: defaults)
    #expect(restored.sidebarOrder == [.locations, .favorites])
    #expect(restored.collapsedSidebar == [.favorites])
    #expect(restored.showHomeFavorites)
    preferences.toggleSidebar(.favorites)
    #expect(preferences.collapsedSidebar.isEmpty)
}

@Test @MainActor func sidebarOrderRepairsUnknownAndDuplicateSavedValues() {
    let suite = "files-sidebar-invalid-\(UUID())", defaults: UserDefaults
    defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["locations", "obsolete", "locations"], forKey: "sidebarOrder")
    defaults.set(["unknown", "favorites"], forKey: "collapsedSidebar")
    let preferences = BrowserPreferences(defaults: defaults)
    #expect(preferences.sidebarOrder == [.locations, .favorites])
    #expect(preferences.collapsedSidebar == [.favorites])
    preferences.moveSidebar(.locations, by: -1)
    #expect(preferences.sidebarOrder == [.locations, .favorites])
}

@Test func unreadableDirectoryReturnsPermissionError() async throws {
    let root = try fixture()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    await #expect(throws: (any Error).self) {
        _ = try await LocalFileSystem().contents(of: root, showHidden: false)
    }
}

@Test func directoryFailuresClassifyWrappedErrorsWithoutLeakingSystemMessages() {
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
        userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
    #expect(DirectoryFailure(wrapped) == .permissionDenied)
    #expect(DirectoryFailure(POSIXError(.ENOTDIR)) == .notDirectory)
    #expect(DirectoryFailure(CocoaError(.fileReadNoSuchFile)) == .notFound)
    #expect(DirectoryFailure(POSIXError(.ENETUNREACH)) == .unavailable)
    let unknown = DirectoryFailure(NSError(domain: "test", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "private diagnostic /secret/path"]))
    #expect(unknown == .unknown)
    #expect(!unknown.message(korean: true).contains("/secret/path"))
    #expect(unknown.message(korean: true) != unknown.message(korean: false))
}

@Test @MainActor func failureClearsAfterRecoveryAndHomeNavigation() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("recovered")
    let model = BrowserModel()
    func settle() async throws {
        for _ in 0..<100 {
            if !model.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
    }
    model.navigate(missing); try await settle()
    #expect(model.failure == .notFound)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    model.reload(); #expect(model.failure == nil); try await settle()
    #expect(model.failure == nil); #expect(model.error == nil); #expect(model.items.isEmpty)
    let file = root.appendingPathComponent("file.txt"); try Data().write(to: file)
    model.navigate(file); try await settle()
    #expect(model.failure == .notDirectory)
    model.navigate(nil)
    #expect(model.failure == nil); #expect(model.error == nil)
}
