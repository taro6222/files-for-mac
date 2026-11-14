import AppKit
import FilesCore

@MainActor
final class FileGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private final class CollectionView: NSCollectionView {
        var onOpen: (() -> Void)?
        var onDoubleClickBackground: (() -> Void)?
        var onActivate: (() -> Void)?
        var onValidateDrop: ((any NSDraggingInfo, IndexPath?) -> NSDragOperation)?
        var onAcceptDrop: ((any NSDraggingInfo, IndexPath?) -> Bool)?
        override func mouseDown(with event: NSEvent) {
            onActivate?()
            let hitsItem = indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil
            super.mouseDown(with: event)
            if event.clickCount == 2 { hitsItem ? onOpen?() : onDoubleClickBackground?() }
        }
        override func becomeFirstResponder() -> Bool { onActivate?(); return super.becomeFirstResponder() }
        override func menu(for event: NSEvent) -> NSMenu? {
            onActivate?()
            let point = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: point), !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
            }
            return super.menu(for: event)
        }
        private func targetIndex(_ sender: any NSDraggingInfo) -> IndexPath? {
            let point = convert(sender.draggingLocation, from: nil)
            return indexPathForItem(at: point)
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            onValidateDrop?(sender, targetIndex(sender)) ?? []
        }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            onValidateDrop?(sender, targetIndex(sender)) ?? []
        }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            onAcceptDrop?(sender, targetIndex(sender)) ?? false
        }
    }

    private final class Item: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
        private let icon = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private var iconWidth: NSLayoutConstraint?
        private var iconHeight: NSLayoutConstraint?
        override func loadView() {
            let root = NSView(); root.wantsLayer = true
            icon.imageScaling = .scaleProportionallyUpOrDown; icon.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 2; label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(icon); root.addSubview(label)
            iconWidth = icon.widthAnchor.constraint(equalToConstant: 56)
            iconHeight = icon.heightAnchor.constraint(equalToConstant: 56)
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                iconWidth!, iconHeight!,
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5), label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4), label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -5)
            ])
            view = root
        }
        override var isSelected: Bool { didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
            view.layer?.cornerRadius = 8
        } }
        func configure(item: FileItem, iconSize: CGFloat, showsThumbnails: Bool) {
            representedObject = item; icon.image = fileIcon(for: item, showsThumbnails: showsThumbnails)
            iconWidth?.constant = iconSize; iconHeight?.constant = iconSize
            label.stringValue = item.displayName(showExtensions: true)
            view.setAccessibilityElement(true); view.setAccessibilityLabel(label.stringValue)
        }
    }

    private final class Header: NSView {
        static let identifier = NSUserInterfaceItemIdentifier("FileGridHeader")
        private let label = NSTextField(labelWithString: "")
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor; label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        func configure(_ title: String) { label.stringValue = title; setAccessibilityLabel(title) }
    }

    private let collection = CollectionView()
    private let scroll = NSScrollView()
    private(set) var items: [FileItem] = []
    private var groups: [FileItemGroup] = []
    private var grouping = FileGroupOptions()
    private var suppressSelectionNotification = false
    private var iconSize: CGFloat = 56
    private var viewSize: BrowserViewSize = .medium
    var showsThumbnails = true { didSet { if oldValue != showsThumbnails { collection.reloadData() } } }
    var onSelectionChange: ((Set<String>) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onDoubleClickBackground: (() -> Void)? { didSet { collection.onDoubleClickBackground = onDoubleClickBackground } }
    var onActivate: (() -> Void)?
    var onFileDrop: (([URL], FileItem?, FileDropIntent) -> Bool)?
    var contextMenu: NSMenu? { get { collection.menu } set { collection.menu = newValue } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); translatesAutoresizingMaskIntoConstraints = false
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width: 116, height: 104)
        layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout; collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.dataSource = self; collection.delegate = self
        collection.register(Item.self, forItemWithIdentifier: Item.identifier)
        collection.register(Header.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Header.identifier)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setAccessibilityLabel(L("파일 그리드", "File grid"))
        collection.onActivate = { [weak self] in self?.onActivate?() }
        collection.onOpen = { [weak self] in
            guard let self, let path = self.collection.selectionIndexPaths.first, let item = self.item(at: path) else { return }
            self.onOpen?(item)
        }
        collection.onValidateDrop = { [weak self] info, index in self?.validateDrop(info, index: index) ?? [] }
        collection.onAcceptDrop = { [weak self] info, index in self?.acceptDrop(info, index: index) ?? false }
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func item(at path: IndexPath) -> FileItem? {
        guard groups.indices.contains(path.section), groups[path.section].items.indices.contains(path.item) else { return nil }
        return groups[path.section].items[path.item]
    }
    var selectedItems: [FileItem] { collection.selectionIndexPaths.compactMap(item(at:)) }
    func replaceSelection(with ids: Set<String>) {
        suppressSelectionNotification = true
        collection.selectionIndexPaths = Set(groups.indices.flatMap { section in groups[section].items.indices.compactMap { ids.contains(groups[section].items[$0].id) ? IndexPath(item: $0, section: section) : nil } })
        suppressSelectionNotification = false; selectionChanged()
    }
    func invertSelection() { replaceSelection(with: Set(items.map(\.id)).subtracting(selectedItems.map(\.id))) }
    func update(items: [FileItem], selection: Set<String>, scrollOffset: Double, grouping: FileGroupOptions = FileGroupOptions()) {
        suppressSelectionNotification = true
        self.items = items; self.grouping = grouping; groups = FileGrouping.groups(items, options: grouping)
        (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize = grouping.field == .none ? .zero : NSSize(width: 100, height: 30)
        collection.reloadData()
        collection.collectionViewLayout?.invalidateLayout()
        collection.layoutSubtreeIfNeeded()
        collection.selectionIndexPaths = Set(groups.indices.flatMap { section in groups[section].items.indices.compactMap { selection.contains(groups[section].items[$0].id) ? IndexPath(item: $0, section: section) : nil } })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scrollOffset))); scroll.reflectScrolledClipView(scroll.contentView)
        DispatchQueue.main.async { [weak self] in self?.suppressSelectionNotification = false }
    }
    func apply(viewSize: BrowserViewSize) {
        guard self.viewSize != viewSize else { return }
        self.viewSize = viewSize
        guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        switch viewSize {
        case .small:
            iconSize = 40; layout.itemSize = NSSize(width: 96, height: 84)
            layout.minimumInteritemSpacing = 6; layout.minimumLineSpacing = 8
        case .medium:
            iconSize = 56; layout.itemSize = NSSize(width: 116, height: 104)
            layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 10
        case .large:
            iconSize = 72; layout.itemSize = NSSize(width: 142, height: 124)
            layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 14
        }
        layout.invalidateLayout(); collection.reloadData()
    }
    func focus() { window?.makeFirstResponder(collection) }
    func revealSelection() {
        collection.scrollToItems(at: collection.selectionIndexPaths, scrollPosition: .nearestVerticalEdge)
    }
    func applyBackground(enabled: Bool) {
        scroll.drawsBackground = !enabled
        collection.backgroundColors = enabled ? [.clear] : []
    }
    func currentScrollOffset() -> Double { scroll.contentView.bounds.origin.y }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { groups.indices.contains(section) ? groups[section].items.count : 0 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Item.identifier, for: indexPath)
        if let view = item as? Item, let value = self.item(at: indexPath) { view.configure(item: value, iconSize: iconSize, showsThumbnails: showsThumbnails) }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Header.identifier, for: indexPath)
        if let header = header as? Header, groups.indices.contains(indexPath.section) { header.configure(fileGroupTitle(groups[indexPath.section].key, field: grouping.field)) }
        return header
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard let item = item(at: indexPath) else { return nil }
        return item.url as NSURL
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    private func selectionChanged() {
        guard !suppressSelectionNotification else { return }
        onSelectionChange?(Set(selectedItems.map(\.id)))
    }
    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    private func dropIntent(_ info: any NSDraggingInfo) -> FileDropIntent {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        var modifiers: DropModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return .resolve(modifiers: modifiers, sourceAllowsMove: info.draggingSourceOperationMask.contains(.move))
    }
    private func validateDrop(_ info: any NSDraggingInfo, index: IndexPath?) -> NSDragOperation {
        guard !draggedURLs(info).isEmpty else { return [] }
        if let index, item(at: index)?.isBrowsable != true { return [] }
        return dropIntent(info) == .move ? .move : .copy
    }
    private func acceptDrop(_ info: any NSDraggingInfo, index: IndexPath?) -> Bool {
        let urls = draggedURLs(info); guard !urls.isEmpty else { return false }
        let item = index.flatMap(item(at:))
        return onFileDrop?(urls, item, dropIntent(info)) ?? false
    }
    #if DEBUG
    var qaHasDropHandler: Bool { onFileDrop != nil }
    func qaPasteboardURL(at index: Int) -> URL? {
        guard items.indices.contains(index) else { return nil }
        guard let path = groups.indices.lazy.compactMap({ section in self.groups[section].items.firstIndex(where: { $0.id == self.items[index].id }).map { IndexPath(item: $0, section: section) } }).first else { return nil }
        return (collectionView(collection, pasteboardWriterForItemAt: path) as? NSURL) as URL?
    }
    var qaItemSize: NSSize { (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize ?? .zero }
    var qaSectionCount: Int { groups.count }
    var qaSectionTitles: [String] { groups.map { fileGroupTitle($0.key, field: grouping.field) } }
    #endif
}
