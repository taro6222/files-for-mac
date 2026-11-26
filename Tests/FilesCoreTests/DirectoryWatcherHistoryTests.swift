import Foundation
import CoreServices
import Darwin
import Testing
@testable import FilesCore

private func hasInternalEventHistory() -> Bool {
    let root = FileManager.default.temporaryDirectory
    var info = stat()
    return (try? root.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == true
        && stat(root.path, &info) == 0 && FSEventsCopyUUIDForDevice(info.st_dev) != nil
}
private enum HistoryChildChange: CaseIterable, Sendable { case create, edit, remove }
private func historyFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-history-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}
private func observesChange(_ watcher: DirectoryWatcher, predicate: @escaping @Sendable () -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in watcher.events { if predicate() { return true } }
            return false
        }
        group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
        let result = await group.next() ?? false
        watcher.stop(); group.cancelAll(); return result
    }
}

@Test(.enabled(if: hasInternalEventHistory(), "Requires event history on the internal temporary volume"),
      arguments: HistoryChildChange.allCases)
private func watcherReplaysChildChangesBeforeRegistration(change: HistoryChildChange) async throws {
    let root = try historyFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("child")
    if change != .create { try Data([1]).write(to: file) }
    let token = try await FileSystemWork.run(qos: .utility) { _ in DirectoryWatcher.captureReadToken(for: root) }
    let original = try await LocalFileSystem().contents(of: root, showHidden: true)
    #expect(original.count == (change == .create ? 0 : 1))
    if change == .remove { try FileManager.default.removeItem(at: file) }
    else { try Data([1,2,3,4]).write(to: file) }
    // The edit precedes registration, including the usual FSEvents coalescing interval.
    try await Task.sleep(for: .milliseconds(700))
    let watcher = try #require(DirectoryWatcher(url: root, readToken: token))
    defer { watcher.stop() }
    #expect(watcher.replaysCapturedEvents)
    let changed = await observesChange(watcher) {
        if change == .remove { return !FileManager.default.fileExists(atPath: file.path) }
        return (try? Data(contentsOf: file).count) == 4
    }
    #expect(changed)
}

@Test func watcherWithoutCapturedHistoryRequiresInitialReconciliation() async throws {
    let root = try historyFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let live = try #require(DirectoryWatcher(url: root)); defer { live.stop() }
    let other = try historyFixture(); defer { try? FileManager.default.removeItem(at: other) }
    let token = try await FileSystemWork.run(qos: .utility) { _ in DirectoryWatcher.captureReadToken(for: root) }
    let mismatched = try #require(DirectoryWatcher(url: other, readToken: token)); defer { mismatched.stop() }
    #expect(!live.replaysCapturedEvents && !mismatched.replaysCapturedEvents)
}

@Test(.enabled(if: hasInternalEventHistory(), "Requires event history on the internal temporary volume"))
@MainActor func modelListingCursorCoversWatcherAttachedAfterRead() async throws {
    let root = try historyFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let model = BrowserModel()
    model.navigate(root)
    let firstDeadline = ContinuousClock.now + .seconds(4)
    while model.isLoading && ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!model.isLoading && model.loadedItems.isEmpty)
    let token = try #require(model.listingWatchToken)
    let child = root.appendingPathComponent("late-child")
    try Data("late".utf8).write(to: child)
    try await Task.sleep(for: .milliseconds(700))
    let watcher = try #require(DirectoryWatcher(url: root, readToken: token))
    try #require(watcher.replaysCapturedEvents)
    let monitor = Task { @MainActor in
        for await _ in watcher.events { model.reload() }
    }
    defer { watcher.stop(); monitor.cancel(); model.cancelLoad() }
    let deadline = ContinuousClock.now + .seconds(4)
    while !model.items.contains(where: { $0.name == "late-child" }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.items.contains { $0.name == "late-child" && $0.size == 4 })
}

private actor PreparedNavigationLoader: DirectoryLoading {
    private(set) var requests: [String] = []
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        requests.append(url.path)
        return []
    }
}

@Test @MainActor func navigationDuringReadPreparationDoesNotStartObsoleteLoader() async throws {
    let loader = PreparedNavigationLoader()
    let model = BrowserModel(loader: loader)
    let first = FileManager.default.temporaryDirectory.appendingPathComponent("first-\(UUID())")
    let second = FileManager.default.temporaryDirectory.appendingPathComponent("second-\(UUID())")
    model.onListingPrepared = { if model.location == first { model.navigate(second) } }
    defer { model.onListingPrepared = nil; model.cancelLoad() }
    model.navigate(first)
    let deadline = ContinuousClock.now + .seconds(4)
    while model.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isLoading && model.location == second)
    #expect(await loader.requests == [second.path])
}

@Test func watcherHistoryBoundaryIsNotAChangeAndDroppedEventsStillRescan() {
    let boundary = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
    #expect(DirectoryWatcher.disposition(of: boundary) == .historyBoundary)
    for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagRootChanged,
                 kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagUserDropped,
                 kFSEventStreamEventFlagKernelDropped] {
        #expect(DirectoryWatcher.disposition(of: FSEventStreamEventFlags(flag)) == .rescan)
        #expect(DirectoryWatcher.disposition(of: boundary | FSEventStreamEventFlags(flag)) == .rescan)
    }
    #expect(DirectoryWatcher.disposition(of: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) == .path)
}
