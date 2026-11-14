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
    #expect(visible.first { $0.name == "한글.txt" }?.created != nil)
    #expect(visible.first { $0.name == "folder" }?.isBrowsable == true)
    let all = try await provider.contents(of: root, showHidden: true)
    #expect(all.count == 3)
}

@Test func mountedVolumeCapabilitiesClampUsageAndRestrictEject() {
    let external = MountedVolume(url: URL(fileURLWithPath: "/Volumes/Test"), name: "Test", totalCapacity: 100,
        availableCapacity: 25, formatDescription: "APFS", isInternal: false, isLocal: true, isReadOnly: false,
        isRemovable: true, isEjectable: true)
    #expect(external.usedFraction == 0.75); #expect(external.canRequestEject)
    let internalVolume = MountedVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", totalCapacity: 100,
        availableCapacity: 120, isInternal: true, isRemovable: false, isEjectable: false)
    #expect(internalVolume.usedFraction == 0); #expect(!internalVolume.canRequestEject)
    #expect(MountedVolume(url: URL(fileURLWithPath: "/Volumes/Unknown"), name: "Unknown").usedFraction == nil)
}

@Test func searchSizeUnitsConvertDecimalsAndRejectInvalidBounds() {
    #expect(SearchSizeUnit.bytes.byteCount(42) == 42)
    #expect(SearchSizeUnit.kilobytes.byteCount(1.5) == 1_500)
    #expect(SearchSizeUnit.megabytes.byteCount(2) == 2_000_000)
    #expect(SearchSizeUnit.gigabytes.byteCount(3) == 3_000_000_000)
    #expect(SearchSizeUnit.bytes.byteCount(-1) == nil)
    #expect(SearchSizeUnit.gigabytes.byteCount(.infinity) == nil)
    #expect(SearchSizeUnit.gigabytes.byteCount(Double(Int64.max)) == nil)
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

@Test func closedTabHistoryRestoresMostRecentLocationFirst() {
    var history = ClosedTabHistory()
    let first = TabSnapshot(location: URL(fileURLWithPath: "/first"))
    let home = TabSnapshot(location: nil)
    history.record(first)
    history.record(home)

    #expect(history.canRestore)
    #expect(history.restoreLast() == home)
    #expect(history.restoreLast() == first)
    #expect(history.restoreLast() == nil)
    #expect(!history.canRestore)
}

@Test func closedTabHistoryHonorsCapacity() {
    var history = ClosedTabHistory(capacity: 2)
    history.record(TabSnapshot(location: URL(fileURLWithPath: "/one")))
    history.record(TabSnapshot(location: URL(fileURLWithPath: "/two")))
    history.record(TabSnapshot(location: URL(fileURLWithPath: "/three")))

    #expect(history.snapshots.map(\.location?.path) == ["/two", "/three"])
}

@Test func tabSnapshotRoundTripsNavigationAndViewState() throws {
    let suite = "tab-session-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var history = NavigationHistory()
    history.visit(URL(fileURLWithPath: "/first"))
    history.save(selection: ["/first/item"], scrollOffset: 240)
    history.visit(URL(fileURLWithPath: "/second"))
    history.goBack()
    let snapshot = TabSnapshot(history: history, sortOrder: SortOrder(field: .size, ascending: false),
                               showHidden: true, viewMode: .grid)
    let store = TabSessionStore(defaults: defaults)

    try store.save([snapshot])

    #expect(store.load() == [snapshot])
}

@Test func legacyTabSnapshotDefaultsToDetailsView() throws {
    let snapshot = TabSnapshot(location: URL(fileURLWithPath: "/legacy"), showHidden: true)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    object.removeValue(forKey: "viewMode")

    let restored = try JSONDecoder().decode(TabSnapshot.self,
                                            from: JSONSerialization.data(withJSONObject: object))

    #expect(restored.viewMode == .details)
    #expect(restored.grouping == FileGroupOptions())
    #expect(restored.location?.path == "/legacy")
    #expect(restored.showHidden)
}

@Test @MainActor func tabSnapshotPersistsGroupingAndBrowserModelRestoresIt() throws {
    let grouping = FileGroupOptions(field: .modified, ascending: false, dateUnit: .month)
    let snapshot = TabSnapshot(location: nil, viewMode: .grid, grouping: grouping)
    let decoded = try JSONDecoder().decode(TabSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    let model = BrowserModel()
    model.restore(decoded)
    #expect(model.grouping == grouping)
    model.setGrouping(.init(field: .kind))
    #expect(model.snapshot.grouping == .init(field: .kind))
}

@Test @MainActor func browserViewModeChangesWithoutReloadingLocation() {
    let model = BrowserModel()
    var changes = 0
    model.onChange = { changes += 1 }

    model.setViewMode(.columns)
    model.setViewMode(.columns)

    #expect(model.viewMode == .columns)
    #expect(model.location == nil)
    #expect(changes == 1)
    #expect(model.snapshot.viewMode == .columns)
}

@Test func adaptiveViewPolicyUsesMediaRatioAndCompactWidth() {
    let policy = AdaptiveViewPolicy(sampleLimit: 4, mediaRatioThreshold: 0.6, compactWidth: 560)
    let root = URL(fileURLWithPath: "/adaptive")
    let media = ["a.jpg", "b.png", "c.mov"].map {
        FileItem(url: root.appendingPathComponent($0), name: $0, isDirectory: false)
    }
    let document = FileItem(url: root.appendingPathComponent("notes.txt"), name: "notes.txt", isDirectory: false)
    let folder = FileItem(url: root.appendingPathComponent("folder"), name: "folder", isDirectory: true)

    #expect(policy.resolve(items: media + [document, folder], availableWidth: 900) == .grid)
    #expect(policy.resolve(items: [document, folder], availableWidth: 500) == .list)
    #expect(policy.resolve(items: [document, folder], availableWidth: 900) == .details)
}

@Test func adaptiveViewPolicyUsesBoundedStableSample() {
    let policy = AdaptiveViewPolicy(sampleLimit: 3, mediaRatioThreshold: 0.6)
    let root = URL(fileURLWithPath: "/sample")
    let first = ["1.jpg", "2.png", "3.mov"].map {
        FileItem(url: root.appendingPathComponent($0), name: $0, isDirectory: false)
    }
    let laterDocuments = (0..<20).map {
        FileItem(url: root.appendingPathComponent("\($0).txt"), name: "\($0).txt", isDirectory: false)
    }

    #expect(policy.resolve(items: first + laterDocuments, availableWidth: 900) == .grid)
}

@Test func tabSessionStoreRejectsCorruptStateSafely() throws {
    let suite = "tab-session-corrupt-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not-json".utf8), forKey: "tabSession")

    #expect(TabSessionStore(defaults: defaults).load().isEmpty)
}

@Test func splitTabRoutesUpdatesOnlyToActivePane() {
    let primary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: "/left")))
    var state = SplitTabState(primary: primary)
    let secondaryID = state.split(axis: .horizontal, snapshot: TabSnapshot(location: URL(fileURLWithPath: "/right")))

    state.updateActive(TabSnapshot(location: URL(fileURLWithPath: "/right/child")))

    #expect(state.axis == .horizontal)
    #expect(state.panes[0].tab.location?.path == "/left")
    #expect(state.panes[1].tab.location?.path == "/right/child")
    state.activate(primary.id)
    #expect(state.activePaneID == primary.id)
    #expect(state.activePane.tab.location?.path == "/left")
    #expect(secondaryID != primary.id)
}

@Test func splitTabClampsRatioAndReturnsToSinglePane() {
    let primary = PaneSnapshot(tab: TabSnapshot(location: nil))
    var state = SplitTabState(primary: primary, ratio: 9)
    let secondaryID = state.split(axis: .vertical, snapshot: TabSnapshot(location: nil))
    state.setRatio(-1)

    #expect(state.ratio == 0.2)
    let didClose = state.close(secondaryID)
    #expect(didClose)
    #expect(!state.isSplit)
    #expect(state.activePaneID == primary.id)
    #expect(state.ratio == 0.5)
}

@Test func splitTabStateRoundTripsThroughJSON() throws {
    let primary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: "/a")))
    let secondary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: "/b")))
    let state = SplitTabState(primary: primary, secondary: secondary, axis: .horizontal,
                              ratio: 0.65, activePaneID: secondary.id)

    let restored = try JSONDecoder().decode(SplitTabState.self, from: JSONEncoder().encode(state))

    #expect(restored == state)
    #expect(restored.activePaneID == secondary.id)
}

@Test func workspaceSessionStorePersistsSplitTabsAndRejectsCorruption() throws {
    let suite = "workspace-session-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let primary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: "/primary")))
    let secondary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: "/secondary")))
    let workspace = SplitTabState(primary: primary, secondary: secondary, axis: .horizontal,
                                  ratio: 0.6, activePaneID: secondary.id)
    let store = WorkspaceSessionStore(defaults: defaults)

    try store.save([workspace])
    #expect(store.load() == [workspace])
    defaults.set(Data("broken".utf8), forKey: "workspaceSessionV2")
    #expect(store.load().isEmpty)
}

@Test func fileDropIntentUsesExplicitSafeModifiers() {
    #expect(FileDropIntent.resolve(modifiers: [], sourceAllowsMove: true) == .copy)
    #expect(FileDropIntent.resolve(modifiers: [.option], sourceAllowsMove: true) == .copy)
    #expect(FileDropIntent.resolve(modifiers: [.command], sourceAllowsMove: true) == .move)
    #expect(FileDropIntent.resolve(modifiers: [.command], sourceAllowsMove: false) == .copy)
    #expect(FileDropIntent.resolve(modifiers: [.option, .command], sourceAllowsMove: true) == .copy)
}

@Test func sortingKeepsFoldersFirstAndNaturalNames() {
    let items = [FileItem(url: URL(fileURLWithPath: "/file10"), name: "file10", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/file2"), name: "file2", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/z"), name: "z", isDirectory: true)]
    #expect(SortOrder().sorted(items).map(\.name) == ["z", "file2", "file10"])
    #expect(SortOrder(ascending: false).sorted(items).map(\.name) == ["z", "file10", "file2"])
    #expect(SortOrder(directoryPlacement: .filesFirst).sorted(items).map(\.name) == ["file2", "file10", "z"])
    #expect(SortOrder(foldersFirst: false).sorted(items).map(\.name) == ["file2", "file10", "z"])
    let legacy = Data(#"{"field":"name","ascending":true,"foldersFirst":false}"#.utf8)
    let decoded = try? JSONDecoder().decode(FilesCore.SortOrder.self, from: legacy)
    #expect(decoded?.directoryPlacement == SortDirectoryPlacement.mixed)
}

@Test func finderTagsSortAndGroupWithUntaggedItems() {
    let items = [
        FileItem(url: URL(fileURLWithPath: "/blue"), name: "blue", isDirectory: false, tags: ["Blue"]),
        FileItem(url: URL(fileURLWithPath: "/none"), name: "none", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/amber"), name: "amber", isDirectory: false, tags: ["Amber", "Work"])
    ]
    #expect(SortOrder(field: .tag, directoryPlacement: .mixed).sorted(items).map(\.name) == ["none", "amber", "blue"])
    #expect(FileGrouping.groups(items, options: .init(field: .tag)).map(\.key) == ["0:untagged", "1:amber", "1:blue"])
}

@Test func folderPathsSortAndGroupAcrossSearchResults() {
    let items = [
        FileItem(url: URL(fileURLWithPath: "/z/item"), name: "item", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/a/item"), name: "item", isDirectory: false),
        FileItem(url: URL(fileURLWithPath: "/a/second"), name: "second", isDirectory: false)
    ]
    #expect(SortOrder(field: .path, directoryPlacement: .mixed).sorted(items).map(\.url.path) == ["/a/item", "/a/second", "/z/item"])
    #expect(FileGrouping.groups(items, options: .init(field: .path)).map(\.key) == ["1:/a", "1:/z"])
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

@Test @MainActor func folderNameFilterSurvivesRefreshAndClearsOnNavigation() async throws {
    let model = BrowserModel(loader: DelayedLoader())
    func waitForLoad() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!model.isLoading)
    }

    model.navigate(URL(fileURLWithPath: "/fast"))
    try await waitForLoad()
    model.savePosition(selection: Set(model.items.map(\.id)), scrollOffset: 50)
    model.setNameFilter("missing")
    #expect(model.items.isEmpty)
    #expect(model.history.current.selection.isEmpty)
    model.reload()
    try await waitForLoad()
    #expect(model.items.isEmpty)
    model.setNameFilter("FAST")
    #expect(model.items.map(\.name) == ["fast"])
    model.navigate(URL(fileURLWithPath: "/elsewhere"))
    try await waitForLoad()
    #expect(model.nameFilter.isEmpty)
    #expect(model.items.map(\.name) == ["elsewhere"])
}

@Test @MainActor func shelfRejectsReplacedEntriesAndKeepsItemsSessionOnly() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let first = root.appendingPathComponent("item")
    try Data("original".utf8).write(to: first)
    let suite = "shelf-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    preferences.addToShelf([first, first, root.appendingPathComponent("missing")])
    #expect(preferences.shelfEntries.count == 1)
    let entry = try #require(preferences.shelfEntries.first)
    #expect(entry.isCurrent)
    try fm.moveItem(at: first, to: root.appendingPathComponent("moved"))
    try Data("replacement".utf8).write(to: first)
    #expect(!entry.isCurrent)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).shelfEntries.isEmpty)
    preferences.removeFromShelf([entry])
    #expect(preferences.shelfEntries.isEmpty)
    #expect(try Data(contentsOf: first) == Data("replacement".utf8))
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
    preferences.setShowExtensions(false); preferences.setSection(.volumes, visible: false); preferences.setViewSize(.large)
    #expect(firstWindow == 1 && secondWindow == 4)
    let restored = BrowserPreferences(defaults: defaults)
    #expect(restored.favorites == [b, a]); #expect(!restored.showExtensions); #expect(!restored.showHomeVolumes)
    #expect(restored.viewSize == .large)
    preferences.setSection(.volumes, visible: false); #expect(secondWindow == 4)
}

@Test @MainActor func invalidViewSizePreferenceRepairsToMedium() {
    let suite = "files-view-size-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("enormous", forKey: "viewSize")
    #expect(BrowserPreferences(defaults: defaults).viewSize == .medium)
}

@Test @MainActor func toolbarPreferencesRepairPersistMoveHideAndReset() {
    let suite = "toolbar-preferences-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["favorite", "favorite", "unknown", "path"], forKey: "toolbarOrder")
    defaults.set(["options", "path", "unknown"], forKey: "hiddenToolbarItems")
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.toolbarOrder.prefix(2) == [.favorite, .path])
    #expect(preferences.hiddenToolbarItems == [.options])
    preferences.moveToolbarItem(.favorite, by: 1); preferences.toggleToolbarItem(.hidden)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(restored.toolbarOrder.prefix(2) == [.path, .favorite]); #expect(restored.hiddenToolbarItems.contains(.hidden))
    restored.resetToolbar(); #expect(restored.toolbarOrder == BrowserToolbarItem.allCases); #expect(restored.hiddenToolbarItems.isEmpty)
}

@Test @MainActor func appearancePreferenceRepairsPersistsAndNotifies() {
    let suite = "appearance-preferences-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("unsupported", forKey: "appearance")
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.appearance == .system)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setAppearance(.dark)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).appearance == .dark)
    #expect(notifications == 1)
    preferences.setAppearance(.dark); #expect(notifications == 1)
    preferences.removeObserver(token)
}

@Test @MainActor func continueLastSessionDefaultsOnPersistsAndNotifies() {
    let suite = "session-preferences-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.continueLastSession)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setContinueLastSession(false)
    #expect(!BrowserPreferences(defaults: defaults, initialFavorites: []).continueLastSession)
    #expect(notifications == 1)
    preferences.setContinueLastSession(false); #expect(notifications == 1)
    preferences.removeObserver(token)
}

@Test @MainActor func startupLocationPersistsClearsAndRejectsRelativeSavedValue() {
    let suite = "startup-location-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    preferences.setStartupLocation(URL(fileURLWithPath: "/tmp/startup-folder"))
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).startupLocationPath == "/tmp/startup-folder")
    preferences.setStartupLocation(nil); #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).startupLocationPath == nil)
    defaults.set("relative/folder", forKey: "startupLocationPath")
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).startupLocationPath == nil)
}

@Test @MainActor func sizeUnitDefaultsToBinaryPersistsAndRepairsInvalidValue() {
    let suite = "size-unit-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.sizeUnit == .binary)
    preferences.setSizeUnit(.decimal)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).sizeUnit == .decimal)
    defaults.set("invalid", forKey: "sizeUnit")
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).sizeUnit == .binary)
    #expect(!formatByteCount(1_500, unit: .binary).isEmpty && !formatByteCount(1_500, unit: .decimal).isEmpty)
}

@Test @MainActor func openFoldersInNewTabPersistsAndAvoidsDuplicateNotifications() {
    let suite = "open-folder-tab-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    var changes = 0; let token = preferences.observe { changes += 1 }
    preferences.setOpenFoldersInNewTab(true); preferences.setOpenFoldersInNewTab(true)
    #expect(preferences.openFoldersInNewTab && changes == 1)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).openFoldersInNewTab)
    preferences.removeObserver(token)
}

@Test @MainActor func revealPreviousFolderOnUpDefaultsOnPersistsAndAvoidsDuplicateNotifications() {
    let suite = "reveal-parent-child-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.scrollToPreviousFolderOnUp)
    var changes = 0; let token = preferences.observe { changes += 1 }
    preferences.setScrollToPreviousFolderOnUp(false); preferences.setScrollToPreviousFolderOnUp(false)
    #expect(!preferences.scrollToPreviousFolderOnUp && changes == 1)
    #expect(!BrowserPreferences(defaults: defaults, initialFavorites: []).scrollToPreviousFolderOnUp)
    preferences.removeObserver(token)
}

@Test @MainActor func fileExtensionWarningDefaultsOnPersistsAndAvoidsDuplicateNotifications() {
    let suite = "extension-warning-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.showFileExtensionWarning)
    var changes = 0; let token = preferences.observe { changes += 1 }
    preferences.setShowFileExtensionWarning(false); preferences.setShowFileExtensionWarning(false)
    #expect(!preferences.showFileExtensionWarning && changes == 1)
    #expect(!BrowserPreferences(defaults: defaults, initialFavorites: []).showFileExtensionWarning)
    preferences.removeObserver(token)
    #expect(changesFileExtension(originalName: "report.txt", newName: "report.pdf", isDirectory: false))
    #expect(!changesFileExtension(originalName: "report.TXT", newName: "report.txt", isDirectory: false))
    #expect(!changesFileExtension(originalName: "folder.txt", newName: "folder.pdf", isDirectory: true))
}

@Test @MainActor func toolbarAndStatusBarVisibilityPersistAndNotify() {
    let suite = "chrome-visibility-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.showToolbar && preferences.showStatusBar && preferences.showSidebar)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setShowToolbar(false); preferences.setShowStatusBar(false); preferences.setShowSidebar(false)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!restored.showToolbar && !restored.showStatusBar && !restored.showSidebar)
    #expect(notifications == 3)
    preferences.setShowToolbar(false); preferences.setShowStatusBar(false); preferences.setShowSidebar(false)
    #expect(notifications == 3)
    preferences.removeObserver(token)
}

@Test @MainActor func detailColumnVisibilityDefaultsPersistAndAvoidsDuplicateNotifications() {
    let suite = "column-visibility-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!preferences.showCreatedColumn && preferences.showDateColumn && preferences.showTypeColumn && preferences.showSizeColumn)
    #expect(!preferences.showGitStatusColumn && !preferences.showFileTagColumn && !preferences.showPathColumn)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setShowCreatedColumn(true); preferences.setShowDateColumn(false); preferences.setShowTypeColumn(false)
    preferences.setShowSizeColumn(false); preferences.setShowGitStatusColumn(true)
    preferences.setShowFileTagColumn(true); preferences.setShowPathColumn(true)
    preferences.setShowDateColumn(false); preferences.setShowGitStatusColumn(true)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(restored.showCreatedColumn && !restored.showDateColumn && !restored.showTypeColumn && !restored.showSizeColumn && restored.showGitStatusColumn)
    #expect(restored.showFileTagColumn && restored.showPathColumn)
    #expect(notifications == 7)
    preferences.removeObserver(token)
}

@Test @MainActor func defaultSortDirectoryPlacementPersistsAndAvoidsDuplicateNotifications() {
    let suite = "default-sort-placement-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.defaultSortDirectoryPlacement == .foldersFirst)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setDefaultSortDirectoryPlacement(.mixed)
    preferences.setDefaultSortDirectoryPlacement(.filesFirst)
    preferences.setDefaultSortDirectoryPlacement(.filesFirst)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).defaultSortDirectoryPlacement == .filesFirst)
    #expect(notifications == 2)
    preferences.removeObserver(token)
}

@Test @MainActor func automaticDetailColumnSizingPersistsAndAvoidsDuplicateNotifications() {
    let suite = "automatic-column-sizing-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!preferences.autoSizeColumnsInDetailsLayout)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setAutoSizeColumnsInDetailsLayout(true)
    preferences.setAutoSizeColumnsInDetailsLayout(true)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).autoSizeColumnsInDetailsLayout)
    #expect(notifications == 1)
    preferences.removeObserver(token)
}

@Test @MainActor func startupTabPreferencesPersistRepairAndAvoidDuplicateNotifications() {
    let suite = "startup-tab-preferences-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!preferences.openNewTabOnStartup && preferences.lastSessionSelectedTabIndex == -1)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setOpenNewTabOnStartup(true); preferences.setOpenNewTabOnStartup(true)
    preferences.setLastSessionSelectedTabIndex(3); preferences.setLastSessionSelectedTabIndex(3)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(restored.openNewTabOnStartup && restored.lastSessionSelectedTabIndex == 3)
    preferences.setLastSessionSelectedTabIndex(-9)
    #expect(preferences.lastSessionSelectedTabIndex == -1 && notifications == 3)
    preferences.removeObserver(token)
}

@Test @MainActor func newTabPoliciesPersistAndAvoidDuplicateNotifications() {
    let suite = "new-tab-policy-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!preferences.alwaysOpenDualPaneInNewTab && !preferences.alwaysSwitchToNewlyOpenedTab)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setAlwaysOpenDualPaneInNewTab(true); preferences.setAlwaysSwitchToNewlyOpenedTab(true)
    preferences.setAlwaysOpenDualPaneInNewTab(true); preferences.setAlwaysSwitchToNewlyOpenedTab(true)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(restored.alwaysOpenDualPaneInNewTab && restored.alwaysSwitchToNewlyOpenedTab && notifications == 2)
    preferences.removeObserver(token)
}

@Test @MainActor func appBackgroundPresentationPersistsClampsAndAvoidsDuplicateNotifications() {
    let suite = "app-background-presentation-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.appBackgroundFit == .fill && preferences.appBackgroundOpacity == 1)
    #expect(preferences.appBackgroundHorizontalAlignment == .center && preferences.appBackgroundVerticalAlignment == .center)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setAppBackgroundPresentation(fit: .fit, opacity: 1.5, horizontal: .trailing, vertical: .top)
    preferences.setAppBackgroundPresentation(fit: .fit, opacity: 1, horizontal: .trailing, vertical: .top)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(restored.appBackgroundFit == .fit && restored.appBackgroundOpacity == 1)
    #expect(restored.appBackgroundHorizontalAlignment == .trailing && restored.appBackgroundVerticalAlignment == .top)
    #expect(notifications == 1)
    preferences.removeObserver(token)
}

@Test @MainActor func calculateFolderSizesPreferencePersistsAndAvoidsDuplicateNotifications() {
    let suite = "folder-size-preference-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!preferences.calculateFolderSizes)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setCalculateFolderSizes(true); preferences.setCalculateFolderSizes(true)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).calculateFolderSizes)
    #expect(notifications == 1); preferences.removeObserver(token)
}

@Test @MainActor func showThumbnailsDefaultsOnPersistsAndAvoidsDuplicateNotifications() {
    let suite = "thumbnail-preference-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.showThumbnails)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setShowThumbnails(false); preferences.setShowThumbnails(false)
    #expect(!BrowserPreferences(defaults: defaults, initialFavorites: []).showThumbnails)
    #expect(notifications == 1); preferences.removeObserver(token)
}

@Test @MainActor func doubleClickToGoUpDefaultsOnPersistsAndAvoidsDuplicateNotifications() {
    let suite = "double-click-up-preference-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.doubleClickToGoUp)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setDoubleClickToGoUp(false); preferences.setDoubleClickToGoUp(false)
    #expect(!BrowserPreferences(defaults: defaults, initialFavorites: []).doubleClickToGoUp)
    #expect(notifications == 1); preferences.removeObserver(token)
}

@Test @MainActor func reverseTabScrollDirectionPersistsAndPolicyInverts() {
    let suite = "tab-scroll-preference-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!preferences.reverseTabScrollDirection)
    #expect(TabScrollDirection.resolve(deltaX: -4, deltaY: 1, reversed: false) == .next)
    #expect(TabScrollDirection.resolve(deltaX: -4, deltaY: 1, reversed: true) == .previous)
    #expect(TabScrollDirection.resolve(deltaX: 0.1, deltaY: 0.1, reversed: false) == nil)
    preferences.setReverseTabScrollDirection(true)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).reverseTabScrollDirection)
}

@Test func folderSizeCalculatorCountsNestedRegularFilesAndSkipsSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-size-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("one.bin"))
    try Data(repeating: 2, count: 11).write(to: nested.appendingPathComponent("two.bin"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.bin"), withDestinationURL: nested.appendingPathComponent("two.bin"))
    #expect(try FolderSizeCalculator.size(of: root) == 18)
}

@Test @MainActor func contextMenuVisibilityDefaultsPersistAndAvoidsDuplicateNotifications() {
    let suite = "context-menu-visibility-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.showCompressionOptions && preferences.showOpenTerminal && preferences.showCreateFolderWithSelection && preferences.showPinToSidebar && preferences.showSendToMenu && preferences.showCopyPath)
    #expect(preferences.showOpenInNewTab && preferences.showOpenInNewWindow && preferences.showOpenInNewPane)
    #expect(preferences.showEditTagsMenu && preferences.showCreateShortcut)
    var notifications = 0; let token = preferences.observe { notifications += 1 }
    preferences.setShowCompressionOptions(false); preferences.setShowOpenTerminal(false); preferences.setShowCreateFolderWithSelection(false)
    preferences.setShowPinToSidebar(false)
    preferences.setShowSendToMenu(false)
    preferences.setShowCopyPath(false)
    preferences.setShowOpenInNewTab(false); preferences.setShowOpenInNewWindow(false); preferences.setShowOpenInNewPane(false)
    preferences.setShowEditTagsMenu(false)
    preferences.setShowCreateShortcut(false)
    preferences.setShowCompressionOptions(false); preferences.setShowOpenTerminal(false)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!restored.showCompressionOptions && !restored.showOpenTerminal && !restored.showCreateFolderWithSelection && !restored.showPinToSidebar && !restored.showSendToMenu && !restored.showCopyPath)
    #expect(!restored.showOpenInNewTab && !restored.showOpenInNewWindow && !restored.showOpenInNewPane)
    #expect(!restored.showEditTagsMenu && !restored.showCreateShortcut)
    #expect(notifications == 11)
    preferences.removeObserver(token)
}

@Test func copiedPathFormattingPreservesUnicodeAndEscapesQuotedText() {
    let urls = [URL(fileURLWithPath: "/tmp/한글 folder"), URL(fileURLWithPath: "/tmp/a\"b\\c")]
    #expect(formatCopiedPaths(urls, quoted: false) == "/tmp/한글 folder\n/tmp/a\"b\\c")
    #expect(formatCopiedPaths(urls, quoted: true) == "\"/tmp/한글 folder\"\n\"/tmp/a\\\"b\\\\c\"")
}

@Test func codeSignatureMetadataParserExtractsStableFields() {
    let parsed = CodeSignatureInspector.parse("""
    Executable=/Applications/Example.app/Contents/MacOS/Example
    Identifier=org.example.app
    Format=app bundle with Mach-O thin (arm64)
    Authority=Developer ID Application: Example
    Authority=Developer ID Certification Authority
    TeamIdentifier=ABCDE12345
    """)
    #expect(parsed.identifier == "org.example.app")
    #expect(parsed.teamIdentifier == "ABCDE12345")
    #expect(parsed.format == "app bundle with Mach-O thin (arm64)")
    #expect(parsed.authorities == ["Developer ID Application: Example", "Developer ID Certification Authority"])
}

@Test @MainActor func developerApplicationPreferencePersistsAndClears() {
    let suite = "developer-app-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    let app = URL(fileURLWithPath: "/Applications/Example.app")
    preferences.setDeveloperApplication(app)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).developerApplicationPath == app.path)
    preferences.setDeveloperApplication(nil)
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).developerApplicationPath == nil)
}

@Test @MainActor func browserPreferencesArchiveRoundTripsAndRejectsInvalidWithoutMutation() throws {
    let firstSuite = "preferences-export-first-\(UUID())", secondSuite = "preferences-export-second-\(UUID())"
    let firstDefaults = UserDefaults(suiteName: firstSuite)!, secondDefaults = UserDefaults(suiteName: secondSuite)!
    defer { firstDefaults.removePersistentDomain(forName: firstSuite); secondDefaults.removePersistentDomain(forName: secondSuite) }
    let source = BrowserPreferences(defaults: firstDefaults, initialFavorites: [URL(fileURLWithPath: "/source")])
    source.setShowHidden(true); source.setShowToolbar(false); source.setShowSidebar(false); source.setAppearance(.dark); source.setDeveloperApplication(URL(fileURLWithPath: "/Applications/Editor.app")); source.setAppBackground(URL(fileURLWithPath: "/Library/Application Support/FilesMac/background-image"))
    source.setStartupLocation(URL(fileURLWithPath: "/startup"))
    source.setSizeUnit(.decimal)
    source.setOpenFoldersInNewTab(true)
    source.setScrollToPreviousFolderOnUp(false)
    source.setShowFileExtensionWarning(false)
    source.setDefaultSortDirectoryPlacement(.filesFirst)
    source.setAutoSizeColumnsInDetailsLayout(true)
    source.setOpenNewTabOnStartup(true); source.setLastSessionSelectedTabIndex(2)
    source.setAlwaysOpenDualPaneInNewTab(true); source.setAlwaysSwitchToNewlyOpenedTab(true)
    source.setAppBackgroundPresentation(fit: .fit, opacity: 0.4, horizontal: .trailing, vertical: .top)
    source.setCalculateFolderSizes(true)
    source.setShowThumbnails(false)
    source.setDoubleClickToGoUp(false)
    source.setReverseTabScrollDirection(true)
    source.setShowFilterHeader(true)
    source.setShowShelfPane(true)
    source.setShowInfoPane(true)
    source.setInfoPaneTab(.preview)
    let sharedLayout = SharedFolderLayout(mode: .list, size: .large, sort: SortOrder(field: .size, ascending: false),
                                         grouping: FileGroupOptions(field: .kind))
    source.setFolderLayoutSynchronization(true, initial: sharedLayout)
    source.setShowGitCommitDateColumn(true)
    source.setShowGitCommitMessageColumn(true)
    source.setShowGitCommitAuthorColumn(true)
    source.setShowGitCommitSHAColumn(true)
    source.setShowShelfToggle(true)
    source.setShowCreatedColumn(true); source.setShowDateColumn(false); source.setShowTypeColumn(false); source.setShowSizeColumn(false); source.setShowGitStatusColumn(true)
    source.setShowFileTagColumn(true); source.setShowPathColumn(true)
    source.setShowCompressionOptions(false); source.setShowOpenTerminal(false); source.setShowCreateFolderWithSelection(false)
    source.setShowPinToSidebar(false)
    source.setShowSendToMenu(false)
    source.setShowCopyPath(false)
    source.setShowOpenInNewTab(false); source.setShowOpenInNewWindow(false); source.setShowOpenInNewPane(false)
    source.setShowEditTagsMenu(false)
    source.setFolderViewPreference(FolderViewPreference(mode: .grid, size: .large), for: URL(fileURLWithPath: "/folder"))
    let data = try source.exportData(), destination = BrowserPreferences(defaults: secondDefaults, initialFavorites: [])
    try destination.importData(data)
    #expect(destination.showHidden && !destination.showToolbar && !destination.showSidebar && destination.appearance == .dark)
    #expect(destination.developerApplicationPath == "/Applications/Editor.app")
    #expect(destination.appBackgroundPath == "/Library/Application Support/FilesMac/background-image")
    #expect(destination.startupLocationPath == "/startup")
    #expect(destination.sizeUnit == .decimal)
    #expect(destination.openFoldersInNewTab)
    #expect(!destination.scrollToPreviousFolderOnUp)
    #expect(!destination.showFileExtensionWarning)
    #expect(destination.defaultSortDirectoryPlacement == .filesFirst)
    #expect(destination.autoSizeColumnsInDetailsLayout)
    #expect(destination.openNewTabOnStartup && destination.lastSessionSelectedTabIndex == 2)
    #expect(destination.alwaysOpenDualPaneInNewTab && destination.alwaysSwitchToNewlyOpenedTab)
    #expect(destination.appBackgroundFit == .fit && destination.appBackgroundOpacity == 0.4)
    #expect(destination.appBackgroundHorizontalAlignment == .trailing && destination.appBackgroundVerticalAlignment == .top)
    #expect(destination.calculateFolderSizes)
    #expect(!destination.showThumbnails)
    #expect(!destination.doubleClickToGoUp)
    #expect(destination.reverseTabScrollDirection)
    #expect(destination.showFilterHeader)
    #expect(destination.showShelfPane && destination.showShelfToggle)
    #expect(destination.showInfoPane && destination.infoPaneTab == .preview)
    #expect(destination.synchronizedFolderLayout == sharedLayout)
    #expect(BrowserPreferences(defaults: secondDefaults, initialFavorites: []).synchronizedFolderLayout == sharedLayout)
    #expect(destination.showGitCommitDateColumn && destination.showGitCommitMessageColumn
        && destination.showGitCommitAuthorColumn && destination.showGitCommitSHAColumn)
    #expect(destination.showCreatedColumn && !destination.showDateColumn && !destination.showTypeColumn && !destination.showSizeColumn && destination.showGitStatusColumn)
    #expect(destination.showFileTagColumn && destination.showPathColumn)
    #expect(!destination.showCompressionOptions && !destination.showOpenTerminal && !destination.showCreateFolderWithSelection)
    #expect(!destination.showPinToSidebar)
    #expect(!destination.showSendToMenu)
    #expect(!destination.showCopyPath)
    #expect(!destination.showOpenInNewTab && !destination.showOpenInNewWindow && !destination.showOpenInNewPane)
    #expect(!destination.showEditTagsMenu)
    #expect(destination.folderViewPreference(for: URL(fileURLWithPath: "/folder")) == FolderViewPreference(mode: .grid, size: .large))
    let before = try destination.exportData()
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object["viewSize"] = "huge"
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: BrowserPreferencesArchiveError.invalidValue) { try destination.importData(invalid) }
    #expect(try destination.exportData() == before)
    var relativeBackground = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); relativeBackground["appBackgroundPath"] = "relative/background.png"
    let invalidBackground = try JSONSerialization.data(withJSONObject: relativeBackground)
    #expect(throws: BrowserPreferencesArchiveError.invalidValue) { try destination.importData(invalidBackground) }
    #expect(try destination.exportData() == before)
}

@Test @MainActor func folderViewPreferencesPersistStandardizeRemoveAndRecoverCorruption() {
    let suite = "folder-view-preferences-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    let folder = URL(fileURLWithPath: "/tmp/parent/../folder")
    preferences.setFolderViewPreference(FolderViewPreference(mode: .grid, size: .large), for: folder)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(restored.folderViewPreference(for: URL(fileURLWithPath: "/tmp/folder")) == FolderViewPreference(mode: .grid, size: .large))
    restored.resetFolderViewPreferences(); #expect(restored.folderViewPreferences.isEmpty)
    #expect(defaults.data(forKey: "folderViewPreferences") == nil)
    defaults.set(Data("invalid".utf8), forKey: "folderViewPreferences")
    #expect(BrowserPreferences(defaults: defaults, initialFavorites: []).folderViewPreferences.isEmpty)
}

@Test func localSearchScopesFiltersUnicodeAndHiddenItems() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let nested = root.appendingPathComponent("Nested", isDirectory: true); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let report = root.appendingPathComponent("Résumé report.txt")
    try Data("report-data".utf8).write(to: report)
    try Data().write(to: nested.appendingPathComponent("resume notes.md"))
    try Data().write(to: root.appendingPathComponent(".resume-hidden"))
    func results(_ query: FileSearchQuery) async throws -> [FileItem] {
        var items: [FileItem] = []
        for try await batch in LocalFileSearch().batches(in: root, query: query) { items += batch.items }
        return items
    }
    #expect(try await results(FileSearchQuery(text: "resume", scope: .currentFolder)).map(\.name) == ["Résumé report.txt"])
    #expect(Set(try await results(FileSearchQuery(text: "resume", kind: .files)).map(\.name)) == ["Résumé report.txt", "resume notes.md"])
    #expect(Set(try await results(FileSearchQuery(text: "resume", kind: .files, showHidden: true)).map(\.name)).contains(".resume-hidden"))
    #expect(try await results(FileSearchQuery(text: "nested", kind: .folders)).map(\.name) == ["Nested"])
    let tagSnapshot = try FileTagService().snapshot(report)
    _ = try FileTagService().setTags(["Important", "검토"], at: report, expectedIdentity: tagSnapshot.identity)
    let boundary = Date(timeIntervalSinceNow: -60); try FileManager.default.setAttributes([.modificationDate: boundary], ofItemAtPath: report.path)
    #expect(try await results(FileSearchQuery(text: "report", tagText: "important 검토", minimumSize: 5, maximumSize: 20,
                                              modifiedAfter: boundary, modifiedBefore: boundary)).map(\.name) == ["Résumé report.txt"])
    #expect(try await results(FileSearchQuery(text: "report", tagText: "missing")).isEmpty)
    #expect(try await results(FileSearchQuery(text: "report", minimumSize: 20)).isEmpty)
}

private struct DelayedSearch: FileSearching {
    func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: query.text == "old" ? .milliseconds(120) : .milliseconds(10))
                continuation.yield(FileSearchBatch(items: [FileItem(url: root.appendingPathComponent(query.text), name: query.text, isDirectory: false)], skippedLocations: query.text == "new" ? 2 : 0))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct FixedSearch: FileSearching {
    let name: String
    func batches(in root: URL, query: FileSearchQuery) -> AsyncThrowingStream<FileSearchBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(FileSearchBatch(items: [FileItem(url: root.appendingPathComponent(name), name: name, isDirectory: false)], skippedLocations: 0))
            continuation.finish()
        }
    }
}

@Test func fileGroupingPartitionsDeterministicallyAndPreservesItemOrder() {
    let calendar = Calendar(identifier: .gregorian)
    let date = { (year: Int, month: Int, day: Int) in calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    let root = URL(fileURLWithPath: "/tmp/grouping", isDirectory: true)
    let items = [
        FileItem(url: root.appendingPathComponent("Beta.txt"), name: "Beta.txt", isDirectory: false, size: 2_000_000, created: date(2023, 4, 5), modified: date(2025, 2, 3), kind: "Text"),
        FileItem(url: root.appendingPathComponent("alpha.txt"), name: "alpha.txt", isDirectory: false, size: 0, created: date(2022, 3, 4), modified: date(2024, 1, 2), kind: "Text"),
        FileItem(url: root.appendingPathComponent("Archive"), name: "Archive", isDirectory: true, kind: "Folder"),
        FileItem(url: root.appendingPathComponent("!note"), name: "!note", isDirectory: false, size: 2_000_000_000, kind: "")
    ]
    let names = FileGrouping.groups(items, options: .init(field: .name))
    #expect(names.map(\.key) == ["1:A", "1:B", "2:#"])
    #expect(names[0].items.map(\.name) == ["alpha.txt", "Archive"])
    #expect(FileGrouping.groups(items, options: .init(field: .name, ascending: false)).map(\.key) == ["2:#", "1:B", "1:A"])
    #expect(FileGrouping.groups(items, options: .init(field: .modified, dateUnit: .month), calendar: calendar).map(\.key) == ["0:unknown", "1:2024-01-00", "1:2025-02-00"])
    #expect(FileGrouping.groups(items, options: .init(field: .created, dateUnit: .day), calendar: calendar).map(\.key) == ["0:unknown", "1:2022-03-04", "1:2023-04-05"])
    #expect(FileGrouping.groups(items, options: .init(field: .size)).map(\.key) == ["0:folder", "2:empty", "4:medium", "5:large"])
    #expect(FileGrouping.groups(items, options: .init(field: .kind)).map(\.key) == ["0:unknown", "1:folder", "1:text"])
    #expect(FileGrouping.groups([], options: .init()).isEmpty)
}

@Test func searchRouterSeparatesEnumerationAndSpotlightAdapters() async throws {
    let root = URL(fileURLWithPath: "/tmp"), router = SearchRouter(local: FixedSearch(name: "local"), spotlight: FixedSearch(name: "spotlight"))
    func names(_ method: SearchMethod) async throws -> [String] {
        var names: [String] = []
        for try await batch in router.batches(in: root, query: FileSearchQuery(text: "query", method: method)) { names += batch.items.map(\.name) }
        return names
    }
    #expect(try await names(.fileName) == ["local"])
    #expect(try await names(.spotlightContent) == ["spotlight"])
}

@Test @MainActor func searchModelDiscardsStaleResultsAndReportsCancellation() async throws {
    let model = SearchModel(searcher: DelayedSearch()), root = URL(fileURLWithPath: "/tmp")
    model.search(in: root, query: FileSearchQuery(text: "old"))
    model.search(in: root, query: FileSearchQuery(text: "new"))
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.results.map(\.name) == ["new"]); #expect(model.skippedLocations == 2); #expect(!model.isSearching)
    model.search(in: root, query: FileSearchQuery(text: "old")); model.cancel()
    #expect(model.wasCancelled); #expect(!model.isSearching); #expect(model.results.isEmpty)
}

@Test func filePropertiesAndStreamingSHA256MatchKnownVector() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("vector.txt"); try Data("abc".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let inspector = FilePropertiesInspector(), properties = try await inspector.inspect(file)
    #expect(properties.url == file.standardizedFileURL); #expect(!properties.isDirectory)
    #expect(properties.logicalSize == 3); #expect(properties.posixPermissions == 0o640)
    #expect(properties.typeIdentifier != nil); #expect(properties.modified != nil)
    let digest = try await inspector.sha256(file)
    #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    await #expect(throws: FileHashError.directoryUnsupported) { try await inspector.sha256(root) }
}

@Test func finderTagsRoundTripValidateAndRejectReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("tagged.txt"); try Data("one".utf8).write(to: file)
    let service = FileTagService(), initial = try service.snapshot(file)
    let written = try service.setTags([" Work ", "work", "검토"], at: file, expectedIdentity: initial.identity)
    #expect(written.tags == ["Work", "검토"]); #expect(try service.snapshot(file).tags == written.tags)
    let cleared = try service.setTags([], at: file, expectedIdentity: written.identity)
    #expect(cleared.tags.isEmpty)
    let restored = try service.setTags(["Work", "검토"], at: file, expectedIdentity: cleared.identity)
    #expect(throws: FileTagError.invalidName) { try service.setTags(["bad\ntag"], at: file, expectedIdentity: written.identity) }
    try FileManager.default.removeItem(at: file); try Data("two".utf8).write(to: file)
    #expect(throws: FileTagError.changedIdentity) { try service.setTags(["new"], at: file, expectedIdentity: restored.identity) }
}

@Test func shortcutPreferencesPersistValidateCollisionsAndReset() throws {
    let suite = "shortcut-preferences-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let factory = ["open": KeyboardShortcut(key: "o", modifiers: .command),
                   "refresh": KeyboardShortcut(key: "r", modifiers: .command)]
    let preferences = ShortcutPreferences(defaults: defaults, factory: factory, knownCommandIDs: Set(factory.keys).union(["rename"]))
    try preferences.set(KeyboardShortcut(key: "K", modifiers: [.command, .shift]), for: "open")
    #expect(preferences.shortcut(for: "open") == KeyboardShortcut(key: "k", modifiers: [.command, .shift]))
    #expect(ShortcutPreferences(defaults: defaults, factory: factory).shortcut(for: "open") == KeyboardShortcut(key: "k", modifiers: [.command, .shift]))
    #expect(throws: ShortcutValidationError.conflict(commandID: "open")) {
        try preferences.set(KeyboardShortcut(key: "k", modifiers: [.command, .shift]), for: "refresh")
    }
    #expect(throws: ShortcutValidationError.modifierRequired) {
        try preferences.set(KeyboardShortcut(key: "x", modifiers: []), for: "refresh")
    }
    #expect(throws: ShortcutValidationError.systemReserved) {
        try preferences.set(KeyboardShortcut(key: "space", modifiers: .command), for: "refresh")
    }
    try preferences.set(KeyboardShortcut(key: "e", modifiers: [.command, .option]), for: "rename")
    #expect(preferences.shortcut(for: "rename") != nil)
    preferences.resetAll(); #expect(preferences.effective == factory); #expect(preferences.shortcut(for: "rename") == nil)
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

@Test @MainActor func homeWidgetExpansionPersistsIndependentlyFromVisibility() {
    let suite = "files-home-expansion-\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(preferences.homeFavoritesExpanded && preferences.homeVolumesExpanded && preferences.homeRecentExpanded)
    var changes = 0; let token = preferences.observe { changes += 1 }
    preferences.setHomeSectionExpanded(.favorites, expanded: false)
    preferences.setHomeSectionExpanded(.volumes, expanded: false)
    preferences.setHomeSectionExpanded(.recent, expanded: false)
    preferences.setHomeSectionExpanded(.recent, expanded: false)
    let restored = BrowserPreferences(defaults: defaults, initialFavorites: [])
    #expect(!restored.homeFavoritesExpanded && !restored.homeVolumesExpanded && !restored.homeRecentExpanded)
    #expect(restored.showHomeFavorites && restored.showHomeVolumes && restored.showHomeRecent)
    #expect(changes == 3); preferences.removeObserver(token)
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

@Test @MainActor func cancelledReadIgnoresLateResultAndCanReload() async throws {
    let model = BrowserModel(loader: DelayedLoader())
    model.navigate(URL(fileURLWithPath: "/slow"))
    try await Task.sleep(for: .milliseconds(10))
    model.cancelLoad()
    #expect(model.wasCancelled); #expect(!model.isLoading); #expect(model.error == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.items.isEmpty); #expect(model.wasCancelled)
    model.reload()
    #expect(!model.wasCancelled)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.items.map(\.name) == ["slow"]); #expect(!model.isLoading)
    model.cancelLoad() // A completed list must not become cancelled.
    #expect(!model.wasCancelled)
}

@Test @MainActor func cancelledStreamPreservesPartialRowsAndHomeClearsState() async throws {
    let model = BrowserModel(loader: ChunkedLoader())
    model.navigate(URL(fileURLWithPath: "/chunked"))
    for _ in 0..<50 {
        if !model.items.isEmpty { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.items.count == 1)
    model.cancelLoad()
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.items.map(\.name) == ["first"])
    #expect(model.wasCancelled); #expect(!model.isLoading)
    model.navigate(nil)
    #expect(!model.wasCancelled); #expect(model.items.isEmpty)
}

@Test func deletedEventStillMatchesCanonicalWatchedParent() throws {
    let root = URL(fileURLWithPath: "/private/tmp/files-event-path-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("file.txt")
    try Data().write(to: child)
    let watched = root.resolvingSymlinksInPath().standardizedFileURL.path
    #expect(DirectoryWatcher.affectsDirectory(eventPath: child.path, watchedPath: watched))
    try FileManager.default.removeItem(at: child)
    #expect(DirectoryWatcher.affectsDirectory(eventPath: child.path, watchedPath: watched))
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    #expect(!DirectoryWatcher.affectsDirectory(eventPath: nested.appendingPathComponent("file.txt").path, watchedPath: watched))
}
@Test func diagnosticArtifactsUsePrivateDeterministicFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let artifacts = DiagnosticArtifacts(root: root)
    let fixed = Date(timeIntervalSince1970: 0)
    try artifacts.append(event: "first\nline", at: fixed)
    try artifacts.append(event: "second", at: fixed)
    let log = try String(contentsOf: artifacts.logFile, encoding: .utf8)
    #expect(log == "1970-01-01T00:00:00Z first line\n1970-01-01T00:00:00Z second\n")
    try artifacts.writeSettingsSnapshot(Data("{\"ok\":true}".utf8))
    #expect(try Data(contentsOf: artifacts.settingsSnapshot) == Data("{\"ok\":true}".utf8))
    let permissions = try FileManager.default.attributesOfItem(atPath: artifacts.logFile.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}
