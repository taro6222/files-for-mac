import AppKit
import FilesCore

@MainActor
final class ShelfPane: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    enum Operation { case copy, move, trash, remove }
    private let table = NSTableView()
    private let caption = NSTextField(labelWithString: "")
    private var entries: [ShelfEntry] = []
    private var transferButtons: [NSButton] = []
    private var removeButton: NSButton?
    private var destination: URL?
    var onDrop: (([URL]) -> Void)?
    var onOperation: ((Operation, [ShelfEntry]) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 5
        edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        let bar = NSStackView()
        bar.addArrangedSubview(caption)
        bar.addArrangedSubview(NSView())
        for (title, selector) in [
            (L("복사", "Copy"), #selector(copyToFolder)),
            (L("이동", "Move"), #selector(moveToFolder)),
            (L("휴지통으로", "Trash"), #selector(trashItems)),
            (L("모음에서 제거", "Remove from Shelf"), #selector(removeItems))
        ] {
            let button = NSButton(title: title, target: self, action: selector)
            bar.addArrangedSubview(button)
            if selector == #selector(removeItems) { removeButton = button }
            else { transferButtons.append(button) }
        }
        addArrangedSubview(bar)
        table.addTableColumn(NSTableColumn(identifier: .init("shelfItem")))
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L("임시 파일 모음", "Shelf Items"))
        table.registerForDraggedTypes([.fileURL])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 74).isActive = true
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(entries: [ShelfEntry], destination: URL?) {
        self.destination = destination
        if entries != self.entries {
            let selection = selectedEntries
            self.entries = entries
            table.reloadData()
            table.selectRowIndexes(IndexSet(entries.indices.filter { selection.contains(entries[$0]) }), byExtendingSelection: false)
        }
        caption.stringValue = entries.isEmpty
            ? L("임시 모음에 파일을 놓으세요", "Drop files on the Shelf")
            : L("임시 모음 · \(entries.count)개", "Shelf · \(entries.count) items")
        updateButtons()
    }

    private var selectedEntries: [ShelfEntry] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    private func updateButtons() {
        for button in transferButtons { button.isEnabled = destination != nil && !selectedEntries.isEmpty }
        removeButton?.isEnabled = !selectedEntries.isEmpty
    }
    private func perform(_ operation: Operation) {
        let selection = selectedEntries
        guard !selection.isEmpty else { return }
        onOperation?(operation, selection)
    }
    @objc private func copyToFolder() { perform(.copy) }
    @objc private func moveToFolder() { perform(.move) }
    @objc private func trashItems() { perform(.trash) }
    @objc private func removeItems() { perform(.remove) }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = entries[row].url
        let label = NSTextField(labelWithString: url.path)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = url.path
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if dropURLs(info).isEmpty { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        let urls = dropURLs(info)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    private func dropURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

#if DEBUG
    func qaRemoveFirst() {
        guard !entries.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        removeButton?.performClick(nil)
    }
#endif
}
