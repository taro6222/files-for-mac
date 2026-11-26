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
        var current = browsers.filter { $0 !== browser }
        current.insert(browser, at: min(max(0, requestedIndex ?? current.count), current.count))
        members = current.map(Member.init)
        browser.tabs = self
        if let frame { browser.window?.setFrame(frame, display: false) }
        refresh()
        if select { self.select(browser) } else { browser.window?.orderOut(nil) }
    }
    func remove(_ browser: BrowserWindow) {
        if let frame = selected?.window?.frame { browser.window?.setFrame(frame, display: false) }
        let old = browsers
        let index = old.firstIndex { $0 === browser } ?? 0
        members.removeAll { $0.browser == nil || $0.browser === browser }
        if selected === browser {
            selected = nil
            let remaining = browsers
            if !remaining.isEmpty { select(remaining[min(index, remaining.count - 1)]) }
        }
        refresh()
    }
    func select(_ browser: BrowserWindow) {
        guard browsers.contains(where: { $0 === browser }), !switching else { return }
        switching = true; defer { switching = false }
        let previous = selected
        if previous !== browser, let frame = previous?.window?.frame {
            browser.window?.setFrame(frame, display: false)
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
                selectedIndex: group.firstIndex { $0 === group.first?.tabs.selected } ?? 0)
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
        list.isBordered = false; list.target = self; list.action = #selector(chooseTab(_:))
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
            list.addItem(withTitle: browser.tabDisplayTitle)
            list.lastItem?.tag = index
            list.lastItem?.state = owner.tabs.selected === browser ? .on : .off
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
    @objc private func chooseTab(_ sender: Any?) {
        guard let owner, let item = list.selectedItem, list.indexOfSelectedItem > 0,
              owner.tabs.browsers.indices.contains(item.tag) else { return }
        owner.tabs.select(owner.tabs.browsers[item.tag])
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
private final class BrowserTabCell: WorkspaceTabDragHandle {
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
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
        checks["desktopSessionRestoresPaneAndHistoryState"] =
            desktopSnapshot(browsers: reopened, focused: reopened.last) == saved
        return checks
    }
}
#endif
