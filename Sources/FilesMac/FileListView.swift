import AppKit
import FilesCore

@MainActor
final class FileListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum DisplayRow {
        case header(String)
        case item(FileItem)
    }
    private final class Row: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            guard selectionHighlightStyle != .none else { return }
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
    private final class Table: NSTableView {
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
        override func menu(for event: NSEvent) -> NSMenu? {
            onActivate?()
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
            return super.menu(for: event)
        }
    }

    private let table = Table()
    private let scroll = NSScrollView()
    private(set) var items: [FileItem] = []
    private var rows: [DisplayRow] = []
    private var groupTitles: [String] = []
    private var suppressSelectionNotification = false
    private var viewSize: BrowserViewSize = .medium
    var showsThumbnails = true { didSet { if oldValue != showsThumbnails { table.reloadData() } } }
    var onSelectionChange: ((Set<String>) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onDoubleClickBackground: (() -> Void)? { didSet { table.onDoubleClickBackground = onDoubleClickBackground } }
    var onActivate: (() -> Void)?
    var onFileDrop: (([URL], FileItem?, FileDropIntent) -> Bool)?
    var contextMenu: NSMenu? { get { table.menu } set { table.menu = newValue } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil; table.rowHeight = 30; table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelection(_:))
        table.onActivate = { [weak self] in self?.onActivate?() }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.setAccessibilityLabel(L("파일 목록 보기", "File list view"))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func item(at row: Int) -> FileItem? {
        guard rows.indices.contains(row), case let .item(item) = rows[row] else { return nil }
        return item
    }
    var selectedItems: [FileItem] { table.selectedRowIndexes.compactMap(item(at:)) }
    func replaceSelection(with ids: Set<String>) {
        suppressSelectionNotification = true
        table.selectRowIndexes(IndexSet(rows.indices.filter { item(at: $0).map { ids.contains($0.id) } == true }), byExtendingSelection: false)
        suppressSelectionNotification = false
        onSelectionChange?(Set(selectedItems.map(\.id)))
    }
    func invertSelection() { replaceSelection(with: Set(items.map(\.id)).subtracting(selectedItems.map(\.id))) }
    func update(items: [FileItem], selection: Set<String>, scrollOffset: Double, grouping: FileGroupOptions = FileGroupOptions()) {
        suppressSelectionNotification = true; self.items = items
        let groups = FileGrouping.groups(items, options: grouping)
        groupTitles = grouping.field == .none ? [] : groups.map { fileGroupTitle($0.key, field: grouping.field) }
        rows = grouping.field == .none ? items.map(DisplayRow.item) : groups.flatMap { group in
            [DisplayRow.header(fileGroupTitle(group.key, field: grouping.field))] + group.items.map(DisplayRow.item)
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { item(at: $0).map { selection.contains($0.id) } == true }), byExtendingSelection: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scrollOffset))); scroll.reflectScrolledClipView(scroll.contentView)
        DispatchQueue.main.async { [weak self] in self?.suppressSelectionNotification = false }
    }
    func apply(viewSize: BrowserViewSize) {
        guard self.viewSize != viewSize else { return }
        self.viewSize = viewSize
        table.rowHeight = switch viewSize { case .small: 26; case .medium: 30; case .large: 38 }
        table.reloadData()
    }
    func focus() { window?.makeFirstResponder(table) }
    func revealSelection() {
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }
    func applyBackground(enabled: Bool) { scroll.drawsBackground = !enabled; table.backgroundColor = enabled ? .clear : .controlBackgroundColor }
    func currentScrollOffset() -> Double { scroll.contentView.bounds.origin.y }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case let .header(title) = rows[row] {
            let id = NSUserInterfaceItemIdentifier("FileListGroupHeader")
            let label = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
                let label = NSTextField(labelWithString: ""); label.identifier = id
                label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold); label.textColor = .secondaryLabelColor
                return label
            }()
            label.stringValue = title; label.setAccessibilityLabel(title); return label
        }
        let id = NSUserInterfaceItemIdentifier("FileListCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView(); cell.identifier = id
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; icon.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: ""); label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(icon); cell.addSubview(label); cell.imageView = icon; cell.textField = label
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }()
        guard let item = item(at: row) else { return nil }; cell.imageView?.image = fileIcon(for: item, showsThumbnails: showsThumbnails)
        cell.textField?.stringValue = item.displayName(showExtensions: true); return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(at: row) != nil }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionNotification else { return }
        onSelectionChange?(Set(selectedItems.map(\.id)))
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let item = item(at: row) else { return nil }; return item.url as NSURL
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !draggedURLs(info).isEmpty else { return [] }
        if operation == .on, item(at: row)?.isBrowsable != true { return [] }
        return dropIntent(info) == .move ? .move : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        let urls = draggedURLs(info); guard !urls.isEmpty else { return false }
        let item = operation == .on ? item(at: row) : nil
        return onFileDrop?(urls, item, dropIntent(info)) ?? false
    }
    @objc private func openSelection(_ sender: Any?) { if let item = selectedItems.first { onOpen?(item) } }
    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    private func dropIntent(_ info: any NSDraggingInfo) -> FileDropIntent {
        let flags = NSApp.currentEvent?.modifierFlags ?? []; var modifiers: DropModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }; if flags.contains(.command) { modifiers.insert(.command) }
        return .resolve(modifiers: modifiers, sourceAllowsMove: info.draggingSourceOperationMask.contains(.move))
    }
#if DEBUG
    var qaRowHeight: CGFloat { table.rowHeight }
    var qaGroupTitles: [String] { groupTitles }
#endif
}
