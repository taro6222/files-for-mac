import Foundation
import Testing
@testable import FilesCore

@Test func windowGeometryRejectsInvalidFramesAndRepairsPanelBounds() throws {
    #expect(WorkspaceWindowGeometry(x: .nan, y: 0, width: 900, height: 600) == nil)
    #expect(WorkspaceWindowGeometry(x: 0, y: 0, width: .infinity, height: 600) == nil)
    #expect(WorkspaceWindowGeometry(x: 0, y: 0, width: 0, height: 600) == nil)
    #expect(WorkspaceWindowGeometry(x: 1e100, y: 0, width: 900, height: 600) == nil)
    let value = try #require(WorkspaceWindowGeometry(x: -1500, y: -200, width: 1000, height: 700,
                                                    sidebarWidth: 999, informationWidth: -1))
    #expect(value.x == -1500 && value.y == -200)
    #expect(value.sidebarWidth == 320 && value.informationWidth == 240)
    #expect(WorkspaceWindowGeometry(x: 0, y: 0, width: 900, height: 600, sidebarWidth: .nan)?.sidebarWidth == 220)
}

@Test func groupedGeometryRoundTripsWithoutChangingLegacyTabs() throws {
    let suite = "geometry-roundtrip-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let a = SplitTabState(primary: PaneSnapshot(tab: TabSnapshot(location: nil)))
    let b = SplitTabState(primary: PaneSnapshot(tab: TabSnapshot(location: URL(fileURLWithPath: "/b"))))
    let left = try #require(WorkspaceWindowGeometry(x: -1000, y: 100, width: 1000, height: 700, sidebarWidth: 260, informationWidth: 320))
    let right = try #require(WorkspaceWindowGeometry(x: 100, y: 200, width: 1200, height: 800, sidebarWidth: 200, informationWidth: 400))
    let session = WorkspaceDesktopSession(windows: [WorkspaceWindowSession(tabs: [a, b], selectedIndex: 1, geometry: left),
                                                   WorkspaceWindowSession(tabs: [b], geometry: right)], focusedWindowIndex: 1)
    let store = WorkspaceSessionStore(defaults: defaults)
    try store.saveDesktop(session)
    #expect(store.loadDesktop() == session)
    let data = try #require(defaults.data(forKey: "workspaceSessionV2"))
    #expect(try JSONDecoder().decode([SplitTabState].self, from: data) == [a, b, b])
}

@Test func corruptGeometryDoesNotDiscardHealthyTabsOrOtherWindows() throws {
    let suite = "geometry-damaged-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tab = SplitTabState(primary: PaneSnapshot(tab: TabSnapshot(location: nil)))
    let geometry = try #require(WorkspaceWindowGeometry(x: 0, y: 60, width: 900, height: 600))
    let store = WorkspaceSessionStore(defaults: defaults)
    try store.saveDesktop(WorkspaceDesktopSession(windows: [WorkspaceWindowSession(tabs: [tab], geometry: geometry),
                                                           WorkspaceWindowSession(tabs: [tab], geometry: geometry)]))
    let data = try #require(defaults.data(forKey: "workspaceSessionV2"))
    var rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    rows[0]["windowGeometry"] = ["x": 0, "y": 0, "width": -10, "height": 600]
    defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "workspaceSessionV2")
    let loaded = store.loadDesktop()
    #expect(loaded.windows.count == 2 && loaded.windows[0].tabs == [tab])
    #expect(loaded.windows[0].geometry == nil && loaded.windows[1].geometry == geometry)
}

@Test func survivingTabRetainsGroupGeometryWhenFirstTabIsDamaged() throws {
    let suite = "geometry-partial-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tab = SplitTabState(primary: PaneSnapshot(tab: TabSnapshot(location: nil)))
    let geometry = try #require(WorkspaceWindowGeometry(x: 100, y: 100, width: 1000, height: 700, sidebarWidth: 250))
    let store = WorkspaceSessionStore(defaults: defaults)
    try store.saveDesktop(WorkspaceDesktopSession(windows: [WorkspaceWindowSession(tabs: [tab, tab], geometry: geometry)]))
    let data = try #require(defaults.data(forKey: "workspaceSessionV2"))
    var rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    rows[0]["panes"] = []
    defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "workspaceSessionV2")
    #expect(store.loadDesktop().windows == [WorkspaceWindowSession(tabs: [tab], geometry: geometry)])
}
