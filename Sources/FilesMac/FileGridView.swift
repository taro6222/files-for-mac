import AppKit
import FilesCore

@MainActor
final class FileGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private final class CollectionView: NSCollectionView {
        var onOpen: (() -> Void)?
        var onActivate: (() -> Void)?
        var onValidateDrop: ((any NSDraggingInfo, Int?) -> NSDragOperation)?
        var onAcceptDrop: ((any NSDraggingInfo, Int?) -> Bool)?
        override func mouseDown(with event: NSEvent) {
            onActivate?()
            super.mouseDown(with: event)
            if event.clickCount == 2 { onOpen?() }
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
        private func targetIndex(_ sender: any NSDraggingInfo) -> Int? {
            let point = convert(sender.draggingLocation, from: nil)
            return indexPathForItem(at: point)?.item
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
        func configure(item: FileItem, iconSize: CGFloat) {
            representedObject = item; icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
            iconWidth?.constant = iconSize; iconHeight?.constant = iconSize
            label.stringValue = item.displayName(showExtensions: true)
            view.setAccessibilityElement(true); view.setAccessibilityLabel(label.stringValue)
        }
    }

    private let collection = CollectionView()
    private let scroll = NSScrollView()
    private(set) var items: [FileItem] = []
    private var suppressSelectionNotification = false
    private var iconSize: CGFloat = 56
    private var viewSize: BrowserViewSize = .medium
    var onSelectionChange: ((Set<String>) -> Void)?
    var onOpen: ((FileItem) -> Void)?
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
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setAccessibilityLabel(L("파일 그리드", "File grid"))
        collection.onActivate = { [weak self] in self?.onActivate?() }
        collection.onOpen = { [weak self] in
            guard let self, let index = self.collection.selectionIndexPaths.first?.item, self.items.indices.contains(index) else { return }
            self.onOpen?(self.items[index])
        }
        collection.onValidateDrop = { [weak self] info, index in self?.validateDrop(info, index: index) ?? [] }
        collection.onAcceptDrop = { [weak self] info, index in self?.acceptDrop(info, index: index) ?? false }
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var selectedItems: [FileItem] { collection.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item] : nil } }
    func replaceSelection(with ids: Set<String>) {
        suppressSelectionNotification = true
        collection.selectionIndexPaths = Set(items.indices.filter { ids.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
        suppressSelectionNotification = false; selectionChanged()
    }
    func invertSelection() { replaceSelection(with: Set(items.map(\.id)).subtracting(selectedItems.map(\.id))) }
    func update(items: [FileItem], selection: Set<String>, scrollOffset: Double) {
        suppressSelectionNotification = true
        self.items = items; collection.reloadData()
        collection.collectionViewLayout?.invalidateLayout()
        collection.layoutSubtreeIfNeeded()
        collection.selectionIndexPaths = Set(items.indices.filter { selection.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
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
    func applyBackground(enabled: Bool) {
        scroll.drawsBackground = !enabled
        collection.backgroundColors = enabled ? [.clear] : []
    }
    func currentScrollOffset() -> Double { scroll.contentView.bounds.origin.y }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Item.identifier, for: indexPath)
        if let item = item as? Item, items.indices.contains(indexPath.item) { item.configure(item: items[indexPath.item], iconSize: iconSize) }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(indexPath.item) else { return nil }
        return items[indexPath.item].url as NSURL
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
    private func validateDrop(_ info: any NSDraggingInfo, index: Int?) -> NSDragOperation {
        guard !draggedURLs(info).isEmpty else { return [] }
        if let index, items.indices.contains(index), !items[index].isBrowsable { return [] }
        return dropIntent(info) == .move ? .move : .copy
    }
    private func acceptDrop(_ info: any NSDraggingInfo, index: Int?) -> Bool {
        let urls = draggedURLs(info); guard !urls.isEmpty else { return false }
        let item = index.flatMap { items.indices.contains($0) ? items[$0] : nil }
        return onFileDrop?(urls, item, dropIntent(info)) ?? false
    }
    #if DEBUG
    var qaHasDropHandler: Bool { onFileDrop != nil }
    func qaPasteboardURL(at index: Int) -> URL? {
        guard items.indices.contains(index) else { return nil }
        return (collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: index, section: 0)) as? NSURL) as URL?
    }
    var qaItemSize: NSSize { (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize ?? .zero }
    #endif
}
