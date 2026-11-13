import AppKit
import FilesCore

@MainActor
final class FileGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private final class CollectionView: NSCollectionView {
        var onOpen: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { onOpen?() }
        }
    }

    private final class Item: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
        private let icon = NSImageView()
        private let label = NSTextField(labelWithString: "")
        override func loadView() {
            let root = NSView(); root.wantsLayer = true
            icon.imageScaling = .scaleProportionallyUpOrDown; icon.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 2; label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(icon); root.addSubview(label)
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5), label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4), label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -5)
            ])
            view = root
        }
        override var isSelected: Bool { didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
            view.layer?.cornerRadius = 8
        } }
        func configure(item: FileItem) {
            representedObject = item; icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
            label.stringValue = item.displayName(showExtensions: true)
            view.setAccessibilityElement(true); view.setAccessibilityLabel(label.stringValue)
        }
    }

    private let collection = CollectionView()
    private let scroll = NSScrollView()
    private(set) var items: [FileItem] = []
    var onSelectionChange: ((Set<String>) -> Void)?
    var onOpen: ((FileItem) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); translatesAutoresizingMaskIntoConstraints = false
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width: 116, height: 104)
        layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout; collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.dataSource = self; collection.delegate = self
        collection.register(Item.self, forItemWithIdentifier: Item.identifier)
        collection.setAccessibilityLabel(L("파일 그리드", "File grid"))
        collection.onOpen = { [weak self] in
            guard let self, let index = self.collection.selectionIndexPaths.first?.item, self.items.indices.contains(index) else { return }
            self.onOpen?(self.items[index])
        }
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var selectedItems: [FileItem] { collection.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item] : nil } }
    func update(items: [FileItem], selection: Set<String>, scrollOffset: Double) {
        self.items = items; collection.reloadData()
        collection.selectionIndexPaths = Set(items.indices.filter { selection.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scrollOffset))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func focus() { window?.makeFirstResponder(collection) }
    func currentScrollOffset() -> Double { scroll.contentView.bounds.origin.y }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Item.identifier, for: indexPath)
        if let item = item as? Item, items.indices.contains(indexPath.item) { item.configure(item: items[indexPath.item]) }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    private func selectionChanged() { onSelectionChange?(Set(selectedItems.map(\.id))) }
}
