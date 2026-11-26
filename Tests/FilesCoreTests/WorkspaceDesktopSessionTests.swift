import Foundation
import Testing
@testable import FilesCore

private func sessionWorkspace(_ path: String) -> SplitTabState {
    let primary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: path)))
    let secondary = PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: path + "/other")))
    return SplitTabState(primary: primary, secondary: secondary, axis: .horizontal,
                         ratio: 0.65, activePaneID: secondary.id)
}

@Test func desktopSessionPreservesWindowTabOrderSelectionAndLegacyReader() throws {
    let suite = "desktop-session-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = sessionWorkspace("/a"), b = sessionWorkspace("/b"), c = sessionWorkspace("/c")
    let desktop = WorkspaceDesktopSession(windows: [
        WorkspaceWindowSession(tabs: [c, a], selectedIndex: 1),
        WorkspaceWindowSession(tabs: [b])], focusedWindowIndex: 1)
    let store = WorkspaceSessionStore(defaults: defaults)
    try store.saveDesktop(desktop)
    #expect(store.loadDesktop() == desktop)
    #expect(store.load() == [c, a, b])
    // Decode the actual persisted bytes with the previous release's plain array schema.
    let data = try #require(defaults.data(forKey: "workspaceSessionV2"))
    #expect(try JSONDecoder().decode([SplitTabState].self, from: data) == [c, a, b])
    // A previous build saving the session intentionally returns it to a single window.
    try store.save([b, a])
    #expect(store.loadDesktop(selectedFlatIndex: 1) == WorkspaceDesktopSession(windows: [
        WorkspaceWindowSession(tabs: [b, a], selectedIndex: 1)]))
}

@Test func desktopSessionRecoversLegacyOriginalSelectionAfterDamagedTabs() throws {
    let suite = "desktop-legacy-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = sessionWorkspace("/a"), b = sessionWorkspace("/b")
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([a, b])) as? [Any])
    defaults.set(try JSONSerialization.data(withJSONObject: [NSNull(), encoded[0], ["panes": []], encoded[1]]),
                 forKey: "workspaceSessionV2")
    #expect(WorkspaceSessionStore(defaults: defaults).loadDesktop(selectedFlatIndex: 3) ==
        WorkspaceDesktopSession(windows: [WorkspaceWindowSession(tabs: [a, b], selectedIndex: 1)]))
}

@Test func desktopSessionRepairsMetadataWithoutDiscardingHealthyGroups() throws {
    let suite = "desktop-recovery-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = sessionWorkspace("/a"), b = sessionWorkspace("/b"), c = sessionWorkspace("/c")
    let store = WorkspaceSessionStore(defaults: defaults)
    try store.saveDesktop(WorkspaceDesktopSession(windows: [
        WorkspaceWindowSession(tabs: [a, b], selectedIndex: 1), WorkspaceWindowSession(tabs: [c])], focusedWindowIndex: 1))
    let data = try #require(defaults.data(forKey: "workspaceSessionV2"))
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    json[1]["panes"] = [] // Remove the first group's selected tab, not the healthy window.
    json[0]["selectedInWindow"] = "damaged"
    defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "workspaceSessionV2")
    #expect(store.loadDesktop() == WorkspaceDesktopSession(windows: [
        WorkspaceWindowSession(tabs: [a]), WorkspaceWindowSession(tabs: [c])], focusedWindowIndex: 1))
    // Bad optional metadata does not turn a valid split tab into data loss.
    json[2]["windowGroupID"] = "invalid UUID"
    json[2]["focusedTab"] = ["invalid": true]
    defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "workspaceSessionV2")
    #expect(store.loadDesktop().windows.map(\.tabs) == [[a], [c]])
    defaults.set(Data("broken".utf8), forKey: "workspaceSessionV2")
    #expect(store.loadDesktop().windows.isEmpty)
}

@Test func desktopSessionNormalizesEmptyWindowsAndInvalidSelection() {
    let a = sessionWorkspace("/a")
    let desktop = WorkspaceDesktopSession(windows: [WorkspaceWindowSession(tabs: []),
        WorkspaceWindowSession(tabs: [a], selectedIndex: 20)], focusedWindowIndex: 1)
    #expect(desktop.windows.count == 1)
    #expect(desktop.focusedWindowIndex == 0)
    #expect(desktop.windows[0].selectedIndex == 0)
}

@Test func savedEmptyDesktopIsAuthoritativeInsteadOfRevivingLegacyTabs() throws {
    let suite = "desktop-empty-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceSessionStore(defaults: defaults)
    #expect(!store.hasSavedSession)
    try TabSessionStore(defaults: defaults).save([TabSnapshot(location: URL(fileURLWithPath: "/obsolete"))])
    #expect(!store.hasSavedSession)
    try store.saveDesktop(WorkspaceDesktopSession(windows: []))
    #expect(store.hasSavedSession)
    #expect(store.loadDesktop().windows.isEmpty)
    defaults.set(Data("broken".utf8), forKey: "workspaceSessionV2")
    #expect(store.hasSavedSession)
    #expect(store.loadDesktop().windows.isEmpty)
}
