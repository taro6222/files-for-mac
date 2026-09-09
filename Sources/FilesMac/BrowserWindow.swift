import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class BrowserWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let model = BrowserModel()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let pathField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let hiddenButton = NSButton()
    private let homeView = NSStackView()
    private let sidebar = NSStackView()
    private let content = NSView()
    private var favorites: [URL] = []
    private var recent: [String] = []
    private var rendering = false
    private var watchTimer: Timer?
    private var lastModified: Date?
    private var observedLocation: URL?
    private var observerTokens: [NSObjectProtocol] = []
    private var iconCache: [String: NSImage] = [:]
    private let dateFormatter: DateFormatter = {
        let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d
    }()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Files macOS"; w.minSize = NSSize(width: 900, height: 600)
        w.center(); w.setFrameAutosaveName("BrowserWindow"); w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        let defaults = UserDefaults.standard
        favorites = (defaults.stringArray(forKey: "favorites") ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        ]).map { URL(fileURLWithPath: $0) }
        recent = defaults.stringArray(forKey: "recent") ?? []
        model.showHidden = defaults.bool(forKey: "showHidden")
        setupUI()
        model.onChange = { [weak self] in self?.render() }
        model.navigate(nil)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkChanges() }
        }
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.watchTimer?.invalidate() }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setupUI() {
        guard let root = window?.contentView else { return }
        let split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin; split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let sideEffect = NSVisualEffectView()
        sideEffect.material = .sidebar; sideEffect.blendingMode = .behindWindow; sideEffect.state = .active
        split.addArrangedSubview(sideEffect)
        sideEffect.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        sideEffect.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let sideScroll = NSScrollView(); sideScroll.drawsBackground = false; sideScroll.hasVerticalScroller = true
        sideScroll.translatesAutoresizingMaskIntoConstraints = false; sideEffect.addSubview(sideScroll)
        NSLayoutConstraint.activate([sideScroll.leadingAnchor.constraint(equalTo: sideEffect.leadingAnchor), sideScroll.trailingAnchor.constraint(equalTo: sideEffect.trailingAnchor), sideScroll.topAnchor.constraint(equalTo: sideEffect.topAnchor), sideScroll.bottomAnchor.constraint(equalTo: sideEffect.bottomAnchor)])
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 22, left: 14, bottom: 16, right: 14)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let sideDocument = FlippedView()
        sideDocument.translatesAutoresizingMaskIntoConstraints = false
        sideScroll.documentView = sideDocument
        sideDocument.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sideDocument.widthAnchor.constraint(equalTo: sideScroll.contentView.widthAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sideDocument.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sideDocument.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: sideDocument.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sideDocument.bottomAnchor)
        ])
        buildSidebar()
        let main = NSStackView(); main.orientation = .vertical; main.spacing = 0; main.alignment = .leading
        split.addArrangedSubview(main)
        split.setPosition(220, ofDividerAt: 0)

        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 10, right: 18)
        let brand = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
        brand.contentTintColor = .systemBlue; brand.widthAnchor.constraint(equalToConstant: 22).isActive = true
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(brand); header.addArrangedSubview(titleLabel); header.addArrangedSubview(NSView())
        let choose = button("folder.badge.plus", L("폴더 열기", "Open Folder"), #selector(chooseFolder(_:)))
        header.addArrangedSubview(choose)
        main.addArrangedSubview(header)

        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 12, right: 14)
        configure(backButton, "chevron.left", L("뒤로", "Back"), #selector(goBack(_:)))
        configure(forwardButton, "chevron.right", L("앞으로", "Forward"), #selector(goForward(_:)))
        configure(upButton, "arrow.up", L("상위 폴더", "Enclosing Folder"), #selector(goUp(_:)))
        toolbar.addArrangedSubview(backButton); toolbar.addArrangedSubview(forwardButton); toolbar.addArrangedSubview(upButton)
        toolbar.addArrangedSubview(button("arrow.clockwise", L("새로고침", "Refresh"), #selector(refresh(_:))))
        pathField.font = .systemFont(ofSize: 13); pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = L("폴더 경로 입력", "Enter a folder path")
        pathField.target = self; pathField.action = #selector(submitPath(_:)); pathField.delegate = self
        pathField.setAccessibilityLabel(L("폴더 경로", "Folder path"))
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(pathField)
        configure(hiddenButton, "eye.slash", L("숨김 항목 표시", "Show Hidden Files"), #selector(toggleHidden(_:)))
        toolbar.addArrangedSubview(hiddenButton)
        toolbar.addArrangedSubview(button("pin", L("즐겨찾기 전환", "Toggle Favorite"), #selector(toggleFavorite(_:))))
        main.addArrangedSubview(toolbar)
        let divider = NSBox(); divider.boxType = .separator; main.addArrangedSubview(divider)
        main.addArrangedSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        setupTable()
        homeView.orientation = .vertical; homeView.alignment = .leading; homeView.spacing = 16
        homeView.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        homeView.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(homeView)
        NSLayoutConstraint.activate([homeView.topAnchor.constraint(equalTo: content.topAnchor), homeView.leadingAnchor.constraint(equalTo: content.leadingAnchor), homeView.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
        message.font = .systemFont(ofSize: 14); message.textColor = .secondaryLabelColor
        message.alignment = .center; message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo: content.centerXAnchor), message.centerYAnchor.constraint(equalTo: content.centerYAnchor), message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8)])
        let bottom = NSStackView(); bottom.orientation = .horizontal
        bottom.edgeInsets = NSEdgeInsets(top: 7, left: 18, bottom: 7, right: 18)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        bottom.addArrangedSubview(status); bottom.addArrangedSubview(NSView())
        let phase = NSTextField(labelWithString: L("M1 · 읽기 전용 탐색", "M1 · Read-only browser"))
        phase.font = .systemFont(ofSize: 11); phase.textColor = .tertiaryLabelColor
        bottom.addArrangedSubview(phase); main.addArrangedSubview(bottom)
        for view in [header, toolbar, divider, content, bottom] { view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
    }

    private func setupTable() {
        table.style = .fullWidth; table.rowHeight = 32; table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        table.autosaveName = "FileColumns"; table.autosaveTableColumns = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelection(_:))
        table.setAccessibilityLabel(L("파일 목록", "File list"))
        let specs: [(String, String, CGFloat)] = [("name", L("이름", "Name"), 380), ("modified", L("수정일", "Date Modified"), 185), ("kind", L("종류", "Kind"), 140), ("size", L("크기", "Size"), 100)]
        for (key, label, width) in specs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = label; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let menu = NSMenu()
        let open = menu.addItem(withTitle: L("열기", "Open"), action: #selector(openSelection(_:)), keyEquivalent: ""); open.target = self
        let reveal = menu.addItem(withTitle: L("Finder에서 보기", "Reveal in Finder"), action: #selector(revealSelection(_:)), keyEquivalent: ""); reveal.target = self
        table.menu = menu
    }
    private func configure(_ b: NSButton, _ symbol: String, _ title: String, _ action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.title = ""; b.imagePosition = .imageOnly; b.bezelStyle = .texturedRounded
        b.toolTip = title; b.setAccessibilityLabel(title); b.target = self; b.action = action
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }
    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(); configure(b, symbol, title, action); return b
    }
    private func section(_ title: String, in stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label); stack.setCustomSpacing(10, after: label)
    }
    private func locationButton(_ title: String, symbol: String, url: URL?, in stack: NSStackView) {
        let b = LocationButton(title: title, target: self, action: #selector(openLocation(_:)))
        b.url = url; b.bezelStyle = .recessed; b.isBordered = false
        b.alignment = .left; b.font = .systemFont(ofSize: 13)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading; b.imageHugsTitle = true
        b.toolTip = url?.path ?? title; b.setAccessibilityLabel(title)
        stack.addArrangedSubview(b)
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }
    private func buildSidebar() {
        sidebar.arrangedSubviews.forEach { sidebar.removeArrangedSubview($0); $0.removeFromSuperview() }
        locationButton(L("홈", "Home"), symbol: "house", url: nil, in: sidebar)
        section(L("즐겨찾기", "Favorites"), in: sidebar)
        for url in favorites { locationButton(displayName(url), symbol: "folder", url: url, in: sidebar) }
        section(L("위치", "Locations"), in: sidebar)
        locationButton(L("사용자 폴더", "User Folder"), symbol: "person.crop.circle", url: FileManager.default.homeDirectoryForCurrentUser, in: sidebar)
        locationButton(L("응용 프로그램", "Applications"), symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications"), in: sidebar)
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            locationButton(url.path == "/" ? "Macintosh HD" : displayName(url), symbol: "externaldrive", url: url, in: sidebar)
        }
    }
    private func buildHome() {
        homeView.arrangedSubviews.forEach { homeView.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: L("홈", "Home")); heading.font = .systemFont(ofSize: 28, weight: .bold)
        homeView.addArrangedSubview(heading)
        let subtitle = NSTextField(labelWithString: L("파일과 폴더를 한곳에서 탐색하세요.", "Your files and folders, in one place."))
        subtitle.textColor = .secondaryLabelColor; homeView.addArrangedSubview(subtitle)
        section(L("빠른 접근", "Quick Access"), in: homeView)
        for url in favorites.prefix(5) { locationButton(displayName(url), symbol: "folder.fill", url: url, in: homeView) }
        section(L("최근 위치", "Recent Locations"), in: homeView)
        if recent.isEmpty {
            homeView.addArrangedSubview(NSTextField(labelWithString: L("방문한 폴더가 여기에 표시됩니다.", "Folders you visit will appear here.")))
        } else {
            for path in recent.prefix(4) { locationButton(path, symbol: "clock", url: URL(fileURLWithPath: path), in: homeView) }
        }
    }
    private func displayName(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path) }
    private func savePosition() {
        guard !rendering else { return }
        let ids = Set(table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].id : nil })
        model.savePosition(selection: ids, scrollOffset: scroll.contentView.bounds.origin.y)
    }
    private func navigate(_ url: URL?) { savePosition(); model.navigate(url) }
    private func render() {
        rendering = true; defer { rendering = false }
        titleLabel.stringValue = model.location.map(displayName) ?? L("홈", "Home")
        window?.title = "\(titleLabel.stringValue) — Files macOS"
        pathField.stringValue = model.location?.path ?? ""
        backButton.isEnabled = !model.history.back.isEmpty; forwardButton.isEnabled = !model.history.forward.isEmpty
        upButton.isEnabled = model.location != nil && model.location?.path != "/"
        hiddenButton.contentTintColor = model.showHidden ? .systemBlue : .labelColor
        scroll.isHidden = model.location == nil; homeView.isHidden = model.location != nil
        if model.location == nil { buildHome() }
        table.reloadData()
        let selected = IndexSet(model.items.indices.filter { model.history.current.selection.contains(model.items[$0].id) })
        table.selectRowIndexes(selected, byExtendingSelection: false)
        if !model.isLoading {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: model.history.current.scrollOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if model.isLoading { message.stringValue = L("폴더를 읽는 중…", "Loading folder…") }
        else if let error = model.error { message.stringValue = L("폴더를 열 수 없습니다.\n", "Unable to open this folder.\n") + error }
        else if model.location != nil && model.items.isEmpty { message.stringValue = L("이 폴더는 비어 있습니다.", "This folder is empty.") }
        else { message.stringValue = "" }
        message.isHidden = message.stringValue.isEmpty
        if !model.isLoading && model.error == nil, let url = model.location {
            recent.removeAll { $0 == url.path }; recent.insert(url.path, at: 0); recent = Array(recent.prefix(10))
            UserDefaults.standard.set(recent, forKey: "recent")
        }
        updateStatus()
    }
    private func updateStatus() {
        if model.location == nil { status.stringValue = L("준비됨", "Ready"); return }
        status.stringValue = "\(model.items.count) " + L("개 항목", "items")
        if !table.selectedRowIndexes.isEmpty { status.stringValue += "  ·  \(table.selectedRowIndexes.count) " + L("개 선택", "selected") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.items.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
        let item = model.items[row]
        let id = NSUserInterfaceItemIdentifier(key)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, icon: key == "name")
        switch key {
        case "name":
            cell.textField?.stringValue = item.name
            let cacheKey = item.isDirectory ? (item.isPackage ? item.url.path : "folder") : item.url.pathExtension
            if iconCache[cacheKey] == nil { iconCache[cacheKey] = NSWorkspace.shared.icon(forFile: item.url.path) }
            cell.imageView?.image = iconCache[cacheKey]
        case "modified": cell.textField?.stringValue = item.modified.map(dateFormatter.string) ?? "—"
        case "kind": cell.textField?.stringValue = item.kind == "Folder" ? L("폴더", "Folder") : (item.kind == "File" ? L("파일", "File") : item.kind)
        case "size": cell.textField?.stringValue = item.isDirectory ? "—" : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        default: break
        }
        cell.textField?.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
        return cell
    }
    private func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = id
        let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        var leading = cell.leadingAnchor
        if icon {
            let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image); cell.imageView = image
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20)])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { savePosition(); updateStatus() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let field = SortField(rawValue: descriptor.key ?? "") else { return }
        savePosition(); model.sort(SortOrder(field: field, ascending: descriptor.ascending))
    }
    @objc func openLocation(_ sender: LocationButton) { navigate(sender.url) }
    @objc func goBack(_ sender: Any?) { savePosition(); model.back() }
    @objc func goForward(_ sender: Any?) { savePosition(); model.forward() }
    @objc func goUp(_ sender: Any?) { if let url = model.location { navigate(url.deletingLastPathComponent()) } }
    @objc func refresh(_ sender: Any?) { savePosition(); model.reload() }
    @objc func focusPath(_ sender: Any?) { window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    @objc func submitPath(_ sender: Any?) {
        let path = (pathField.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { navigate(nil); return }
        let base = model.location ?? FileManager.default.homeDirectoryForCurrentUser
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        navigate(url); window?.makeFirstResponder(table)
    }
    @objc func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.navigate(url) }
        }
    }
    @objc func toggleHidden(_ sender: Any?) {
        savePosition(); model.showHidden.toggle(); UserDefaults.standard.set(model.showHidden, forKey: "showHidden"); model.reload()
    }
    @objc func toggleFavorite(_ sender: Any?) {
        guard let url = model.location else { return }
        if favorites.contains(url) { favorites.removeAll { $0 == url } } else { favorites.append(url) }
        UserDefaults.standard.set(favorites.map(\.path), forKey: "favorites"); buildSidebar()
    }
    @objc func openSelection(_ sender: Any?) {
        let rows = table.selectedRowIndexes
        guard let first = rows.first, model.items.indices.contains(first) else { return }
        let item = model.items[first]
        if item.isBrowsable { navigate(item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }
    @objc func revealSelection(_ sender: Any?) {
        let urls = table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].url : nil }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    private func checkChanges() {
        guard let url = model.location, !model.isLoading else { return }
        // Poll only this window's visible directory. No recursive scans.
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if observedLocation != url { observedLocation = url; lastModified = modified; return }
        if modified != lastModified { lastModified = modified; refresh(nil) }
    }
}

@MainActor
final class LocationButton: NSButton { var url: URL? }

@MainActor
final class FlippedView: NSView { override var isFlipped: Bool { true } }
