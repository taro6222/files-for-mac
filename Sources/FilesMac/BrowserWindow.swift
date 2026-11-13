import AppKit
import UniformTypeIdentifiers
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class BrowserWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSMenuDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?
    private let model: BrowserModel
    private let table = BrowserFileTable()
    private let scroll = NSScrollView()
    private let gridView = FileGridView()
    private let listView = FileListView()
    private let columnView = FileColumnView()
    private let adaptivePolicy = AdaptiveViewPolicy()
    private var adaptiveResolvedMode: BrowserViewMode = .details
    private var primaryRenderedViewMode: BrowserViewMode {
        model.viewMode == .adaptive ? adaptiveResolvedMode : model.viewMode
    }
    private let pathField = NSComboBox()
    private let status = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let recoveryActions = NSStackView()
    private let retryButton = NSButton()
    private let chooseAgainButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let hiddenButton = NSButton()
    private let viewModeButton = NSPopUpButton()
    private let refreshButton = NSButton()
    private let favoriteButton = NSButton()
    private let optionsButton = NSButton()
    private let toolbar = NSStackView()
    private let toolbarOverflow = NSPopUpButton()
    private var toolbarViews: [BrowserToolbarItem: NSView] = [:]
    private var toolbarCompact: Bool?
    private var toolbarSettingsWindow: ToolbarSettingsWindow?
    private var searchWindow: SearchWindow?
    private var infoWindow: FileInfoWindow?
    private var archiveWindow: ArchiveWindow?
    private let quickLook = QuickLookController()
    private let homeView = NSStackView()
    private let sidebar = NSStackView()
    private let content = NSView()
    private let workspaceSplit = NSSplitView()
    private var secondaryPane: SecondaryBrowserPane?
    private var secondaryActive = false
    private var primaryPaneID = UUID()
    private var secondaryPaneID: UUID?
    private var activeModel: BrowserModel { secondaryActive ? secondaryPane?.model ?? model : model }
    private var primarySelectedItems: [FileItem] {
        if primaryRenderedViewMode == .grid { return gridView.selectedItems }
        if primaryRenderedViewMode == .list { return listView.selectedItems }
        if primaryRenderedViewMode == .columns { return columnView.selectedItems }
        return table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0] : nil }
    }
    private var activeSelectedItems: [FileItem] {
        if secondaryActive { return secondaryPane?.selectedItems ?? [] }
        return primarySelectedItems
    }
    private func refreshActivePane() { if secondaryActive { secondaryPane?.refresh() } else { refresh(nil) } }
    private let preferences: BrowserPreferences
    private var preferencesToken: UUID?
    private var favorites: [URL] { preferences.favorites }
    private var recent: [URL] { preferences.recent }
    private let homeScroll = NSScrollView()
    private let optionsMenu = NSMenu()
    private lazy var commandPalette = CommandPaletteWindow()
    private var sharingPicker: NSSharingServicePicker?
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = 0
    private var suggestions: [String] = []
    private var lastRecordedLocation: URL?
    private var volumes: [MountedVolume] = []
    private var volumeTask: Task<Void, Never>?
    static private(set) var entryOperationRunning = false
    private static var operationJournalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
    }
    private var pendingEntrySelection: URL?
    private var rendering = false
    private var watcher: DirectoryWatcher?
    private enum WatcherStatus { case idle, connecting, active, unavailable }
    private var watcherStatus: WatcherStatus = .idle
    private let makeWatcher: @Sendable (URL) -> DirectoryWatcher?
    private var watcherTask: Task<Void, Never>?
    private var watchedURL: URL?
    private var pendingRefresh = false
    private var observerTokens: [NSObjectProtocol] = []
    private var iconCache: [String: NSImage] = [:]
    private let dateFormatter: DateFormatter = {
        let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d
    }()

    func tabSnapshot() -> TabSnapshot {
        savePosition(allowWhileLoading: true)
        return model.snapshot
    }
    func workspaceSnapshot() -> SplitTabState {
        let primary = PaneSnapshot(id: primaryPaneID, tab: tabSnapshot())
        guard let secondaryPane else { return SplitTabState(primary: primary) }
        let secondary = PaneSnapshot(id: secondaryPaneID ?? UUID(), tab: secondaryPane.snapshot())
        let dimension = workspaceSplit.isVertical ? workspaceSplit.bounds.width : workspaceSplit.bounds.height
        let primaryFrame = workspaceSplit.arrangedSubviews[0].frame
        let primarySize = workspaceSplit.isVertical ? primaryFrame.width : primaryFrame.height
        let ratio = dimension > 0 ? Double(primarySize / dimension) : 0.5
        return SplitTabState(primary: primary, secondary: secondary,
                             axis: workspaceSplit.isVertical ? .vertical : .horizontal,
                             ratio: ratio, activePaneID: secondaryActive ? secondary.id : primary.id)
    }
    init(preferences: BrowserPreferences = .shared, restoresFrame: Bool = true, initialLocation: URL? = nil,
         initialSnapshot: TabSnapshot? = nil,
         initialWorkspace: SplitTabState? = nil,
         loader: any DirectoryLoading = LocalFileSystem(),
         makeWatcher: @escaping @Sendable (URL) -> DirectoryWatcher? = { DirectoryWatcher(url: $0) }) {
        self.model = BrowserModel(loader: loader)
        self.preferences = preferences
        self.makeWatcher = makeWatcher
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "Files macOS"; w.minSize = NSSize(width: 900, height: 600)
        w.center()
        if restoresFrame { w.setFrameAutosaveName("BrowserWindow") }
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = Self.appearance(preferences.appearance)
        w.contentView = BrowserBackgroundView()
        model.showHidden = preferences.showHidden
        setupUI(restoresLayout: restoresFrame)
        model.onChange = { [weak self] in self?.render() }
        preferencesToken = preferences.observe { [weak self] in self?.preferencesChanged() }
        let primarySnapshot = initialWorkspace?.panes.first?.tab ?? initialSnapshot
        if let primarySnapshot { model.restore(primarySnapshot) }
        else { model.navigate(initialLocation) }
        if let initialWorkspace {
            primaryPaneID = initialWorkspace.panes[0].id
            restoreWorkspace(initialWorkspace)
        }
        refreshVolumes()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.watcherTask?.cancel()
                if let watcher = self.watcher { Task.detached { watcher.stop() } }
                self.watcher = nil
                self.model.onChange = nil; self.model.cancelLoad()
                self.completionTask?.cancel(); self.volumeTask?.cancel()
                self.secondaryPane?.shutdown()
                if let token = self.preferencesToken { self.preferences.removeObserver(token) }
                for token in self.observerTokens {
                    NotificationCenter.default.removeObserver(token)
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                }
                self.observerTokens.removeAll(); self.onClose?()
            }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.rebuildToolbar()
                if self.model.viewMode == .adaptive && !self.model.isLoading { self.render() }
            }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func appearance(_ preference: BrowserAppearance) -> NSAppearance? {
        switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func setupUI(restoresLayout: Bool) {
        guard let root = window?.contentView else { return }
        let split = NSSplitView()
        if restoresLayout { split.autosaveName = "BrowserSidebarSplit" }
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
        workspaceSplit.isVertical = true; workspaceSplit.dividerStyle = .thin
        workspaceSplit.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(workspaceSplit)
        workspaceSplit.addArrangedSubview(main)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
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

        toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 12, right: 14)
        configure(backButton, "chevron.left", L("뒤로", "Back"), #selector(goBack(_:)))
        configure(forwardButton, "chevron.right", L("앞으로", "Forward"), #selector(goForward(_:)))
        configure(upButton, "arrow.up", L("상위 폴더", "Enclosing Folder"), #selector(goUp(_:)))
        configure(refreshButton, "arrow.clockwise", L("새로고침", "Refresh"), #selector(refreshOrStop(_:)))
        pathField.numberOfVisibleItems = 8
        pathField.completes = false
        pathField.toolTip = L("경로 입력 후 아래 화살표로 추천 폴더를 선택하거나 Tab으로 완성", "Type a path, then use the dropdown or Tab to complete")
        pathField.font = .systemFont(ofSize: 13); pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = L("폴더 경로 입력", "Enter a folder path")
        pathField.target = self; pathField.action = #selector(submitPath(_:)); pathField.delegate = self
        pathField.setAccessibilityLabel(L("폴더 경로", "Folder path"))
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(hiddenButton, "eye.slash", L("숨김 항목 표시", "Show Hidden Files"), #selector(toggleHidden(_:)))
        configureViewModeButton(viewModeButton)
        configure(favoriteButton, "pin", L("즐겨찾기 전환", "Toggle Favorite"), #selector(toggleFavorite(_:)))
        optionsMenu.delegate = self
        configure(optionsButton, "slider.horizontal.3", L("보기 옵션", "View Options"), #selector(showOptions(_:)))
        toolbarViews = [.back: backButton, .forward: forwardButton, .up: upButton, .refresh: refreshButton,
                        .path: pathField, .hidden: hiddenButton, .viewMode: viewModeButton,
                        .favorite: favoriteButton, .options: optionsButton]
        for (item, view) in toolbarViews { view.identifier = NSUserInterfaceItemIdentifier("toolbar." + item.rawValue) }
        toolbarOverflow.addItem(withTitle: ""); toolbarOverflow.lastItem?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L("추가 툴바 항목", "More Toolbar Items"))
        toolbarOverflow.setAccessibilityLabel(L("추가 툴바 항목", "More Toolbar Items")); toolbarOverflow.isHidden = true
        rebuildToolbar(force: true)
        main.addArrangedSubview(toolbar)
        let divider = NSBox(); divider.boxType = .separator; main.addArrangedSubview(divider)
        main.addArrangedSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        setupTable(restoresLayout: restoresLayout)
        homeView.orientation = .vertical; homeView.alignment = .leading; homeView.spacing = 16
        homeView.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeScroll.drawsBackground = false; homeScroll.hasVerticalScroller = true
        homeScroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(homeScroll)
        let homeDocument = FlippedView(); homeDocument.translatesAutoresizingMaskIntoConstraints = false
        homeScroll.documentView = homeDocument; homeDocument.addSubview(homeView)
        NSLayoutConstraint.activate([
            homeScroll.topAnchor.constraint(equalTo: content.topAnchor), homeScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            homeScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), homeScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            homeDocument.widthAnchor.constraint(equalTo: homeScroll.contentView.widthAnchor),
            homeView.topAnchor.constraint(equalTo: homeDocument.topAnchor), homeView.bottomAnchor.constraint(equalTo: homeDocument.bottomAnchor),
            homeView.leadingAnchor.constraint(equalTo: homeDocument.leadingAnchor), homeView.trailingAnchor.constraint(equalTo: homeDocument.trailingAnchor)
        ])
        message.font = .systemFont(ofSize: 14); message.textColor = .secondaryLabelColor
        message.alignment = .center; message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(message)
        NSLayoutConstraint.activate([message.centerXAnchor.constraint(equalTo: content.centerXAnchor), message.centerYAnchor.constraint(equalTo: content.centerYAnchor), message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8)])
        recoveryActions.orientation = .horizontal; recoveryActions.spacing = 10
        recoveryActions.translatesAutoresizingMaskIntoConstraints = false
        retryButton.title = L("다시 시도", "Retry"); retryButton.bezelStyle = .rounded
        retryButton.target = self; retryButton.action = #selector(refresh(_:))
        retryButton.setAccessibilityIdentifier("recovery.retry")
        chooseAgainButton.title = L("폴더 선택…", "Choose Folder…"); chooseAgainButton.bezelStyle = .rounded
        chooseAgainButton.target = self; chooseAgainButton.action = #selector(chooseFolder(_:))
        chooseAgainButton.setAccessibilityIdentifier("recovery.chooseFolder")
        recoveryActions.addArrangedSubview(retryButton); recoveryActions.addArrangedSubview(chooseAgainButton)
        content.addSubview(recoveryActions)
        NSLayoutConstraint.activate([
            recoveryActions.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 14),
            recoveryActions.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            recoveryActions.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32)
        ])
        let bottom = NSStackView(); bottom.orientation = .horizontal
        bottom.edgeInsets = NSEdgeInsets(top: 7, left: 18, bottom: 7, right: 18)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        bottom.addArrangedSubview(status); bottom.addArrangedSubview(NSView())
        let phase = NSTextField(labelWithString: L("M3 · 보기 및 사용자 지정", "M3 · Views and customization"))
        phase.font = .systemFont(ofSize: 11); phase.textColor = .tertiaryLabelColor
        bottom.addArrangedSubview(phase); main.addArrangedSubview(bottom)
        for view in [header, toolbar, divider, content, bottom] { view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
    }

    private func setupTable(restoresLayout: Bool) {
        table.style = .fullWidth; table.rowHeight = 32; table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        if restoresLayout { table.autosaveName = "FileColumns" }
        table.autosaveTableColumns = restoresLayout
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelection(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
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
        content.addSubview(gridView)
        NSLayoutConstraint.activate([gridView.leadingAnchor.constraint(equalTo: content.leadingAnchor), gridView.trailingAnchor.constraint(equalTo: content.trailingAnchor), gridView.topAnchor.constraint(equalTo: content.topAnchor), gridView.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        content.addSubview(listView)
        NSLayoutConstraint.activate([listView.leadingAnchor.constraint(equalTo: content.leadingAnchor), listView.trailingAnchor.constraint(equalTo: content.trailingAnchor), listView.topAnchor.constraint(equalTo: content.topAnchor), listView.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        content.addSubview(columnView)
        NSLayoutConstraint.activate([columnView.leadingAnchor.constraint(equalTo: content.leadingAnchor), columnView.trailingAnchor.constraint(equalTo: content.trailingAnchor), columnView.topAnchor.constraint(equalTo: content.topAnchor), columnView.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        gridView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.primaryRenderedViewMode == .grid else { return }
            self.model.savePosition(selection: selection, scrollOffset: self.gridView.currentScrollOffset())
            self.render()
        }
        gridView.onActivate = { [weak self] in self?.setSecondaryActive(false) }
        gridView.onOpen = { [weak self] item in self?.openGridItem(item) }
        gridView.onFileDrop = { [weak self] sources, item, intent in
            guard let self, let destination = item?.isBrowsable == true ? item?.url : self.model.location else { return false }
            if intent == .move { self.prepareMove(sources: sources, destination: destination) }
            else { self.prepareCopy(sources: sources, destination: destination) }
            return true
        }
        listView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.primaryRenderedViewMode == .list else { return }
            self.model.savePosition(selection: selection, scrollOffset: self.listView.currentScrollOffset()); self.render()
        }
        listView.onActivate = { [weak self] in self?.setSecondaryActive(false) }
        listView.onOpen = { [weak self] item in self?.openRenderedItem(item) }
        listView.onFileDrop = { [weak self] sources, item, intent in
            guard let self, let destination = item?.isBrowsable == true ? item?.url : self.model.location else { return false }
            if intent == .move { self.prepareMove(sources: sources, destination: destination) }
            else { self.prepareCopy(sources: sources, destination: destination) }; return true
        }
        columnView.onSelectionChange = { [weak self] selection in
            guard let self, !self.rendering, self.primaryRenderedViewMode == .columns else { return }
            self.model.savePosition(selection: selection, scrollOffset: 0); self.render()
        }
        columnView.onActivate = { [weak self] in self?.setSecondaryActive(false) }
        columnView.onOpen = { [weak self] item in self?.openRenderedItem(item) }
        columnView.onFileDrop = { [weak self] sources, item, columnURL, intent in
            guard let self else { return false }
            let destination = item?.isBrowsable == true ? item!.url : columnURL
            if intent == .move { self.prepareMove(sources: sources, destination: destination) }
            else { self.prepareCopy(sources: sources, destination: destination) }
            return true
        }
        let menu = NSMenu()
        let folder = menu.addItem(withTitle: L("새 폴더…", "New Folder…"), action: #selector(createFolder(_:)), keyEquivalent: ""); folder.target = self
        let folderFromSelection = menu.addItem(withTitle: L("선택 항목으로 새 폴더…", "New Folder with Selection…"), action: #selector(createFolderFromSelection(_:)), keyEquivalent: ""); folderFromSelection.target = self
        let rename = menu.addItem(withTitle: L("이름 변경…", "Rename…"), action: #selector(renameSelection(_:)), keyEquivalent: ""); rename.target = self
        let batchRename = menu.addItem(withTitle: L("일괄 이름 변경…", "Batch Rename…"), action: #selector(batchRenameSelection(_:)), keyEquivalent: ""); batchRename.target = self
        let open = menu.addItem(withTitle: L("열기", "Open"), action: #selector(openSelection(_:)), keyEquivalent: ""); open.target = self
        let archive = menu.addItem(withTitle: L("압축 파일 탐색", "Browse Archive"), action: #selector(openArchive(_:)), keyEquivalent: ""); archive.target = self
        let createArchive = menu.addItem(withTitle: L("선택 항목을 ZIP으로…", "Compress Selection to ZIP…"), action: #selector(createArchive(_:)), keyEquivalent: ""); createArchive.target = self
        let copy = menu.addItem(withTitle: L("선택 항목 복사…", "Copy Selection To…"), action: #selector(copySelection(_:)), keyEquivalent: ""); copy.target = self
        let move = menu.addItem(withTitle: L("선택 항목 이동…", "Move Selection To…"), action: #selector(moveSelection(_:)), keyEquivalent: ""); move.target = self
        menu.addItem(NSMenuItem.separator())
        let delete = menu.addItem(withTitle: L("휴지통으로 이동", "Move to Trash"), action: #selector(deleteSelection(_:)), keyEquivalent: ""); delete.target = self
        let restore = menu.addItem(withTitle: L("휴지통에서 복원…", "Restore From Trash…"), action: #selector(restoreSelection(_:)), keyEquivalent: ""); restore.target = self
        let permanentDelete = menu.addItem(withTitle: L("영구 삭제…", "Delete Permanently…"), action: #selector(permanentlyDeleteSelection(_:)), keyEquivalent: "")
        permanentDelete.target = self
        delete.isEnabled = false
        restore.isEnabled = false
        permanentDelete.isEnabled = false
        let reveal = menu.addItem(withTitle: L("Finder에서 보기", "Reveal in Finder"), action: #selector(revealSelection(_:)), keyEquivalent: ""); reveal.target = self
        let share = menu.addItem(withTitle: L("공유…", "Share…"), action: #selector(shareSelection(_:)), keyEquivalent: ""); share.target = self
        let terminal = menu.addItem(withTitle: L("터미널에서 열기", "Open in Terminal"), action: #selector(openInTerminal(_:)), keyEquivalent: ""); terminal.target = self
        let openWith = menu.addItem(withTitle: L("다른 앱으로 열기…", "Open With…"), action: #selector(openWithApplication(_:)), keyEquivalent: ""); openWith.target = self
        table.menu = menu; gridView.contextMenu = menu; listView.contextMenu = menu; columnView.contextMenu = menu
    }
    private func configure(_ b: NSButton, _ symbol: String, _ title: String, _ action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.title = ""; b.imagePosition = .imageOnly; b.bezelStyle = .texturedRounded
        b.toolTip = title; b.setAccessibilityLabel(title); b.target = self; b.action = action
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
    }
    private func configureViewModeButton(_ button: NSPopUpButton) {
        button.removeAllItems()
        for (mode, title) in [(BrowserViewMode.details, L("상세", "Details")),
                              (.list, L("목록", "List")),
                              (.grid, L("그리드", "Grid")),
                              (.columns, L("컬럼", "Columns")),
                              (.adaptive, L("적응형", "Adaptive"))] {
            button.addItem(withTitle: title)
            button.lastItem?.representedObject = mode.rawValue
        }
        button.target = self; button.action = #selector(changeViewMode(_:))
        button.toolTip = L("보기 모드", "View Mode")
        button.setAccessibilityLabel(L("보기 모드", "View Mode"))
    }
    private func rebuildToolbar(force: Bool = false) {
        let compact = toolbar.bounds.width > 0 && toolbar.bounds.width < 760
        guard force || toolbarCompact != compact else { return }
        toolbarCompact = compact
        for view in toolbar.arrangedSubviews { toolbar.removeArrangedSubview(view); view.removeFromSuperview() }
        let compactOverflow: Set<BrowserToolbarItem> = [.hidden, .favorite, .options]
        let visible = preferences.toolbarOrder.filter { !preferences.hiddenToolbarItems.contains($0) }
        for item in visible where !(compact && compactOverflow.contains(item)) {
            if let view = toolbarViews[item] { toolbar.addArrangedSubview(view) }
        }
        let overflowItems = compact ? visible.filter { compactOverflow.contains($0) } : []
        configureToolbarOverflow(overflowItems)
        if !overflowItems.isEmpty { toolbar.addArrangedSubview(toolbarOverflow) }
    }
    private func configureToolbarOverflow(_ items: [BrowserToolbarItem]) {
        toolbarOverflow.removeAllItems(); toolbarOverflow.pullsDown = true
        toolbarOverflow.addItem(withTitle: ""); toolbarOverflow.lastItem?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        for item in items {
            let details = toolbarDetails(item)
            let menuItem = toolbarOverflow.menu?.addItem(withTitle: details.title, action: details.action, keyEquivalent: "")
            menuItem?.target = self
        }
        toolbarOverflow.isHidden = items.isEmpty
    }
    private func toolbarDetails(_ item: BrowserToolbarItem) -> (title: String, action: Selector) {
        switch item {
        case .back: return (L("뒤로", "Back"), #selector(goBack(_:)))
        case .forward: return (L("앞으로", "Forward"), #selector(goForward(_:)))
        case .up: return (L("상위 폴더", "Enclosing Folder"), #selector(goUp(_:)))
        case .refresh: return (L("새로고침", "Refresh"), #selector(refreshOrStop(_:)))
        case .path: return (L("경로 입력", "Go to Path"), #selector(focusPath(_:)))
        case .hidden: return (L("숨김 항목 전환", "Toggle Hidden Files"), #selector(toggleHidden(_:)))
        case .viewMode: return (L("보기 모드", "View Mode"), #selector(openViewOptions(_:)))
        case .favorite: return (L("즐겨찾기 전환", "Toggle Favorite"), #selector(toggleFavorite(_:)))
        case .options: return (L("보기 옵션", "View Options"), #selector(openViewOptions(_:)))
        }
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
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.alignment = .left; b.font = .systemFont(ofSize: 13)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading; b.imageHugsTitle = true
        b.toolTip = url?.path ?? title; b.setAccessibilityLabel(title)
        let menu = NSMenu(); menu.autoenablesItems = false
        if let url, favorites.contains(url) {
            for (label, action) in [(L("위로 이동", "Move Up"), #selector(moveFavoriteUp(_:))),
                                    (L("아래로 이동", "Move Down"), #selector(moveFavoriteDown(_:))),
                                    (L("즐겨찾기에서 제거", "Remove Favorite"), #selector(removeFavorite(_:)))] {
                let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = url
            }
            if let index = favorites.firstIndex(of: url) {
                menu.items[0].isEnabled = index > 0
                menu.items[1].isEnabled = index < favorites.count - 1
            }
        }
        if let url, let volume = volumes.first(where: { $0.url == url }) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let utility = menu.addItem(withTitle: L("디스크 유틸리티에서 열기", "Open in Disk Utility"), action: #selector(openDiskUtility(_:)), keyEquivalent: "")
            utility.target = self; utility.representedObject = volume.url
            if volume.canRequestEject {
                let eject = menu.addItem(withTitle: L("추출…", "Eject…"), action: #selector(ejectVolume(_:)), keyEquivalent: "")
                eject.target = self; eject.representedObject = volume.url
            }
        }
        if !menu.items.isEmpty { b.menu = menu }
        stack.addArrangedSubview(b)
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }
    private func buildSidebar() {
        sidebar.arrangedSubviews.forEach { sidebar.removeArrangedSubview($0); $0.removeFromSuperview() }
        locationButton(L("홈", "Home"), symbol: "house", url: nil, in: sidebar)
        for section in preferences.sidebarOrder {
            let collapsed = preferences.collapsedSidebar.contains(section)
            let title = section == .favorites ? L("즐겨찾기", "Favorites") : L("위치", "Locations")
            let disclosure = SidebarSectionButton(title: title, target: self, action: #selector(toggleSidebarSection(_:)))
            disclosure.section = section; disclosure.bezelStyle = .recessed; disclosure.isBordered = false
            disclosure.alignment = .left; disclosure.font = .systemFont(ofSize: 11, weight: .semibold)
            disclosure.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
            disclosure.imagePosition = .imageLeading; disclosure.imageHugsTitle = true
            disclosure.setAccessibilityLabel(title + (collapsed ? L(" 펼치기", " Expand") : L(" 접기", " Collapse")))
            disclosure.identifier = NSUserInterfaceItemIdentifier("sidebar." + section.rawValue)
            let menu = NSMenu(); menu.autoenablesItems = false
            for (label, action, offset) in [(L("섹션 위로", "Move Section Up"), #selector(moveSidebarUp(_:)), -1),
                                             (L("섹션 아래로", "Move Section Down"), #selector(moveSidebarDown(_:)), 1)] {
                let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = section.rawValue
                if let index = preferences.sidebarOrder.firstIndex(of: section) { item.isEnabled = preferences.sidebarOrder.indices.contains(index + offset) }
            }
            disclosure.menu = menu; sidebar.addArrangedSubview(disclosure)
            disclosure.heightAnchor.constraint(equalToConstant: 28).isActive = true
            disclosure.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -28).isActive = true
            guard !collapsed else { continue }
            switch section {
            case .favorites:
                for url in favorites { locationButton(displayName(url), symbol: "folder", url: url, in: sidebar) }
            case .locations:
                locationButton(L("사용자 폴더", "User Folder"), symbol: "person.crop.circle", url: FileManager.default.homeDirectoryForCurrentUser, in: sidebar)
                locationButton(L("응용 프로그램", "Applications"), symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications"), in: sidebar)
                for volume in volumes { locationButton(volume.name, symbol: "externaldrive", url: volume.url, in: sidebar) }
            }
        }
    }
    private func buildHome() {
        homeView.arrangedSubviews.forEach { homeView.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: L("홈", "Home")); heading.font = .systemFont(ofSize: 28, weight: .bold)
        homeView.addArrangedSubview(heading)
        let subtitle = NSTextField(labelWithString: L("파일과 폴더를 한곳에서 탐색하세요.", "Your files and folders, in one place."))
        subtitle.textColor = .secondaryLabelColor; homeView.addArrangedSubview(subtitle)
        if preferences.showHomeFavorites {
            section(L("빠른 접근", "Quick Access"), in: homeView)
            for url in favorites { locationButton(displayName(url), symbol: "folder.fill", url: url, in: homeView) }
        }
        if preferences.showHomeVolumes {
            section(L("드라이브", "Drives"), in: homeView)
            for volume in volumes {
                let card = VolumeCardView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 6
                card.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
                homeView.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: homeView.widthAnchor, constant: -64).isActive = true
                locationButton(volume.name, symbol: "externaldrive.fill", url: volume.url, in: card)
                let description = NSTextField(labelWithString: capacityDescription(volume))
                description.font = .systemFont(ofSize: 11); description.textColor = .secondaryLabelColor
                card.addArrangedSubview(description)
                if let usedFraction = volume.usedFraction {
                    let meter = NSLevelIndicator(); meter.levelIndicatorStyle = .continuousCapacity
                    meter.minValue = 0; meter.maxValue = 1; meter.doubleValue = usedFraction
                    meter.setAccessibilityLabel(L("사용한 공간 비율", "Used capacity"))
                    card.addArrangedSubview(meter); meter.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -28).isActive = true
                }
            }
        }
        if preferences.showHomeRecent {
            section(L("최근 위치", "Recent Locations"), in: homeView)
            if recent.isEmpty {
                homeView.addArrangedSubview(NSTextField(labelWithString: L("방문한 폴더가 여기에 표시됩니다.", "Folders you visit will appear here.")))
            } else {
                for url in recent { locationButton(url.path, symbol: "clock", url: url, in: homeView) }
                let clear = NSButton(title: L("최근 기록 지우기", "Clear Recent Locations"), target: self, action: #selector(clearRecent(_:)))
                clear.bezelStyle = .rounded; homeView.addArrangedSubview(clear)
            }
        }
    }
    private func displayName(_ url: URL) -> String { FileManager.default.displayName(atPath: url.path) }
    private func savePosition(allowWhileLoading: Bool = false) {
        // Partial rows may not contain the selection awaiting history restoration.
        guard !rendering, allowWhileLoading || (!model.isLoading && !model.wasCancelled) else { return }
        let ids: Set<String>; let offset: Double
        switch primaryRenderedViewMode {
        case .grid: ids = Set(gridView.selectedItems.map(\.id)); offset = gridView.currentScrollOffset()
        case .list: ids = Set(listView.selectedItems.map(\.id)); offset = listView.currentScrollOffset()
        case .columns: ids = Set(columnView.selectedItems.map(\.id)); offset = 0
        default: ids = Set(table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].id : nil }); offset = scroll.contentView.bounds.origin.y
        }
        model.savePosition(selection: ids, scrollOffset: offset)
    }
    private func navigate(_ url: URL?) {
        completionTask?.cancel(); completionGeneration += 1
        suggestions = []; pathField.removeAllItems()
        pathField.stringValue = url?.path ?? ""
        window?.makeFirstResponder(nil)
        savePosition(); model.navigate(url); applyFolderViewPreference()
    }
    private var effectiveViewSize: BrowserViewSize {
        model.location.flatMap { preferences.folderViewPreference(for: $0)?.size } ?? preferences.viewSize
    }
    private func applyFolderViewPreference() {
        guard let url = model.location, let folder = preferences.folderViewPreference(for: url) else { return }
        model.setViewMode(folder.mode)
    }
    private func render() {
        rendering = true; defer {
            rendering = false
            updateWatcher()
            if pendingRefresh && !model.isLoading && !model.wasCancelled {
                pendingRefresh = false
                let location = model.location
                Task { @MainActor [weak self] in
                    if let location { self?.requestWatcherRefresh(for: location) }
                }
            }
        }
        titleLabel.stringValue = model.location.map(displayName) ?? L("홈", "Home")
        window?.title = "\(titleLabel.stringValue) — Files macOS"
        if pathField.currentEditor() == nil { pathField.stringValue = model.location?.path ?? "" }
        backButton.isEnabled = !model.history.back.isEmpty; forwardButton.isEnabled = !model.history.forward.isEmpty
        upButton.isEnabled = model.location != nil && model.location?.path != "/"
        hiddenButton.contentTintColor = model.showHidden ? .systemBlue : .labelColor
        if let item = viewModeButton.itemArray.first(where: {
            ($0.representedObject as? String) == model.viewMode.rawValue
        }) { viewModeButton.select(item) }
        let refreshTitle = model.isLoading ? L("읽기 중단", "Stop Loading") : L("새로고침", "Refresh")
        refreshButton.image = NSImage(systemSymbolName: model.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: refreshTitle)
        refreshButton.toolTip = refreshTitle; refreshButton.setAccessibilityLabel(refreshTitle)
        if model.viewMode == .adaptive && !model.isLoading {
            adaptiveResolvedMode = adaptivePolicy.resolve(items: model.items, availableWidth: content.bounds.width)
        }
        let showsGrid = model.location != nil && primaryRenderedViewMode == .grid
        let showsList = model.location != nil && primaryRenderedViewMode == .list
        let showsColumns = model.location != nil && primaryRenderedViewMode == .columns
        scroll.isHidden = model.location == nil || showsGrid || showsList || showsColumns
        gridView.isHidden = model.location == nil || !showsGrid
        listView.isHidden = model.location == nil || !showsList
        columnView.isHidden = model.location == nil || !showsColumns
        homeScroll.isHidden = model.location != nil
        if model.location == nil { lastRecordedLocation = nil; buildHome() }
        var revealEntry = false
        if let target = pendingEntrySelection, !model.isLoading {
            pendingEntrySelection = nil
            if target.deletingLastPathComponent().standardizedFileURL == model.location {
                revealEntry = true
                model.savePosition(selection: [target.path], scrollOffset: model.history.current.scrollOffset)
            }
        }
        table.reloadData()
        let selected = IndexSet(model.items.indices.filter { model.history.current.selection.contains(model.items[$0].id) })
        table.selectRowIndexes(selected, byExtendingSelection: false)
        gridView.apply(viewSize: effectiveViewSize)
        listView.apply(viewSize: effectiveViewSize)
        gridView.update(items: model.items, selection: model.history.current.selection,
                        scrollOffset: model.history.current.scrollOffset)
        listView.update(items: model.items, selection: model.history.current.selection,
                        scrollOffset: model.history.current.scrollOffset)
        columnView.showHidden = model.showHidden; columnView.sortOrder = model.sortOrder
        columnView.update(baseURL: model.location, items: model.items, selection: model.history.current.selection)
        if !model.isLoading {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: model.history.current.scrollOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            if revealEntry, let row = selected.first { table.scrollRowToVisible(row) }
            else if model.history.current.scrollOffset > 0, let row = selected.first,
                    !NSLocationInRange(row, table.rows(in: table.visibleRect)) {
                table.scrollRowToVisible(row)
                Task { @MainActor [weak self] in self?.table.scrollRowToVisible(row) }
            }
            else if model.history.current.scrollOffset == 0 && !model.items.isEmpty { table.scrollRowToVisible(0) }
        }
        if model.isLoading && model.items.isEmpty { message.stringValue = L("폴더를 읽는 중…", "Loading folder…") }
        else if let failure = model.failure {
            message.stringValue = L("폴더를 열 수 없습니다.\n", "Unable to open this folder.\n")
                + failure.message(korean: Locale.preferredLanguages.first?.hasPrefix("ko") == true)
        }
        else if model.wasCancelled && model.items.isEmpty {
            message.stringValue = L("읽기를 중단했습니다.\n새로고침하거나 다른 폴더로 이동하세요.", "Loading stopped.\nRefresh or open another folder.")
        }
        else if model.location != nil && model.items.isEmpty { message.stringValue = L("이 폴더는 비어 있습니다.", "This folder is empty.") }
        else { message.stringValue = "" }
        message.isHidden = message.stringValue.isEmpty
        recoveryActions.isHidden = message.isHidden || model.isLoading || (model.failure == nil && !model.wasCancelled)
        if !model.isLoading && !model.wasCancelled && model.error == nil, let url = model.location, url != lastRecordedLocation {
            lastRecordedLocation = url; preferences.recordVisit(url)
        }
        updateStatus()
        if model.location != nil && window?.firstResponder === window {
            if showsGrid { gridView.focus() } else if showsList { listView.focus() } else if showsColumns { columnView.focus() } else { window?.makeFirstResponder(table) }
        }
    }
    private func updateStatus() {
        if model.location == nil { status.stringValue = L("준비됨", "Ready"); return }
        status.stringValue = "\(model.items.count) " + L("개 항목", "items")
        let selectedItems = primarySelectedItems
        if !selectedItems.isEmpty {
            status.stringValue += "  ·  \(selectedItems.count) " + L("개 선택", "selected")
            let bytes = selectedItems.reduce(Int64(0)) { total, item in
                item.isDirectory ? total : total + (item.size ?? 0)
            }
            status.stringValue += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if model.isLoading { status.stringValue += " · " + L("읽는 중…", "Loading…") }
        if model.wasCancelled { status.stringValue += " · " + L("읽기 중단 · 불완전한 목록일 수 있음", "Loading stopped · List may be incomplete") }
        if model.location != nil {
            if watcherStatus == .connecting { status.stringValue += " · " + L("자동 갱신 연결 중…", "Connecting automatic refresh…") }
            else if watcherStatus == .unavailable { status.stringValue += " · " + L("자동 갱신 사용 불가", "Automatic refresh unavailable") }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.items.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
        let item = model.items[row]
        let id = NSUserInterfaceItemIdentifier(key)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, icon: key == "name")
        switch key {
        case "name":
            cell.textField?.stringValue = item.displayName(showExtensions: preferences.showExtensions)
            cell.toolTip = item.name
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
    func tableViewSelectionDidChange(_ notification: Notification) {
        setSecondaryActive(false); savePosition(allowWhileLoading: true); updateStatus()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard model.items.indices.contains(row) else { return nil }
        return model.items[row].url as NSURL
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard primaryDropDestination(row: row, operation: dropOperation) != nil,
              !draggedURLs(info).isEmpty else { return [] }
        return dropIntent(info) == .move ? .move : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        setSecondaryActive(false)
        guard let destination = primaryDropDestination(row: row, operation: dropOperation) else { return false }
        let sources = draggedURLs(info); guard !sources.isEmpty else { return false }
        if dropIntent(info) == .move { prepareMove(sources: sources, destination: destination) }
        else { prepareCopy(sources: sources, destination: destination) }
        return true
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let field = SortField(rawValue: descriptor.key ?? "") else { return }
        savePosition(); model.sort(SortOrder(field: field, ascending: descriptor.ascending))
    }
    @objc func openLocation(_ sender: LocationButton) { navigate(sender.url) }
    @objc func goBack(_ sender: Any?) { if secondaryActive { secondaryPane?.goBack() } else { window?.makeFirstResponder(nil); savePosition(); model.back(); applyFolderViewPreference() } }
    @objc func goForward(_ sender: Any?) { if secondaryActive { secondaryPane?.goForward() } else { window?.makeFirstResponder(nil); savePosition(); model.forward(); applyFolderViewPreference() } }
    @objc func goUp(_ sender: Any?) { if secondaryActive { secondaryPane?.goUp() } else if let url = model.location { navigate(url.deletingLastPathComponent()) } }
    @objc func refresh(_ sender: Any?) { if secondaryActive { secondaryPane?.refresh() } else { savePosition(); model.reload() } }
    @objc func refreshOrStop(_ sender: Any?) {
        if activeModel.isLoading { stopLoading(sender) } else { refresh(sender) }
    }
    @objc func stopLoading(_ sender: Any?) {
        if secondaryActive { secondaryPane?.stopLoading(); return }
        pendingRefresh = false
        model.cancelLoad()
    }
    @objc func focusPath(_ sender: Any?) { if secondaryActive { secondaryPane?.focusPath() } else { window?.makeFirstResponder(pathField); pathField.selectText(nil) } }
    @objc func showSearch(_ sender: Any?) {
        guard let root = activeModel.location else { return }
        if searchWindow == nil {
            searchWindow = SearchWindow { [weak self] item in
                guard let self else { return }
                self.setSecondaryActive(false); self.pendingEntrySelection = item.url
                self.navigate(item.url.deletingLastPathComponent())
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
        searchWindow?.present(root: root, showHidden: activeModel.showHidden)
    }
    @objc func showInfo(_ sender: Any?) {
        let items = activeSelectedItems
        guard !items.isEmpty else { return }
        if infoWindow == nil { infoWindow = FileInfoWindow() }
        infoWindow?.present(items: items)
    }
    @objc func showQuickLook(_ sender: Any?) {
        let items = activeSelectedItems
        guard !items.isEmpty else { return }
        quickLook.present(items: items)
    }
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
        panel.title = L("폴더 선택", "Choose Folder")
        panel.prompt = L("열기", "Open")
        panel.message = model.failure == .permissionDenied
            ? L("접근할 폴더를 직접 선택하세요. 파일 시스템의 읽기 권한은 별도로 필요합니다.", "Select the folder to access. File system read permissions are still required.")
            : L("탐색할 폴더를 선택하세요.", "Select a folder to browse.")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.openChosenFolder(url) }
        }
    }
    private func openChosenFolder(_ url: URL) {
        if secondaryActive { secondaryPane?.open(url); return }
        let sameLocation = model.location == url.standardizedFileURL
        navigate(url)
        // An explicit selection may grant access after a previous registration failed.
        if sameLocation { updateWatcher(force: true) }
    }
    @objc func retryAutomaticRefresh(_ sender: Any?) { updateWatcher(force: true) }
    @objc func toggleHidden(_ sender: Any?) {
        preferences.setShowHidden(!preferences.showHidden)
    }
    @objc func changeViewMode(_ sender: Any?) {
        guard let button = sender as? NSPopUpButton,
              let raw = button.selectedItem?.representedObject as? String,
              let mode = BrowserViewMode(rawValue: raw) else { return }
        model.setViewMode(mode)
        if let location = model.location, let saved = preferences.folderViewPreference(for: location) {
            preferences.setFolderViewPreference(FolderViewPreference(mode: mode, size: saved.size), for: location)
        }
    }
    @objc func toggleFavorite(_ sender: Any?) {
        guard let url = activeModel.location else { return }
        preferences.toggleFavorite(url)
    }
    @objc func openSelection(_ sender: Any?) {
        if secondaryActive { secondaryPane?.openSelected(); return }
        if primaryRenderedViewMode == .grid, let item = gridView.selectedItems.first { openGridItem(item); return }
        if primaryRenderedViewMode == .list, let item = listView.selectedItems.first { openRenderedItem(item); return }
        if primaryRenderedViewMode == .columns, let item = columnView.selectedItems.first { openRenderedItem(item); return }
        if sender as? NSTableView === table && table.clickedRow < 0 { return }
        let rows = table.selectedRowIndexes
        guard let first = rows.first, model.items.indices.contains(first) else { return }
        let item = model.items[first]
        openItem(item)
    }
    private func openGridItem(_ item: FileItem) {
        openRenderedItem(item)
    }
    private func openRenderedItem(_ item: FileItem) {
        openItem(item)
    }
    private func openItem(_ item: FileItem) {
        if item.isBrowsable { navigate(item.url) }
        else if item.url.pathExtension.lowercased() == "zip" { presentArchive(item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }
    private func presentArchive(_ url: URL) {
        let controller = archiveWindow ?? ArchiveWindow(); archiveWindow = controller; controller.present(archiveURL: url)
    }
    @objc func openArchive(_ sender: Any?) {
        guard activeSelectedItems.count == 1, let item = activeSelectedItems.first, item.url.pathExtension.lowercased() == "zip" else { return }
        presentArchive(item.url)
    }
    @objc func createArchive(_ sender: Any?) {
        let sources = activeSelectedItems.map(\.url)
        guard !sources.isEmpty, !activeModel.isLoading, !ArchiveCreationWindow.isRunning, let parent = activeModel.location, let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = sources.count == 1 ? sources[0].deletingPathExtension().lastPathComponent + ".zip" : L("압축 파일.zip", "Archive.zip")
        panel.directoryURL = parent; panel.prompt = L("압축", "Compress")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            ArchiveCreationWindow.start(sources: sources, destination: destination) { self.refreshActivePane() }
        }
    }
    @objc func createFolder(_ sender: Any?) { promptForEntryName(source: nil) }
    @objc func createFolderFromSelection(_ sender: Any?) {
        let sources = activeSelectedItems.map(\.url), targetModel = activeModel
        guard !sources.isEmpty, !targetModel.isLoading, !Self.entryOperationRunning,
              !MoveWindow.isRunning, let parent = targetModel.location, let window else { return }
        let alert = NSAlert(); alert.messageText = L("선택 항목으로 새 폴더", "New Folder with Selection")
        alert.informativeText = L("새 폴더를 만든 뒤 선택한 항목을 안전한 이동 작업으로 옮깁니다.",
                                  "Create a folder, then move the selected items with the safe move operation.")
        let field = NSTextField(string: L("새 폴더", "New Folder")); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: L("만들고 이동", "Create and Move")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Self.entryOperationRunning = true
            Task {
                do {
                    let result = try await EntryOperations.createFolder(in: parent, name: field.stringValue,
                                                                         journalDirectory: Self.operationJournalDirectory)
                    Self.entryOperationRunning = false
                    if let warning = result.journalWarning { self.showEntryError(warning) }
                    MoveWindow.start(sources: sources, destination: result.target, conflictPolicy: .skip) {
                        targetModel.reload()
                    }
                } catch {
                    Self.entryOperationRunning = false
                    let text: String
                    switch error {
                    case EntryOperationError.invalidName: text = L("사용할 수 없는 폴더 이름입니다.", "The folder name is invalid.")
                    case EntryOperationError.conflict: text = L("같은 이름의 항목이 이미 있습니다.", "An item with that name already exists.")
                    default: text = error.localizedDescription
                    }
                    self.showEntryError(text)
                }
            }
        }
    }
    @objc func renameSelection(_ sender: Any?) {
        guard activeSelectedItems.count == 1 else { return }
        promptForEntryName(source: activeSelectedItems[0])
    }
    @objc func batchRenameSelection(_ sender: Any?) {
        guard activeSelectedItems.count > 1, let window else { return }
        let sources = activeSelectedItems.map(\.url)
        let alert = NSAlert(); alert.messageText = L("일괄 이름 변경", "Batch Rename")
        alert.informativeText = L("방식을 선택하고 값을 입력하세요. 다음 화면에서 실제 변경 이름을 확인합니다.",
                                  "Choose a mode and enter values. Review the resulting names on the next screen.")
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: 96)
        let mode = NSPopUpButton(); mode.addItems(withTitles: [L("찾기 및 바꾸기", "Find and Replace"), L("번호 매기기", "Numbering"), L("정규식", "Regular Expression")])
        let first = NSTextField(); first.placeholderString = L("찾을 문자열 / 기본 이름 / 정규식", "Find text / Base name / Regular expression")
        let second = NSTextField(); second.placeholderString = L("바꿀 문자열 / 시작 번호 / 치환식", "Replacement / Start number / Replacement template")
        stack.addArrangedSubview(mode); stack.addArrangedSubview(first); stack.addArrangedSubview(second); alert.accessoryView = stack
        alert.addButton(withTitle: L("미리보기", "Preview")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = first
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !first.stringValue.isEmpty, let self else { return }
            let requests: [BatchRenameRequest]
            do {
                switch mode.indexOfSelectedItem {
                case 1:
                    let start = Int(second.stringValue) ?? 1
                    guard start >= 0 else { self.showEntryError(L("시작 번호는 0 이상이어야 합니다.", "The starting number must be zero or greater.")); return }
                    requests = BatchRenamePattern.numbered(sources, base: first.stringValue, start: start)
                case 2:
                    requests = try BatchRenamePattern.regularExpression(sources, pattern: first.stringValue, replacement: second.stringValue)
                default:
                    requests = BatchRenamePattern.replacing(sources, find: first.stringValue, replacement: second.stringValue)
                }
                self.confirmBatchRename(requests)
            } catch {
                self.showEntryError(L("정규식을 해석할 수 없습니다: ", "Invalid regular expression: ") + error.localizedDescription)
            }
        }
    }
    private func confirmBatchRename(_ requests: [BatchRenameRequest]) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L("변경될 이름 미리보기", "Preview New Names")
        let preview = requests.prefix(20).map { $0.source.lastPathComponent + " → " + $0.name }.joined(separator: "\n")
        let remainder = requests.count > 20 ? L("\n…외 ", "\n…and ") + "\(requests.count - 20)" + L("개", " more") : ""
        alert.informativeText = L("실행 시 전체 계획의 중복과 기존 항목 충돌을 다시 검사합니다.\n\n",
                                  "The full plan is checked again for duplicates and existing-item conflicts before applying.\n\n") + preview + remainder
        alert.addButton(withTitle: L("이름 변경", "Rename")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            BatchRenameWindow.start(requests: requests) { [weak self] in self?.refresh(nil) }
        }
    }
    @objc func deleteSelection(_ sender: Any?) {
        guard canDeleteSelection else { return }
        guard let window else { return }
        let selected = activeSelectedItems.map(\.url)
        guard !selected.isEmpty else { return }
        let current = activeModel.location?.standardizedFileURL
        let names = selected.map(\.lastPathComponent).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = L("휴지통으로 이동", "Move to Trash")
        alert.informativeText = L("선택한 항목을 휴지통으로 이동합니다.\n\n", "Move the selected items to the Trash.\n\n") + names
        alert.addButton(withTitle: L("삭제", "Move to Trash"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self else { return }
            DeletionWindow.start(sources: selected) { [weak self] in
                if self?.activeModel.location?.standardizedFileURL == current {
                    self?.refreshActivePane()
                }
            }
        }
    }
    @objc func restoreSelection(_ sender: Any?) {
        guard canRestoreSelection else { return }
        guard let window else { return }
        let selected = activeSelectedItems.map(\.url)
        guard !selected.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("복원 위치 선택", "Choose Restore Location")
        panel.message = L("휴지통 항목을 복원할 대상 폴더를 선택하세요.", "Choose the destination folder for restore.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.prepareRestore(sources: selected, destination: destination)
        }
    }
    private func prepareRestore(sources: [URL], destination: URL) {
        RestoreWindow.start(sources: sources, destination: destination) { [weak self] in
            self?.refresh(nil)
        }
    }
    private var canDeleteSelection: Bool {
        !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning &&
        !DeletionWindow.isRunning && !activeSelectedItems.isEmpty
    }
    private var canRestoreSelection: Bool {
        !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning &&
        !DeletionWindow.isRunning && !RestoreWindow.isRunning && !activeSelectedItems.isEmpty
    }
    private var canMoveSelection: Bool {
        !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning &&
        !DeletionWindow.isRunning && !RestoreWindow.isRunning && !MoveWindow.isRunning && !PermanentDeleteWindow.isRunning &&
        !activeSelectedItems.isEmpty
    }
    @objc func permanentlyDeleteSelection(_ sender: Any?) {
        guard canPermanentDeleteSelection else { return }
        guard let window else { return }
        let selected = activeSelectedItems.map(\.url)
        guard !selected.isEmpty else { return }
        let names = selected.map(\.lastPathComponent).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = L("영구 삭제", "Delete Permanently")
        alert.alertStyle = .critical
        alert.informativeText = L("선택한 항목을 영구 삭제합니다. 이 작업은 실행 취소할 수 없습니다.", "Delete selected items permanently. This action cannot be undone.") + "\n\n" + names
        alert.addButton(withTitle: L("영구 삭제", "Delete Permanently"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self else { return }
            PermanentDeleteWindow.start(sources: selected) { [weak self] in
                self?.refresh(nil)
            }
        }
    }
    private var canPermanentDeleteSelection: Bool {
        !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning &&
        !DeletionWindow.isRunning && !RestoreWindow.isRunning && !PermanentDeleteWindow.isRunning && !activeSelectedItems.isEmpty
    }
    private func promptForEntryName(source: FileItem?) {
        let targetModel = activeModel
        guard !Self.entryOperationRunning, !CopyWindow.isRunning, !targetModel.isLoading,
              let parent = targetModel.location, let window else { return }
        let alert = NSAlert()
        alert.messageText = source == nil ? L("새 폴더", "New Folder") : L("이름 변경", "Rename")
        alert.informativeText = source?.url.path ?? parent.path
        let field = NSTextField(string: source?.name ?? L("새 폴더", "New Folder"))
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.setAccessibilityLabel(L("항목 이름", "Item name"))
        alert.accessoryView = field
        alert.addButton(withTitle: source == nil ? L("만들기", "Create") : L("변경", "Rename"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn, !Self.entryOperationRunning, !CopyWindow.isRunning else { return }
            let name = field.stringValue
            Self.entryOperationRunning = true
            Task {
                defer { Self.entryOperationRunning = false }
                do {
                    let journal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
                        .appendingPathComponent("operations")
                    let result: EntryOperationResult
                    if let source {
                        result = try await EntryOperations.rename(source.url, to: name, expectedIdentity: source.identity, journalDirectory: journal)
                    } else {
                        result = try await EntryOperations.createFolder(in: parent, name: name, journalDirectory: journal)
                    }
                    if targetModel.location == parent {
                        if targetModel === model { pendingEntrySelection = result.target.standardizedFileURL }
                        if name.hasPrefix(".") { preferences.setShowHidden(true) }
                        targetModel.reload()
                    }
                    if let warning = result.journalWarning { showEntryError(warning) }
                } catch {
                    let message: String
                    switch error {
                    case EntryOperationError.invalidName: message = L("이름을 입력하세요. /, :, NUL 및 . 또는 .. 이름은 사용할 수 없습니다.", "Enter a name without /, :, NUL; . and .. are not allowed.")
                    case EntryOperationError.conflict: message = L("같은 이름의 항목이 있습니다. 기존 항목은 변경하지 않았습니다.", "An item with this name exists. It was not changed.")
                    case EntryOperationError.sourceChanged: message = L("원본 또는 상위 폴더가 변경됐습니다. 새로고침 후 다시 시도하세요.", "The source or parent changed. Refresh and try again.")
                    default: message = error.localizedDescription
                    }
                    showEntryError(message)
                }
            }
        }
    }
    private func showEntryError(_ message: String) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert(); alert.messageText = L("파일 작업 안내", "File operation notice")
        alert.informativeText = message; alert.beginSheetModal(for: window)
    }
    @objc func copySelection(_ sender: Any?) {
        guard !Self.entryOperationRunning, !CopyWindow.isRunning, !activeModel.isLoading, let window else { return }
        let sources = activeSelectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("여기에 복사", "Copy Here")
        panel.message = L("복사할 대상 폴더를 선택하세요. 다음 화면에서 이름 충돌 정책을 선택합니다.", "Choose the destination folder. Choose the conflict policy next.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.prepareCopy(sources: sources, destination: destination)
        }
    }
    @objc func moveSelection(_ sender: Any?) {
        guard canMoveSelection else { return }
        guard let window else { return }
        let selected = activeSelectedItems.map(\.url)
        guard !selected.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("이동할 위치 선택", "Choose Move Location")
        panel.message = L("선택한 항목을 이동할 대상 폴더를 선택하세요.", "Choose destination folder for move.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.prepareMove(sources: selected, destination: destination)
        }
    }
    @objc func undoLastMove(_ sender: Any?) {
        guard !Self.entryOperationRunning, !MoveWindow.isRunning,
              let record = EntryOperations.latestUndoMove(journalDirectory: Self.operationJournalDirectory),
              let window else { return }
        let alert = NSAlert()
        alert.messageText = L("마지막 이동 실행 취소", "Undo Last Move")
        alert.informativeText = L("이동한 항목을 원래 위치로 되돌립니다. 이동 후 변경됐거나 원래 위치에 충돌이 있는 항목은 건너뜁니다.",
                                  "Return moved items to their original locations. Items changed after the move or whose original location now conflicts will be skipped.") +
            "\n\n" + L("항목: ", "Items: ") + "\(record.items.count)"
        alert.addButton(withTitle: L("실행 취소", "Undo"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Self.entryOperationRunning = true
            Task {
                let report = await EntryOperations.undoMove(record, journalDirectory: Self.operationJournalDirectory)
                Self.entryOperationRunning = false
                self.refresh(nil)
                self.showMoveUndoResult(report)
            }
        }
    }
    @objc func undoLastCopy(_ sender: Any?) {
        guard !Self.entryOperationRunning, !CopyWindow.isRunning,
              let record = CopyEngine.latestUndoCopy(journalDirectory: Self.operationJournalDirectory),
              let window else { return }
        let alert = NSAlert()
        alert.messageText = L("마지막 복사 실행 취소", "Undo Last Copy")
        alert.informativeText = L("이 앱이 마지막 복사 작업에서 만든 항목을 삭제합니다. 복사 후 변경되거나 다른 항목으로 교체된 결과는 보존합니다.",
                                  "Delete items created by this app's last copy operation. Results changed or replaced after the copy will be preserved.") +
            "\n\n" + L("항목: ", "Items: ") + "\(record.items.count)"
        alert.addButton(withTitle: L("실행 취소", "Undo"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Self.entryOperationRunning = true
            Task {
                let report = await CopyEngine.undoCopy(record, journalDirectory: Self.operationJournalDirectory)
                Self.entryOperationRunning = false
                self.refresh(nil)
                self.secondaryPane?.refresh()
                self.showCopyUndoResult(report)
            }
        }
    }
    private func showCopyUndoResult(_ report: CopyUndoResult) {
        guard let window, window.isVisible else { return }
        let completed = report.items.filter { $0.state == "completed" }.count
        let alert = NSAlert()
        alert.messageText = report.state == "completed"
            ? L("복사 실행 취소 완료", "Copy Undo Complete")
            : L("일부 복사 결과를 삭제하지 못했습니다", "Some Copied Items Were Preserved")
        let details = report.items.filter { $0.state != "completed" }.map {
            $0.target.path + "\n" + ($0.message ?? L("알 수 없는 오류", "Unknown error"))
        }.joined(separator: "\n\n")
        alert.informativeText = L("삭제: ", "Deleted: ") + "\(completed)/\(report.items.count)" +
            (details.isEmpty ? "" : "\n\n" + details) +
            (report.journalError.map { "\n\n" + L("저널 저장 오류: ", "Journal error: ") + $0 } ?? "")
        alert.beginSheetModal(for: window)
    }
    private func showMoveUndoResult(_ report: MoveUndoResult) {
        guard let window, window.isVisible else { return }
        let completed = report.items.filter { $0.state == "completed" }.count
        let alert = NSAlert()
        alert.messageText = report.state == "completed"
            ? L("이동 실행 취소 완료", "Move Undo Complete")
            : L("일부 항목을 되돌리지 못했습니다", "Some Items Could Not Be Restored")
        let details = report.items.filter { $0.state != "completed" }.map {
            $0.source.path + "\n" + ($0.message ?? L("알 수 없는 오류", "Unknown error"))
        }.joined(separator: "\n\n")
        alert.informativeText = L("복원: ", "Restored: ") + "\(completed)/\(report.items.count)" +
            (details.isEmpty ? "" : "\n\n" + details) +
            (report.journalError.map { "\n\n" + L("저널 저장 오류: ", "Journal error: ") + $0 } ?? "")
        alert.beginSheetModal(for: window)
    }
    func copyFilesToClipboard() {
        guard !activeModel.isLoading else { return }
        let urls = activeSelectedItems.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }
    private var clipboardFiles: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    var canCopyFiles: Bool { !activeModel.isLoading && !activeSelectedItems.isEmpty }
    var canPasteFiles: Bool { activeModel.location != nil && !activeModel.isLoading && !CopyWindow.isRunning && !Self.entryOperationRunning && !clipboardFiles.isEmpty }
    func pasteFilesFromClipboard() {
        guard canPasteFiles, let destination = activeModel.location else { return }
        prepareCopy(sources: clipboardFiles, destination: destination)
    }
    private func prepareCopy(sources: [URL], destination: URL) {
        guard !Self.entryOperationRunning, !CopyWindow.isRunning, !FolderMergeWindow.isRunning, let window else { return }
        let targetModel = activeModel
        let canMergeFolders = sources.contains { hasFolderMergeConflict(source: $0, destination: destination) }
        let alert = NSAlert()
        alert.messageText = L("복사 시 이름 충돌 처리", "Copy conflict policy")
        alert.informativeText = L("대상: ", "Destination: ") + destination.path + "\n" +
            L("\(sources.count)개 항목을 복사합니다. 이번 작업에서 이름이 겹치면 적용할 정책을 선택하세요. 기존 항목은 덮어쓰지 않습니다.", "Copy \(sources.count) items. Choose how this job handles conflicting names. Existing items are never overwritten.")
        if canMergeFolders { alert.addButton(withTitle: L("폴더 병합", "Merge Folders")) }
        alert.addButton(withTitle: L("양쪽 유지", "Keep Both"))
        alert.addButton(withTitle: L("건너뛰기", "Skip Conflicts"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { response in
            if canMergeFolders, response == .alertFirstButtonReturn {
                FolderMergeWindow.start(sources: sources, destination: destination) { targetModel.reload() }
                return
            }
            let keepResponse: NSApplication.ModalResponse = canMergeFolders ? .alertSecondButtonReturn : .alertFirstButtonReturn
            let skipResponse = NSApplication.ModalResponse(rawValue: keepResponse.rawValue + 1)
            guard response == keepResponse || response == skipResponse else { return }
            CopyWindow.start(sources: sources, destination: destination,
                             conflictPolicy: response == keepResponse ? .keepBoth : .skip) {
                if targetModel.location?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                    targetModel.reload()
                }
            }
        }
    }
    private func hasFolderMergeConflict(source: URL, destination: URL) -> Bool {
        var sourceInfo = stat(), targetInfo = stat()
        let target = destination.appendingPathComponent(source.lastPathComponent)
        guard lstat(source.path, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFDIR,
              lstat(target.path, &targetInfo) == 0, (targetInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        return true
    }
    private func prepareMove(sources: [URL], destination: URL) {
        guard !Self.entryOperationRunning, !MoveWindow.isRunning, let window else { return }
        let targetModel = activeModel
        let alert = NSAlert()
        alert.messageText = L("이동 시 이름 충돌 처리", "Move conflict policy")
        alert.informativeText = L("대상: ", "Destination: ") + destination.path + "\n" +
            L("\(sources.count)개 항목을 이동합니다. 이번 작업에서 이름이 겹치면 적용할 정책을 선택하세요.", "Moving \(sources.count) items. Choose how this job handles conflicting names.")
        alert.addButton(withTitle: L("건너뛰기", "Skip Conflicts"))
        alert.addButton(withTitle: L("교체", "Replace Existing"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            MoveWindow.start(sources: sources, destination: destination,
                             conflictPolicy: response == .alertSecondButtonReturn ? .replace : .skip) {
                targetModel.reload()
            }
        }
    }
    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    private func primaryDropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
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
    @objc func revealSelection(_ sender: Any?) {
        let urls = activeSelectedItems.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc func shareSelection(_ sender: Any?) {
        let urls = activeSelectedItems.map(\.url); guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls); sharingPicker = picker
        let anchor: NSView = secondaryActive ? (secondaryPane ?? content) : content
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    @objc func openInTerminal(_ sender: Any?) {
        let selected = activeSelectedItems.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() }
        let urls = Array(Set(selected.isEmpty ? [activeModel.location].compactMap { $0 } : selected)).sorted { $0.path < $1.path }
        guard !urls.isEmpty, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            showEntryError(L("터미널 또는 열 위치를 찾을 수 없습니다.", "Terminal or the location could not be found.")); return
        }
        Task { @MainActor in
            do { try await NSWorkspace.shared.open(urls, withApplicationAt: terminal, configuration: .init()) }
            catch { showEntryError(L("터미널에서 열지 못했습니다: ", "Could not open in Terminal: ") + error.localizedDescription) }
        }
    }
    @objc func openWithApplication(_ sender: Any?) {
        let urls = activeSelectedItems.map(\.url); guard !urls.isEmpty, let window else { return }
        let panel = NSOpenPanel(); panel.title = L("열 앱 선택", "Choose an Application")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let application = panel.url, let self else { return }
            Task { @MainActor in
                do { try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) }
                catch { self.showEntryError(L("선택한 앱으로 열지 못했습니다: ", "Could not open with the selected application: ") + error.localizedDescription) }
            }
        }
    }
    private func updateWatcher(force: Bool = false) {
        guard force || watchedURL != model.location else { return }
        watcherTask?.cancel()
        if let watcher { Task.detached { watcher.stop() } }
        watcher = nil; watchedURL = model.location
        watcherStatus = model.location == nil ? .idle : .connecting
        updateStatus()
        pendingRefresh = false
        guard let url = model.location else { return }
        watcherTask = Task { [weak self, makeWatcher] in
            // FSEventStreamCreate and symlink resolution may block on filesystem I/O.
            let watcher = await Task.detached(priority: .utility) { makeWatcher(url) }.value
            guard !Task.isCancelled, self?.watchedURL == url else {
                if let watcher { Task.detached { watcher.stop() } }
                return
            }
            self?.watcher = watcher
            self?.watcherStatus = watcher == nil ? .unavailable : .active
            self?.updateStatus()
            guard let watcher else { return }
            // Cover changes between the initial directory read and watcher activation.
            self?.requestWatcherRefresh(for: url)
            for await _ in watcher.events {
                guard let self, !Task.isCancelled, self.model.location == url else { return }
                self.requestWatcherRefresh(for: url)
            }
        }
    }

    private func requestWatcherRefresh(for url: URL) {
        guard model.location == url, !model.wasCancelled else { return }
        if model.isLoading { pendingRefresh = true }
        else { refresh(nil) }
    }

}

@MainActor
final class LocationButton: SidebarKeyboardButton { var url: URL? }

@MainActor
final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class BrowserFileTable: NSTableView, NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { (window?.windowController as? BrowserWindow)?.copyFilesToClipboard() }
    @objc func paste(_ sender: Any?) { (window?.windowController as? BrowserWindow)?.pasteFilesFromClipboard() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let browser = window?.windowController as? BrowserWindow
        if item.action == #selector(copy(_:)) { return browser?.canCopyFiles == true }
        if item.action == #selector(paste(_:)) { return browser?.canPasteFiles == true }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            (window?.windowController as? BrowserWindow)?.stopLoading(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private func capacityDescription(_ volume: MountedVolume) -> String {
    guard let total = volume.totalCapacity, let available = volume.availableCapacity else { return L("용량 정보 없음", "Capacity unavailable") }
    var text = ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + L(" 사용 가능 / ", " free of ") + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    if let format = volume.formatDescription { text += " · " + format }
    if volume.isReadOnly == true { text += L(" · 읽기 전용", " · Read Only") }
    return text
}

extension BrowserWindow {
    @objc func splitVertically(_ sender: Any?) { installSecondaryPane(axis: .vertical) }
    @objc func splitHorizontally(_ sender: Any?) { installSecondaryPane(axis: .horizontal) }
    @objc func closeSecondaryPane(_ sender: Any?) {
        guard let secondaryPane else { return }
        secondaryPane.shutdown(); secondaryPane.removeFromSuperview()
        self.secondaryPane = nil; secondaryPaneID = nil; secondaryActive = false
        content.wantsLayer = true; content.layer?.borderWidth = 0
        window?.makeFirstResponder(table)
    }
    private func installSecondaryPane(axis: SplitAxis, snapshot: TabSnapshot? = nil, id: UUID? = nil,
                                      ratio: Double = 0.5, activate: Bool = true) {
        workspaceSplit.isVertical = axis == .vertical
        if secondaryPane == nil {
            let pane = SecondaryBrowserPane(snapshot: snapshot ?? tabSnapshot(), preferences: preferences)
            pane.onActivate = { [weak self] in self?.setSecondaryActive(true) }
            pane.onFileDrop = { [weak self] sources, destination, intent in
                guard let self else { return false }
                if intent == .move { self.prepareMove(sources: sources, destination: destination) }
                else { self.prepareCopy(sources: sources, destination: destination) }
                return true
            }
            pane.setContextMenu(table.menu)
            secondaryPane = pane; secondaryPaneID = id ?? UUID(); workspaceSplit.addArrangedSubview(pane)
        }
        workspaceSplit.adjustSubviews()
        let dimension = workspaceSplit.isVertical ? workspaceSplit.bounds.width : workspaceSplit.bounds.height
        if dimension > 0 { workspaceSplit.setPosition(dimension * CGFloat(min(0.8, max(0.2, ratio))), ofDividerAt: 0) }
        setSecondaryActive(activate)
        if activate { secondaryPane?.focusFiles() }
    }
    private func restoreWorkspace(_ state: SplitTabState) {
        guard state.panes.count == 2 else { return }
        let secondary = state.panes[1]
        Task { @MainActor [weak self] in
            self?.installSecondaryPane(axis: state.axis, snapshot: secondary.tab, id: secondary.id,
                                       ratio: state.ratio, activate: state.activePaneID == secondary.id)
        }
    }
    private func setSecondaryActive(_ active: Bool) {
        secondaryActive = active && secondaryPane != nil
        secondaryPane?.setActive(secondaryActive)
        content.wantsLayer = true
        content.layer?.borderWidth = secondaryActive ? 0 : (secondaryPane == nil ? 0 : 2)
        content.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    private func preferencesChanged() {
        window?.appearance = Self.appearance(preferences.appearance)
        buildSidebar()
        rebuildToolbar(force: true)
        secondaryPane?.applyPreferences()
        if model.location == nil { buildHome() }
        if model.showHidden != preferences.showHidden {
            savePosition(); model.showHidden = preferences.showHidden; model.reload()
        } else if !rendering {
            savePosition(); render()
        }
    }
    @objc private func clearRecent(_ sender: Any?) { preferences.clearRecent() }
    @objc private func moveFavoriteUp(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { preferences.moveFavorite(url, by: -1) }
    }
    @objc private func moveFavoriteDown(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { preferences.moveFavorite(url, by: 1) }
    }
    @objc private func removeFavorite(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL, favorites.contains(url) { preferences.toggleFavorite(url) }
    }
    @objc private func showOptions(_ sender: NSButton) {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === optionsMenu else { return }
        menu.removeAllItems()
        let entries: [(String, Selector, Bool)] = [
            (L("파일 확장자 표시", "Show File Extensions"), #selector(toggleExtensions(_:)), preferences.showExtensions),
            (L("숨김 항목 표시", "Show Hidden Files"), #selector(toggleHidden(_:)), preferences.showHidden),
            (L("홈: 빠른 접근", "Home: Quick Access"), #selector(toggleHomeFavorites(_:)), preferences.showHomeFavorites),
            (L("홈: 드라이브", "Home: Drives"), #selector(toggleHomeVolumes(_:)), preferences.showHomeVolumes),
            (L("홈: 최근 위치", "Home: Recent Locations"), #selector(toggleHomeRecent(_:)), preferences.showHomeRecent)
        ]
        for (label, action, selected) in entries {
            let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
            item.target = self; item.state = selected ? .on : .off
        }
        menu.addItem(.separator())
        for (size, label) in [(BrowserViewSize.small, L("보기 크기: 작게", "View Size: Small")),
                              (.medium, L("보기 크기: 보통", "View Size: Medium")),
                              (.large, L("보기 크기: 크게", "View Size: Large"))] {
            let item = menu.addItem(withTitle: label, action: #selector(setViewSize(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = size.rawValue
            item.state = effectiveViewSize == size ? .on : .off
        }
        if let location = model.location {
            menu.addItem(.separator())
            let saved = preferences.folderViewPreference(for: location) != nil
            let save = menu.addItem(withTitle: L("이 폴더의 보기 저장", "Save View for This Folder"), action: #selector(saveFolderView(_:)), keyEquivalent: "")
            save.target = self; save.state = saved ? .on : .off
            let clear = menu.addItem(withTitle: L("이 폴더의 보기 초기화", "Reset View for This Folder"), action: #selector(clearFolderView(_:)), keyEquivalent: "")
            clear.target = self; clear.isEnabled = saved
        }
        menu.addItem(.separator())
        let toolbarItem = menu.addItem(withTitle: L("툴바 사용자 지정…", "Customize Toolbar…"), action: #selector(showToolbarSettings(_:)), keyEquivalent: "")
        toolbarItem.target = self
    }
    @objc private func toggleExtensions(_ sender: Any?) { preferences.setShowExtensions(!preferences.showExtensions) }
    @objc private func setViewSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = BrowserViewSize(rawValue: raw) else { return }
        if let location = model.location, preferences.folderViewPreference(for: location) != nil {
            preferences.setFolderViewPreference(FolderViewPreference(mode: model.viewMode, size: size), for: location)
        } else { preferences.setViewSize(size) }
    }
    @objc private func saveFolderView(_ sender: Any?) {
        guard let location = model.location else { return }
        preferences.setFolderViewPreference(FolderViewPreference(mode: model.viewMode, size: effectiveViewSize), for: location)
    }
    @objc private func clearFolderView(_ sender: Any?) {
        guard let location = model.location else { return }
        preferences.removeFolderViewPreference(for: location); render()
    }
    @objc private func showToolbarSettings(_ sender: Any?) {
        if toolbarSettingsWindow == nil { toolbarSettingsWindow = ToolbarSettingsWindow(preferences: preferences) }
        toolbarSettingsWindow?.present()
    }
    @objc private func toggleHomeFavorites(_ sender: Any?) { preferences.toggleSection(.favorites) }
    @objc private func toggleHomeVolumes(_ sender: Any?) { preferences.toggleSection(.volumes) }
    @objc private func toggleHomeRecent(_ sender: Any?) { preferences.toggleSection(.recent) }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSComboBox === pathField else { return }
        completionTask?.cancel(); completionGeneration += 1
        suggestions = []; pathField.removeAllItems()
        let request = completionGeneration, input = pathField.stringValue
        let base = model.location ?? FileManager.default.homeDirectoryForCurrentUser
        let hidden = preferences.showHidden
        completionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let values = try await PathCompletion().suggestions(for: input, relativeTo: base, showHidden: hidden)
                guard let self, request == self.completionGeneration, !Task.isCancelled else { return }
                self.suggestions = values
                self.pathField.removeAllItems(); self.pathField.addItems(withObjectValues: values)
            } catch {
                guard let self, request == self.completionGeneration, !Task.isCancelled else { return }
                self.suggestions = []; self.pathField.removeAllItems()
            }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === pathField && commandSelector == #selector(NSResponder.insertTab(_:)), let first = suggestions.first {
            pathField.stringValue = first; textView.string = first
            textView.setSelectedRange(NSRange(location: (first as NSString).length, length: 0))
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pathField))
            return true
        }
        return false
    }
    private func refreshVolumes() {
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { MountedVolumeProvider().mountedVolumes() }.value
            guard let self, !Task.isCancelled else { return }
            self.volumes = result; self.buildSidebar()
            if self.model.location == nil { self.buildHome() }
        }
    }

    private var fileOperationIsRunning: Bool {
        Self.entryOperationRunning || CopyWindow.isRunning || MoveWindow.isRunning || FolderMergeWindow.isRunning ||
        DeletionWindow.isRunning || PermanentDeleteWindow.isRunning || RestoreWindow.isRunning || BatchRenameWindow.isRunning
    }

    @objc private func openDiskUtility(_ sender: NSMenuItem) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") else {
            showEntryError(L("디스크 유틸리티를 찾을 수 없습니다.", "Disk Utility could not be found.")); return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration)
    }

    @objc private func ejectVolume(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let volume = volumes.first(where: { $0.url == url }), volume.canRequestEject else { return }
        guard !fileOperationIsRunning else {
            showEntryError(L("파일 작업이 진행 중이므로 드라이브를 추출할 수 없습니다. 작업이 끝난 뒤 다시 시도하세요.",
                                  "The drive cannot be ejected while a file operation is running. Try again when it finishes.")); return
        }
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L("드라이브 추출", "Eject Drive")
        alert.informativeText = L("‘\(volume.name)’ 드라이브를 안전하게 추출합니다.", "Safely eject ‘\(volume.name)’.")
        alert.addButton(withTitle: L("추출", "Eject")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            catch { self.showEntryError(L("드라이브를 추출하지 못했습니다: ", "Could not eject the drive: ") + error.localizedDescription) }
        }
    }
}

@MainActor
private final class SidebarSectionButton: SidebarKeyboardButton {
    var section: BrowserPreferences.SidebarSection = .favorites
}

extension BrowserWindow {
    @objc private func toggleSidebarSection(_ sender: SidebarSectionButton) {
        let section = sender.section
        preferences.toggleSidebar(section)
        if let replacement = sidebar.arrangedSubviews.first(where: { $0.identifier?.rawValue == "sidebar." + section.rawValue }) {
            window?.makeFirstResponder(replacement)
        }
    }
    @objc private func moveSidebarUp(_ sender: NSMenuItem) { moveSidebar(sender, by: -1) }
    @objc private func moveSidebarDown(_ sender: NSMenuItem) { moveSidebar(sender, by: 1) }
    private func moveSidebar(_ sender: NSMenuItem, by offset: Int) {
        guard let raw = sender.representedObject as? String, let section = BrowserPreferences.SidebarSection(rawValue: raw) else { return }
        preferences.moveSidebar(section, by: offset)
    }
    @objc func goHome(_ sender: Any?) { navigate(nil); focusSidebar(nil) }
    @objc func focusFiles(_ sender: Any?) {
        if secondaryActive { secondaryPane?.focusFiles() }
        else if model.location == nil { focusSidebar(nil) }
        else if primaryRenderedViewMode == .grid { gridView.focus() }
        else if primaryRenderedViewMode == .list { listView.focus() }
        else if primaryRenderedViewMode == .columns { columnView.focus() }
        else { window?.makeFirstResponder(table) }
    }
    @objc func focusSidebar(_ sender: Any?) {
        if let first = sidebar.arrangedSubviews.first { window?.makeFirstResponder(first) }
    }
    @objc func openViewOptions(_ sender: Any?) {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: content.bounds.maxX - 200, y: content.bounds.maxY), in: content)
    }
    @objc func showCommandPalette(_ sender: Any?) { commandPalette.present(relativeTo: window) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(splitVertically(_:)), #selector(splitHorizontally(_:)): return true
        case #selector(closeSecondaryPane(_:)): return secondaryPane != nil
        case #selector(undoLastMove(_:)):
            return !Self.entryOperationRunning && !MoveWindow.isRunning &&
                EntryOperations.latestUndoMove(journalDirectory: Self.operationJournalDirectory) != nil
        case #selector(undoLastCopy(_:)):
            return canUndoCopy(journalDirectory: Self.operationJournalDirectory)
        case #selector(deleteSelection(_:)): return canDeleteSelection
        case #selector(restoreSelection(_:)): return canRestoreSelection
        case #selector(permanentlyDeleteSelection(_:)): return canPermanentDeleteSelection
        case #selector(moveSelection(_:)): return canMoveSelection
        case #selector(createFolder(_:)): return activeModel.location != nil && !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning
        case #selector(createFolderFromSelection(_:)): return activeModel.location != nil && !activeModel.isLoading && !activeSelectedItems.isEmpty && !Self.entryOperationRunning && !MoveWindow.isRunning
        case #selector(renameSelection(_:)): return activeModel.location != nil && activeSelectedItems.count == 1 && !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning
        case #selector(batchRenameSelection(_:)): return activeModel.location != nil && activeSelectedItems.count > 1 && !activeModel.isLoading && !BatchRenameWindow.isRunning
        case #selector(retryAutomaticRefresh(_:)): return model.location != nil && watcherStatus != .active
        case #selector(copySelection(_:)): return !CopyWindow.isRunning && !activeModel.isLoading && !activeSelectedItems.isEmpty
        case #selector(stopLoading(_:)): return secondaryActive ? secondaryPane?.model.isLoading == true : model.isLoading
        case #selector(goBack(_:)): return secondaryActive ? !(secondaryPane?.model.history.back.isEmpty ?? true) : !model.history.back.isEmpty
        case #selector(goForward(_:)): return secondaryActive ? !(secondaryPane?.model.history.forward.isEmpty ?? true) : !model.history.forward.isEmpty
        case #selector(goUp(_:)): return secondaryActive ? secondaryPane?.model.location != nil : model.location != nil && model.location?.path != "/"
        case #selector(openSelection(_:)): return !activeSelectedItems.isEmpty && activeModel.location != nil
        case #selector(openArchive(_:)): return activeSelectedItems.count == 1 && activeSelectedItems.first?.url.pathExtension.lowercased() == "zip"
        case #selector(createArchive(_:)): return !ArchiveCreationWindow.isRunning && !activeModel.isLoading && !activeSelectedItems.isEmpty
        case #selector(revealSelection(_:)), #selector(shareSelection(_:)), #selector(openWithApplication(_:)): return !activeSelectedItems.isEmpty && activeModel.location != nil
        case #selector(openInTerminal(_:)): return activeModel.location != nil
        default: return true
        }
    }
    private func canUndoCopy(journalDirectory: URL) -> Bool {
        !Self.entryOperationRunning && !CopyWindow.isRunning && !FolderMergeWindow.isRunning &&
            CopyEngine.latestUndoCopy(journalDirectory: journalDirectory) != nil
    }
}

/// Arrow navigation works independently of macOS's optional full-keyboard-access setting.
@MainActor
class SidebarKeyboardButton: NSButton {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty && event.keyCode == 53 {
            (window?.windowController as? BrowserWindow)?.stopLoading(nil)
            return
        }
        if modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126,
           let stack = superview as? NSStackView {
            let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.isEnabled }
            if let index = buttons.firstIndex(of: self) {
                let next = index + (event.keyCode == 125 ? 1 : -1)
                if buttons.indices.contains(next) { window?.makeFirstResponder(buttons[next]) }
            }
            return
        }
        if event.keyCode == 109, event.modifierFlags.contains(.shift), let menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
            return
        }
        super.keyDown(with: event)
    }
}

#if DEBUG
private final class RetryingWatcherFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func make(_ url: URL) -> DirectoryWatcher? {
        lock.lock(); calls += 1; let attempt = calls; lock.unlock()
        return attempt == 1 ? nil : DirectoryWatcher(url: url)
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private struct DelayedUIListLoader: DirectoryLoading {
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] {
        // Deliberately ignore caller cancellation to exercise generation checks.
        await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
        return [FileItem(url: url.appendingPathComponent("ready.txt"), name: "ready.txt", isDirectory: false)]
    }
}

/// Runs against generated fixtures only; release builds contain no QA entry point.
extension BrowserWindow {
    static func runUIVerification(output: String) async {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        let suite = "FilesMac.UIVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks: [String: Bool] = [:]
        var metrics: [String: Double] = [:]
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let fixture = destination.appendingPathComponent("fixture", isDirectory: true)
            try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
            let gridFolder = fixture.appendingPathComponent("000-grid-folder", isDirectory: true)
            try fm.createDirectory(at: gridFolder, withIntermediateDirectories: true)
            let columnFolder = gridFolder.appendingPathComponent("nested-column-folder", isDirectory: true)
            try fm.createDirectory(at: columnFolder, withIntermediateDirectories: true)
            try Data("column".utf8).write(to: columnFolder.appendingPathComponent("leaf.txt"))
            for name in ["one.jpg", "two.png", "three.mov"] {
                try Data("media".utf8).write(to: columnFolder.appendingPathComponent(name))
            }
            for index in 0..<9_998 {
                let name = index == 0 ? "00000-한글-é-📁-long-file-name.txt" : String(format: "%05d-file.txt", index)
                try Data("fixture".utf8).write(to: fixture.appendingPathComponent(name))
            }
            let archiveFixture = fixture.appendingPathComponent("99998-fixture.zip")
            _ = try await ZipArchiveProvider().create(from: [fixture.appendingPathComponent("00000-한글-é-📁-long-file-name.txt")], at: archiveFixture)
            let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [fixture])
            let dark = ProcessInfo.processInfo.environment["FILES_UI_QA_THEME"] == "dark"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let controller = BrowserWindow(preferences: preferences, restoresFrame: false)
            guard let window = controller.window, let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 600), display: true)
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            func capture(_ name: String, view: NSView? = nil) throws {
                let view = view ?? root
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: destination.appendingPathComponent(name + ".png"))
            }
            try await Task.sleep(for: .milliseconds(500))
            try capture("home")
            checks["minimumWindow"] = window.frame.size == NSSize(width: 900, height: 600)
            let paletteEntries = CommandPaletteCatalog.entries(from: NSApp.mainMenu)
            checks["commandPaletteIndexesMenus"] = paletteEntries.count >= 20
            checks["commandPaletteStableIDs"] = Set(paletteEntries.map(\.id)).count == paletteEntries.count
            checks["commandPaletteSearch"] = CommandPaletteCatalog.filtered(paletteEntries, query: L("숨김", "hidden")).contains { $0.item.action == #selector(toggleHidden(_:)) }
            controller.showCommandPalette(nil); try await Task.sleep(for: .milliseconds(50))
            controller.commandPalette.qaSetQuery(L("숨김", "hidden"))
            checks["commandPaletteWindow"] = controller.commandPalette.window?.isVisible == true
                && controller.commandPalette.qaSearchFocused && controller.commandPalette.qaVisibleCount >= 1
            try capture("command-palette", view: controller.commandPalette.window?.contentView)
            controller.commandPalette.close(); window.makeKeyAndOrderFront(nil)
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.showShortcutSettings(nil); try await Task.sleep(for: .milliseconds(50))
                checks["shortcutSettingsCommands"] = delegate.qaShortcutRowCount >= 15
                checks["shortcutSettingsWindow"] = delegate.qaShortcutWindowVisible
                try capture("keyboard-shortcuts", view: delegate.qaShortcutContentView)
                delegate.qaShortcutContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showArchiveCapabilities(nil); try await Task.sleep(for: .milliseconds(50))
                checks["archiveCapabilitiesWindow"] = delegate.qaArchiveCapabilitiesVisible
                try capture("archive-capabilities", view: delegate.qaArchiveCapabilitiesContentView)
                delegate.qaArchiveCapabilitiesContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
            } else { checks["shortcutSettingsWindow"] = false }
            controller.showToolbarSettings(nil); try await Task.sleep(for: .milliseconds(50))
            checks["toolbarSettingsWindow"] = controller.toolbarSettingsWindow?.window?.isVisible == true
                && controller.toolbarSettingsWindow?.qaRowCount == BrowserToolbarItem.allCases.count
            try capture("toolbar-settings", view: controller.toolbarSettingsWindow?.window?.contentView)
            controller.toolbarSettingsWindow?.close(); window.makeKeyAndOrderFront(nil)
            controller.rebuildToolbar(force: true)
            let overflowTitles = controller.toolbarOverflow.itemArray.map(\.title)
            checks["toolbarCompactOverflow"] = controller.toolbarCompact == true
                && overflowTitles.contains(L("숨김 항목 전환", "Toggle Hidden Files"))
                && overflowTitles.contains(L("즐겨찾기 전환", "Toggle Favorite"))
            preferences.toggleToolbarItem(.favorite)
            checks["toolbarVisibilityPreference"] = preferences.hiddenToolbarItems.contains(.favorite)
                && !controller.toolbarOverflow.itemArray.map(\.title).contains(L("즐겨찾기 전환", "Toggle Favorite"))
            preferences.toggleToolbarItem(.favorite)
            let optionsIndex = preferences.toolbarOrder.firstIndex(of: .options)!
            preferences.moveToolbarItem(.options, by: -1)
            checks["toolbarOrderPreference"] = preferences.toolbarOrder.firstIndex(of: .options) == optionsIndex - 1
            preferences.moveToolbarItem(.options, by: 1)
            let appearanceSettings = AppearanceSettingsWindow(preferences: preferences)
            preferences.setFolderViewPreference(FolderViewPreference(mode: .grid, size: .large), for: fixture)
            appearanceSettings.present(); try await Task.sleep(for: .milliseconds(50))
            appearanceSettings.qaSelect(.dark)
            checks["appearanceDark"] = preferences.appearance == .dark && window.appearance?.name == .darkAqua
            appearanceSettings.qaSelect(.light)
            checks["appearanceLight"] = preferences.appearance == .light && window.appearance?.name == .aqua
            appearanceSettings.qaSelect(.system)
            checks["appearanceSystem"] = preferences.appearance == .system && window.appearance == nil
            appearanceSettings.qaSelect(dark ? .dark : .light)
            checks["appearanceSettingsWindow"] = appearanceSettings.window?.isVisible == true
            checks["folderSettingsManagement"] = appearanceSettings.qaFolderCount == 1
            try capture("appearance-settings", view: appearanceSettings.window?.contentView)
            appearanceSettings.qaResetFolderViews()
            checks["folderSettingsResetAll"] = appearanceSettings.qaFolderCount == 0
            appearanceSettings.close(); window.makeKeyAndOrderFront(nil)
            checks["pathFieldUsableWidth"] = controller.pathField.frame.width >= 160
            controller.focusPath(nil)
            checks["pathFocus"] = controller.pathField.currentEditor() != nil
            let start = ContinuousClock.now
            controller.navigate(fixture)
            var firstLayout: Double?
            while controller.model.isLoading && start.duration(to: .now) < .seconds(30) {
                if firstLayout == nil && !controller.model.items.isEmpty {
                    root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
                    firstLayout = elapsed(start)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            metrics["firstNonemptyAppKitDisplaySeconds"] = firstLayout ?? elapsed(start)
            metrics["completeAppKitDisplaySeconds"] = elapsed(start)
            checks["tenThousandRows"] = !controller.model.isLoading && controller.model.error == nil && controller.table.numberOfRows == 10_000
            controller.showSearch(nil); controller.searchWindow?.qaSearch("long-file-name", scope: .currentFolder)
            let searchStart = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && searchStart.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["searchWindow"] = controller.searchWindow?.window?.isVisible == true
            checks["searchResults"] = controller.searchWindow?.qaResultCount == 1
            checks["searchCapability"] = controller.searchWindow?.qaShowsDirectEnumeration == true
            try capture("search", view: controller.searchWindow?.window?.contentView)
            controller.searchWindow?.close(); window.makeKeyAndOrderFront(nil)
            let postSearchRefresh = ContinuousClock.now
            while controller.model.isLoading && postSearchRefresh.duration(to: .now) < .seconds(30) {
                try await Task.sleep(for: .milliseconds(10))
            }
            controller.table.selectRowIndexes([1], byExtendingSelection: false)
            controller.showInfo(nil)
            let infoStart = ContinuousClock.now
            while controller.infoWindow?.qaLoaded != true && infoStart.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            checks["fileInfoWindow"] = controller.infoWindow?.window?.isVisible == true && controller.infoWindow?.qaLoaded == true
            controller.infoWindow?.qaStartHash()
            let hashStart = ContinuousClock.now
            while controller.infoWindow?.qaHashing == true && hashStart.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            checks["fileInfoHash"] = controller.infoWindow?.qaDigest?.count == 64
            controller.infoWindow?.qaSetTags("QA, 검토")
            checks["fileInfoTags"] = controller.infoWindow?.qaTags == ["QA", "검토"]
            try capture("file-info", view: controller.infoWindow?.window?.contentView)
            controller.infoWindow?.close(); window.makeKeyAndOrderFront(nil)
            let tagRefresh = ContinuousClock.now
            while controller.model.isLoading && tagRefresh.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            controller.showSearch(nil); controller.searchWindow?.qaSearchAdvanced("long-file-name", tag: "QA", minimum: "1", maximum: "10")
            let advancedSearch = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && advancedSearch.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["searchMetadataFilters"] = controller.searchWindow?.qaResultCount == 1
            controller.searchWindow?.qaSearchAdvanced("long-file-name", tag: "QA", minimum: "0.001", maximum: "0.01", unit: .kilobytes)
            let unitSearch = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && unitSearch.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["searchSizeUnits"] = controller.searchWindow?.qaResultCount == 1
            controller.searchWindow?.qaInvalidSize(); checks["searchSizeValidation"] = controller.searchWindow?.qaValidationError == true
            try capture("search-advanced", view: controller.searchWindow?.window?.contentView)
            controller.searchWindow?.qaSearchSpotlight("files-mac-spotlight-no-match-qa")
            let spotlightSearch = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && spotlightSearch.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["spotlightSearchCapability"] = controller.searchWindow?.qaShowsSpotlight == true && controller.searchWindow?.qaIsSearching == false
            try capture("search-spotlight", view: controller.searchWindow?.window?.contentView)
            let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            controller.searchWindow?.present(root: projectRoot, showHidden: false)
            controller.searchWindow?.qaSearchSpotlight("SearchRouter", scope: .descendants)
            let spotlightHit = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && spotlightHit.duration(to: .now) < .seconds(15) { try await Task.sleep(for: .milliseconds(20)) }
            checks["spotlightContentHit"] = controller.searchWindow?.qaContainsResult(named: "LocalSearch.swift") == true
            controller.searchWindow?.close(); window.makeKeyAndOrderFront(nil)
            controller.showQuickLook(nil); try await Task.sleep(for: .milliseconds(500))
            checks["quickLookWindow"] = controller.quickLook.qaVisible
            checks["quickLookItems"] = controller.quickLook.qaItemCount == 1
            try capture("quick-look", view: controller.quickLook.qaContentView)
            controller.quickLook.close(); window.makeKeyAndOrderFront(nil)
            if let archiveItem = controller.model.items.first(where: { $0.name == archiveFixture.lastPathComponent }) {
                controller.model.savePosition(selection: [archiveItem.id], scrollOffset: 0); controller.render(); controller.openArchive(nil)
            }
            let archiveLoad = ContinuousClock.now
            while controller.archiveWindow?.qaLoaded != true && archiveLoad.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["archiveWindow"] = controller.archiveWindow?.window?.isVisible == true
            checks["archiveListing"] = controller.archiveWindow?.qaEntryCount == 1
            let archiveDestination = destination.appendingPathComponent("archive-extracted", isDirectory: true)
            if fm.fileExists(atPath: archiveDestination.path) { try fm.removeItem(at: archiveDestination) }
            try fm.createDirectory(at: archiveDestination, withIntermediateDirectories: true)
            controller.archiveWindow?.qaExtract(to: archiveDestination)
            let archiveExtract = ContinuousClock.now
            while controller.archiveWindow?.qaIsRunning == true && archiveExtract.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            let extractedArchiveText = try String(contentsOf: archiveDestination.appendingPathComponent("00000-한글-é-📁-long-file-name.txt"), encoding: .utf8)
            checks["archiveExtraction"] = controller.archiveWindow?.qaSucceeded == true && extractedArchiveText == "fixture"
            try capture("archive", view: controller.archiveWindow?.window?.contentView)
            controller.archiveWindow?.close(); window.makeKeyAndOrderFront(nil)
            let createdArchive = destination.appendingPathComponent("created-by-ui.zip")
            try? fm.removeItem(at: createdArchive)
            ArchiveCreationWindow.start(sources: [fixture.appendingPathComponent("00000-한글-é-📁-long-file-name.txt")], destination: createdArchive) {}
            let archiveCreate = ContinuousClock.now
            while ArchiveCreationWindow.qaLatest?.qaRunning == true && archiveCreate.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            let createdEntries = try ZipArchiveProvider().entries(at: createdArchive)
            checks["archiveCreation"] = ArchiveCreationWindow.qaLatest?.qaSucceeded == true && createdEntries.count == 1
            try capture("archive-creation", view: ArchiveCreationWindow.qaLatest?.window?.contentView)
            ArchiveCreationWindow.qaLatest?.close(); window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            let metadataRefresh = ContinuousClock.now
            while controller.model.isLoading && metadataRefresh.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            controller.focusFiles(nil)
            checks["fileListFocus"] = window.firstResponder === controller.table
            try capture("files-top")
            controller.table.selectRowIndexes(IndexSet(integer: 9_999), byExtendingSelection: false)
            let scrollStart = ContinuousClock.now
            controller.table.scrollRowToVisible(9_999)
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            metrics["scrollToLastRowDisplaySeconds"] = elapsed(scrollStart)
            checks["lastRowVisible"] = NSLocationInRange(9_999, controller.table.rows(in: controller.table.visibleRect))
            controller.savePosition()
            try capture("files-bottom")
            controller.goHome(nil)
            controller.goBack(nil)
            let restorationStart = ContinuousClock.now
            while controller.model.isLoading && restorationStart.duration(to: .now) < .seconds(30) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let historyDisplayStart = ContinuousClock.now
            while !NSLocationInRange(9_999, controller.table.rows(in: controller.table.visibleRect))
                    && historyDisplayStart.duration(to: .now) < .seconds(1) {
                root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["historySelection"] = controller.table.selectedRowIndexes == IndexSet(integer: 9_999)
            checks["historyScroll"] = NSLocationInRange(9_999, controller.table.rows(in: controller.table.visibleRect))
            controller.model.setViewMode(.grid)
            controller.model.savePosition(selection: [gridFolder.path], scrollOffset: 0)
            controller.render()
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            checks["gridVisible"] = !controller.gridView.isHidden && controller.scroll.isHidden
            checks["gridSelectionIdentity"] = controller.gridView.selectedItems.map(\.id) == [gridFolder.path]
            preferences.setViewSize(.large)
            checks["largeViewSizeApplied"] = controller.gridView.qaItemSize == NSSize(width: 142, height: 124)
                && controller.listView.qaRowHeight == 38
            preferences.setViewSize(.medium)
            controller.focusFiles(nil)
            checks["gridFocus"] = (window.firstResponder as? NSView)?.isDescendant(of: controller.gridView) == true
            try capture("files-grid")
            if let folderItem = controller.model.items.first(where: { $0.url.standardizedFileURL == gridFolder.standardizedFileURL }) {
                controller.openGridItem(folderItem)
            }
            checks["gridFolderOpen"] = controller.model.location == gridFolder.standardizedFileURL
            controller.goBack(nil)
            let gridBackStart = ContinuousClock.now
            while controller.model.isLoading && gridBackStart.duration(to: .now) < .seconds(30) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["gridModeRestoredAfterNavigation"] = controller.model.viewMode == .grid && controller.model.location == fixture.standardizedFileURL
            controller.model.savePosition(selection: [gridFolder.path], scrollOffset: 0)
            controller.model.setViewMode(.list)
            controller.render(); root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            checks["listVisible"] = !controller.listView.isHidden && controller.scroll.isHidden
            checks["listSelectionIdentity"] = controller.listView.selectedItems.map(\.id) == [gridFolder.path]
            controller.focusFiles(nil)
            checks["listFocus"] = (window.firstResponder as? NSView)?.isDescendant(of: controller.listView) == true
            try capture("files-list")
            if let selected = controller.listView.selectedItems.first { controller.openRenderedItem(selected) }
            checks["listFolderOpen"] = controller.model.location == gridFolder.standardizedFileURL
            controller.goBack(nil)
            let listBackStart = ContinuousClock.now
            while controller.model.isLoading && listBackStart.duration(to: .now) < .seconds(30) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["listModeRestoredAfterNavigation"] = controller.model.viewMode == .list && controller.model.location == fixture.standardizedFileURL
            controller.model.savePosition(selection: [], scrollOffset: 0)
            controller.model.setViewMode(.columns)
            controller.render(); root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            controller.columnView.qaSelect(id: gridFolder.path)
            let columnStart = ContinuousClock.now
            while controller.columnView.qaColumnCount < 2 && columnStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            controller.columnView.qaSelect(id: columnFolder.path, column: 1)
            let nestedColumnStart = ContinuousClock.now
            while controller.columnView.qaColumnCount < 3 && nestedColumnStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            checks["columnsVisible"] = !controller.columnView.isHidden && controller.scroll.isHidden
            checks["columnsHierarchy"] = controller.columnView.qaColumnCount == 3
                && controller.columnView.selectedItems.map(\.id) == [columnFolder.path]
            controller.focusFiles(nil)
            checks["columnsFocus"] = (window.firstResponder as? NSView)?.isDescendant(of: controller.columnView) == true
            try capture("files-columns")
            controller.columnView.qaMoveLeft()
            checks["columnsLeftNavigation"] = controller.columnView.qaColumnCount == 2
            if let selected = controller.columnView.selectedItems.first { controller.openRenderedItem(selected) }
            checks["columnsFolderOpen"] = controller.model.location == columnFolder.standardizedFileURL
            controller.goBack(nil)
            let columnBackStart = ContinuousClock.now
            while controller.model.isLoading && columnBackStart.duration(to: .now) < .seconds(30) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["columnsModeRestoredAfterNavigation"] = controller.model.viewMode == .columns && controller.model.location == fixture.standardizedFileURL
            controller.navigate(columnFolder)
            let adaptiveLoadStart = ContinuousClock.now
            while controller.model.isLoading && adaptiveLoadStart.duration(to: .now) < .seconds(10) {
                try await Task.sleep(for: .milliseconds(10))
            }
            controller.model.setViewMode(.adaptive); controller.render()
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            checks["adaptiveMediaUsesGrid"] = controller.model.viewMode == .adaptive
                && controller.primaryRenderedViewMode == .grid && !controller.gridView.isHidden
            controller.model.setViewMode(.details); controller.render()
            checks["adaptiveManualChoiceWins"] = controller.model.viewMode == .details
                && controller.primaryRenderedViewMode == .details && !controller.scroll.isHidden
            preferences.setFolderViewPreference(FolderViewPreference(mode: .grid, size: .large), for: columnFolder)
            controller.navigate(fixture); controller.navigate(columnFolder); controller.render()
            checks["folderViewApplied"] = controller.model.viewMode == .grid && controller.effectiveViewSize == .large
            preferences.removeFolderViewPreference(for: columnFolder); controller.render()
            checks["folderViewReset"] = preferences.folderViewPreference(for: columnFolder) == nil
                && controller.effectiveViewSize == preferences.viewSize
            controller.model.setViewMode(.details)
            controller.navigate(fixture.appendingPathComponent("missing-directory"))
            let errorStart = ContinuousClock.now
            while controller.model.isLoading && errorStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["missingDirectoryShowsError"] = controller.model.error != nil && !controller.message.isHidden && controller.table.numberOfRows == 0
            controller.retryButton.performClick(nil)
            let retryStart = ContinuousClock.now
            while controller.model.isLoading && retryStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["failedReadRetries"] = !controller.model.isLoading && controller.model.failure == .notFound
                && !controller.recoveryActions.isHidden
            try capture("error")
            let denied = fixture.appendingPathComponent("unreadable", isDirectory: true)
            try fm.createDirectory(at: denied, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
            controller.navigate(denied)
            let permissionStart = ContinuousClock.now
            while controller.model.isLoading && permissionStart.duration(to: .now) < .seconds(5) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["permissionDeniedShowsError"] = controller.model.error != nil && !controller.message.isHidden && controller.table.numberOfRows == 0
            checks["permissionRecoveryVisible"] = !controller.recoveryActions.isHidden && controller.chooseAgainButton.isEnabled
            checks["permissionErrorLocalized"] = controller.message.stringValue.contains(DirectoryFailure.permissionDenied.message(korean: Locale.preferredLanguages.first?.hasPrefix("ko") == true))
            try capture("permission-error")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
            try Data().write(to: denied.appendingPathComponent("visible.txt"))
            try Data().write(to: denied.appendingPathComponent(".hidden"))
            var peer: BrowserWindow? = BrowserWindow(preferences: preferences, restoresFrame: false)
            weak let releasedPeer = peer
            peer?.showWindow(nil)
            peer?.navigate(denied)
            controller.navigate(fixture)
            func settleWindows() async throws {
                let start = ContinuousClock.now
                while (controller.model.isLoading || peer?.model.isLoading == true) && elapsed(start) < 30 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                if controller.model.isLoading || peer?.model.isLoading == true { throw CocoaError(.validationMissingMandatoryProperty) }
            }
            try await settleWindows()
            controller.table.selectRowIndexes(IndexSet(integer: controller.table.numberOfRows - 1), byExtendingSelection: false)
            peer?.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let primarySelection = controller.model.history.current.selection
            let peerSelection = peer?.model.history.current.selection
            var repeatsPassed = true
            var durations: [Double] = []
            var cycleChecks: [[String: Bool]] = []
            let repetitions = min(100, max(5, Int(ProcessInfo.processInfo.environment["FILES_UI_QA_REPETITIONS"] ?? "5") ?? 5))
            for iteration in 0..<repetitions {
                let cycleStart = ContinuousClock.now
                preferences.setShowHidden(iteration.isMultiple(of: 2))
                preferences.setShowExtensions(!iteration.isMultiple(of: 2))
                try await settleWindows()
                peer?.window?.contentView?.layoutSubtreeIfNeeded()
                let visibleRow = peer?.model.items.firstIndex { $0.name == "visible.txt" } ?? -1
                let visibleCell = visibleRow >= 0 ? peer?.table.view(atColumn: 0, row: visibleRow, makeIfNecessary: true) as? NSTableCellView : nil
                var cycle: [String: Bool] = [
                    "peerRows": peer?.table.numberOfRows == (preferences.showHidden ? 2 : 1),
                    "extensionCell": visibleCell?.textField?.stringValue == (preferences.showExtensions ? "visible.txt" : "visible"),
                    "primarySelection": controller.model.history.current.selection == primarySelection,
                    "peerSelection": peer?.model.history.current.selection == peerSelection,
                    "locations": peer?.model.location == denied && controller.model.location == fixture]
                controller.goHome(nil); controller.goBack(nil)
                try await settleWindows()
                cycle["restoredSelection"] = controller.model.history.current.selection == primarySelection
                cycle["restoredRows"] = controller.table.numberOfRows == 10_001 && controller.model.failure == nil
                cycleChecks.append(cycle)
                repeatsPassed = repeatsPassed && cycle.values.allSatisfy { $0 }
                durations.append(elapsed(cycleStart))
            }
            checks["multiwindowCycles"] = repeatsPassed && !primarySelection.isEmpty && peerSelection?.isEmpty == false
            metrics["multiwindowCycleMinimumSeconds"] = durations.min()
            metrics["multiwindowCycleMaximumSeconds"] = durations.max()
            // Nearest-rank percentile; raw samples are included so results remain auditable.
            func p95(_ samples: [Double]) -> Double {
                samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1]
            }
            metrics["multiwindowCycleP95Seconds"] = p95(durations)
            var scrollDurations: [Double] = []
            var scrollPositionsValid = true
            for step in 0..<100 {
                let row = step * (controller.table.numberOfRows - 1) / 99
                let scrollStart = ContinuousClock.now
                controller.table.scrollRowToVisible(row)
                root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
                scrollDurations.append(elapsed(scrollStart))
                scrollPositionsValid = scrollPositionsValid && NSLocationInRange(row, controller.table.rows(in: controller.table.visibleRect))
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["hundredScrollPositions"] = scrollPositionsValid
            metrics["scrollStepP95Seconds"] = p95(scrollDurations)
            peer?.close(); peer = nil
            try await Task.sleep(for: .milliseconds(100))
            checks["closedWindowReleased"] = releasedPeer == nil
            controller.focusFiles(nil)
            checks["remainingWindowUsable"] = window.firstResponder === controller.table && controller.model.items.count == 10_001
            let factoryFinished = DispatchSemaphore(value: 0)
            let delayed = BrowserWindow(preferences: preferences, restoresFrame: false, makeWatcher: { url in
                Thread.sleep(forTimeInterval: 0.5)
                let watcher = DirectoryWatcher(url: url)
                factoryFinished.signal()
                return watcher
            })
            let navigationStart = ContinuousClock.now
            delayed.navigate(denied)
            delayed.goHome(nil)
            checks["slowWatcherDoesNotBlockNavigation"] = elapsed(navigationStart) < 0.4 && delayed.model.location == nil
            try await Task.sleep(for: .seconds(1))
            func factoryHasFinished() -> Bool { factoryFinished.wait(timeout: .now()) == .success }
            checks["lateWatcherDiscarded"] = factoryHasFinished()
                && delayed.watcher == nil && delayed.watchedURL == nil && delayed.model.location == nil
            delayed.close()
            let factory = RetryingWatcherFactory()
            let reconnect = BrowserWindow(preferences: preferences, restoresFrame: false, makeWatcher: { factory.make($0) })
            reconnect.navigate(denied)
            let initiallyConnecting = reconnect.watcherStatus == .connecting
            let firstAttempt = ContinuousClock.now
            while reconnect.watcherStatus == .connecting && elapsed(firstAttempt) < 3 {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["watcherRegistrationStatus"] = initiallyConnecting && reconnect.watcherStatus == .unavailable
            reconnect.openChosenFolder(denied)
            let retryAttempt = ContinuousClock.now
            while reconnect.watcherStatus == .connecting && elapsed(retryAttempt) < 3 {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["sameFolderReconnects"] = factory.count() == 2 && reconnect.watcherStatus == .active
            let changedFile = denied.appendingPathComponent("watcher-reconnected.txt")
            let baselineStart = ContinuousClock.now
            repeat {
                try await Task.sleep(for: .milliseconds(200))
            } while (reconnect.model.isLoading || reconnect.pendingRefresh) && elapsed(baselineStart) < 3
            let baselineReady = !reconnect.model.isLoading && !reconnect.pendingRefresh
                && !reconnect.model.items.contains { $0.name == changedFile.lastPathComponent }
            try Data("changed".utf8).write(to: changedFile)
            let changeStart = ContinuousClock.now
            while !reconnect.model.items.contains(where: { $0.name == changedFile.lastPathComponent }) && elapsed(changeStart) < 4 {
                try await Task.sleep(for: .milliseconds(20))
            }
            checks["reconnectedWatcherReceivesChanges"] = baselineReady && reconnect.model.items.contains { $0.name == changedFile.lastPathComponent }
            try fm.removeItem(at: changedFile)
            let removalStart = ContinuousClock.now
            while reconnect.model.items.contains(where: { $0.name == changedFile.lastPathComponent }) && elapsed(removalStart) < 4 {
                try await Task.sleep(for: .milliseconds(20))
            }
            checks["reconnectedWatcherReceivesDeletion"] = !reconnect.model.items.contains { $0.name == changedFile.lastPathComponent }
            reconnect.close()
            let cancellable = BrowserWindow(preferences: preferences, restoresFrame: false,
                loader: DelayedUIListLoader(), makeWatcher: { _ in nil })
            cancellable.window?.setFrame(NSRect(x: 80, y: 80, width: 900, height: 600), display: true)
            cancellable.showWindow(nil)
            cancellable.navigate(denied)
            let hadStopLabel = cancellable.refreshButton.accessibilityLabel() == L("읽기 중단", "Stop Loading")
            cancellable.refreshButton.performClick(nil)
            checks["stopButtonCancels"] = hadStopLabel && cancellable.model.wasCancelled && !cancellable.model.isLoading
                && cancellable.refreshButton.accessibilityLabel() == L("새로고침", "Refresh")
            checks["cancelledRecoveryVisible"] = !cancellable.recoveryActions.isHidden
            try capture("cancelled", view: cancellable.window?.contentView)
            try await Task.sleep(for: .milliseconds(400))
            cancellable.requestWatcherRefresh(for: denied)
            checks["cancelledReadStaysStopped"] = cancellable.model.wasCancelled && !cancellable.model.isLoading
                && cancellable.model.items.isEmpty && !cancellable.message.isHidden
            cancellable.retryButton.performClick(nil)
            try await Task.sleep(for: .milliseconds(400))
            checks["cancelledReadRetries"] = !cancellable.model.isLoading && !cancellable.model.wasCancelled
                && cancellable.model.items.map(\.name) == ["ready.txt"] && cancellable.recoveryActions.isHidden
            cancellable.close()
            let report: [String: Any] = ["checks": checks, "metrics": metrics,
                "samples": ["multiwindowCycleSeconds": durations, "scrollStepSeconds": scrollDurations],
                "cycles": cycleChecks,
                "language": Locale.preferredLanguages.first ?? "unknown", "theme": dark ? "dark" : "light",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "measurement": "Warm local fixture; AppKit layout/display completion, not compositor presentation. Percentiles describe this run only."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("report.json"))
            try fm.removeItem(at: fixture)
            // End the QA process only after deferred preference cleanup runs.
            DispatchQueue.main.async { exit(checks.values.allSatisfy { $0 } ? 0 : 1) }
        } catch {
            fputs("UI verification failed: \(error)\n", stderr)
            DispatchQueue.main.async { exit(1) }
        }
    }
    static func runM2UIVerification(output: String) async {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        let root = destination.appendingPathComponent("m2-fixture", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let journals = root.appendingPathComponent("journals", isDirectory: true)
        let suite = "FilesMac.M2UIVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        do {
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let mergeSource = source.appendingPathComponent("merge", isDirectory: true)
            let mergeTarget = target.appendingPathComponent("merge", isDirectory: true)
            try fm.createDirectory(at: mergeSource, withIntermediateDirectories: true)
            try fm.createDirectory(at: mergeTarget, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
            try Data("nested".utf8).write(to: mergeSource.appendingPathComponent("nested.txt"))
            try Data("keep".utf8).write(to: mergeTarget.appendingPathComponent("keep.txt"))
            try Data("source".utf8).write(to: source.appendingPathComponent("conflict.txt"))
            try Data("target".utf8).write(to: target.appendingPathComponent("conflict.txt"))
            let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [target])
            let dark = ProcessInfo.processInfo.environment["FILES_UI_QA_THEME"] == "dark"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let controller = BrowserWindow(preferences: preferences, restoresFrame: false)
            guard let window = controller.window, let content = window.contentView else { throw CocoaError(.coderInvalidValue) }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 600), display: true)
            controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
            func settle() async throws {
                let start = ContinuousClock.now
                while controller.model.isLoading && elapsed(start) < 10 { try await Task.sleep(for: .milliseconds(10)) }
                if controller.model.isLoading { throw CocoaError(.validationMissingMandatoryProperty) }
                content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            }
            func capture(_ name: String) throws {
                guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.fileWriteUnknown) }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: destination.appendingPathComponent(name + ".png"))
            }
            controller.navigate(target); try await settle()
            let report = await CopyMergeBatch.run(
                sources: [source.appendingPathComponent("new.txt"), mergeSource, source.appendingPathComponent("conflict.txt")],
                destination: target, journalDirectory: journals, cancellation: CopyCancellation())
            controller.refresh(nil); try await settle()
            checks["batchCompleted"] = report.state == "completed" && report.items.map(\.state) == ["completed", "merged", "conflict"]
            checks["listReflectsCopy"] = controller.model.items.contains { $0.name == "new.txt" }
            checks["mergePreservesConflict"] = (try String(contentsOf: target.appendingPathComponent("conflict.txt"), encoding: .utf8)) == "target"
            checks["mergeAddsNested"] = fm.fileExists(atPath: mergeTarget.appendingPathComponent("nested.txt").path)
            checks["splitWorkspace"] = { controller.splitVertically(nil); return controller.workspaceSnapshot().isSplit }()
            guard let secondary = controller.secondaryPane else { throw CocoaError(.validationMissingMandatoryProperty) }
            let secondaryStart = ContinuousClock.now
            while secondary.model.isLoading && elapsed(secondaryStart) < 10 { try await Task.sleep(for: .milliseconds(10)) }
            guard let secondaryMerge = secondary.model.items.first(where: { $0.url.standardizedFileURL == mergeTarget.standardizedFileURL }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            secondary.model.savePosition(selection: [secondaryMerge.id], scrollOffset: 0)
            secondary.model.setViewMode(.grid)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            checks["secondaryGridSelection"] = secondary.selectedItems.map(\.id) == [secondaryMerge.id]
            let primaryGridIntegration = (controller.gridView.contextMenu === controller.table.menu,
                                          controller.gridView.qaHasDropHandler,
                                          controller.gridView.qaPasteboardURL(at: 0))
            let secondaryGridIntegration = secondary.qaGridIntegration()
            checks["gridContextCommands"] = primaryGridIntegration.0 && secondaryGridIntegration.menu
            let contextActions = Set(controller.table.menu?.items.compactMap(\.action) ?? [])
            checks["systemOpenCommands"] = [#selector(revealSelection(_:)), #selector(shareSelection(_:)), #selector(openInTerminal(_:)), #selector(openWithApplication(_:))].allSatisfy(contextActions.contains)
            checks["archiveContextCommands"] = [#selector(openArchive(_:)), #selector(createArchive(_:))].allSatisfy(contextActions.contains)
            checks["gridDragSources"] = primaryGridIntegration.1 && secondaryGridIntegration.drop
                && primaryGridIntegration.2 != nil && secondaryGridIntegration.source != nil
            diagnostics["secondaryRequestedSelection"] = secondaryMerge.id
            diagnostics["secondaryHistorySelection"] = Array(secondary.model.history.current.selection).sorted()
            diagnostics["secondaryRenderedSelection"] = secondary.selectedItems.map(\.id)
            diagnostics["secondaryItemCount"] = secondary.model.items.count
            secondary.openSelected()
            checks["secondaryGridFolderOpen"] = secondary.model.location == mergeTarget.standardizedFileURL
            secondary.goBack()
            let secondaryBackStart = ContinuousClock.now
            while secondary.model.isLoading && elapsed(secondaryBackStart) < 10 { try await Task.sleep(for: .milliseconds(10)) }
            checks["secondaryGridSession"] = secondary.snapshot().viewMode == .grid
            guard let secondaryMergeAgain = secondary.model.items.first(where: { $0.url.standardizedFileURL == mergeTarget.standardizedFileURL }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            secondary.model.savePosition(selection: [secondaryMergeAgain.id], scrollOffset: 0)
            secondary.model.setViewMode(.list)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            checks["secondaryListSelection"] = secondary.selectedItems.map(\.id) == [secondaryMergeAgain.id]
            secondary.openSelected()
            checks["secondaryListFolderOpen"] = secondary.model.location == mergeTarget.standardizedFileURL
            secondary.goBack()
            let secondaryListBackStart = ContinuousClock.now
            while secondary.model.isLoading && elapsed(secondaryListBackStart) < 10 { try await Task.sleep(for: .milliseconds(10)) }
            checks["secondaryListSession"] = secondary.snapshot().viewMode == .list
            guard let secondaryColumnFolder = secondary.model.items.first(where: { $0.url.standardizedFileURL == mergeTarget.standardizedFileURL }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            secondary.model.savePosition(selection: [], scrollOffset: 0)
            secondary.model.setViewMode(.columns)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            secondary.qaSelectColumn(id: secondaryColumnFolder.id)
            let secondaryColumnStart = ContinuousClock.now
            while secondary.qaColumnCount < 2 && elapsed(secondaryColumnStart) < 10 { try await Task.sleep(for: .milliseconds(10)) }
            checks["secondaryColumnsHierarchy"] = secondary.qaColumnCount == 2
                && secondary.selectedItems.map(\.id) == [secondaryColumnFolder.id]
            checks["secondaryColumnsSession"] = secondary.snapshot().viewMode == .columns
            let primaryColumnIntegration = (controller.columnView.qaHasDropHandler, controller.columnView.qaPasteboardURL())
            let secondaryColumnIntegration = secondary.qaColumnIntegration
            checks["columnContextCommands"] = primaryColumnIntegration.0 && secondaryColumnIntegration.ready
            checks["columnDragSources"] = primaryColumnIntegration.1 != nil && secondaryColumnIntegration.source != nil
            secondary.model.setViewMode(.adaptive)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            checks["secondaryAdaptiveCompactList"] = secondary.snapshot().viewMode == .adaptive
                && secondary.qaRenderedViewMode == .list
            preferences.setViewSize(.small)
            checks["secondaryViewSizeApplied"] = secondary.qaGridItemSize == NSSize(width: 96, height: 84)
                && secondary.qaListRowHeight == 26
            preferences.setViewSize(.medium)
            let undoMenu = NSMenuItem(title: "", action: #selector(undoLastCopy(_:)), keyEquivalent: "")
            checks["undoMenuAction"] = undoMenu.action == #selector(undoLastCopy(_:))
            checks["undoMenuEnabled"] = controller.canUndoCopy(journalDirectory: journals)
            try capture("merged-split")
            guard let undo = CopyEngine.latestUndoCopy(journalDirectory: journals) else { throw CocoaError(.fileNoSuchFile) }
            let undoResult = await CopyEngine.undoCopy(undo, journalDirectory: journals)
            controller.closeSecondaryPane(nil); controller.refresh(nil); try await settle()
            checks["undoCompleted"] = undoResult.state == "completed"
            checks["undoUpdatesList"] = !controller.model.items.contains { $0.name == "new.txt" }
            checks["undoPreservesExisting"] = fm.fileExists(atPath: mergeTarget.appendingPathComponent("keep.txt").path)
                && !fm.fileExists(atPath: mergeTarget.appendingPathComponent("nested.txt").path)
            try capture("after-undo")
            let result: [String: Any] = ["checks": checks, "diagnostics": diagnostics,
                "language": Locale.preferredLanguages.first ?? "unknown", "theme": dark ? "dark" : "light",
                "os": ProcessInfo.processInfo.operatingSystemVersionString]
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("report.json"))
            controller.close()
            DispatchQueue.main.async { exit(checks.values.allSatisfy { $0 } ? 0 : 1) }
        } catch {
            fputs("M2 UI verification failed: \(error)\n", stderr)
            DispatchQueue.main.async { exit(1) }
        }
    }
    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
#endif

/// Paint semantic colors during drawing so theme changes also update cached views.
private final class BrowserBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class VolumeCardView: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
