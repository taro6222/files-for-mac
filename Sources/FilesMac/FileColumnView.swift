import AppKit
import FilesCore

@MainActor
final class FileColumnView: NSView {
    @MainActor private final class WidthHandle: NSView {
        static let defaultWidth: CGFloat = 230
        private static let widths: ClosedRange<CGFloat> = 150...620
        weak var columnWidth: NSLayoutConstraint?
        private var dragStart: (x: CGFloat, width: CGFloat)?

        init(folder: String) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let title = L("컬럼 너비 조절", "Resize column")
            toolTip = title
            setAccessibilityElement(true)
            setAccessibilityRole(.slider)
            setAccessibilityLabel(title + " — " + folder)
            setAccessibilityMinValue(NSNumber(value: Double(Self.widths.lowerBound)))
            setAccessibilityMaxValue(NSNumber(value: Double(Self.widths.upperBound)))
            setAccessibilityValue(NSNumber(value: Double(Self.defaultWidth)))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: floor(bounds.midX), y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
        override func mouseDown(with event: NSEvent) {
            guard let columnWidth else { return }
            if event.clickCount == 2 {
                dragStart = nil
                _ = resize(to: Self.defaultWidth)
            } else {
                dragStart = (event.locationInWindow.x, columnWidth.constant)
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            _ = resize(to: dragStart.width + event.locationInWindow.x - dragStart.x)
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }
        override func accessibilityPerformIncrement() -> Bool { adjust(by: 20) }
        override func accessibilityPerformDecrement() -> Bool { adjust(by: -20) }

        private func adjust(by delta: CGFloat) -> Bool {
            guard let columnWidth else { return false }
            return resize(to: columnWidth.constant + delta)
        }
        private func resize(to proposal: CGFloat) -> Bool {
            guard let columnWidth else { return false }
            let width = min(Self.widths.upperBound, max(Self.widths.lowerBound, proposal.rounded()))
            guard width != columnWidth.constant else { return false }
            columnWidth.constant = width
            setAccessibilityValue(NSNumber(value: Double(width)))
            NSAccessibility.post(element: self, notification: .valueChanged)
            return true
        }
    }

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
        let widthHandle: WidthHandle
        private(set) lazy var width = view.widthAnchor.constraint(equalToConstant: WidthHandle.defaultWidth)
        var suppress = false
        init(owner: FileColumnView, url: URL, items: [FileItem], pathChildID: String?) {
            let folder = url.path == "/" ? L("루트 폴더", "Root folder") : url.lastPathComponent
            self.owner = owner; self.url = url; self.items = items; self.pathChildID = pathChildID
            widthHandle = WidthHandle(folder: folder)
            super.init()
            view.translatesAutoresizingMaskIntoConstraints = false
            table.headerView = nil; table.rowHeight = 28; table.style = .fullWidth; table.allowsMultipleSelection = true
            table.setAccessibilityLabel(folder)
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(open(_:))
            table.onActivate = { [weak self] in self?.owner?.activate(column: self) }
            table.onRight = { [weak self] in self?.owner?.expand(column: self, moveFocus: true) }
            table.onLeft = { [weak self] in self?.owner?.moveLeft(from: self) }
            table.onDoubleClickBackground = { [weak self] in self?.owner?.onDoubleClickBackground?() }
            table.onValidateDrop = { [weak self] info, row in self?.owner?.validateDrop(info, column: self, row: row) ?? [] }
            table.onAcceptDrop = { [weak self] info, row in self?.owner?.acceptDrop(info, column: self, row: row) ?? false }
            table.registerForDraggedTypes(FilePromiseDrop.types); table.setDraggingSourceOperationMask([.copy, .move], forLocal: true); table.setDraggingSourceOperationMask(.copy, forLocal: false)
            let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.resizingMask = .autoresizingMask; table.addTableColumn(name)
            scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scroll)
            view.addSubview(widthHandle)
            widthHandle.columnWidth = width
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: widthHandle.leadingAnchor),
                scroll.topAnchor.constraint(equalTo: view.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                widthHandle.topAnchor.constraint(equalTo: view.topAnchor),
                widthHandle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                widthHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                widthHandle.widthAnchor.constraint(equalToConstant: 7),
                width
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
            guard items.indices.contains(row) else { return nil }; return FileDragPromise(item: items[row])
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
    private var expansionTask: Task<Void, Never>?
    private var expansionItemID: String?
    private weak var lastFocusedColumn: Column?
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
    var onPromiseDrop: (([NSFilePromiseReceiver], FileItem?, URL) -> Bool)?
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
    private var focusedColumn: Column? { columns.first { $0.table === window?.firstResponder } }
    private var selectionColumn: Column? {
        focusedColumn ?? lastFocusedColumn ?? columns.reversed().first { !$0.selectedItems.isEmpty } ?? columns.last
    }
    var selectedItems: [FileItem] { selectionColumn?.selectedItems ?? [] }
    func replaceSelection(with ids: Set<String>) {
        guard let column = selectionColumn else { return }
        column.apply(selection: ids); selectionChanged(column: column)
    }
    func invertSelection() {
        guard let column = selectionColumn else { return }
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
            cancelExpansion()
            removeColumns(after: 0)
            baseIDs = ids
        }
        guard let first = columns.first else { return }
        first.items = items
        let targetsBase = items.contains { selection.contains($0.id) }
        let targetsDescendant = columns.dropFirst().contains { column in
            column === (focusedColumn ?? lastFocusedColumn) || column.selectedItems.contains { selection.contains($0.id) }
        }
        if targetsBase || !targetsDescendant {
            first.apply(selection: selection)
            if !first.selectedItems.isEmpty { expand(column: first) }
        }
    }
    func focus() {
        let column = lastFocusedColumn ?? columns.reversed().first { !$0.selectedItems.isEmpty } ?? columns.first
        if let column { window?.makeFirstResponder(column.table) }
    }
    func applyBackground(enabled: Bool) {
        customBackgroundEnabled = enabled; scroll.drawsBackground = !enabled
        for column in ancestors + columns { column.scroll.drawsBackground = !enabled; column.table.backgroundColor = enabled ? .clear : .controlBackgroundColor }
    }
    private func reset() {
        cancelExpansion()
        lastFocusedColumn = nil
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
    private func activate(column: Column?) {
        if let column, columns.contains(where: { $0 === column }) { lastFocusedColumn = column }
        onActivate?()
    }
    private func selectionChanged(column: Column) {
        if ancestors.contains(where: { $0 === column }) {
            if let selected = column.selectedItems.first { selectAncestor(column, item: selected.url) }
            return
        }
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        cancelExpansion()
        removeColumns(after: index); onSelectionChange?(Set(column.selectedItems.map(\.id)))
        expand(column: column)
    }
    private func open(column: Column?) {
        guard let item = column?.selectedItems.first else { return }
        onOpen?(item)
    }
    private func cancelExpansion() {
        loadGeneration += 1
        expansionTask?.cancel()
        expansionTask = nil
        expansionItemID = nil
    }
    private func expand(column: Column?, moveFocus: Bool = false) {
        guard let column, column.selectedItems.count == 1, let item = column.selectedItems.first,
              item.isBrowsable, let index = columns.firstIndex(where: { $0 === column }) else { return }
        if columns.indices.contains(index + 1), columns[index + 1].url == item.url {
            if moveFocus { focusChild(columns[index + 1]) }
            return
        }
        if !moveFocus, expansionItemID == item.id { return }
        cancelExpansion()
        let generation = loadGeneration
        expansionItemID = item.id
        expansionTask = Task { [weak self] in
            do {
                let loaded = try await LocalFileSystem().contents(of: item.url, showHidden: self?.showHidden ?? false)
                guard let self, self.loadGeneration == generation, self.columns.indices.contains(index),
                      self.columns[index] === column, column.selectedItems.map(\.id) == [item.id] else { return }
                self.expansionTask = nil
                self.expansionItemID = nil
                self.removeColumns(after: index); self.append(url: item.url, sortedItems: self.sortOrder.sorted(loaded))
                if moveFocus, self.focusedColumn === column, let child = self.columns.last { self.focusChild(child) }
            } catch {
                if let self, self.loadGeneration == generation {
                    self.expansionTask = nil
                    self.expansionItemID = nil
                }
            }
        }
    }
    private func focusChild(_ column: Column) {
        guard window?.makeFirstResponder(column.table) == true else { return }
        if column.selectedItems.isEmpty, !column.items.isEmpty {
            column.suppress = false
            column.table.selectRowIndexes([0], byExtendingSelection: false)
        } else {
            onSelectionChange?(Set(column.selectedItems.map(\.id)))
        }
    }
    private func moveLeft(from column: Column?) {
        guard let column, let index = columns.firstIndex(where: { $0 === column }) else { return }
        if index == 0 {
            if let parent = ancestors.last { selectAncestor(parent, item: column.url) }
            return
        }
        cancelExpansion()
        let parent = columns[index - 1]
        window?.makeFirstResponder(parent.table)
        onSelectionChange?(Set(parent.selectedItems.map(\.id)))
        removeColumns(after: index - 1)
    }
    private func selectAncestor(_ column: Column, item: URL) {
        focusBaseAfterNavigation = window?.firstResponder is Table
        onSelectAncestor?(column.url, item)
    }
    private func removeColumns(after index: Int) {
        guard index + 1 < columns.count else { return }
        for column in columns[(index + 1)...] {
            if column === lastFocusedColumn { lastFocusedColumn = nil }
            column.view.removeFromSuperview()
        }
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
        guard let column, (FilePromiseDrop.isExternalPromise(info) || !draggedURLs(info).isEmpty) else { return [] }
        if row >= 0, column.items.indices.contains(row), !column.items[row].isBrowsable { return [] }
        if FilePromiseDrop.isExternalPromise(info) { return .copy }
        return dropIntent(info) == .move ? .move : .copy
    }
    private func acceptDrop(_ info: any NSDraggingInfo, column: Column?, row: Int) -> Bool {
        guard let column else { return false }
        let item = row >= 0 && column.items.indices.contains(row) ? column.items[row] : nil
        if FilePromiseDrop.isExternalPromise(info) { return onPromiseDrop?(FilePromiseDrop.receivers(info), item, column.url) ?? false }
        let urls = draggedURLs(info); guard !urls.isEmpty else { return false }
        return onFileDrop?(urls, item, column.url, dropIntent(info)) ?? false
    }

#if DEBUG
    var qaColumnCount: Int { columns.count }
    var qaColumnWidths: [CGFloat] {
        document.layoutSubtreeIfNeeded()
        return columns.map { $0.view.frame.width }
    }
    func qaDragBaseWidth(by delta: CGFloat) {
        guard let column = columns.first,
              let down = qaWidthEvent(.leftMouseDown, on: column.widthHandle, delta: 0, clicks: 1),
              let drag = qaWidthEvent(.leftMouseDragged, on: column.widthHandle, delta: delta, clicks: 1),
              let up = qaWidthEvent(.leftMouseUp, on: column.widthHandle, delta: delta, clicks: 1) else { return }
        column.widthHandle.mouseDown(with: down)
        column.widthHandle.mouseDragged(with: drag)
        column.widthHandle.mouseUp(with: up)
    }
    func qaIncreaseBaseWidth() -> Bool { columns.first?.widthHandle.accessibilityPerformIncrement() ?? false }
    func qaResetBaseWidth() {
        guard let handle = columns.first?.widthHandle,
              let event = qaWidthEvent(.leftMouseDown, on: handle, delta: 0, clicks: 2) else { return }
        handle.mouseDown(with: event)
    }
    private func qaWidthEvent(_ type: NSEvent.EventType, on handle: WidthHandle, delta: CGFloat, clicks: Int) -> NSEvent? {
        guard let window else { return nil }
        let origin = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x + delta, y: origin.y),
                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }
    var qaFocusedColumnURL: URL? { focusedColumn?.url }
    var qaBaseSelection: [String] { columns.first?.selectedItems.map(\.id) ?? [] }
    func qaMoveRightFromBase() {
        guard let base = columns.first else { return }
        window?.makeFirstResponder(base.table)
        expand(column: base, moveFocus: true)
    }
    var qaParentColumnURL: URL? { ancestors.last?.url }
    var qaParentSelection: [String] { ancestors.last?.selectedItems.map(\.id) ?? [] }
    func qaMoveLeftFromBase() { moveLeft(from: columns.first) }
    var qaColumnState: [[String: Any]] {
        columns.map { ["url": $0.url.path, "rows": $0.items.count, "selection": $0.selectedItems.map(\.id),
                       "firstNames": Array($0.items.prefix(8).map(\.name))] }
    }
    func qaSelect(id: String, column index: Int = 0) {
        guard columns.indices.contains(index), let row = columns[index].items.firstIndex(where: { $0.id == id }) else { return }
        window?.makeFirstResponder(columns[index].table)
        columns[index].suppress = false
        columns[index].table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    func qaMoveLeft() { moveLeft(from: columns.last) }
    var qaHasDropHandler: Bool { onFileDrop != nil && contextMenu != nil }
    func qaPasteboardURL(column index: Int = 0, row: Int = 0) -> URL? {
        guard columns.indices.contains(index) else { return nil }
        return fileDragURL(from: columns[index].tableView(columns[index].table, pasteboardWriterForRow: row))
    }
#endif
}
