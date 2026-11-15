import AppKit
import FilesCore

@MainActor
final class FileColumnView: NSView {
    @MainActor private final class Table: NSTableView {
        var onActivate: (() -> Void)?
        var onRight: (() -> Void)?
        var onLeft: (() -> Void)?
        var onDoubleClickBackground: (() -> Void)?
        var onValidateDrop: ((any NSDraggingInfo, Int) -> NSDragOperation)?
        var onAcceptDrop: ((any NSDraggingInfo, Int) -> Bool)?
        override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
        override func mouseDown(with event: NSEvent) {
            onActivate?()
            if event.clickCount == 2 && row(at: convert(event.locationInWindow, from: nil)) < 0 {
                deselectAll(nil); onDoubleClickBackground?(); return
            }
            super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 124 { onRight?(); return }
            if event.keyCode == 123 { onLeft?(); return }
            super.keyDown(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard menu != nil else { return nil }
            onActivate?(); let target = row(at: convert(event.locationInWindow, from: nil))
            if target >= 0 && !selectedRowIndexes.contains(target) { selectRowIndexes([target], byExtendingSelection: false) }
            return super.menu(for: event)
        }
    }
    @MainActor private final class Column: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var owner: FileColumnView?
        let url: URL
        let pathChildID: String?
        var items: [FileItem]
        let table = Table()
        let scroll = NSScrollView()
        let view = NSView()
        var suppress = false
        init(owner: FileColumnView, url: URL, items: [FileItem], pathChildID: String?) {
            self.owner = owner; self.url = url; self.items = items; self.pathChildID = pathChildID; super.init()
            view.translatesAutoresizingMaskIntoConstraints = false
            table.headerView = nil; table.rowHeight = 28; table.style = .fullWidth; table.allowsMultipleSelection = true
            table.setAccessibilityLabel(url.path == "/" ? L("루트 폴더", "Root folder") : url.lastPathComponent)
            table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(open(_:))
            table.onActivate = { [weak self] in self?.owner?.activate(column: self) }
            table.onRight = { [weak self] in self?.owner?.expand(column: self) }
            table.onLeft = { [weak self] in self?.owner?.moveLeft(from: self) }
            table.onDoubleClickBackground = { [weak self] in self?.owner?.onDoubleClickBackground?() }
            table.onValidateDrop = { [weak self] info, row in self?.owner?.validateDrop(info, column: self, row: row) ?? [] }
            table.onAcceptDrop = { [weak self] info, row in self?.owner?.acceptDrop(info, column: self, row: row) ?? false }
            table.registerForDraggedTypes([.fileURL]); table.setDraggingSourceOperationMask([.copy, .move], forLocal: true); table.setDraggingSourceOperationMask(.copy, forLocal: false)
            let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.resizingMask = .autoresizingMask; table.addTableColumn(name)
            scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: view.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                view.widthAnchor.constraint(equalToConstant: 230)
            ])
        }
        var selectedItems: [FileItem] { table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil } }
        func apply(selection: Set<String>) {
            suppress = true; table.reloadData(); table.selectRowIndexes(IndexSet(items.indices.filter { selection.contains(items[$0].id) }), byExtendingSelection: false)
            DispatchQueue.main.async { [weak self] in self?.suppress = false }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("ColumnCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView(); cell.identifier = id
                let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
                let label = NSTextField(labelWithString: ""); label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingMiddle
                let arrow = NSTextField(labelWithString: "›"); arrow.translatesAutoresizingMaskIntoConstraints = false; arrow.textColor = .secondaryLabelColor
                cell.addSubview(icon); cell.addSubview(label); cell.addSubview(arrow); cell.imageView = icon; cell.textField = label
                arrow.identifier = NSUserInterfaceItemIdentifier("arrow")
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), arrow.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4), arrow.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), arrow.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                return cell
            }()
            let item = items[row]; cell.imageView?.image = fileIcon(for: item, showsThumbnails: owner?.showsThumbnails ?? true); cell.textField?.stringValue = item.name
            let isPathChild = item.id == pathChildID
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isPathChild ? .semibold : .regular)
            if let arrow = cell.subviews.first(where: { $0.identifier?.rawValue == "arrow" }) as? NSTextField {
                arrow.stringValue = item.isBrowsable || isPathChild ? "›" : ""
                arrow.textColor = isPathChild ? .controlAccentColor : .secondaryLabelColor
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppress else { return }; owner?.selectionChanged(column: self)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row) else { return nil }; return items[row].url as NSURL
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            owner?.validateDrop(info, column: self, row: operation == .on ? row : -1) ?? []
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            owner?.acceptDrop(info, column: self, row: operation == .on ? row : -1) ?? false
        }
        @objc private func open(_ sender: Any?) { owner?.open(column: self) }
    }

    private let scroll = NSScrollView()
    private let document = NSView()
    private let stack = NSStackView()
    private var columns: [Column] = []
    private var ancestors: [Column] = []
    private var ancestorTask: Task<Void, Never>?
    private var focusBaseAfterNavigation = false
    private var customBackgroundEnabled = false
    private var baseURL: URL?
    private var baseIDs: [String] = []
    private var loadGeneration = 0
    var showHidden = false { didSet { if oldValue != showHidden { reloadAncestors() } } }
    var showsThumbnails = true { didSet { if oldValue != showsThumbnails { (ancestors + columns).forEach { $0.table.reloadData() } } } }
    var sortOrder = SortOrder() {
        didSet {
            guard oldValue != sortOrder else { return }
            for column in ancestors {
                let selection = Set(column.selectedItems.map(\.id))
                column.items = sortOrder.sorted(column.items)
                column.apply(selection: selection)
            }
        }
    }
    var onSelectionChange: ((Set<String>) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onDoubleClickBackground: (() -> Void)?
    var onActivate: (() -> Void)?
    var onSelectAncestor: ((URL, URL) -> Void)?
    var onFileDrop: (([URL], FileItem?, URL, FileDropIntent) -> Bool)?
    var contextMenu: NSMenu? { didSet { columns.forEach { $0.table.menu = contextMenu } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false; stack.orientation = .horizontal; stack.spacing = 1; stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); scroll.documentView = document; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor), document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor), stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor), stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)])
        setAccessibilityLabel(L("컬럼 파일 보기", "Column file view"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var selectedItems: [FileItem] { columns.reversed().first(where: { !$0.selectedItems.isEmpty })?.selectedItems ?? [] }
    func replaceSelection(with ids: Set<String>) {
        guard let column = columns.reversed().first(where: { !$0.selectedItems.isEmpty }) ?? columns.last else { return }
        column.apply(selection: ids); selectionChanged(column: column)
    }
    func invertSelection() {
        guard let column = columns.reversed().first(where: { !$0.selectedItems.isEmpty }) ?? columns.last else { return }
        replaceSelection(with: Set(column.items.map(\.id)).subtracting(column.selectedItems.map(\.id)))
    }
    func update(baseURL: URL?, items: [FileItem], selection: Set<String>) {
        guard let baseURL else {
            if self.baseURL != nil { reset() }
            focusBaseAfterNavigation = false
            return
        }
        let ids = items.map(\.id)
        if self.baseURL != baseURL {
            reset(); self.baseURL = baseURL; baseIDs = ids; append(url: baseURL, sortedItems: items)
            reloadAncestors()
            if focusBaseAfterNavigation {
                focusBaseAfterNavigation = false
                window?.makeFirstResponder(columns.first?.table)
            }
        } else if baseIDs != ids {
            loadGeneration += 1
            removeColumns(after: 0)
            baseIDs = ids
        }
        columns.first?.items = items
        columns.first?.apply(selection: selection)
        if let first = columns.first, !first.selectedItems.isEmpty { expand(column: first) }
    }
    func focus() { if let table = columns.last?.table { window?.makeFirstResponder(table) } }
    func applyBackground(enabled: Bool) {
        customBackgroundEnabled = enabled; scroll.drawsBackground = !enabled
        for column in ancestors + columns { column.scroll.drawsBackground = !enabled; column.table.backgroundColor = enabled ? .clear : .controlBackgroundColor }
    }
    private func reset() {
        loadGeneration += 1
        ancestorTask?.cancel(); ancestorTask = nil
        columns.removeAll(); ancestors.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        baseURL = nil; baseIDs = []
    }
    private func reloadAncestors() {
        ancestorTask?.cancel(); ancestorTask = nil
        ancestors.forEach { $0.view.removeFromSuperview() }
        ancestors.removeAll()
        guard let baseURL else { return }
        let showHidden = showHidden
        ancestorTask = Task { [weak self] in
            let listings = await Self.loadAncestors(of: baseURL, showHidden: showHidden)
            guard let self, !Task.isCancelled, self.baseURL == baseURL else { return }
            ancestorTask = nil
            for listing in listings.reversed() {
                let column = makeColumn(url: listing.url, sortedItems: sortOrder.sorted(listing.items), pathChildID: listing.child.path)
                stack.insertArrangedSubview(column.view, at: ancestors.count)
                ancestors.append(column)
                column.apply(selection: [listing.child.path])
            }
            scrollToEnd()
        }
    }

    nonisolated private static func loadAncestors(of baseURL: URL, showHidden: Bool)
        async -> [(url: URL, child: URL, items: [FileItem])] {
        let base = baseURL.standardizedFileURL
        let volumePath = (try? base.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path
        // APFS firmlinks can expose the data volume through paths rooted at `/`.
        let root = volumePath.flatMap { base.path == $0 || base.path.hasPrefix($0 + "/") ? $0 : nil } ?? "/"
        let filesystem = LocalFileSystem()
        var child = base
        var listings: [(url: URL, child: URL, items: [FileItem])] = []
        while child.path != root && !Task.isCancelled {
            let parent = child.deletingLastPathComponent()
            guard parent.path != child.path, !parent.path.isEmpty,
                  let items = try? await filesystem.contents(of: parent, showHidden: true),
                  items.contains(where: { $0.id == child.path }) else { break }
            listings.append((parent, child, items.filter { showHidden || !$0.isHidden || $0.id == child.path }))
            child = parent
        }
        return listings
    }
    private func makeColumn(url: URL, sortedItems: [FileItem], pathChildID: String? = nil) -> Column {
        let column = Column(owner: self, url: url, items: sortedItems, pathChildID: pathChildID)
        column.scroll.drawsBackground = !customBackgroundEnabled
        column.table.backgroundColor = customBackgroundEnabled ? .clear : .controlBackgroundColor
        return column
    }
    private func append(url: URL, sortedItems: [FileItem]) {
        let column = makeColumn(url: url, sortedItems: sortedItems); column.table.menu = contextMenu
        columns.append(column); stack.addArrangedSubview(column.view)
        DispatchQueue.main.async { [weak self] in self?.scrollToEnd() }
    }
    private func scrollToEnd() { document.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: NSPoint(x: max(0, document.bounds.width - scroll.contentView.bounds.width), y: 0)); scroll.reflectScrolledClipView(scroll.contentView) }
    private func activate(column: Column?) { onActivate?() }
    private func selectionChanged(column: Column) {
        if ancestors.contains(where: { $0 === column }) {
            if let selected = column.selectedItems.first { selectAncestor(column, item: selected.url) }
            return
        }
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        removeColumns(after: index); onSelectionChange?(Set(column.selectedItems.map(\.id)))
        expand(column: column)
    }
    private func open(column: Column?) {
        guard let item = column?.selectedItems.first else { return }
        onOpen?(item)
    }
    private func expand(column: Column?) {
        guard let column, let item = column.selectedItems.first, let index = columns.firstIndex(where: { $0 === column }) else { return }
        guard item.isBrowsable else { return }
        if columns.indices.contains(index + 1), columns[index + 1].url == item.url { return }
        let generation = loadGeneration + 1; loadGeneration = generation
        Task { [weak self] in
            do {
                let loaded = try await LocalFileSystem().contents(of: item.url, showHidden: self?.showHidden ?? false)
                guard let self, self.loadGeneration == generation, self.columns.indices.contains(index),
                      self.columns[index] === column, column.selectedItems.first?.id == item.id else { return }
                self.removeColumns(after: index); self.append(url: item.url, sortedItems: self.sortOrder.sorted(loaded))
            } catch { }
        }
    }
    private func moveLeft(from column: Column?) {
        guard let column, let index = columns.firstIndex(where: { $0 === column }) else { return }
        if index == 0 {
            if let parent = ancestors.last { selectAncestor(parent, item: column.url) }
            return
        }
        removeColumns(after: index - 1); window?.makeFirstResponder(columns[index - 1].table)
    }
    private func selectAncestor(_ column: Column, item: URL) {
        focusBaseAfterNavigation = window?.firstResponder is Table
        onSelectAncestor?(column.url, item)
    }
    private func removeColumns(after index: Int) {
        guard index + 1 < columns.count else { return }
        for column in columns[(index + 1)...] { column.view.removeFromSuperview() }
        columns.removeSubrange((index + 1)...)
    }
    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    private func dropIntent(_ info: any NSDraggingInfo) -> FileDropIntent {
        let flags = NSApp.currentEvent?.modifierFlags ?? []; var modifiers: DropModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }; if flags.contains(.command) { modifiers.insert(.command) }
        return .resolve(modifiers: modifiers, sourceAllowsMove: info.draggingSourceOperationMask.contains(.move))
    }
    private func validateDrop(_ info: any NSDraggingInfo, column: Column?, row: Int) -> NSDragOperation {
        guard let column, !draggedURLs(info).isEmpty else { return [] }
        if row >= 0, column.items.indices.contains(row), !column.items[row].isBrowsable { return [] }
        return dropIntent(info) == .move ? .move : .copy
    }
    private func acceptDrop(_ info: any NSDraggingInfo, column: Column?, row: Int) -> Bool {
        guard let column else { return false }; let urls = draggedURLs(info); guard !urls.isEmpty else { return false }
        let item = row >= 0 && column.items.indices.contains(row) ? column.items[row] : nil
        return onFileDrop?(urls, item, column.url, dropIntent(info)) ?? false
    }

#if DEBUG
    var qaColumnCount: Int { columns.count }
    var qaParentColumnURL: URL? { ancestors.last?.url }
    var qaParentSelection: [String] { ancestors.last?.selectedItems.map(\.id) ?? [] }
    func qaMoveLeftFromBase() { moveLeft(from: columns.first) }
    func qaSelect(id: String, column index: Int = 0) {
        guard columns.indices.contains(index), let row = columns[index].items.firstIndex(where: { $0.id == id }) else { return }
        columns[index].suppress = false
        columns[index].table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    func qaMoveLeft() { moveLeft(from: columns.last) }
    var qaHasDropHandler: Bool { onFileDrop != nil && contextMenu != nil }
    func qaPasteboardURL(column index: Int = 0, row: Int = 0) -> URL? {
        guard columns.indices.contains(index) else { return nil }
        return (columns[index].tableView(columns[index].table, pasteboardWriterForRow: row) as? NSURL) as URL?
    }
#endif
}
