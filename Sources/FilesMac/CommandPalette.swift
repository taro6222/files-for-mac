import AppKit

@MainActor
struct CommandPaletteEntry {
    let id: String
    let category: String
    let title: String
    let shortcut: String
    let item: NSMenuItem

    var searchableText: String { (category + " " + title).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    var isEnabled: Bool { isEnabled(for: resolvedTarget(in: nil)) }

    func resolvedTarget(in owner: NSWindow?) -> AnyObject? {
        guard let action = item.action else { return nil }
        if let target = item.target { return target as AnyObject }
        if let owner {
            var responder = owner.firstResponder
            while let candidate = responder {
                if candidate.responds(to: action) { return candidate }
                responder = candidate.nextResponder
            }
            if let controller = owner.windowController, controller.responds(to: action) { return controller }
            if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
            return NSApp.responds(to: action) ? NSApp : nil
        }
        return NSApp.target(forAction: action, to: nil, from: item) as AnyObject?
    }

    func isEnabled(for target: AnyObject?) -> Bool {
        guard let target else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return item.isEnabled
    }
}

@MainActor
enum CommandPaletteCatalog {
    static func entries(from root: NSMenu?) -> [CommandPaletteEntry] {
        guard let root else { return [] }
        var result: [CommandPaletteEntry] = []
        for section in root.items {
            guard let submenu = section.submenu else { continue }
            collect(submenu, category: section.title, path: section.title, into: &result)
        }
        return result
    }
    static func filtered(_ entries: [CommandPaletteEntry], query: String) -> [CommandPaletteEntry] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in terms.allSatisfy { entry.searchableText.contains($0) } }
    }
    private static func collect(_ menu: NSMenu, category: String, path: String, into result: inout [CommandPaletteEntry]) {
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem {
            if let submenu = item.submenu { collect(submenu, category: category, path: path + "/" + item.title, into: &result); continue }
            guard let action = item.action, action != #selector(BrowserWindow.showCommandPalette(_:)) else { continue }
            result.append(CommandPaletteEntry(id: path + "/\(index)/" + item.title + "/" + NSStringFromSelector(action), category: category,
                                              title: item.title, shortcut: shortcut(for: item), item: item))
        }
    }
    private static func shortcut(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
            + item.keyEquivalent.uppercased()
    }
}

@MainActor
final class CommandPaletteWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let search = NSTextField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var all: [CommandPaletteEntry] = []
    private var visible: [CommandPaletteEntry] = []
    private weak var browserWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    convenience init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        self.init(window: panel); panel.title = L("명령 팔레트", "Command Palette"); panel.isReleasedWhenClosed = false
        panel.delegate = self
        buildUI(); reloadCatalog()
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        search.placeholderString = L("명령 검색", "Search commands"); search.delegate = self; search.setAccessibilityLabel(L("명령 검색", "Search commands")); stack.addArrangedSubview(search)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 36; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(runSelected(_:))
        table.setAccessibilityLabel(L("검색 결과", "Command Results"))
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; stack.addArrangedSubview(scroll)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); stack.addArrangedSubview(status)
    }
    func present(relativeTo owner: NSWindow?) {
        if window?.isVisible != true {
            browserWindow = owner
            if let editor = owner?.firstResponder as? NSTextView, editor.isFieldEditor {
                previousResponder = editor.delegate as? NSControl
            } else {
                previousResponder = owner?.firstResponder
            }
        }
        reloadCatalog(); search.stringValue = ""; applyFilter(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search)
    }
    func windowWillClose(_ notification: Notification) {
        defer { browserWindow = nil; previousResponder = nil }
        guard let owner = browserWindow, owner.isVisible else { return }
        owner.makeKeyAndOrderFront(nil)
        if let previousResponder { owner.makeFirstResponder(previousResponder) }
    }
    private func reloadCatalog() { all = CommandPaletteCatalog.entries(from: NSApp.mainMenu) }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.moveDown(_:)) { moveSelection(1); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { runSelected(nil); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    private func applyFilter() { visible = CommandPaletteCatalog.filtered(all, query: search.stringValue); table.reloadData(); if !visible.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }; updateStatus() }
    private func moveSelection(_ delta: Int) { guard !visible.isEmpty else { return }; table.selectRowIndexes([min(max(0, table.selectedRow + delta), visible.count - 1)], byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow) }
    private func updateStatus() { status.stringValue = visible.isEmpty ? L("일치하는 명령 없음", "No matching commands") : L("\(visible.count)개 명령", "\(visible.count) commands") }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }; let entry = visible[row], id = NSUserInterfaceItemIdentifier("CommandCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let t = NSTextField(labelWithString: ""); t.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(t); c.textField = t; NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        cell.textField?.stringValue = "\(entry.category)  ›  \(entry.title)" + (entry.shortcut.isEmpty ? "" : "    \(entry.shortcut)")
        cell.textField?.textColor = entry.isEnabled(for: entry.resolvedTarget(in: browserWindow)) ? .labelColor : .tertiaryLabelColor
        return cell
    }
    @objc private func runSelected(_ sender: Any?) {
        guard visible.indices.contains(table.selectedRow) else { return }
        let entry = visible[table.selectedRow]
        let target = entry.resolvedTarget(in: browserWindow)
        guard let action = entry.item.action, entry.isEnabled(for: target) else {
            status.stringValue = L("현재 문맥에서 사용할 수 없습니다", "Unavailable in the current context")
            NSAccessibility.post(element: status, notification: .valueChanged)
            NSSound.beep()
            return
        }
        close()
        NSApp.sendAction(action, to: target, from: entry.item)
    }
#if DEBUG
    var qaVisibleCount: Int { visible.count }
    var qaSearchFocused: Bool { search.currentEditor() != nil }
    func qaSetQuery(_ value: String) {
        search.stringValue = value
        search.currentEditor()?.string = value
        applyFilter()
    }
    var qaStatus: String { status.stringValue }
#endif
}
