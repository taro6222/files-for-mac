import AppKit
import FilesCore

@MainActor
final class SecondaryBrowserPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let model: BrowserModel
    private let preferences: BrowserPreferences
    var onActivate: (() -> Void)?
    var onFileDrop: (([URL], URL, FileDropIntent) -> Bool)?
    var onOpenFolderInNewTab: ((URL) -> Void)?
    private let pathField = NSTextField()
    private let table = ActivatingTableView()
    private let scroll = NSScrollView()
    private let gridView = FileGridView()
    private let listView = FileListView()
    private let columnView = FileColumnView()
    private let browserContent = AppBackgroundView()
    private let adaptivePolicy = AdaptiveViewPolicy()
    private var adaptiveResolvedMode: BrowserViewMode = .details
    private var adaptiveWidth: CGFloat = 0
    private var renderedViewMode: BrowserViewMode {
        model.viewMode == .adaptive ? adaptiveResolvedMode : model.viewMode
    }
    private let status = NSTextField(labelWithString: "")
    private let hiddenButton = NSButton()
    private let viewModeButton = NSPopUpButton()
    private var watcher: DirectoryWatcher?
    private var watcherTask: Task<Void, Never>?
    private var watchedURL: URL?
    private var pendingRefresh = false
    private var rendering = false
    private var autoFitObservedLoading = false
    private var pendingEntrySelection: URL?
    private var detailRows: [DetailDisplayRow] = []
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .short; return value }()

    init(snapshot: TabSnapshot, preferences: BrowserPreferences = .shared) {
        model = BrowserModel()
        self.preferences = preferences
        super.init(frame: .zero)
        wantsLayer = true; translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        model.onChange = { [weak self] in self?.modelChanged() }
        model.restore(snapshot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard model.viewMode == .adaptive, !model.isLoading, !rendering,
              abs(bounds.width - adaptiveWidth) >= 1 else { return }
        adaptiveWidth = bounds.width; render()
    }

    func snapshot() -> TabSnapshot { savePosition(); return model.snapshot }
    var selectedItems: [FileItem] {
        if renderedViewMode == .grid { return gridView.selectedItems }
        if renderedViewMode == .list { return listView.selectedItems }
        if renderedViewMode == .columns { return columnView.selectedItems }
        return table.selectedRowIndexes.compactMap { detailItem(at: $0, in: detailRows) }
    }
    func setActive(_ active: Bool) {
        layer?.borderWidth = active ? 2 : 0; layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    func goBack() { activate(); savePosition(); model.back(); applyFolderViewPreference() }
    func goForward() { activate(); savePosition(); model.forward(); applyFolderViewPreference() }
    func goUp() {
        activate()
        if let location = model.location {
            if preferences.scrollToPreviousFolderOnUp { pendingEntrySelection = location.standardizedFileURL }
            navigate(location.deletingLastPathComponent())
        }
    }
    func refresh() { activate(); savePosition(); model.reload() }
    func openLocation(_ url: URL) { activate(); navigate(url) }
    func focusPath() { activate(); window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    func updateSort(field: SortField? = nil, ascending: Bool? = nil,
                    placement: SortDirectoryPlacement? = nil, toggleDirection: Bool = false) {
        activate(); savePosition()
        var order = model.sortOrder
        if let field { order.field = field }
        if let ascending { order.ascending = ascending }
        if let placement { order.directoryPlacement = placement }
        if toggleDirection { order.ascending.toggle() }
        model.sort(order)
    }
    func clearSelection() {
        activate()
        switch renderedViewMode {
        case .grid: gridView.replaceSelection(with: [])
        case .list: listView.replaceSelection(with: [])
        case .columns: columnView.replaceSelection(with: [])
        default: table.deselectAll(nil)
        }
    }
    func invertSelection() {
        activate()
        switch renderedViewMode {
        case .grid: gridView.invertSelection()
        case .list: listView.invertSelection()
        case .columns: columnView.invertSelection()
        default:
            let itemRows = IndexSet(detailRows.indices.filter { detailItem(at: $0, in: detailRows) != nil })
            let inverted = itemRows.subtracting(table.selectedRowIndexes)
            table.selectRowIndexes(inverted, byExtendingSelection: false)
        }
    }
    func toggleFocusedSelection() {
        guard let item = selectedItems.first else { return }
        var ids = Set(selectedItems.map(\.id)); ids.remove(item.id)
        switch renderedViewMode {
        case .grid: gridView.replaceSelection(with: ids)
        case .list: listView.replaceSelection(with: ids)
        case .columns: columnView.replaceSelection(with: ids)
        default: table.selectRowIndexes(detailSelectionRows(ids: ids, in: detailRows), byExtendingSelection: false)
        }
    }
    var canAutoFitColumns: Bool { renderedViewMode == .details && !model.items.isEmpty }
    func autoFitColumns() {
        guard canAutoFitColumns else { return }
        fitDetailColumns(in: table, rowCount: model.items.count) { [self] identifier, row in
            let item = model.items[row]
            switch identifier.rawValue {
            case "name": return item.displayName(showExtensions: true)
            case "created": return item.created.map(dateFormatter.string) ?? "—"
            case "modified": return item.modified.map(dateFormatter.string) ?? "—"
            case "kind": return item.kind
            case "size": return item.isDirectory ? "—" : item.size.map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
            default: return ""
            }
        }
    }
    func focusFiles() {
        activate()
        if renderedViewMode == .grid { gridView.focus() }
        else if renderedViewMode == .list { listView.focus() }
        else if renderedViewMode == .columns { columnView.focus() }
        else { window?.makeFirstResponder(table) }
    }
    func stopLoading() { model.cancelLoad() }
    func setViewMode(_ mode: BrowserViewMode) { activate(); setViewModeAndPersist(mode) }
    func applyPreferences() { applyBackground(); render() }
    func setContextMenu(_ menu: NSMenu?) { gridView.contextMenu = menu; listView.contextMenu = menu; columnView.contextMenu = menu }
    func openSelected() {
        if renderedViewMode == .grid, let item = gridView.selectedItems.first { openGridItem(item) }
        else if renderedViewMode == .list, let item = listView.selectedItems.first { openGridItem(item) }
        else if renderedViewMode == .columns, let item = columnView.selectedItems.first { openGridItem(item) }
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
        for (key, title, width) in [("name", L("이름", "Name"), 300.0), ("created", L("생성일", "Date Created"), 200.0), ("modified", L("수정일", "Date Modified"), 185.0), ("kind", L("종류", "Kind"), 120.0), ("size", L("크기", "Size"), 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true); table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)]
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        browserContent.translatesAutoresizingMaskIntoConstraints = false
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
            guard let self, !self.rendering, self.renderedViewMode == .grid else { return }
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
            guard let self, !self.rendering, self.renderedViewMode == .list else { return }
            self.model.savePosition(selection: selection, scrollOffset: self.listView.currentScrollOffset()); self.render()
        }
        listView.onActivate = { [weak self] in self?.activate() }
        listView.onOpen = { [weak self] item in self?.openGridItem(item) }
        listView.onFileDrop = { [weak self] sources, item, intent in
            guard let self, let destination = item?.isBrowsable == true ? item?.url : self.model.location else { return false }
            self.activate(); return self.onFileDrop?(sources, destination, intent) ?? false
        }
        columnView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.renderedViewMode == .columns else { return }
            self.model.savePosition(selection: selection, scrollOffset: 0); self.render()
        }
        columnView.onActivate = { [weak self] in self?.activate() }
        columnView.onOpen = { [weak self] item in self?.openGridItem(item) }
        columnView.onFileDrop = { [weak self] sources, item, columnURL, intent in
            guard let self else { return false }; self.activate()
            return self.onFileDrop?(sources, item?.isBrowsable == true ? item!.url : columnURL, intent) ?? false
        }
        stack.addArrangedSubview(browserContent)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(); footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        footer.addArrangedSubview(status); footer.addArrangedSubview(NSView()); stack.addArrangedSubview(footer)
        for view in [toolbar, browserContent, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        browserContent.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        applyBackground()
    }
    private func applyBackground() {
        browserContent.setPresentation(fit: preferences.appBackgroundFit, opacity: preferences.appBackgroundOpacity,
                                       horizontal: preferences.appBackgroundHorizontalAlignment, vertical: preferences.appBackgroundVerticalAlignment)
        _ = browserContent.setImage(at: preferences.appBackgroundPath)
        let enabled = browserContent.image != nil
        scroll.drawsBackground = !enabled; table.backgroundColor = enabled ? .clear : .controlBackgroundColor
        gridView.applyBackground(enabled: enabled); listView.applyBackground(enabled: enabled); columnView.applyBackground(enabled: enabled)
    }
    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(); button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.title = ""; button.imagePosition = .imageOnly; button.bezelStyle = .texturedRounded; button.target = self; button.action = action; return button
    }
    private func activate() { onActivate?() }
    private func savePosition() {
        guard !rendering else { return }
        let selection: Set<String>; let offset: Double
        switch renderedViewMode {
        case .grid: selection = Set(gridView.selectedItems.map(\.id)); offset = gridView.currentScrollOffset()
        case .list: selection = Set(listView.selectedItems.map(\.id)); offset = listView.currentScrollOffset()
        case .columns: selection = Set(columnView.selectedItems.map(\.id)); offset = 0
        default: selection = Set(table.selectedRowIndexes.compactMap { detailItem(at: $0, in: detailRows)?.id }); offset = scroll.contentView.bounds.origin.y
        }
        model.savePosition(selection: selection, scrollOffset: offset)
    }
    private func navigate(_ url: URL?) { savePosition(); model.navigate(url); applyFolderViewPreference() }
    private var effectiveViewSize: BrowserViewSize {
        model.location.flatMap { preferences.folderViewPreference(for: $0)?.size } ?? preferences.viewSize
    }
    private func applyFolderViewPreference() {
        guard let url = model.location, let folder = preferences.folderViewPreference(for: url) else { return }
        model.setViewMode(folder.mode)
    }
    private func setViewModeAndPersist(_ mode: BrowserViewMode) {
        model.setViewMode(mode)
        if let location = model.location, let saved = preferences.folderViewPreference(for: location) {
            preferences.setFolderViewPreference(FolderViewPreference(mode: mode, size: saved.size), for: location)
        }
    }
    private func modelChanged() {
        let autoFitLoadCompleted = autoFitObservedLoading && !model.isLoading
        autoFitObservedLoading = model.isLoading
        render()
        if autoFitLoadCompleted && preferences.autoSizeColumnsInDetailsLayout && renderedViewMode == .details && !model.items.isEmpty { autoFitColumns() }
        updateWatcher()
        if pendingRefresh && !model.isLoading && !model.wasCancelled {
            pendingRefresh = false
            Task { @MainActor [weak self] in self?.model.reload() }
        }
    }
    private func render() {
        rendering = true; defer { rendering = false }
        pathField.stringValue = model.location?.path ?? ""
        var revealEntry = false
        if let target = pendingEntrySelection, !model.isLoading {
            pendingEntrySelection = nil
            if target.deletingLastPathComponent().standardizedFileURL == model.location {
                revealEntry = true; model.savePosition(selection: [target.path], scrollOffset: model.history.current.scrollOffset)
            }
        }
        detailRows = detailDisplayRows(items: model.items, grouping: model.grouping)
        table.tableColumn(withIdentifier: .init("created"))?.isHidden = !preferences.showCreatedColumn
        table.tableColumn(withIdentifier: .init("modified"))?.isHidden = !preferences.showDateColumn
        table.reloadData()
        if model.viewMode == .adaptive && !model.isLoading {
            adaptiveResolvedMode = adaptivePolicy.resolve(items: model.items, availableWidth: bounds.width)
            adaptiveWidth = bounds.width
        }
        let showsGrid = renderedViewMode == .grid
        let showsList = renderedViewMode == .list
        let showsColumns = renderedViewMode == .columns
        scroll.isHidden = showsGrid || showsList || showsColumns; gridView.isHidden = !showsGrid; listView.isHidden = !showsList; columnView.isHidden = !showsColumns
        hiddenButton.contentTintColor = model.showHidden ? .systemBlue : .labelColor
        if let item = viewModeButton.itemArray.first(where: {
            ($0.representedObject as? String) == model.viewMode.rawValue
        }) { viewModeButton.select(item) }
        let expectedSort = NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)
        if table.sortDescriptors.first != expectedSort { table.sortDescriptors = [expectedSort] }
        let selected = detailSelectionRows(ids: model.history.current.selection, in: detailRows)
        table.selectRowIndexes(selected, byExtendingSelection: false)
        gridView.apply(viewSize: effectiveViewSize)
        listView.apply(viewSize: effectiveViewSize)
        gridView.update(items: model.items, selection: model.history.current.selection,
                        scrollOffset: model.history.current.scrollOffset, grouping: model.grouping)
        listView.update(items: model.items, selection: model.history.current.selection,
                        scrollOffset: model.history.current.scrollOffset, grouping: model.grouping)
        columnView.showHidden = model.showHidden; columnView.sortOrder = model.sortOrder
        columnView.update(baseURL: model.location, items: model.items, selection: model.history.current.selection)
        if !model.isLoading {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: model.history.current.scrollOffset)); scroll.reflectScrolledClipView(scroll.contentView)
            if revealEntry, let row = selected.first { table.scrollRowToVisible(row) }
        }
        if model.isLoading { status.stringValue = L("읽는 중…", "Loading…") }
        else if let failure = model.failure { status.stringValue = failure.message(korean: Locale.preferredLanguages.first?.hasPrefix("ko") == true) }
        else { status.stringValue = L("\(model.items.count)개 항목", "\(model.items.count) items") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { detailRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard detailRows.indices.contains(row), let tableColumn else { return nil }
        let id = tableColumn.identifier
        if case let .header(title) = detailRows[row] {
            guard id.rawValue == "name" else { return nil }
            let headerID = NSUserInterfaceItemIdentifier("SecondaryDetailGroupHeader")
            let label = tableView.makeView(withIdentifier: headerID, owner: self) as? NSTextField ?? { let label = NSTextField(labelWithString: ""); label.identifier = headerID; label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold); label.textColor = .secondaryLabelColor; return label }()
            label.stringValue = title; label.setAccessibilityLabel(title); return label
        }
        guard let item = detailItem(at: row, in: detailRows) else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        switch id.rawValue {
        case "name": cell.textField?.stringValue = item.displayName(showExtensions: true)
        case "created": cell.textField?.stringValue = item.created.map(dateFormatter.string) ?? "—"
        case "modified": cell.textField?.stringValue = item.modified.map(dateFormatter.string) ?? "—"
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.isDirectory ? "—" : item.size.map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
        default: break
        }
        return cell
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard detailRows.indices.contains(row) else { return false }; if case .header = detailRows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { detailItem(at: row, in: detailRows) != nil }
    func tableViewSelectionDidChange(_ notification: Notification) { activate(); savePosition() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let item = detailItem(at: row, in: detailRows) else { return nil }
        return item.url as NSURL
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
        savePosition(); var order = model.sortOrder; order.field = field; order.ascending = descriptor.ascending; model.sort(order)
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
        setViewModeAndPersist(mode)
    }
    @objc private func submitPath(_ sender: Any?) {
        activate(); let path = (pathField.stringValue as NSString).expandingTildeInPath
        let base = model.location ?? FileManager.default.homeDirectoryForCurrentUser
        navigate(path.isEmpty ? nil : (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)))
    }
    @objc private func openSelection(_ sender: Any?) {
        activate(); guard let row = table.selectedRowIndexes.first, let item = detailItem(at: row, in: detailRows) else { return }
        if item.isBrowsable && preferences.openFoldersInNewTab { onOpenFolderInNewTab?(item.url) } else if item.isBrowsable { navigate(item.url) } else { NSWorkspace.shared.open(item.url) }
    }
    private func openGridItem(_ item: FileItem) {
        activate(); if item.isBrowsable && preferences.openFoldersInNewTab { onOpenFolderInNewTab?(item.url) } else if item.isBrowsable { navigate(item.url) } else { NSWorkspace.shared.open(item.url) }
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
        if operation == .on, let item = detailItem(at: row, in: detailRows), item.isBrowsable { return item.url }
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
    var qaRenderedViewMode: BrowserViewMode { renderedViewMode }
    var qaGridItemSize: NSSize { gridView.qaItemSize }
    var qaListRowHeight: CGFloat { listView.qaRowHeight }
    var qaColumnIntegration: (ready: Bool, source: URL?) { (columnView.qaHasDropHandler, columnView.qaPasteboardURL()) }
    #endif
}

@MainActor
private final class ActivatingTableView: NSTableView {
    var onActivate: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onActivate?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
}
