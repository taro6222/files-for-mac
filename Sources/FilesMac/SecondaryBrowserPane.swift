import AppKit
import FilesCore

@MainActor
final class SecondaryBrowserPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let refreshImage = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    private static let stopImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    let model: BrowserModel
    private let preferences: BrowserPreferences
    var onActivate: (() -> Void)?
    var onLocationChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onFileDrop: (([URL], URL, FileDropIntent) -> Bool)?
    var onOpenFolderInNewTab: ((URL) -> Void)?
    private let pathField = NSTextField()
    private let table = ActivatingTableView()
    private let scroll = NSScrollView()
    private let gridView = FileGridView()
    private let listView = FileListView()
    private let columnView = FileColumnView()
    private let browserContent = AppBackgroundView()
    private let folderFilter = FolderFilterField()
    private let adaptivePolicy = AdaptiveViewPolicy()
    private var adaptiveResolvedMode: BrowserViewMode = .details
    private var adaptiveWidth: CGFloat = 0
    private var renderedViewMode: BrowserViewMode {
        model.viewMode == .adaptive ? adaptiveResolvedMode : model.viewMode
    }
    private let status = NSTextField(labelWithString: "")
    private let hiddenButton = PaneActionButton()
    private let refreshButton = PaneActionButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let viewModeButton = NSPopUpButton()
    private var watcher: DirectoryWatcher?
    private var watcherTask: Task<Void, Never>?
    private var watchedURL: URL?
    private var pendingRefresh = false
    private var rendering = false
    private var appliedSharedFolderLayout = false
    private var autoFitObservedLoading = false
    private var folderSizeTask: Task<Void, Never>?
    private var pendingEntrySelection: URL?
    private var detailRows: [DetailDisplayRow] = []
    private let dateFormatter: DateFormatter = { let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .short; return value }()

    init(snapshot: TabSnapshot, preferences: BrowserPreferences = .shared, loader: any DirectoryLoading = LocalFileSystem()) {
        model = BrowserModel(loader: loader)
        self.preferences = preferences
        super.init(frame: .zero)
        wantsLayer = true; translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        model.onChange = { [weak self] in self?.modelChanged() }
        model.restore(snapshot)
        if preferences.syncFolderLayouts { applyFolderViewPreference() }
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
    func refresh() {
        activate()
        if model.failure != nil || watcher == nil { updateWatcher(force: true) }
        savePosition()
        model.reload(userInitiated: true)
    }
    func openLocation(_ url: URL) { activate(); navigate(url) }
    func revealSearchResult(_ url: URL, isHidden: Bool) {
        activate()
        model.setNameFilter("")
        if isHidden { model.showHidden = true }
        pendingEntrySelection = url
        navigate(url.deletingLastPathComponent())
    }
    func focusPath() { activate(); window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    func updateSort(field: SortField? = nil, ascending: Bool? = nil,
                    placement: SortDirectoryPlacement? = nil, toggleDirection: Bool = false) {
        activate(); savePosition()
        var order = model.sortOrder
        if let field { order.field = field }
        if let ascending { order.ascending = ascending }
        if let placement { order.directoryPlacement = placement }
        if toggleDirection { order.ascending.toggle() }
        setSort(order)
    }
    private func setSort(_ order: FilesCore.SortOrder) {
        if preferences.syncFolderLayouts { preferences.updateSharedFolderLayout { $0.sort = order } }
        else { model.sort(order) }
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
            case "syncStatus": return item.cloudState.map { cloudStateTitle($0) } ?? "—"
            case "created": return item.created.map(dateFormatter.string) ?? "—"
            case "modified": return item.modified.map(dateFormatter.string) ?? "—"
            case "kind": return item.kind
            case "size": return item.isDirectory && !preferences.calculateFolderSizes ? "—" : item.size.map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
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
    func stopLoading() {
        pendingRefresh = false
        model.cancelLoad()
    }
    func setViewMode(_ mode: BrowserViewMode) { activate(); setViewModeAndPersist(mode) }
    func focusFilter() { window?.makeFirstResponder(folderFilter) }
    func applyPreferences() {
        if preferences.syncFolderLayouts || appliedSharedFolderLayout {
            appliedSharedFolderLayout = preferences.syncFolderLayouts
            applyFolderViewPreference()
        }
        if !preferences.showFilterHeader { model.setNameFilter("") }
        applyBackground(); render()
        if preferences.calculateFolderSizes { startFolderSizeCalculationIfNeeded() } else { folderSizeTask?.cancel(); folderSizeTask = nil }
    }
    func setContextMenu(_ menu: NSMenu?) { gridView.contextMenu = menu; listView.contextMenu = menu; columnView.contextMenu = menu }
    func openSelected() {
        if renderedViewMode == .grid, let item = gridView.selectedItems.first { openGridItem(item) }
        else if renderedViewMode == .list, let item = listView.selectedItems.first { openGridItem(item) }
        else if renderedViewMode == .columns, let item = columnView.selectedItems.first { openGridItem(item) }
        else { openSelection(nil) }
    }
    func open(_ url: URL?) { activate(); navigate(url) }
    func shutdown() {
        folderSizeTask?.cancel()
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
        configure(backButton, symbol: "chevron.left", title: L("뒤로", "Back"), action: #selector(back(_:)))
        configure(forwardButton, symbol: "chevron.right", title: L("앞으로", "Forward"), action: #selector(forward(_:)))
        configure(upButton, symbol: "arrow.up", title: L("상위 폴더", "Enclosing Folder"), action: #selector(up(_:)))
        for button in [backButton, forwardButton, upButton] { toolbar.addArrangedSubview(button) }
        pathField.placeholderString = L("폴더 경로", "Folder path"); pathField.target = self; pathField.action = #selector(submitPath(_:))
        pathField.setAccessibilityLabel(L("보조 pane 경로", "Secondary pane path")); toolbar.addArrangedSubview(pathField)
        configure(refreshButton, symbol: "arrow.clockwise", title: L("새로고침", "Refresh"), action: #selector(reload(_:)))
        refreshButton.image = Self.refreshImage
        toolbar.addArrangedSubview(refreshButton)
        configure(hiddenButton, symbol: "eye.slash", title: L("숨김 항목 전환", "Toggle Hidden Files"), action: #selector(toggleHidden(_:)))
        hiddenButton.setButtonType(.pushOnPushOff)
        toolbar.addArrangedSubview(hiddenButton)
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
        table.setAccessibilityLabel(L("보조 패널 파일 목록", "Secondary pane file list"))
        table.delegate = self; table.dataSource = self; table.onActivate = { [weak self] in self?.activate() }
        table.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
        table.doubleAction = #selector(openSelection(_:)); table.target = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        for (key, title, width) in [("name", L("이름", "Name"), 300.0), ("syncStatus", L("동기화 상태", "Sync Status"), 150.0), ("created", L("생성일", "Date Created"), 200.0), ("modified", L("수정일", "Date Modified"), 185.0), ("kind", L("종류", "Kind"), 120.0), ("size", L("크기", "Size"), 90.0)] {
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
        gridView.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
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
        listView.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
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
        columnView.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
        columnView.onFileDrop = { [weak self] sources, item, columnURL, intent in
            guard let self else { return false }; self.activate()
            return self.onFileDrop?(sources, item?.isBrowsable == true ? item!.url : columnURL, intent) ?? false
        }
        folderFilter.onChange = { [weak self] query in
            self?.activate()
            self?.model.setNameFilter(query)
        }
        stack.addArrangedSubview(folderFilter)
        stack.addArrangedSubview(browserContent)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(); footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        footer.addArrangedSubview(status); footer.addArrangedSubview(NSView()); stack.addArrangedSubview(footer)
        for view in [toolbar, folderFilter, browserContent, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let preferredContentHeight = browserContent.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        preferredContentHeight.priority = .defaultLow
        preferredContentHeight.isActive = true
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
    private func startFolderSizeCalculationIfNeeded() {
        guard folderSizeTask == nil else { return }
        guard preferences.calculateFolderSizes, !model.isLoading, let location = model.location else { return }
        let folders = model.loadedItems.filter(\.isBrowsable).map(\.url)
        guard !folders.isEmpty else { return }
        folderSizeTask = Task { [weak self] in
            let sizes = await FolderSizeCalculator().sizes(of: folders)
            guard !Task.isCancelled else { return }
            self?.model.applyDirectorySizes(sizes, at: location)
            self?.folderSizeTask = nil
        }
    }
    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.title = ""; button.imagePosition = .imageOnly; button.bezelStyle = .texturedRounded
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.target = self; button.action = action
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
    private func navigate(_ url: URL?) {
        folderSizeTask?.cancel(); folderSizeTask = nil
        savePosition(); model.navigate(url); applyFolderViewPreference()
    }
    private var effectiveViewSize: BrowserViewSize {
        preferences.synchronizedFolderLayout?.size
            ?? model.location.flatMap { preferences.folderViewPreference(for: $0)?.size } ?? preferences.viewSize
    }
    private func applyFolderViewPreference() {
        if let layout = preferences.synchronizedFolderLayout {
            appliedSharedFolderLayout = true
            model.applySharedFolderLayout(layout)
            return
        }
        guard let url = model.location, let folder = preferences.folderViewPreference(for: url) else { return }
        model.setViewMode(folder.mode)
    }
    private func setViewModeAndPersist(_ mode: BrowserViewMode) {
        if preferences.syncFolderLayouts {
            preferences.updateSharedFolderLayout { $0.mode = mode }
            return
        }
        model.setViewMode(mode)
        if let location = model.location, let saved = preferences.folderViewPreference(for: location) {
            preferences.setFolderViewPreference(FolderViewPreference(mode: mode, size: saved.size), for: location)
        }
    }
    private func modelChanged() {
        onLocationChange?()
        let autoFitLoadCompleted = autoFitObservedLoading && !model.isLoading
        autoFitObservedLoading = model.isLoading
        render()
        if autoFitLoadCompleted { startFolderSizeCalculationIfNeeded() }
        if autoFitLoadCompleted && preferences.autoSizeColumnsInDetailsLayout && renderedViewMode == .details && !model.items.isEmpty { autoFitColumns() }
        updateWatcher()
        if pendingRefresh && !model.isLoading && !model.wasCancelled {
            pendingRefresh = false
            let location = model.location
            Task { @MainActor [weak self] in
                if let location { self?.requestWatcherRefresh(for: location) }
            }
        }
    }
    private func render() {
        rendering = true
        defer {
            rendering = false
            onSelectionChange?()
        }
        folderFilter.synchronize(with: model, visible: preferences.showFilterHeader)
        pathField.stringValue = model.location?.path ?? ""
        var revealEntry = false
        if let target = pendingEntrySelection, !model.isLoading {
            pendingEntrySelection = nil
            if target.deletingLastPathComponent().standardizedFileURL == model.location,
               model.items.contains(where: { $0.id == target.path }) {
                revealEntry = true; model.savePosition(selection: [target.path], scrollOffset: model.history.current.scrollOffset)
            }
        }
        detailRows = detailDisplayRows(items: model.items, grouping: model.grouping)
        table.tableColumn(withIdentifier: .init("syncStatus"))?.isHidden = !preferences.showSyncStatusColumn
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
        hiddenButton.state = model.showHidden ? .on : .off
        backButton.isEnabled = !model.history.back.isEmpty
        forwardButton.isEnabled = !model.history.forward.isEmpty
        upButton.isEnabled = model.location.map { $0.path != "/" } ?? false
        if let item = viewModeButton.itemArray.first(where: {
            ($0.representedObject as? String) == model.viewMode.rawValue
        }) { viewModeButton.select(item) }
        let expectedSort = NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)
        if table.sortDescriptors.first != expectedSort { table.sortDescriptors = [expectedSort] }
        let selected = detailSelectionRows(ids: model.history.current.selection, in: detailRows)
        table.selectRowIndexes(selected, byExtendingSelection: false)
        gridView.apply(viewSize: effectiveViewSize)
        listView.apply(viewSize: effectiveViewSize)
        gridView.showsThumbnails = preferences.showThumbnails; listView.showsThumbnails = preferences.showThumbnails
        let selection = model.history.current.selection
        let scrollOffset = model.history.current.scrollOffset
        if showsGrid {
            gridView.update(items: model.items, selection: selection, scrollOffset: scrollOffset, grouping: model.grouping)
            if revealEntry { gridView.revealSelection() }
        }
        if showsList {
            listView.update(items: model.items, selection: selection, scrollOffset: scrollOffset, grouping: model.grouping)
            if revealEntry { listView.revealSelection() }
        }
        columnView.showHidden = model.showHidden
        columnView.sortOrder = model.sortOrder
        columnView.showsThumbnails = preferences.showThumbnails
        if showsColumns {
            columnView.update(baseURL: model.location, items: model.items, selection: selection)
        } else {
            columnView.update(baseURL: nil, items: [], selection: [])
        }
        if !model.isLoading {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: model.history.current.scrollOffset)); scroll.reflectScrolledClipView(scroll.contentView)
            if revealEntry, let row = selected.first { table.scrollRowToVisible(row) }
        }
        let refreshTitle = model.isLoading ? L("읽기 중단", "Stop Loading") : L("새로고침", "Refresh")
        if refreshButton.toolTip != refreshTitle {
            refreshButton.image = model.isLoading ? Self.stopImage : Self.refreshImage
            refreshButton.toolTip = refreshTitle
            refreshButton.setAccessibilityLabel(refreshTitle)
        }
        if model.isLoading { status.stringValue = L("읽는 중…", "Loading…") }
        else if let failure = model.failure { status.stringValue = failure.message(korean: Locale.preferredLanguages.first?.hasPrefix("ko") == true) }
        else if model.wasCancelled { status.stringValue = L("읽기를 중단했습니다. 새로고침하세요.", "Loading stopped. Refresh to retry.") }
        else if !model.nameFilter.isEmpty && model.items.isEmpty { status.stringValue = L("일치하는 이름이 없습니다.", "No matching names.") }
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
        case "name": cell.textField?.stringValue = item.displayName(showExtensions: true); cell.imageView?.image = fileIcon(for: item, showsThumbnails: preferences.showThumbnails)
        case "syncStatus":
            let status = cloudStateTitle(item.cloudState)
            cell.textField?.stringValue = item.cloudState == nil ? "—" : status
            cell.toolTip = status
        case "created": cell.textField?.stringValue = item.created.map(dateFormatter.string) ?? "—"
        case "modified": cell.textField?.stringValue = item.modified.map(dateFormatter.string) ?? "—"
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.isDirectory && !preferences.calculateFolderSizes ? "—" : item.size.map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
        default: break
        }
        return cell
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard detailRows.indices.contains(row) else { return false }; if case .header = detailRows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { detailItem(at: row, in: detailRows) != nil }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rendering else { return }
        activate()
        savePosition()
        onSelectionChange?()
    }
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
        guard !rendering, let descriptor = tableView.sortDescriptors.first,
              let field = SortField(rawValue: descriptor.key ?? "") else { return }
        savePosition()
        var order = model.sortOrder
        order.field = field
        order.ascending = descriptor.ascending
        setSort(order)
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
    @objc private func reload(_ sender: Any?) {
        if model.isLoading { activate(); stopLoading() }
        else { refresh() }
    }
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
    private func handleBackgroundDoubleClick() {
        guard preferences.doubleClickToGoUp else { return }
        goUp()
    }
    private func updateWatcher(force: Bool = false) {
        guard force || watchedURL != model.location else { return }
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
                self.requestWatcherRefresh(for: url)
            }
        }
    }
    private func requestWatcherRefresh(for url: URL) {
        guard model.location == url, !model.wasCancelled else { return }
        if model.isLoading { pendingRefresh = true }
        else { model.reload() }
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
    var qaReadControl: (label: String?, status: String) {
        (refreshButton.accessibilityLabel(), status.stringValue)
    }
    func qaPressReadControl() -> Bool { refreshButton.accessibilityPerformPress() }
    func qaSimulateFolderChange(at url: URL) { requestWatcherRefresh(for: url) }

    func qaSubmitFocusedPath(_ url: URL) -> Bool {
        guard pathField.frame.width > 0, let editor = pathField.currentEditor() else { return false }
        editor.string = url.path
        pathField.stringValue = url.path
        submitPath(nil)
        return true
    }

    func qaNavigationAccessibility() -> Bool {
        let labels = [L("뒤로", "Back"), L("앞으로", "Forward"), L("상위 폴더", "Enclosing Folder"),
                      L("새로고침", "Refresh"), L("숨김 항목 전환", "Toggle Hidden Files")]
        let buttons = [backButton, forwardButton, upButton, refreshButton, hiddenButton]
        return zip(buttons, labels).allSatisfy { button, label in
            button.accessibilityLabel() == label && button.toolTip == label && button.accessibilityRole() != nil
        } && table.accessibilityLabel() == L("보조 패널 파일 목록", "Secondary pane file list")
    }
    var qaNavigationEnabled: [Bool] {
        [backButton, forwardButton, upButton].map { $0.isAccessibilityEnabled() }
    }
    func qaPressHiddenAccessibility() -> Bool {
        let previous = model.showHidden
        let previousState: NSControl.StateValue = previous ? .on : .off
        guard hiddenButton.state == previousState, hiddenButton.accessibilityPerformPress() else { return false }
        let toggled = model.showHidden != previous && hiddenButton.state != previousState
        guard hiddenButton.accessibilityPerformPress() else { return false }
        return toggled && model.showHidden == previous && hiddenButton.state == previousState
    }
    func qaEnterFilter(_ query: String) {
        folderFilter.stringValue = query
        folderFilter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: folderFilter))
    }
    func qaGridIntegration() -> (menu: Bool, drop: Bool, source: URL?) {
        (gridView.contextMenu != nil, gridView.qaHasDropHandler, gridView.qaPasteboardURL(at: 0))
    }
    var qaColumnCount: Int { columnView.qaColumnCount }
    func qaSelectColumn(id: String, column: Int = 0) { columnView.qaSelect(id: id, column: column) }
    var qaRenderedViewMode: BrowserViewMode { renderedViewMode }
    var qaGridItemSize: NSSize { gridView.qaItemSize }
    var qaListRowHeight: CGFloat { listView.qaRowHeight }
    var qaColumnIntegration: (ready: Bool, source: URL?) { (columnView.qaHasDropHandler, columnView.qaPasteboardURL()) }
    var qaThumbnailPolicyApplied: Bool { gridView.showsThumbnails == preferences.showThumbnails && listView.showsThumbnails == preferences.showThumbnails && columnView.showsThumbnails == preferences.showThumbnails }
    #endif
}

private final class PaneActionButton: NSButton {
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        performClick(nil)
        return true
    }
}

@MainActor
private final class ActivatingTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onDoubleClickBackground: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.clickCount == 2 && row(at: convert(event.locationInWindow, from: nil)) < 0 {
            deselectAll(nil); onDoubleClickBackground?(); return
        }
        super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
}
