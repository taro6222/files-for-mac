import AppKit
import FilesCore

@MainActor
enum BrowserGeometryRestoration {
    static func frame(for saved: WorkspaceWindowGeometry, screens: [NSRect]) -> NSRect {
        let proposed = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        let visible = screens.max { a, b in intersectionArea(proposed, a) < intersectionArea(proposed, b) }
            .flatMap { intersectionArea(proposed, $0) > 0 ? $0 : nil }
            ?? screens.first ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        let width = min(visible.width, max(900, proposed.width))
        let height = min(visible.height, max(600, proposed.height))
        return NSRect(x: min(max(proposed.minX, visible.minX), visible.maxX - width),
                      y: min(max(proposed.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

#if DEBUG
extension BrowserGeometryRestoration {
    static func verify(preferences: BrowserPreferences) async throws -> [String: Bool] {
        let a = BrowserWindow(preferences: preferences, restoresFrame: false)
        let b = BrowserWindow(preferences: preferences, restoresFrame: false)
        let c = BrowserWindow(preferences: preferences, restoresFrame: false)
        var reopened: [BrowserWindow] = []
        var transient: BrowserWindow?
        defer { for browser in [a, b, c] + reopened + [transient].compactMap({ $0 }) { browser.close() } }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let raw = WorkspaceWindowGeometry(x: 40, y: 90, width: 960, height: 640, sidebarWidth: 260, informationWidth: 320),
              let other = WorkspaceWindowGeometry(x: 180, y: 110, width: 1000, height: 660, sidebarWidth: 200, informationWidth: 380) else { throw CocoaError(.coderInvalidValue) }
        a.restoreWindowGeometry(raw); a.showWindow(nil)
        let sourceFrame = a.window?.frame
        a.attachTab(b, select: false)
        let inserted = b.windowGeometry?.sidebarWidth == 260 && b.windowGeometry?.informationWidth == 320
            && b.window?.frame == sourceFrame
        a.tabs.select(b)
        guard let changed = WorkspaceWindowGeometry(x: raw.x, y: raw.y, width: raw.width, height: raw.height,
            sidebarWidth: 300, informationWidth: 360) else { throw CocoaError(.coderInvalidValue) }
        b.restoreWindowGeometry(changed)
        a.tabs.select(a)
        let switched = a.windowGeometry?.sidebarWidth == 300 && a.windowGeometry?.informationWidth == 360
        a.restoreWindowGeometry(raw); a.tabs.select(b)
        let extra = BrowserWindow(preferences: preferences, restoresFrame: false)
        transient = extra
        a.attachTab(extra); extra.restoreWindowGeometry(changed); extra.close()
        let closed = a.tabs.selected === b && b.windowGeometry?.sidebarWidth == 300 && b.windowGeometry?.informationWidth == 360
        b.restoreWindowGeometry(raw)
        c.restoreWindowGeometry(other); c.showWindow(nil)
        try await Task.sleep(for: .milliseconds(150))
        let saved = BrowserTabs.desktopSnapshot(browsers: [a, b, c], focused: c)
        var checks = ["windowGeometryTransfersAcrossTabs": inserted && switched && closed]
        let suite = "geometry-appkit-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.coderInvalidValue) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceSessionStore(defaults: defaults)
        try store.saveDesktop(saved)
        for browser in [a, b, c] { browser.close() }
        let selected = BrowserTabs.restoreDesktop(store.loadDesktop()) { workspace in
            let browser = BrowserWindow(preferences: preferences, restoresFrame: false, initialWorkspace: workspace)
            reopened.append(browser)
            return browser
        }
        try await Task.sleep(for: .milliseconds(150))
        checks["windowGeometryRestoresSeparateFrames"] = selected.count == 2
            && selected[0].window?.frame == saved.windows[0].geometry.map { frame(for: $0, screens: screens) }
            && selected[1].window?.frame == saved.windows[1].geometry.map { frame(for: $0, screens: screens) }
        checks["windowGeometryRestoresPanelPreferences"] = selected.count == 2
            && selected[0].windowGeometry?.sidebarWidth == 260 && selected[0].windowGeometry?.informationWidth == 320
            && selected[1].windowGeometry?.sidebarWidth == 200 && selected[1].windowGeometry?.informationWidth == 380
        guard let invalidScreen = WorkspaceWindowGeometry(x: 1_000_000, y: -1_000_000, width: 8000, height: 8000) else { throw CocoaError(.coderInvalidValue) }
        let virtual = NSRect(x: -1400, y: 20, width: 1400, height: 900)
        let result = frame(for: invalidScreen, screens: [virtual])
        checks["windowGeometryClampsDisconnectedDisplay"] = virtual.contains(result) && result.size == virtual.size
        return checks
    }
}
#endif
