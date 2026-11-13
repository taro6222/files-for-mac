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
    private let status = NSTextField(labelWithString: "")
    private let hiddenButton = NSButton()
    private var watcher: DirectoryWatcher?
    private var watcherTask: Task<Void, Never>?
    private var watchedURL: URL?
    private var pendingRefresh = false

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
        table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0] : nil }
    }
    func setActive(_ active: Bool) {
        layer?.borderWidth = active ? 2 : 0; layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    func goBack() { activate(); savePosition(); model.back() }
    func goForward() { activate(); savePosition(); model.forward() }
    func goUp() { activate(); if let location = model.location { navigate(location.deletingLastPathComponent()) } }
    func refresh() { activate(); savePosition(); model.reload() }
    func focusPath() { activate(); window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    func focusFiles() { activate(); window?.makeFirstResponder(table) }
    func stopLoading() { model.cancelLoad() }
    func openSelected() { openSelection(nil) }
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
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; stack.addArrangedSubview(scroll)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(); footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        footer.addArrangedSubview(status); footer.addArrangedSubview(NSView()); stack.addArrangedSubview(footer)
        for view in [toolbar, scroll, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }
    private func button(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(); button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.title = ""; button.imagePosition = .imageOnly; button.bezelStyle = .texturedRounded; button.target = self; button.action = action; return button
    }
    private func activate() { onActivate?() }
    private func savePosition() {
        let selection = Set(table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].id : nil })
        model.savePosition(selection: selection, scrollOffset: scroll.contentView.bounds.origin.y)
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
        pathField.stringValue = model.location?.path ?? ""; table.reloadData()
        hiddenButton.contentTintColor = model.showHidden ? .systemBlue : .labelColor
        let expectedSort = NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)
        if table.sortDescriptors.first != expectedSort { table.sortDescriptors = [expectedSort] }
        table.selectRowIndexes(IndexSet(model.items.indices.filter { model.history.current.selection.contains(model.items[$0].id) }), byExtendingSelection: false)
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
    @objc private func submitPath(_ sender: Any?) {
        activate(); let path = (pathField.stringValue as NSString).expandingTildeInPath
        let base = model.location ?? FileManager.default.homeDirectoryForCurrentUser
        navigate(path.isEmpty ? nil : (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)))
    }
    @objc private func openSelection(_ sender: Any?) {
        activate(); guard let row = table.selectedRowIndexes.first, model.items.indices.contains(row) else { return }
        let item = model.items[row]; if item.isBrowsable { navigate(item.url) } else { NSWorkspace.shared.open(item.url) }
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
}

@MainActor
private final class ActivatingTableView: NSTableView {
    var onActivate: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onActivate?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
}
