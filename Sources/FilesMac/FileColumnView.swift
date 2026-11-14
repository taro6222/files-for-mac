import AppKit
import FilesCore

@MainActor
final class FileColumnView: NSView {
    @MainActor private final class Table: NSTableView {
        var onActivate: (() -> Void)?
        var onRight: (() -> Void)?
        var onLeft: (() -> Void)?
        var onValidateDrop: ((any NSDraggingInfo, Int) -> NSDragOperation)?
        var onAcceptDrop: ((any NSDraggingInfo, Int) -> Bool)?
        override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
        override func mouseDown(with event: NSEvent) { onActivate?(); super.mouseDown(with: event) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 124 { onRight?(); return }
            if event.keyCode == 123 { onLeft?(); return }
            super.keyDown(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            onActivate?(); let target = row(at: convert(event.locationInWindow, from: nil))
            if target >= 0 && !selectedRowIndexes.contains(target) { selectRowIndexes([target], byExtendingSelection: false) }
            return super.menu(for: event)
        }
    }
    @MainActor private final class Column: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var owner: FileColumnView?
        let url: URL
        var items: [FileItem]
        let table = Table()
        let scroll = NSScrollView()
        let view = NSView()
        var suppress = false
        init(owner: FileColumnView, url: URL, items: [FileItem]) {
            self.owner = owner; self.url = url; self.items = items; super.init()
            view.translatesAutoresizingMaskIntoConstraints = false
            table.headerView = nil; table.rowHeight = 28; table.style = .fullWidth; table.allowsMultipleSelection = true
            table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(open(_:))
            table.onActivate = { [weak self] in self?.owner?.activate(column: self) }
            table.onRight = { [weak self] in self?.owner?.expand(column: self) }
            table.onLeft = { [weak self] in self?.owner?.moveLeft(from: self) }
            table.onValidateDrop = { [weak self] info, row in self?.owner?.validateDrop(info, column: self, row: row) ?? [] }
            table.onAcceptDrop = { [weak self] info, row in self?.owner?.acceptDrop(info, column: self, row: row) ?? false }
            table.registerForDraggedTypes([.fileURL]); table.setDraggingSourceOperationMask([.copy, .move], forLocal: true); table.setDraggingSourceOperationMask(.copy, forLocal: false)
            let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.resizingMask = .autoresizingMask; table.addTableColumn(name)
            scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scroll)
            NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), view.widthAnchor.constraint(equalToConstant: 250)])
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
            (cell.subviews.first { $0.identifier?.rawValue == "arrow" } as? NSTextField)?.stringValue = item.isBrowsable ? "›" : ""
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
    private var customBackgroundEnabled = false
    private var baseURL: URL?
    private var baseIDs: [String] = []
    private var loadGeneration = 0
    var showHidden = false
    var showsThumbnails = true { didSet { if oldValue != showsThumbnails { columns.forEach { $0.table.reloadData() } } } }
    var sortOrder = SortOrder()
    var onSelectionChange: ((Set<String>) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onActivate: (() -> Void)?
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
        guard let baseURL else { reset(); return }
        let ids = items.map(\.id)
        if self.baseURL != baseURL || baseIDs != ids {
            reset(); self.baseURL = baseURL; baseIDs = ids; append(url: baseURL, items: items)
        }
        columns.first?.apply(selection: selection)
        if let first = columns.first, !first.selectedItems.isEmpty { expand(column: first) }
    }
    func focus() { if let table = columns.last?.table { window?.makeFirstResponder(table) } }
    func applyBackground(enabled: Bool) {
        customBackgroundEnabled = enabled; scroll.drawsBackground = !enabled
        for column in columns { column.scroll.drawsBackground = !enabled; column.table.backgroundColor = enabled ? .clear : .controlBackgroundColor }
    }
    private func reset() { loadGeneration += 1; columns.removeAll(); stack.arrangedSubviews.forEach { $0.removeFromSuperview() }; baseURL = nil; baseIDs = [] }
    private func append(url: URL, items: [FileItem]) {
        let column = Column(owner: self, url: url, items: sortOrder.sorted(items)); column.table.menu = contextMenu
        column.scroll.drawsBackground = !customBackgroundEnabled
        column.table.backgroundColor = customBackgroundEnabled ? .clear : .controlBackgroundColor
        columns.append(column); stack.addArrangedSubview(column.view)
        DispatchQueue.main.async { [weak self] in self?.scrollToEnd() }
    }
    private func scrollToEnd() { document.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: NSPoint(x: max(0, document.bounds.width - scroll.contentView.bounds.width), y: 0)); scroll.reflectScrolledClipView(scroll.contentView) }
    private func activate(column: Column?) { onActivate?() }
    private func selectionChanged(column: Column) {
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
                guard let self, self.loadGeneration == generation, column.selectedItems.first?.id == item.id else { return }
                self.removeColumns(after: index); self.append(url: item.url, items: loaded)
            } catch { }
        }
    }
    private func moveLeft(from column: Column?) {
        guard let column, let index = columns.firstIndex(where: { $0 === column }), index > 0 else { return }
        removeColumns(after: index - 1); window?.makeFirstResponder(columns[index - 1].table)
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
