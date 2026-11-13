import AppKit
import FilesCore

@MainActor
final class ToolbarSettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let preferences: BrowserPreferences
    private let table = NSTableView()
    private let visibility = NSButton()
    private let up = NSButton()
    private let down = NSButton()

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("툴바 사용자 지정", "Customize Toolbar"); panel.isReleasedWhenClosed = false; buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildUI() {
        guard let content = window?.contentView else { return }; let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L("항목 순서와 표시 여부는 모든 창에 즉시 적용됩니다. 경로 필드는 항상 표시됩니다.", "Item order and visibility apply to every window immediately. The path field is always shown.")))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("toolbarItem")); column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 32; table.delegate = self; table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical); stack.addArrangedSubview(scroll)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        up.title = L("위로", "Move Up"); up.target = self; up.action = #selector(moveToolbarItemUp(_:)); controls.addArrangedSubview(up)
        down.title = L("아래로", "Move Down"); down.target = self; down.action = #selector(moveToolbarItemDown(_:)); controls.addArrangedSubview(down)
        visibility.target = self; visibility.action = #selector(toggleVisibility(_:)); controls.addArrangedSubview(visibility)
        controls.addArrangedSubview(NSView()); let reset = NSButton(title: L("기본값 복원", "Restore Defaults"), target: self, action: #selector(reset(_:))); controls.addArrangedSubview(reset); stack.addArrangedSubview(controls)
        if !preferences.toolbarOrder.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }; updateControls()
    }
    func present() { table.reloadData(); updateControls(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { preferences.toolbarOrder.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard preferences.toolbarOrder.indices.contains(row) else { return nil }; let item = preferences.toolbarOrder[row], id = NSUserInterfaceItemIdentifier("ToolbarItemCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let t = NSTextField(labelWithString: ""); t.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(t); c.textField = t; NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        let state = preferences.hiddenToolbarItems.contains(item) ? L("숨김", "Hidden") : L("표시", "Shown")
        cell.textField?.stringValue = "\(label(item))    \(state)"; cell.textField?.textColor = preferences.hiddenToolbarItems.contains(item) ? .secondaryLabelColor : .labelColor; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    private var selected: BrowserToolbarItem? { preferences.toolbarOrder.indices.contains(table.selectedRow) ? preferences.toolbarOrder[table.selectedRow] : nil }
    private func updateControls() {
        guard let selected, let index = preferences.toolbarOrder.firstIndex(of: selected) else { up.isEnabled = false; down.isEnabled = false; visibility.isEnabled = false; return }
        up.isEnabled = index > 0; down.isEnabled = index < preferences.toolbarOrder.count - 1; visibility.isEnabled = !selected.isRequired
        visibility.title = preferences.hiddenToolbarItems.contains(selected) ? L("표시", "Show") : L("숨기기", "Hide")
    }
    private func move(_ offset: Int) { guard let selected, let old = preferences.toolbarOrder.firstIndex(of: selected) else { return }; preferences.moveToolbarItem(selected, by: offset); table.reloadData(); table.selectRowIndexes([old + offset], byExtendingSelection: false); updateControls() }
    @objc private func moveToolbarItemUp(_ sender: Any?) { move(-1) }
    @objc private func moveToolbarItemDown(_ sender: Any?) { move(1) }
    @objc private func toggleVisibility(_ sender: Any?) { guard let selected else { return }; preferences.toggleToolbarItem(selected); table.reloadData(); updateControls() }
    @objc private func reset(_ sender: Any?) { preferences.resetToolbar(); table.reloadData(); table.selectRowIndexes([0], byExtendingSelection: false); updateControls() }
    private func label(_ item: BrowserToolbarItem) -> String {
        switch item { case .back: L("뒤로", "Back"); case .forward: L("앞으로", "Forward"); case .up: L("상위 폴더", "Enclosing Folder"); case .refresh: L("새로고침", "Refresh"); case .path: L("경로", "Path"); case .hidden: L("숨김 항목", "Hidden Files"); case .viewMode: L("보기 모드", "View Mode"); case .favorite: L("즐겨찾기", "Favorite"); case .options: L("보기 옵션", "View Options") }
    }
#if DEBUG
    var qaRowCount: Int { preferences.toolbarOrder.count }
#endif
}
