import AppKit
import FilesCore

@MainActor
final class SearchWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model = SearchModel()
    private let onOpen: (FileItem) -> Void
    private let search = NSSearchField(), scope = NSPopUpButton(), kind = NSPopUpButton(), hidden = NSButton(checkboxWithTitle: L("숨김 포함", "Include Hidden"), target: nil, action: nil)
    private let table = NSTableView(), status = NSTextField(labelWithString: ""), stop = NSButton()
    private var root: URL?

    init(onOpen: @escaping (FileItem) -> Void) {
        self.onOpen = onOpen
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("검색", "Search"); panel.isReleasedWhenClosed = false; buildUI()
        model.onChange = { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        search.placeholderString = L("파일 이름 검색", "Search file names"); search.delegate = self; search.target = self; search.action = #selector(start(_:)); search.setAccessibilityLabel(L("파일 이름 검색", "Search file names")); controls.addArrangedSubview(search)
        scope.addItems(withTitles: [L("하위 폴더 포함", "Include Subfolders"), L("현재 폴더", "Current Folder")]); scope.setAccessibilityLabel(L("검색 범위", "Search scope")); controls.addArrangedSubview(scope)
        kind.addItems(withTitles: [L("모든 항목", "All Items"), L("파일", "Files"), L("폴더", "Folders")]); kind.setAccessibilityLabel(L("항목 종류", "Item kind")); controls.addArrangedSubview(kind)
        hidden.target = self; hidden.action = #selector(start(_:)); controls.addArrangedSubview(hidden)
        let go = NSButton(title: L("검색", "Search"), target: self, action: #selector(start(_:))); controls.addArrangedSubview(go); stack.addArrangedSubview(controls)
        for (id, title, width) in [("name", L("이름", "Name"), 240.0), ("path", L("위치", "Location"), 360.0), ("kind", L("종류", "Kind"), 90.0)] { let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelection(_:)); table.allowsMultipleSelection = false
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical); stack.addArrangedSubview(scroll)
        let footer = NSStackView(); footer.orientation = .horizontal; status.textColor = .secondaryLabelColor; footer.addArrangedSubview(status); footer.addArrangedSubview(NSView())
        stop.title = L("중단", "Stop"); stop.target = self; stop.action = #selector(cancel(_:)); footer.addArrangedSubview(stop); stack.addArrangedSubview(footer)
    }
    func present(root: URL, showHidden: Bool) { self.root = root; hidden.state = showHidden ? .on : .off; render(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search) }
    @objc private func start(_ sender: Any?) {
        guard let root else { return }
        let selectedScope: SearchScope = scope.indexOfSelectedItem == 1 ? .currentFolder : .descendants
        let selectedKind = SearchItemKind.allCases[kind.indexOfSelectedItem]
        model.search(in: root, query: FileSearchQuery(text: search.stringValue, scope: selectedScope, kind: selectedKind, showHidden: hidden.state == .on))
    }
    @objc private func cancel(_ sender: Any?) { model.cancel() }
    @objc private func openSelection(_ sender: Any?) { guard model.results.indices.contains(table.selectedRow) else { return }; onOpen(model.results[table.selectedRow]); close() }
    private func render() {
        table.reloadData(); stop.isEnabled = model.isSearching
        if model.isSearching { status.stringValue = L("직접 열거로 검색 중… \(model.results.count)개", "Searching by direct enumeration… \(model.results.count)") }
        else if model.wasCancelled { status.stringValue = L("검색 중단 · 부분 결과 \(model.results.count)개", "Search stopped · \(model.results.count) partial results") }
        else if let error = model.error { status.stringValue = L("검색 실패: ", "Search failed: ") + error }
        else { status.stringValue = L("직접 열거 결과 \(model.results.count)개", "\(model.results.count) results from direct enumeration") }
        if model.skippedLocations > 0 { status.stringValue += L(" · 접근 불가 \(model.skippedLocations)곳", " · \(model.skippedLocations) locations skipped") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.results.indices.contains(row), let id = tableColumn?.identifier else { return nil }; let item = model.results[row]
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let t = NSTextField(labelWithString: ""); t.lineBreakMode = .byTruncatingMiddle; t.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(t); c.textField = t; NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        switch id.rawValue { case "name": cell.textField?.stringValue = item.name; case "path": cell.textField?.stringValue = item.url.deletingLastPathComponent().path; default: cell.textField?.stringValue = item.kind }
        return cell
    }
#if DEBUG
    func qaSearch(_ text: String, scope value: SearchScope) { search.stringValue = text; scope.selectItem(at: value == .currentFolder ? 1 : 0); start(nil) }
    var qaIsSearching: Bool { model.isSearching }
    var qaResultCount: Int { model.results.count }
    var qaShowsDirectEnumeration: Bool { status.stringValue.contains(L("직접 열거", "direct enumeration")) }
#endif
}
