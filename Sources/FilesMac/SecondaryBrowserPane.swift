import AppKit
import FilesCore

@MainActor
final class SecondaryBrowserPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let model: BrowserModel
    var onActivate: (() -> Void)?
    var onFileDrop: (([URL], URL, FileDropIntent) -> Bool)?
    private let pathField = NSTextField()
    private let table = ActivatingTableView()
    private let scroll = NSScrollView()
    private let gridView = FileGridView()
    private let listView = FileListView()
    private let columnView = FileColumnView()
    private let status = NSTextField(labelWithString: "")
    private let hiddenButton = NSButton()
    private let viewModeButton = NSPopUpButton()
    private var watcher: DirectoryWatcher?
    private var watcherTask: Task<Void, Never>?
    private var watchedURL: URL?
    private var pendingRefresh = false
    private var rendering = false

    init(snapshot: TabSnapshot) {
        model = BrowserModel()
        super.init(frame: .zero)
        wantsLayer = true; translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        model.onChange = { [weak self] in self?.modelChanged() }
        model.restore(snapshot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func snapshot() -> TabSnapshot { savePosition(); return model.snapshot }
    var selectedItems: [FileItem] {
        if model.viewMode == .grid { return gridView.selectedItems }
        if model.viewMode == .list { return listView.selectedItems }
        if model.viewMode == .columns { return columnView.selectedItems }
        return table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0] : nil }
    }
    func setActive(_ active: Bool) {
        layer?.borderWidth = active ? 2 : 0; layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    func goBack() { activate(); savePosition(); model.back() }
    func goForward() { activate(); savePosition(); model.forward() }
    func goUp() { activate(); if let location = model.location { navigate(location.deletingLastPathComponent()) } }
    func refresh() { activate(); savePosition(); model.reload() }
    func focusPath() { activate(); window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    func focusFiles() {
        activate()
        if model.viewMode == .grid { gridView.focus() }
        else if model.viewMode == .list { listView.focus() }
        else if model.viewMode == .columns { columnView.focus() }
        else { window?.makeFirstResponder(table) }
    }
    func stopLoading() { model.cancelLoad() }
    func setViewMode(_ mode: BrowserViewMode) { activate(); model.setViewMode(mode) }
    func setContextMenu(_ menu: NSMenu?) { gridView.contextMenu = menu; listView.contextMenu = menu }
    func openSelected() {
        if model.viewMode == .grid, let item = gridView.selectedItems.first { openGridItem(item) }
        else if model.viewMode == .list, let item = listView.selectedItems.first { openGridItem(item) }
        else if model.viewMode == .columns, let item = columnView.selectedItems.first { openGridItem(item) }
        else { openSelection(nil) }
    }
    func open(_ url: URL?) { activate(); navigate(url) }
    func shutdown() {
        watcherTask?.cancel(); watcherTask = nil
        if let watcher { Task.detached { watcher.stop() } }
        watcher = nil; watchedURL = nil; model.onChange = nil; model.cancelLoad()
    }

    private func buildUI() {
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        toolbar.addArrangedSubview(button("chevron.left", #selector(back(_:))))
        toolbar.addArrangedSubview(button("chevron.right", #selector(forward(_:))))
        toolbar.addArrangedSubview(button("arrow.up", #selector(up(_:))))
        pathField.placeholderString = L("폴더 경로", "Folder path"); pathField.target = self; pathField.action = #selector(submitPath(_:))
        pathField.setAccessibilityLabel(L("보조 pane 경로", "Secondary pane path")); toolbar.addArrangedSubview(pathField)
        toolbar.addArrangedSubview(button("arrow.clockwise", #selector(reload(_:))))
        hiddenButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: L("숨김 항목 전환", "Toggle Hidden Files"))
        hiddenButton.title = ""; hiddenButton.imagePosition = .imageOnly; hiddenButton.bezelStyle = .texturedRounded
        hiddenButton.target = self; hiddenButton.action = #selector(toggleHidden(_:)); toolbar.addArrangedSubview(hiddenButton)
        for (mode, title) in [(BrowserViewMode.details, L("상세", "Details")),
                              (.list, L("목록", "List")),
                              (.grid, L("그리드", "Grid")),
                              (.columns, L("컬럼", "Columns")),
                              (.adaptive, L("적응형", "Adaptive"))] {
            viewModeButton.addItem(withTitle: title)
            viewModeButton.lastItem?.representedObject = mode.rawValue
        }
        viewModeButton.target = self; viewModeButton.action = #selector(changeViewMode(_:))
        viewModeButton.toolTip = L("보기 모드", "View Mode")
        viewModeButton.setAccessibilityLabel(L("보기 모드", "View Mode"))
        toolbar.addArrangedSubview(viewModeButton)
        stack.addArrangedSubview(toolbar)
        table.style = .fullWidth; table.rowHeight = 30; table.allowsMultipleSelection = true
        table.delegate = self; table.dataSource = self; table.onActivate = { [weak self] in self?.activate() }
        table.doubleAction = #selector(openSelection(_:)); table.target = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        for (key, title, width) in [("name", L("이름", "Name"), 300.0), ("kind", L("종류", "Kind"), 120.0), ("size", L("크기", "Size"), 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true); table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)]
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let browserContent = NSView(); browserContent.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; browserContent.addSubview(scroll); browserContent.addSubview(gridView); browserContent.addSubview(listView); browserContent.addSubview(columnView)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: browserContent.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: browserContent.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: browserContent.topAnchor), scroll.bottomAnchor.constraint(equalTo: browserContent.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: browserContent.leadingAnchor), gridView.trailingAnchor.constraint(equalTo: browserContent.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: browserContent.topAnchor), gridView.bottomAnchor.constraint(equalTo: browserContent.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: browserContent.leadingAnchor), listView.trailingAnchor.constraint(equalTo: browserContent.trailingAnchor),
            listView.topAnchor.constraint(equalTo: browserContent.topAnchor), listView.bottomAnchor.constraint(equalTo: browserContent.bottomAnchor),
            columnView.leadingAnchor.constraint(equalTo: browserContent.leadingAnchor), columnView.trailingAnchor.constraint(equalTo: browserContent.trailingAnchor),
            columnView.topAnchor.constraint(equalTo: browserContent.topAnchor), columnView.bottomAnchor.constraint(equalTo: browserContent.bottomAnchor)
        ])
        gridView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.model.viewMode == .grid else { return }
            self.model.savePosition(selection: selection, scrollOffset: self.gridView.currentScrollOffset())
            self.render()
        }
        gridView.onActivate = { [weak self] in self?.activate() }
        gridView.onOpen = { [weak self] item in self?.openGridItem(item) }
        gridView.onFileDrop = { [weak self] sources, item, intent in
            guard let self, let destination = item?.isBrowsable == true ? item?.url : self.model.location else { return false }
            self.activate()
            return self.onFileDrop?(sources, destination, intent) ?? false
        }
        listView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.model.viewMode == .list else { return }
            self.model.savePosition(selection: selection, scrollOffset: self.listView.currentScrollOffset()); self.render()
        }
        listView.onActivate = { [weak self] in self?.activate() }
        listView.onOpen = { [weak self] item in self?.openGridItem(item) }
        listView.onFileDrop = { [weak self] sources, item, intent in
            guard let self, let destination = item?.isBrowsable == true ? item?.url : self.model.location else { return false }
            self.activate(); return self.onFileDrop?(sources, destination, intent) ?? false
        }
        columnView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.model.viewMode == .columns else { return }
            self.model.savePosition(selection: selection, scrollOffset: 0); self.render()
        }
        columnView.onActivate = { [weak self] in self?.activate() }
        columnView.onOpen = { [weak self] item in self?.openGridItem(item) }
        stack.addArrangedSubview(browserContent)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(); footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        footer.addArrangedSubview(status); footer.addArrangedSubview(NSView()); stack.addArrangedSubview(footer)
        for view in [toolbar, browserContent, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        browserContent.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }
    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(); button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.title = ""; button.imagePosition = .imageOnly; button.bezelStyle = .texturedRounded; button.target = self; button.action = action; return button
    }
    private func activate() { onActivate?() }
    private func savePosition() {
        guard !rendering else { return }
        let selection: Set<String>; let offset: Double
        switch model.viewMode {
        case .grid: selection = Set(gridView.selectedItems.map(\.id)); offset = gridView.currentScrollOffset()
        case .list: selection = Set(listView.selectedItems.map(\.id)); offset = listView.currentScrollOffset()
        case .columns: selection = Set(columnView.selectedItems.map(\.id)); offset = 0
        default: selection = Set(table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].id : nil }); offset = scroll.contentView.bounds.origin.y
        }
        model.savePosition(selection: selection, scrollOffset: offset)
    }
    private func navigate(_ url: URL?) { savePosition(); model.navigate(url) }
    private func modelChanged() {
        render(); updateWatcher()
        if pendingRefresh && !model.isLoading && !model.wasCancelled {
            pendingRefresh = false
            Task { @MainActor [weak self] in self?.model.reload() }
        }
    }
    private func render() {
        rendering = true; defer { rendering = false }
        pathField.stringValue = model.location?.path ?? ""; table.reloadData()
        let showsGrid = model.viewMode == .grid
        let showsList = model.viewMode == .list
        let showsColumns = model.viewMode == .columns
        scroll.isHidden = showsGrid || showsList || showsColumns; gridView.isHidden = !showsGrid; listView.isHidden = !showsList; columnView.isHidden = !showsColumns
        hiddenButton.contentTintColor = model.showHidden ? .systemBlue : .labelColor
        if let item = viewModeButton.itemArray.first(where: {
            ($0.representedObject as? String) == model.viewMode.rawValue
        }) { viewModeButton.select(item) }
        let expectedSort = NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)
        if table.sortDescriptors.first != expectedSort { table.sortDescriptors = [expectedSort] }
        table.selectRowIndexes(IndexSet(model.items.indices.filter { model.history.current.selection.contains(model.items[$0].id) }), byExtendingSelection: false)
        gridView.update(items: model.items, selection: model.history.current.selection,
                        scrollOffset: model.history.current.scrollOffset)
        listView.update(items: model.items, selection: model.history.current.selection,
                        scrollOffset: model.history.current.scrollOffset)
        columnView.showHidden = model.showHidden; columnView.sortOrder = model.sortOrder
        columnView.update(baseURL: model.location, items: model.items, selection: model.history.current.selection)
        if !model.isLoading { scroll.contentView.scroll(to: NSPoint(x: 0, y: model.history.current.scrollOffset)); scroll.reflectScrolledClipView(scroll.contentView) }
        if model.isLoading { status.stringValue = L("읽는 중…", "Loading…") }
        else if let failure = model.failure { status.stringValue = failure.message(korean: Locale.preferredLanguages.first?.hasPrefix("ko") == true) }
        else { status.stringValue = L("\(model.items.count)개 항목", "\(model.items.count) items") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.items.indices.contains(row), let tableColumn else { return nil }
        let item = model.items[row], id = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        switch id.rawValue {
        case "name": cell.textField?.stringValue = item.displayName(showExtensions: true)
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.isDirectory ? "—" : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        default: break
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { activate(); savePosition() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard model.items.indices.contains(row) else { return nil }
        return model.items[row].url as NSURL
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropDestination(row: row, operation: dropOperation) != nil,
              !draggedURLs(info).isEmpty else { return [] }
        let intent = dropIntent(info)
        return intent == .move ? .move : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        activate()
        guard let destination = dropDestination(row: row, operation: dropOperation) else { return false }
        let urls = draggedURLs(info); guard !urls.isEmpty else { return false }
        return onFileDrop?(urls, destination, dropIntent(info)) ?? false
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let field = SortField(rawValue: descriptor.key ?? "") else { return }
        savePosition(); model.sort(SortOrder(field: field, ascending: descriptor.ascending))
    }
    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = id
        let label = NSTextField(labelWithString: ""); label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    @objc private func back(_ sender: Any?) { goBack() }
    @objc private func forward(_ sender: Any?) { goForward() }
    @objc private func up(_ sender: Any?) { goUp() }
    @objc private func reload(_ sender: Any?) { refresh() }
    @objc private func toggleHidden(_ sender: Any?) {
        activate(); savePosition(); model.showHidden.toggle(); model.reload()
    }
    @objc private func changeViewMode(_ sender: Any?) {
        activate()
        guard let raw = viewModeButton.selectedItem?.representedObject as? String,
              let mode = BrowserViewMode(rawValue: raw) else { return }
        model.setViewMode(mode)
    }
    @objc private func submitPath(_ sender: Any?) {
        activate(); let path = (pathField.stringValue as NSString).expandingTildeInPath
        let base = model.location ?? FileManager.default.homeDirectoryForCurrentUser
        navigate(path.isEmpty ? nil : (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)))
    }
    @objc private func openSelection(_ sender: Any?) {
        activate(); guard let row = table.selectedRowIndexes.first, model.items.indices.contains(row) else { return }
        let item = model.items[row]; if item.isBrowsable { navigate(item.url) } else { NSWorkspace.shared.open(item.url) }
    }
    private func openGridItem(_ item: FileItem) {
        activate(); if item.isBrowsable { navigate(item.url) } else { NSWorkspace.shared.open(item.url) }
    }
    private func updateWatcher() {
        guard watchedURL != model.location else { return }
        watcherTask?.cancel()
        if let watcher { Task.detached { watcher.stop() } }
        watcher = nil; watchedURL = model.location; pendingRefresh = false
        guard let url = model.location else { return }
        watcherTask = Task { [weak self] in
            let watcher = await Task.detached(priority: .utility) { DirectoryWatcher(url: url) }.value
            guard let self, !Task.isCancelled, self.watchedURL == url else {
                if let watcher { Task.detached { watcher.stop() } }
                return
            }
            self.watcher = watcher
            guard let watcher else { return }
            for await _ in watcher.events {
                guard !Task.isCancelled, self.watchedURL == url, self.model.location == url else { return }
                if self.model.isLoading { self.pendingRefresh = true }
                else { self.model.reload() }
            }
        }
    }
    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, model.items.indices.contains(row), model.items[row].isBrowsable { return model.items[row].url }
        return model.location
    }
    private func dropIntent(_ info: any NSDraggingInfo) -> FileDropIntent {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        var modifiers: DropModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return .resolve(modifiers: modifiers, sourceAllowsMove: info.draggingSourceOperationMask.contains(.move))
    }
    #if DEBUG
    func qaGridIntegration() -> (menu: Bool, drop: Bool, source: URL?) {
        (gridView.contextMenu != nil, gridView.qaHasDropHandler, gridView.qaPasteboardURL(at: 0))
    }
    var qaColumnCount: Int { columnView.qaColumnCount }
    func qaSelectColumn(id: String, column: Int = 0) { columnView.qaSelect(id: id, column: column) }
    #endif
}

@MainActor
private final class ActivatingTableView: NSTableView {
    var onActivate: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onActivate?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
}
