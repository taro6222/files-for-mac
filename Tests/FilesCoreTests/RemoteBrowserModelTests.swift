import Foundation
import Testing
@testable import FilesCore

@MainActor
private func settleRemote(_ model: RemoteBrowserModel) async {
    await model.waitForCurrentLoad()
}

@Test @MainActor func remoteBrowserNavigatesDirectoriesAndHistoryWithoutFileURLs() async throws {
    let model = try RemoteBrowserModel(path: "/team") { path in
        if path == "/team" {
            return [RemoteDirectoryEntry(name: "z.txt", remotePath: "/team/z.txt"),
                    RemoteDirectoryEntry(name: "Folder", remotePath: "/team/Folder", isDirectory: true)]
        }
        return [RemoteDirectoryEntry(name: "child.txt", remotePath: path + "/child.txt")]
    }
    model.start(); await settleRemote(model)
    #expect(model.entries.map(\.name) == ["Folder", "z.txt"])
    try model.open(model.entries[0]); await settleRemote(model)
    #expect(model.path == "/team/Folder"); #expect(model.canGoBack); #expect(model.entries.map(\.name) == ["child.txt"])
    model.goBack(); await settleRemote(model); #expect(model.path == "/team")
    model.goForward(); await settleRemote(model); #expect(model.path == "/team/Folder")
    model.goUp(); await settleRemote(model); #expect(model.path == "/team")
}

@Test @MainActor func remoteBrowserRejectsUnsafePathsAndDiscardsStaleResults() async throws {
    #expect(throws: RemoteBrowserError.invalidPath) { try RemoteBrowserModel(path: "relative") { _ in [] } }
    #expect(throws: RemoteBrowserError.invalidPath) { try RemoteBrowserModel(path: "/team/../secret") { _ in [] } }
    let model = try RemoteBrowserModel { path in
        if path == "/slow" { try await Task.sleep(for: .milliseconds(100)); return [.init(name: "stale", remotePath: "/slow/stale")] }
        return [.init(name: "fresh", remotePath: path + (path == "/" ? "" : "/") + "fresh")]
    }
    try model.navigate(to: "/slow"); try model.navigate(to: "/fresh"); await settleRemote(model)
    #expect(model.path == "/fresh"); #expect(model.entries.map(\.name) == ["fresh"])
    model.reload(); model.cancel(); #expect(model.wasCancelled); #expect(!model.isLoading)
}

private actor RemoteLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func remoteBrowserWaitsForRequestCompletionWithoutAFixedSleep() async throws {
    let gate = RemoteLoadGate()
    let model = try RemoteBrowserModel(path: "/team") { path in
        await gate.wait(); return [.init(name: "ready.txt", remotePath: path + "/ready.txt")]
    }
    model.start()
    #expect(model.isLoading && model.entries.isEmpty)
    let waiting = Task { await model.waitForCurrentLoad(); return model.entries.map(\.name) }
    while !(await gate.started) { await Task.yield() }
    #expect(model.isLoading && model.entries.isEmpty)
    await gate.open()
    #expect(await waiting.value == ["ready.txt"])
    #expect(!model.isLoading && model.error == nil)
}
