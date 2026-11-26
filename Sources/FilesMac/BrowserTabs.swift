import AppKit
import FilesCore

/// Browser tabs keep their existing controllers and panes, without creating AppKit's tab bar.
@MainActor
final class BrowserTabs {
    private final class Member {
        weak var browser: BrowserWindow?
        init(_ browser: BrowserWindow) { self.browser = browser }
    }
    private var members: [Member] = []
    private(set) weak var selected: BrowserWindow?
    private(set) var switching = false
    var browsers: [BrowserWindow] { members.compactMap(\.browser) }
    var windows: [NSWindow] { browsers.compactMap(\.window) }

    func register(_ browser: BrowserWindow) {
        // Tabs swap complete browser windows. Per-window fade animations can keep blocking
        // AppKit workers alive while hidden and eventually starve filesystem registration.
        browser.window?.animationBehavior = .none
        guard !browsers.contains(where: { $0 === browser }) else { return }
        members.append(Member(browser)); if selected == nil { selected = browser }
        refresh()
    }
    func insert(_ browser: BrowserWindow, at requestedIndex: Int? = nil, select: Bool = true) {
        let frame = selected?.window?.frame
        if browser.tabs !== self { browser.tabs.remove(browser) }
        if let selected { browser.synchronizePanelWidths(from: selected) }
        var current = browsers.filter { $0 !== browser }
        current.insert(browser, at: min(max(0, requestedIndex ?? current.count), current.count))
        members = current.map(Member.init)
        browser.tabs = self
        if let frame { browser.window?.setFrame(frame, display: false) }
        refresh()
        if select { self.select(browser) } else { browser.window?.orderOut(nil) }
    }
    func remove(_ browser: BrowserWindow) {
        if let selected {
            browser.synchronizePanelWidths(from: selected)
            if let frame = selected.window?.frame { browser.window?.setFrame(frame, display: false) }
        }
        let old = browsers
        let index = old.firstIndex { $0 === browser } ?? 0
        members.removeAll { $0.browser == nil || $0.browser === browser }
        if selected === browser {
            selected = nil
            let remaining = browsers
            if !remaining.isEmpty {
                let next = remaining[min(index, remaining.count - 1)]
                next.synchronizePanelWidths(from: browser)
                select(next)
            }
        }
        refresh()
    }
    func select(_ browser: BrowserWindow) {
        guard browsers.contains(where: { $0 === browser }), !switching else { return }
        switching = true; defer { switching = false }
        let previous = selected
        if previous !== browser, let previous {
            browser.synchronizePanelWidths(from: previous)
            if let frame = previous.window?.frame { browser.window?.setFrame(frame, display: false) }
        }
        selected = browser
        for other in browsers where other !== browser { other.window?.orderOut(nil) }
        browser.window?.makeKeyAndOrderFront(nil)
        refresh()
    }
    func selectRelative(_ offset: Int) {
        let current = browsers
        guard !current.isEmpty else { return }
        let index = current.firstIndex { $0 === selected } ?? 0
        select(current[(index + offset % current.count + current.count) % current.count])
    }
    func detach(_ browser: BrowserWindow, at point: NSPoint? = nil) {
        guard browsers.count > 1 else { return }
        remove(browser)
        let independent = BrowserTabs(); browser.tabs = independent; independent.register(browser)
        if let point, let window = browser.window {
            window.setFrameTopLeftPoint(NSPoint(x: point.x - 120, y: point.y + 20))
        }
        independent.select(browser)
    }
    static func desktopSnapshot(browsers: [BrowserWindow], focused: BrowserWindow?) -> WorkspaceDesktopSession {
        let live = browsers.filter { $0.window?.contentView != nil }
        var visited = Set<ObjectIdentifier>()
        var groups: [[BrowserWindow]] = []
        for browser in live where visited.insert(ObjectIdentifier(browser.tabs)).inserted {
            groups.append(browser.tabs.browsers.filter { candidate in live.contains { $0 === candidate } })
        }
        return WorkspaceDesktopSession(windows: groups.map { group in
            WorkspaceWindowSession(tabs: group.map { $0.workspaceSnapshot() },
                selectedIndex: group.firstIndex { $0 === group.first?.tabs.selected } ?? 0,
                geometry: (group.first?.tabs.selected ?? group.first)?.windowGeometry)
        }, focusedWindowIndex: groups.firstIndex { group in group.contains { $0 === focused } } ?? 0)
    }

    @discardableResult
    static func restoreDesktop(_ session: WorkspaceDesktopSession,
                               makeBrowser: (SplitTabState) -> BrowserWindow) -> [BrowserWindow] {
        var selections: [BrowserWindow] = []
        var focused: BrowserWindow?
        for (index, saved) in session.windows.enumerated() {
            let browsers = saved.tabs.map(makeBrowser)
            guard let first = browsers.first else { continue }
            for browser in browsers.dropFirst() { first.attachTab(browser, select: false) }
            if let geometry = saved.geometry { for browser in browsers { browser.restoreWindowGeometry(geometry) } }
            let selected = browsers[saved.selectedIndex]
            selections.append(selected)
            if index == session.focusedWindowIndex { focused = selected }
        }
        for selected in selections { selected.tabs.select(selected) }
        (focused ?? selections.first).map { $0.tabs.select($0) }
        return selections
    }

    func refresh() {
        for browser in browsers { browser.refreshTabBar() }
    }
}

@MainActor
final class BrowserTabWindow: NSWindow {
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if let browser = windowController as? BrowserWindow,
           browser.tabs.browsers.count > 1, !browser.tabs.switching {
            browser.tabs.select(browser)
        } else { super.makeKeyAndOrderFront(sender) }
    }
    override func orderFront(_ sender: Any?) {
        if let browser = windowController as? BrowserWindow,
           browser.tabs.browsers.count > 1, !browser.tabs.switching {
            browser.tabs.select(browser)
        } else { super.orderFront(sender) }
    }
    override func close() {
        (windowController as? BrowserWindow).map { $0.tabs.remove($0) }
        super.close()
    }
}

@MainActor
final class BrowserTabBar: NSView {
    weak var owner: BrowserWindow?
    private let scroll = NSScrollView()
    private let row = NSStackView()
    private let add = NSButton()
    private let list = NSPopUpButton(frame: .zero, pullsDown: true)
    private var cells: [BrowserTabCell] = []
    private var presentation: [String] = []
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(L("탐색 탭", "Browser tabs"))
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        row.orientation = .horizontal; row.spacing = 4; row.alignment = .centerY
        scroll.documentView = row
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.isBordered = false; add.target = self; add.action = #selector(newTab(_:))
        add.setAccessibilityLabel(L("새 탭", "New tab"))
        list.addItem(withTitle: ""); list.imagePosition = .imageOnly
        list.isBordered = false
        (list.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        list.setAccessibilityLabel(L("탭 목록", "Tab list"))
        for view in [scroll, add, list] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            scroll.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            add.widthAnchor.constraint(equalToConstant: 28), add.centerYAnchor.constraint(equalTo: centerYAnchor),
            list.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 4),
            list.widthAnchor.constraint(equalToConstant: 28), list.centerYAnchor.constraint(equalTo: centerYAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        registerForDraggedTypes([WorkspaceTabDragHandle.dragType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update() {
        guard let owner else { return }
        let browsers = owner.tabs.browsers
        let next = browsers.map { "\(ObjectIdentifier($0))|\($0.tabDisplayTitle)|\($0.window?.title ?? "")|\(owner.tabs.selected === $0)" }
        guard next != presentation else { return }
        presentation = next
        isHidden = browsers.count < 2
        guard !isHidden else {
            for cell in cells { cell.representedBrowser = nil; cell.isHidden = true }
            list.removeAllItems()
            return
        }
        while cells.count < browsers.count {
            let cell = BrowserTabCell(); cells.append(cell); row.addArrangedSubview(cell)
        }
        for (index, cell) in cells.enumerated() {
            cell.isHidden = index >= browsers.count
            cell.representedBrowser = index < browsers.count ? browsers[index] : nil
            if index < browsers.count { cell.update(selected: owner.tabs.selected === browsers[index]) }
        }
        // Keep at most one reusable spare; no closed controller is retained by a cell.
        while cells.count > browsers.count + 1 { cells.removeLast().removeFromSuperview() }
        list.removeAllItems(); list.addItem(withTitle: "")
        list.item(at: 0)?.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        for (index, browser) in browsers.enumerated() {
            // NSPopUpButton.addItem reuses an existing title. Different tabs may have
            // identical titles, so append distinct menu items and keep weak identities.
            let item = NSMenuItem(title: browser.tabDisplayTitle, action: #selector(chooseTab(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.representedObject = BrowserTabMenuReference(browser)
            item.state = owner.tabs.selected === browser ? .on : .off
            list.menu?.addItem(item)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        row.frame = NSRect(x: 0, y: 0, width: CGFloat(cells.filter { !$0.isHidden }.count) * 184, height: max(30, scroll.contentSize.height))
        if let owner, let index = owner.tabs.browsers.firstIndex(where: { $0 === owner.tabs.selected }), cells.indices.contains(index) {
            row.layoutSubtreeIfNeeded()
            row.scrollToVisible(cells[index].frame)
        }
    }
    #if DEBUG
    var verifiesVisibleLayout: Bool {
        guard !isHidden, let root = window?.contentView, frame.height == 40,
              root.bounds.contains(convert(bounds, to: root)), cells.filter({ !$0.isHidden }).count > 1 else { return false }
        return cells.filter { !$0.isHidden }.allSatisfy { $0.frame.width == 180 && $0.frame.height == 30 }
    }
    #endif
    @objc private func newTab(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.newTab(sender) }
    @objc private func chooseTab(_ item: NSMenuItem) {
        guard let owner, let browser = (item.representedObject as? BrowserTabMenuReference)?.browser,
              browser.tabs === owner.tabs else { return }
        owner.tabs.select(browser)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? WorkspaceTabDragHandle)?.representedBrowser == nil ? [] : .move
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let source = (sender.draggingSource as? WorkspaceTabDragHandle)?.representedBrowser,
              let owner else { return false }
        let point = row.convert(sender.draggingLocation, from: nil)
        var index = Int(max(0, point.x + 92) / 184)
        if source.tabs === owner.tabs, let old = owner.tabs.browsers.firstIndex(where: { $0 === source }), old < index { index -= 1 }
        owner.tabs.insert(source, at: index)
        return true
    }
}

@MainActor
private final class BrowserTabMenuReference {
    weak var browser: BrowserWindow?
    init(_ browser: BrowserWindow) { self.browser = browser }
}

@MainActor
private final class BrowserTabCell: WorkspaceTabDragHandle {
    fileprivate let label = NSTextField(labelWithString: "")
    fileprivate let closeButton = NSButton()
    private var selected = false
    init() {
        super.init(fixedSize: false)
        setAccessibilityRole(.radioButton)
        widthAnchor.constraint(equalToConstant: 180).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        label.lineBreakMode = .byTruncatingMiddle
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(closeTab(_:))
        for view in [label, closeButton] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20), closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        onActivate = { [weak self] in guard let browser = self?.representedBrowser else { return }; browser.tabs.select(browser) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(selected: Bool) {
        self.selected = selected
        let title = representedBrowser?.tabDisplayTitle ?? ""
        label.stringValue = title; label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        toolTip = representedBrowser?.window?.title
        setAccessibilityLabel(title); setAccessibilityValue(selected ? 1 : 0)
        closeButton.setAccessibilityLabel(L("탭 닫기: ", "Close tab: ") + title)
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === closeButton ? result : (result == nil ? nil : self)
    }
    override func draw(_ dirtyRect: NSRect) {
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.quaternaryLabelColor.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    @objc private func closeTab(_ sender: Any?) { representedBrowser?.window?.performClose(sender) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(L("새 창으로 탭 이동", "Move Tab to New Window"), #selector(detachTab(_:))),
                                (L("탭 닫기", "Close Tab"), #selector(closeTab(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        return menu
    }
    @objc private func detachTab(_ sender: Any?) {
        guard let browser = representedBrowser else { return }
        browser.tabs.detach(browser)
    }
}

#if DEBUG
extension BrowserTabs {
    static func verifyDesktopSession(preferences: BrowserPreferences, split: SplitTabState,
                                     other: SplitTabState) async throws -> [String: Bool] {
        let suite = "browser-desktop-qa-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.coderInvalidValue) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceSessionStore(defaults: defaults)
        let a = BrowserWindow(preferences: preferences, restoresFrame: false, initialWorkspace: split)
        let b = BrowserWindow(preferences: preferences, restoresFrame: false, initialWorkspace: other)
        let c = BrowserWindow(preferences: preferences, restoresFrame: false,
                              initialWorkspace: SplitTabState(primary: PaneSnapshot(tab: TabSnapshot(location: nil))))
        let d = BrowserWindow(preferences: preferences, restoresFrame: false, initialWorkspace: split)
        let original = [a, b, c, d]
        var reopened: [BrowserWindow] = []
        defer { for browser in original + reopened { browser.close() } }
        a.attachTab(b); a.attachTab(c)
        a.tabs.insert(c, at: 0); a.tabs.select(b)
        d.showWindow(nil)
        try await Task.sleep(for: .milliseconds(200))
        guard let visible = NSScreen.main?.visibleFrame else { throw CocoaError(.coderInvalidValue) }
        b.window?.setFrame(visible.insetBy(dx: -100, dy: -100), display: false)
        let saved = desktopSnapshot(browsers: original, focused: d)
        var checks = ["desktopSessionUsesVisualOrder": saved.windows.count == 2
            && saved.windows[0].tabs == [c.workspaceSnapshot(), a.workspaceSnapshot(), b.workspaceSnapshot()]
            && saved.windows[0].selectedIndex == 2 && saved.focusedWindowIndex == 1]
        try store.saveDesktop(saved)
        for browser in original { browser.close() }
        let loaded = store.loadDesktop()
        let selections = restoreDesktop(loaded) { state in
            let browser = BrowserWindow(preferences: preferences, restoresFrame: false, initialWorkspace: state)
            reopened.append(browser)
            return browser
        }
        try await Task.sleep(for: .milliseconds(200))
        checks["desktopSessionRestoresSeparateWindows"] = reopened.count == 4 && selections.count == 2
            && reopened[0].tabs.browsers.count == 3 && reopened[3].tabs.browsers.count == 1
            && reopened[0].tabs !== reopened[3].tabs
        checks["desktopSessionRestoresSelectedTabs"] = selections.count == 2 && reopened.count == 4
            && selections[0] === reopened[2] && selections[1] === reopened[3]
            && reopened.filter { $0.window?.isVisible == true }.count == 2
            && selections.allSatisfy { $0.tabs.selected === $0 && $0.window?.isVisible == true }
        let actual = desktopSnapshot(browsers: reopened, focused: reopened.last)
        func geometries(_ session: WorkspaceDesktopSession) -> [[String: Double]] {
            session.windows.map { window in
                guard let g = window.geometry else { return [:] }
                return ["x": g.x, "y": g.y, "width": g.width, "height": g.height,
                        "sidebar": g.sidebarWidth, "information": g.informationWidth]
            }
        }
        let encoder = JSONEncoder()
        let savedTabs = try JSONSerialization.jsonObject(with: encoder.encode(saved.windows.map(\.tabs)))
        let actualTabs = try JSONSerialization.jsonObject(with: encoder.encode(actual.windows.map(\.tabs)))
        let orderedBrowsers = selections.flatMap { $0.tabs.browsers }
        let expectedTabs = saved.windows.flatMap(\.tabs)
        let restoredTabs = actual.windows.flatMap(\.tabs)
        let ratioErrors = zip(zip(restoredTabs, expectedTabs), orderedBrowsers).map { pair, browser in
            abs(pair.0.ratio - pair.1.ratio) * max(1, browser.qaWorkspaceDimension)
        }
        let paneStateMatches = restoredTabs.count == expectedTabs.count
            && orderedBrowsers.count == expectedTabs.count
            && zip(restoredTabs, expectedTabs).allSatisfy { current, previous in
                current.panes == previous.panes && current.axis == previous.axis
                    && current.activePaneID == previous.activePaneID
            } && ratioErrors.allSatisfy { $0 <= 1 }
        let geometryMatches = actual.windows.count == saved.windows.count
            && zip(actual.windows, saved.windows).allSatisfy { current, previous in
                guard let g = current.geometry, let saved = previous.geometry else { return false }
                let expected = BrowserGeometryRestoration.frame(for: saved, screens: NSScreen.screens.map(\.visibleFrame))
                return g.x == expected.minX && g.y == expected.minY && g.width == expected.width && g.height == expected.height
                    && g.sidebarWidth == saved.sidebarWidth && g.informationWidth == saved.informationWidth
            }
        let comparison: [String: Any] = ["savedGeometry": geometries(saved), "restoredGeometry": geometries(actual),
            "savedTabs": savedTabs, "restoredTabs": actualTabs,
            "paneAndHistoryUnchanged": actual.windows.map(\.tabs) == saved.windows.map(\.tabs),
            "paneStateMatchesWithOnePointRatioBound": paneStateMatches, "ratioErrorsInPoints": ratioErrors,
            "savedSelectedTabs": saved.windows.map(\.selectedIndex), "restoredSelectedTabs": actual.windows.map(\.selectedIndex),
            "savedFocus": saved.focusedWindowIndex, "restoredFocus": actual.focusedWindowIndex]
        let data = try JSONSerialization.data(withJSONObject: comparison, options: [.sortedKeys])
        if let output = ProcessInfo.processInfo.environment["FILES_UI_QA_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("desktop-session-comparison.json"), options: .atomic)
        }
        checks["desktopSessionRestoresPaneAndHistoryState"] = paneStateMatches
            && actual.windows.map(\.selectedIndex) == saved.windows.map(\.selectedIndex)
            && actual.focusedWindowIndex == saved.focusedWindowIndex
        checks["desktopSessionClampsOversizedWindow"] = geometryMatches
            && (saved.windows.first?.geometry?.width ?? 0) > visible.width
            && actual.windows.first?.geometry?.x == visible.minX && actual.windows.first?.geometry?.y == visible.minY
            && actual.windows.first?.geometry?.width == visible.width && actual.windows.first?.geometry?.height == visible.height
        return checks
    }
}
#endif

#if DEBUG
extension BrowserTabBar {
    @MainActor static func runBoundaryVerification(output: String) async {
        let root = URL(fileURLWithPath: output, isDirectory: true)
        let suite = "tab-boundaries-\(UUID())"
        var browsers: [BrowserWindow] = []
        var checks: [String: Bool] = [:]
        var diagnostics: [String: String] = [:]
        var status: Int32 = 1
        defer { for browser in browsers { browser.close() }; exit(status) }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.coderInvalidValue) }
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
            let dark = ProcessInfo.processInfo.environment["FILES_TAB_UI_QA_THEME"] == "dark"
            preferences.setAppearance(dark ? .dark : .light)
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let folder = root.appendingPathComponent(String(repeating: "긴이름", count: 16) + "-" + String(repeating: "a", count: 64), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            for index in 0..<12 {
                let browser = BrowserWindow(preferences: preferences, restoresFrame: false, initialLocation: index == 11 ? folder : nil)
                browsers.append(browser)
                if index == 0 {
                    browser.window?.setFrame(NSRect(x: 80, y: 80, width: 900, height: 600), display: true)
                    browser.showWindow(nil)
                } else { browsers[0].attachTab(browser, select: false) }
            }
            let group = browsers[0].tabs
            group.select(browsers[11])
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(250))
            func findBar(_ view: NSView) -> BrowserTabBar? {
                if let bar = view as? BrowserTabBar { return bar }
                return view.subviews.lazy.compactMap(findBar).first
            }
            guard let content = browsers[11].window?.contentView, let bar = findBar(content) else { throw CocoaError(.coderInvalidValue) }
            content.layoutSubtreeIfNeeded()
            let sidebarWidth = content.subviews.compactMap { $0 as? NSSplitView }.first?.arrangedSubviews.first?.frame.width ?? 0
            diagnostics["sidebarWidth"] = String(describing: sidebarWidth)
            checks["minimumWindowPreservesSidebarWidth"] = sidebarWidth >= 180 && sidebarWidth <= 320
            checks["defaultSidebarWidthUsesDesignValue"] = abs(sidebarWidth - 220) <= 0.5
            let visible = bar.scroll.contentView.bounds
            let selectedFrame = bar.cells[11].frame
            diagnostics["clipBounds"] = NSStringFromRect(visible)
            diagnostics["selectedFrame"] = NSStringFromRect(selectedFrame)
            diagnostics["barBounds"] = NSStringFromRect(bar.bounds)
            checks["overflowKeepsSelectedTabVisible"] = bar.cells.count == 12 && bar.row.frame.width > visible.width
                && visible.contains(selectedFrame) && bar.verifiesVisibleLayout
            checks["overflowControlsStayInsideBar"] = bar.bounds.contains(bar.add.frame) && bar.bounds.contains(bar.list.frame)
                && bar.add.frame.width >= 28 && bar.list.frame.width >= 28
            diagnostics["accessibleLabel"] = bar.cells[11].accessibilityLabel() ?? "nil"
            diagnostics["expectedTitle"] = folder.lastPathComponent
            diagnostics["labelFrame"] = NSStringFromRect(bar.cells[11].label.frame)
            diagnostics["closeFrame"] = NSStringFromRect(bar.cells[11].closeButton.frame)
            diagnostics["lineBreakMode"] = String(describing: bar.cells[11].label.lineBreakMode)
            checks["longTitleKeepsFullAccessibleLabel"] = bar.cells[11].accessibilityLabel() == folder.lastPathComponent
                && bar.cells[11].label.lineBreakMode == .byTruncatingMiddle && bar.cells[11].closeButton.alignmentRect(forFrame: bar.cells[11].closeButton.frame).width == 20
                && bar.cells[11].label.frame.maxX < bar.cells[11].closeButton.frame.minX
            func capture(_ view: NSView, name: String) throws {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                        context.setBlendMode(.destinationOver)
                        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                    }
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: root.appendingPathComponent(name + ".png"))
            }
            try capture(bar, name: "overflow")
            try capture(content, name: "minimum-window")
            guard let sidebarSplit = content.subviews.compactMap({ $0 as? BrowserRootSplitView }).first,
                  let sidebar = sidebarSplit.arrangedSubviews.first else { throw CocoaError(.coderInvalidValue) }
            sidebarSplit.setPosition(260, ofDividerAt: 0)
            content.layoutSubtreeIfNeeded()
            browsers[11].window?.setFrame(NSRect(x: 80, y: 80, width: 1200, height: 800), display: true)
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            diagnostics["sidebarAfterResize"] = String(describing: sidebar.frame.width)
            checks["sidebarUserWidthSurvivesWindowResize"] = abs(sidebar.frame.width - 260) <= 0.5
            checks["sidebarDragUsesDesignBounds"] = sidebarSplit.delegate === sidebarSplit
                && sidebarSplit.splitView(sidebarSplit, constrainMinCoordinate: 0, ofSubviewAt: 0) == 180
                && sidebarSplit.splitView(sidebarSplit, constrainMaxCoordinate: 2000, ofSubviewAt: 0) == 320
            preferences.setShowSidebar(false)
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            let mainWidth = sidebarSplit.arrangedSubviews[1].frame.width
            let dividerWidth = CGFloat(max(0, sidebarSplit.arrangedSubviews.count - 1)) * sidebarSplit.dividerThickness
            let hiddenFreedSpace = sidebar.isHidden && mainWidth >= sidebarSplit.bounds.width - dividerWidth
            diagnostics["hiddenSidebarMainWidth"] = String(describing: mainWidth)
            preferences.setShowSidebar(true)
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            diagnostics["sidebarAfterShow"] = String(describing: sidebar.frame.width)
            checks["sidebarHideRestoresUserWidth"] = hiddenFreedSpace && !sidebar.isHidden && abs(sidebar.frame.width - 260) <= 0.5
            sidebarSplit.setPosition(220, ofDividerAt: 0)
            browsers[11].window?.setFrame(NSRect(x: 80, y: 80, width: 900, height: 600), display: true)
            preferences.setShowInfoPane(true)
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            let information = sidebarSplit.arrangedSubviews[2]
            diagnostics["informationPaneDefaultWidth"] = String(describing: information.frame.width)
            checks["informationPaneReadableWithSidebar"] = !information.isHidden
                && abs(information.frame.width - 280) <= 0.5 && abs(sidebar.frame.width - 220) <= 0.5
                && sidebarSplit.arrangedSubviews[1].frame.width >= 360
            try capture(content, name: "information-pane")
            browsers[11].window?.setFrame(NSRect(x: 80, y: 80, width: 1200, height: 800), display: true)
            content.layoutSubtreeIfNeeded()
            sidebarSplit.setPosition(sidebarSplit.bounds.maxX - 320 - sidebarSplit.dividerThickness, ofDividerAt: 1)
            preferences.setShowInfoPane(false)
            try await Task.sleep(for: .milliseconds(100))
            preferences.setShowInfoPane(true)
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            diagnostics["informationPaneAfterShow"] = String(describing: information.frame.width)
            checks["informationPaneUserWidthRestores"] = !information.isHidden && abs(information.frame.width - 320) <= 0.5
            checks["informationPaneDragUsesDesignBounds"] =
                sidebarSplit.splitView(sidebarSplit, constrainMinCoordinate: 0, ofSubviewAt: 1) == sidebarSplit.bounds.maxX - 420 - sidebarSplit.dividerThickness
                && sidebarSplit.splitView(sidebarSplit, constrainMaxCoordinate: 2000, ofSubviewAt: 1) == sidebarSplit.bounds.maxX - 240 - sidebarSplit.dividerThickness
            guard let menuItem = bar.list.item(at: 5), let action = menuItem.action else { throw CocoaError(.coderInvalidValue) }
            checks["duplicateTitlesKeepDistinctMenuItems"] = bar.list.numberOfItems == 13
                && (1...11).allSatisfy { bar.list.item(at: $0)?.title == browsers[0].tabDisplayTitle }
            let sent = NSApp.sendAction(action, to: menuItem.target, from: menuItem)
            checks["tabListSelectsRequestedHiddenTab"] = sent && group.selected === browsers[4]
            group.insert(browsers[4], at: 11)
            group.select(browsers[0])
            let sentAfterReorder = NSApp.sendAction(action, to: menuItem.target, from: menuItem)
            checks["trackedMenuItemFollowsTabAfterReorder"] = sentAfterReorder && group.selected === browsers[4]
            group.insert(browsers[4], at: 4)
            let target = browsers[4]
            guard let targetBar = target.window?.contentView.flatMap(findBar) else { throw CocoaError(.coderInvalidValue) }
            checks["accessibleTabPressSelectsTab"] = targetBar.cells[8].accessibilityPerformPress() && group.selected === browsers[8]
            group.select(browsers[11])
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: browsers[11].window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124) else { throw CocoaError(.coderInvalidValue) }
            bar.cells[11].keyDown(with: event)
            checks["tabArrowWrapsToFirst"] = group.selected === browsers[0]
            // Exercise the actual close button for an unselected tab in a visible bar.
            guard let firstBar = browsers[0].window?.contentView.flatMap(findBar) else { throw CocoaError(.coderInvalidValue) }
            firstBar.cells[6].closeButton.performClick(nil)
            try await Task.sleep(for: .milliseconds(100))
            checks["closeButtonClosesRepresentedBackgroundTab"] = group.browsers.count == 11
                && !group.browsers.contains { $0 === browsers[6] } && group.selected === browsers[0]
            for browser in browsers.dropFirst() { browser.close() }
            try await Task.sleep(for: .milliseconds(100))
            checks["closeManyTabsClearsHiddenControls"] = group.browsers.count == 1 && firstBar.isHidden
                && firstBar.cells.count <= 3 && firstBar.cells.allSatisfy { $0.representedBrowser == nil }
                && firstBar.list.numberOfItems == 0
            status = checks.values.allSatisfy { $0 } ? 0 : 1
            let result: [String: Any] = ["checks": checks, "diagnostics": diagnostics, "theme": dark ? "dark" : "light",
                "language": Locale.preferredLanguages.first ?? "unknown", "physicalInputAccepted": false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            fputs("Tab boundary verification: \(error)\n", stderr)
        }
    }
}
#endif
