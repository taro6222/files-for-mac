import AppKit
import ImageIO
import UniformTypeIdentifiers
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class BrowserWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSMenuDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?
    private let model: BrowserModel
    private let table = BrowserFileTable()
#if RELEASE_PERFORMANCE_QA
    // Sampling must leave the table cells free to deallocate between cycles.
    private let soakDetailCells = NSHashTable<NSTableCellView>.weakObjects()
    private var countsSoakDetailCells = false
#endif
    private let scroll = NSScrollView()
    private let detailHost = NSView()
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
    private static let refreshImage = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    private static let stopLoadingImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    private let favoriteButton = NSButton()
    private let optionsButton = NSButton()
    private let shelfToggle = NSButton()
    private let shelf = ShelfPane()
    private var appliedSharedFolderLayout = false
    private let toolbar = NSStackView()
    private let bottom = NSStackView()
    private let toolbarOverflow = NSPopUpButton()
    private let rootSplit = NSSplitView()
    private let inspector = BrowserInfoPane()
    private var inspectorWidth: NSLayoutConstraint?
    private let sidebarContainer = NSVisualEffectView()
    private var toolbarViews: [BrowserToolbarItem: NSView] = [:]
    private var toolbarCompact: Bool?
    private var toolbarSettingsWindow: ToolbarSettingsWindow?
    private var searchWindow: SearchWindow?
    private var infoWindow: FileInfoWindow?
    private var archiveWindow: ArchiveWindow?
    private let quickLook = QuickLookController()
    private let homeView = NSStackView()
    private let homeRecentView = NSStackView()
    private var homeNeedsUpdate = true
    private var homeRecentNeedsUpdate = true
    private let sidebar = NSStackView()
    private let content = AppBackgroundView()
    private let folderFilter = FolderFilterField()
    private let workspaceSplit = WorkspaceSplitView()
    private let primaryPaneHost = NSView()
    private let secondaryPaneHost = NSView()
    private var secondaryPane: SecondaryBrowserPane?
    private var isRestoringSplitWorkspace = false
    private var secondaryActive = false
    private var primaryPaneID = UUID()
    private var secondaryPaneID: UUID?
    private var detailRows: [DetailDisplayRow] = []
    private var detailPresentationNeedsReload = true
    private var activeModel: BrowserModel { secondaryActive ? secondaryPane?.model ?? model : model }
    var activeLocation: URL? { activeModel.location }
    private var primarySelectedItems: [FileItem] {
        if primaryRenderedViewMode == .grid { return gridView.selectedItems }
        if primaryRenderedViewMode == .list { return listView.selectedItems }
        if primaryRenderedViewMode == .columns { return columnView.selectedItems }
        return table.selectedRowIndexes.compactMap { detailItem(at: $0, in: detailRows) }
    }
    private var activeSelectedItems: [FileItem] {
        if secondaryActive { return secondaryPane?.selectedItems ?? [] }
        return primarySelectedItems
    }
    private func refreshActivePane() { if secondaryActive { secondaryPane?.refresh() } else { refresh(nil) } }
    private let preferences: BrowserPreferences
    private var preferencesToken: UUID?
    private var recentLocationsToken: UUID?
    private var favorites: [URL] { preferences.favorites }
    private var recent: [URL] { preferences.recent }
    private let homeScroll = NSScrollView()
    private let optionsMenu = NSMenu()
    private var compressionMenuItems: [NSMenuItem] = []
    private var openTerminalMenuItem: NSMenuItem?
    private var createFolderWithSelectionMenuItem: NSMenuItem?
    private var createSymbolicLinkMenuItem: NSMenuItem?
    private var pinToSidebarMenuItem: NSMenuItem?
    private var shareMenuItem: NSMenuItem?
    private var copyPathMenuItems: [NSMenuItem] = []
    private var openInNewTabMenuItem: NSMenuItem?
    private var openInNewWindowMenuItem: NSMenuItem?
    private var openInNewPaneMenuItem: NSMenuItem?
    private var editTagsMenuItem: NSMenuItem?
    private lazy var commandPalette = CommandPaletteWindow()
    private var sharingPicker: NSSharingServicePicker?
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = 0
    private var suggestions: [String] = []
    private var lastRecordedLocation: URL?
    private var volumes: [MountedVolume] = []
    private var volumeTask: Task<Void, Never>?
    private var cloudLocations: [CloudLocation] = []
    private var cloudTask: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?
    private var gitGeneration = 0
    private var gitLocation: URL?
    private var gitStatuses: [String: String] = [:]
    private var gitChangedPaths: [String] = []
    private var gitCommitRoot: URL?
    private var gitCommits: [URL: GitFileCommit] = [:]
    private var gitCommitRequested: Set<URL> = []
    private var gitCommitQueue: [URL] = []
    private var gitCommitTask: Task<Void, Never>?
    private var gitObservedLoading = false
    private var autoFitObservedLoading = false
    private var folderSizeTask: Task<Void, Never>?
    private let cloudProvider: CloudLocationProvider
    private let openSystemURL: (URL) -> Bool
    private let undoJournalDirectory: URL
    private let filePasteboard: NSPasteboard
    static private(set) var entryOperationRunning = false
    private static var pendingMoveRedo: MoveRedoRecord?
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
    private var compactOverlayState: (frame: NSRect, minSize: NSSize, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior)?
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
         cloudProvider: CloudLocationProvider = CloudLocationProvider(),
         makeWatcher: @escaping @Sendable (URL) -> DirectoryWatcher? = { DirectoryWatcher(url: $0) },
         openSystemURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         undoJournalDirectory: URL? = nil,
         filePasteboard: NSPasteboard = .general) {
        self.model = BrowserModel(loader: loader)
        self.preferences = preferences
        FileIconCache.shared.configure(enabled: preferences.enableThumbnailCache, limitMiB: preferences.thumbnailCacheLimitMiB)
        self.cloudProvider = cloudProvider
        self.makeWatcher = makeWatcher
        self.openSystemURL = openSystemURL
        self.undoJournalDirectory = undoJournalDirectory ?? Self.operationJournalDirectory
        self.filePasteboard = filePasteboard
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
        applyAppBackground()
        model.onChange = { [weak self] in self?.render() }
        preferencesToken = preferences.observe(includesRecentLocations: false) { [weak self] in self?.preferencesChanged() }
        recentLocationsToken = preferences.observeRecentLocations { [weak self] in
            guard let self else { return }
            self.homeRecentNeedsUpdate = true
            if self.model.location == nil { self.updateHomeIfNeeded() }
        }
        let primarySnapshot = initialWorkspace?.panes.first?.tab ?? initialSnapshot
        if let primarySnapshot { model.restore(primarySnapshot) }
        else {
            model.sort(SortOrder(directoryPlacement: preferences.defaultSortDirectoryPlacement))
            model.navigate(initialLocation)
        }
        if let initialWorkspace {
            primaryPaneID = initialWorkspace.panes[0].id
            restoreWorkspace(initialWorkspace)
        }
        if preferences.syncFolderLayouts { applyFolderViewPreference() }
        refreshVolumes()
        refreshCloudLocations()
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
                self.completionTask?.cancel(); self.volumeTask?.cancel(); self.cloudTask?.cancel(); self.gitTask?.cancel(); self.folderSizeTask?.cancel()
                self.resetGitCommits()
                self.inspector.clear()
                self.secondaryPane?.shutdown()
                if let token = self.preferencesToken { self.preferences.removeObserver(token) }
                if let token = self.recentLocationsToken { self.preferences.removeObserver(token) }
                for token in self.observerTokens {
                    NotificationCenter.default.removeObserver(token)
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                }
                self.observerTokens.removeAll(); self.onClose?()
                // The close callback can still read the workspace's selection and layout.
                self.window?.contentView = nil
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
        let split = rootSplit
        if restoresLayout { split.autosaveName = "BrowserSidebarSplit" }
        split.isVertical = true; split.dividerStyle = .thin; split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let sideEffect = sidebarContainer
        sideEffect.material = .sidebar; sideEffect.blendingMode = .behindWindow; sideEffect.state = .active
        split.addArrangedSubview(sideEffect)
        let sidebarMinimumWidth = sideEffect.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        let sidebarMaximumWidth = sideEffect.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        sidebarMinimumWidth.priority = .defaultHigh; sidebarMaximumWidth.priority = .defaultHigh
        sidebarMinimumWidth.isActive = true; sidebarMaximumWidth.isActive = true
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
        inspector.isHidden = true
        inspector.onTabChange = { [weak self] tab in self?.preferences.setInfoPaneTab(tab) }
        split.addArrangedSubview(inspector)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 240)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        workspaceSplit.addArrangedSubview(primaryPaneHost)
        embedPane(main, in: primaryPaneHost)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setPosition(220, ofDividerAt: 0)

        let header = TabScrollStackView(); header.orientation = .horizontal; header.spacing = 10
        header.onTabScroll = { [weak self] deltaX, deltaY in
            guard let self, let direction = TabScrollDirection.resolve(deltaX: deltaX, deltaY: deltaY, reversed: self.preferences.reverseTabScrollDirection),
                  let delegate = NSApp.delegate as? AppDelegate else { return }
            direction == .next ? delegate.nextTab(nil) : delegate.previousTab(nil)
        }
        header.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 10, right: 18)
        let brand = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
        brand.contentTintColor = .systemBlue; brand.widthAnchor.constraint(equalToConstant: 22).isActive = true
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(brand); header.addArrangedSubview(titleLabel); header.addArrangedSubview(NSView())
        let choose = button("folder.badge.plus", L("폴더 열기", "Open Folder"), #selector(chooseFolder(_:)))
        header.addArrangedSubview(choose)
        let tabDrag = WorkspaceTabDragHandle()
        header.addArrangedSubview(tabDrag)
        main.addArrangedSubview(header)

        toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 12, right: 14)
        configure(backButton, "chevron.left", L("뒤로", "Back"), #selector(goBack(_:)))
        configure(forwardButton, "chevron.right", L("앞으로", "Forward"), #selector(goForward(_:)))
        configure(upButton, "arrow.up", L("상위 폴더", "Enclosing Folder"), #selector(goUp(_:)))
        configure(refreshButton, "arrow.clockwise", L("새로고침", "Refresh"), #selector(refreshOrStop(_:)))
        refreshButton.image = Self.refreshImage
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
        configure(shelfToggle, "tray", L("임시 파일 모음", "Shelf"), #selector(toggleShelfPane(_:)))
        toolbarViews = [.back: backButton, .forward: forwardButton, .up: upButton, .refresh: refreshButton,
                        .path: pathField, .hidden: hiddenButton, .viewMode: viewModeButton,
                        .favorite: favoriteButton, .options: optionsButton]
        for (item, view) in toolbarViews { view.identifier = NSUserInterfaceItemIdentifier("toolbar." + item.rawValue) }
        toolbarOverflow.addItem(withTitle: ""); toolbarOverflow.lastItem?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L("추가 툴바 항목", "More Toolbar Items"))
        toolbarOverflow.setAccessibilityLabel(L("추가 툴바 항목", "More Toolbar Items")); toolbarOverflow.isHidden = true
        rebuildToolbar(force: true)
        main.addArrangedSubview(toolbar)
        let divider = NSBox(); divider.boxType = .separator; main.addArrangedSubview(divider)
        folderFilter.onChange = { [weak self] query in
            self?.setSecondaryActive(false)
            self?.model.setNameFilter(query)
        }
        main.addArrangedSubview(folderFilter)
        main.addArrangedSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        let preferredContentHeight = content.heightAnchor.constraint(greaterThanOrEqualToConstant: 350)
        preferredContentHeight.priority = .defaultLow
        preferredContentHeight.isActive = true
        setupTable(restoresLayout: restoresLayout)
        homeView.orientation = .vertical; homeView.alignment = .leading; homeView.spacing = 16
        homeView.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        homeRecentView.orientation = .vertical; homeRecentView.alignment = .leading
        homeRecentView.spacing = homeView.spacing
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
        bottom.orientation = .horizontal
        bottom.edgeInsets = NSEdgeInsets(top: 7, left: 18, bottom: 7, right: 18)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        bottom.addArrangedSubview(status); bottom.addArrangedSubview(NSView())
        shelf.onDrop = { [weak self] urls in self?.preferences.addToShelf(urls) }
        shelf.onOperation = { [weak self] operation, entries in self?.performShelfOperation(operation, entries: entries) }
        main.addArrangedSubview(shelf)
        updateShelf()
        main.addArrangedSubview(bottom)
        toolbar.isHidden = !preferences.showToolbar
        bottom.isHidden = !preferences.showStatusBar
        sidebarContainer.isHidden = !preferences.showSidebar
        for view in [header, toolbar, divider, folderFilter, content, shelf, bottom] { view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
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
        let specs: [(String, String, CGFloat)] = [("name", L("이름", "Name"), 340), ("git", "Git", 72),
            ("gitCommitDate", L("Git 커밋 날짜", "Git Commit Date"), 140),
            ("gitCommitMessage", L("Git 커밋 메시지", "Git Commit Message"), 140),
            ("gitCommitAuthor", L("Git 커밋 작성자", "Git Commit Author"), 140),
            ("gitCommitSHA", L("Git 커밋 SHA", "Git Commit SHA"), 100),
            ("syncStatus", L("동기화 상태", "Sync Status"), 150), ("tag", L("Finder 태그", "Finder Tags"), 150), ("path", L("폴더 경로", "Folder Path"), 260),
            ("created", L("생성일", "Date Created"), 200), ("modified", L("수정일", "Date Modified"), 185),
            ("kind", L("종류", "Kind"), 140), ("size", L("크기", "Size"), 100)]
        for (key, label, width) in specs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = label; column.width = width; column.minWidth = 70
            if key != "git" && !key.hasPrefix("gitCommit") {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            table.addTableColumn(column)
        }
        applyColumnVisibility()
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(detailHost)
        NSLayoutConstraint.activate([
            detailHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detailHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailHost.topAnchor.constraint(equalTo: content.topAnchor),
            detailHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        scroll.autoresizingMask = [.width, .height]
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
        gridView.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
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
        listView.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
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
        columnView.onDoubleClickBackground = { [weak self] in self?.handleBackgroundDoubleClick() }
        columnView.onFileDrop = { [weak self] sources, item, columnURL, intent in
            guard let self else { return false }
            let destination = item?.isBrowsable == true ? item!.url : columnURL
            if intent == .move { self.prepareMove(sources: sources, destination: destination) }
            else { self.prepareCopy(sources: sources, destination: destination) }
            return true
        }
        let menu = NSMenu()
        let folder = menu.addItem(withTitle: L("새 폴더…", "New Folder…"), action: #selector(createFolder(_:)), keyEquivalent: ""); folder.target = self
        let newItem = menu.addItem(withTitle: L("새 항목…", "New Item…"), action: #selector(addItem(_:)), keyEquivalent: "")
        newItem.target = self
        let folderFromSelection = menu.addItem(withTitle: L("선택 항목으로 새 폴더…", "New Folder with Selection…"), action: #selector(createFolderFromSelection(_:)), keyEquivalent: ""); folderFromSelection.target = self
        createFolderWithSelectionMenuItem = folderFromSelection
        let rename = menu.addItem(withTitle: L("이름 변경…", "Rename…"), action: #selector(renameSelection(_:)), keyEquivalent: ""); rename.target = self
        let symbolicLink = menu.addItem(withTitle: L("심볼릭 링크 만들기…", "Create Symbolic Link…"), action: #selector(createSymbolicLink(_:)), keyEquivalent: ""); symbolicLink.target = self
        createSymbolicLinkMenuItem = symbolicLink
        let batchRename = menu.addItem(withTitle: L("일괄 이름 변경…", "Batch Rename…"), action: #selector(batchRenameSelection(_:)), keyEquivalent: ""); batchRename.target = self
        let open = menu.addItem(withTitle: L("열기", "Open"), action: #selector(openSelection(_:)), keyEquivalent: ""); open.target = self
        let openTab = menu.addItem(withTitle: L("새 탭에서 열기", "Open in New Tab"), action: #selector(openInNewTab(_:)), keyEquivalent: ""); openTab.target = self; openInNewTabMenuItem = openTab
        let openWindow = menu.addItem(withTitle: L("새 창에서 열기", "Open in New Window"), action: #selector(openInNewWindow(_:)), keyEquivalent: ""); openWindow.target = self; openInNewWindowMenuItem = openWindow
        let openPane = menu.addItem(withTitle: L("새 pane에서 열기", "Open in New Pane"), action: #selector(openInNewPane(_:)), keyEquivalent: ""); openPane.target = self; openInNewPaneMenuItem = openPane
        let pin = menu.addItem(withTitle: L("사이드바 즐겨찾기 전환", "Toggle Sidebar Favorite"), action: #selector(toggleSelectedFavorite(_:)), keyEquivalent: ""); pin.target = self
        pinToSidebarMenuItem = pin
        let editTags = menu.addItem(withTitle: L("Finder 태그 편집…", "Edit Finder Tags…"), action: #selector(showInfo(_:)), keyEquivalent: ""); editTags.target = self; editTagsMenuItem = editTags
        let wallpaper = menu.addItem(withTitle: L("데스크탑 배경으로 설정", "Set as Desktop Wallpaper"), action: #selector(setAsDesktopWallpaper(_:)), keyEquivalent: ""); wallpaper.target = self
        let appBackground = menu.addItem(withTitle: L("앱 배경으로 설정", "Set as App Background"), action: #selector(setAsAppBackground(_:)), keyEquivalent: ""); appBackground.target = self
        let clearAppBackground = menu.addItem(withTitle: L("앱 배경 지우기", "Clear App Background"), action: #selector(clearAppBackground(_:)), keyEquivalent: ""); clearAppBackground.target = self
        let rotateLeft = menu.addItem(withTitle: L("왼쪽으로 회전", "Rotate Left"), action: #selector(rotateImagesLeft(_:)), keyEquivalent: ""); rotateLeft.target = self
        let rotateRight = menu.addItem(withTitle: L("오른쪽으로 회전", "Rotate Right"), action: #selector(rotateImagesRight(_:)), keyEquivalent: ""); rotateRight.target = self
        let installCertificate = menu.addItem(withTitle: L("인증서 설치…", "Install Certificate…"), action: #selector(installCertificates(_:)), keyEquivalent: ""); installCertificate.target = self
        let installFont = menu.addItem(withTitle: L("글꼴 설치…", "Install Font…"), action: #selector(installFonts(_:)), keyEquivalent: ""); installFont.target = self
        let playAll = menu.addItem(withTitle: L("선택 미디어 모두 재생", "Play All Selected Media"), action: #selector(playAllMedia(_:)), keyEquivalent: ""); playAll.target = self
        let toggleSelection = menu.addItem(withTitle: L("포커스 항목 선택 해제", "Toggle Focused Selection"), action: #selector(toggleFocusedSelection(_:)), keyEquivalent: ""); toggleSelection.target = self
        let openTagged = menu.addItem(withTitle: L("같은 Finder 태그 항목 찾기", "Find Items with Same Finder Tag"), action: #selector(openAllTagged(_:)), keyEquivalent: ""); openTagged.target = self
        let removeTags = menu.addItem(withTitle: L("Finder 태그 모두 제거", "Remove All Finder Tags"), action: #selector(removeTags(_:)), keyEquivalent: ""); removeTags.target = self
        let autoFit = menu.addItem(withTitle: L("열 너비 자동 맞춤", "Auto Fit Columns"), action: #selector(autoFitColumns(_:)), keyEquivalent: ""); autoFit.target = self
        let archive = menu.addItem(withTitle: L("압축 파일 탐색", "Browse Archive"), action: #selector(openArchive(_:)), keyEquivalent: ""); archive.target = self
        let createArchive = menu.addItem(withTitle: L("선택 항목 압축…", "Compress Selection…"), action: #selector(createArchive(_:)), keyEquivalent: ""); createArchive.target = self
        let extractHere = menu.addItem(withTitle: L("여기에 압축 해제", "Extract Here"), action: #selector(extractArchivesHere(_:)), keyEquivalent: ""); extractHere.target = self
        let extractSmart = menu.addItem(withTitle: L("여기에 스마트 압축 해제", "Extract Here Smart"), action: #selector(extractArchivesSmart(_:)), keyEquivalent: ""); extractSmart.target = self
        let extractChild = menu.addItem(withTitle: L("각 하위 폴더에 압축 해제", "Extract to Child Folders"), action: #selector(extractArchivesToChildFolders(_:)), keyEquivalent: ""); extractChild.target = self
        compressionMenuItems = [archive, createArchive, extractHere, extractSmart, extractChild]
        let cloudDownload = menu.addItem(withTitle: L("지금 다운로드", "Download Now"), action: #selector(downloadCloudSelection(_:)), keyEquivalent: ""); cloudDownload.target = self
        let cloudEvict = menu.addItem(withTitle: L("공간 비우기", "Free Up Space"), action: #selector(evictCloudSelection(_:)), keyEquivalent: ""); cloudEvict.target = self
        let systemStorage = menu.addItem(withTitle: L("시스템 저장 공간 설정 열기", "Open System Storage Settings"),
                                         action: #selector(openStorageSettings(_:)), keyEquivalent: "")
        systemStorage.target = self
        let copy = menu.addItem(withTitle: L("선택 항목 복사…", "Copy Selection To…"), action: #selector(copySelection(_:)), keyEquivalent: ""); copy.target = self
        let move = menu.addItem(withTitle: L("선택 항목 이동…", "Move Selection To…"), action: #selector(moveSelection(_:)), keyEquivalent: ""); move.target = self
        let flatten = menu.addItem(withTitle: L("폴더 펼치기…", "Flatten Folder…"), action: #selector(flattenFolder(_:)), keyEquivalent: "")
        flatten.target = self
        let copyItemPath = menu.addItem(withTitle: L("선택 항목 경로 복사", "Copy Selected Paths"), action: #selector(copyItemPath(_:)), keyEquivalent: ""); copyItemPath.target = self
        let copyItemPathQuoted = menu.addItem(withTitle: L("선택 항목 경로 따옴표로 복사", "Copy Selected Paths with Quotes"), action: #selector(copyItemPathWithQuotes(_:)), keyEquivalent: ""); copyItemPathQuoted.target = self
        let copyCurrentPath = menu.addItem(withTitle: L("현재 폴더 경로 복사", "Copy Current Folder Path"), action: #selector(copyCurrentPath(_:)), keyEquivalent: ""); copyCurrentPath.target = self
        let copyCurrentPathQuoted = menu.addItem(withTitle: L("현재 폴더 경로 따옴표로 복사", "Copy Current Folder Path with Quotes"), action: #selector(copyCurrentPathWithQuotes(_:)), keyEquivalent: ""); copyCurrentPathQuoted.target = self
        copyPathMenuItems = [copyItemPath, copyItemPathQuoted, copyCurrentPath, copyCurrentPathQuoted]
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
        shareMenuItem = share
        let terminal = menu.addItem(withTitle: L("터미널에서 열기", "Open in Terminal"), action: #selector(openInTerminal(_:)), keyEquivalent: ""); terminal.target = self
        openTerminalMenuItem = terminal
        let openWith = menu.addItem(withTitle: L("다른 앱으로 열기…", "Open With…"), action: #selector(openWithApplication(_:)), keyEquivalent: ""); openWith.target = self
        table.menu = menu; gridView.contextMenu = menu; listView.contextMenu = menu; columnView.contextMenu = menu
        applyContextMenuVisibility()
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
        if preferences.showShelfToggle { toolbar.addArrangedSubview(shelfToggle) }
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
    private func homeSection(_ title: String, expanded: Bool, action: Selector) {
        let button = SidebarKeyboardButton(title: (expanded ? "▾ " : "▸ ") + title, target: self, action: action)
        button.bezelStyle = .recessed; button.isBordered = false; button.alignment = .left
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.setAccessibilityLabel(title); button.setAccessibilityValue(expanded ? L("펼침", "Expanded") : L("접힘", "Collapsed"))
        homeView.addArrangedSubview(button); homeView.setCustomSpacing(10, after: button)
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
                                    (L("즐겨찾기에서 제거", "Remove Favorite"), #selector(unpinSidebarLocation(_:)))] {
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
            if volume.isLocal == true {
                let storage = menu.addItem(withTitle: L("시스템 저장 공간 설정 열기", "Open System Storage Settings"),
                                           action: #selector(openStorageSettingsForVolume(_:)), keyEquivalent: "")
                storage.target = self
                storage.representedObject = volume.url
            }
            if volume.canRequestEject {
                let eject = menu.addItem(withTitle: L("추출…", "Eject…"), action: #selector(ejectVolume(_:)), keyEquivalent: "")
                eject.target = self; eject.representedObject = volume.url
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for (label, action) in [
            (L("위치 복사", "Copy Location"), #selector(copyLocationItem(_:))),
            (L("터미널에서 열기", "Open in Terminal"), #selector(openLocationInTerminal(_:)))
        ] {
            let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = url; item.isEnabled = url != nil
        }
        if let url, !favorites.contains(url) {
            let item = menu.addItem(withTitle: L("사이드바에 고정", "Pin to Sidebar"), action: #selector(pinSidebarLocation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url
        }
        menu.addItem(.separator())
        for (label, action) in [
            (L("새 탭에서 열기", "Open in New Tab"), #selector(openLocationInNewTab(_:))),
            (L("새 창에서 열기", "Open in New Window"), #selector(openLocationInNewWindow(_:))),
            (L("다른 pane에서 열기", "Open in Other Pane"), #selector(openLocationInOtherPane(_:)))
        ] {
            let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = url; item.isEnabled = url != nil
        }
        b.menu = menu
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
                for location in cloudLocations { locationButton(location.name, symbol: "cloud", url: location.url, in: sidebar) }
                for volume in volumes {
                    locationButton(volume.name, symbol: volume.isLocal == false ? "network" : "externaldrive",
                                   url: volume.url, in: sidebar)
                }
            }
        }
    }
    private func invalidateHome() {
        homeNeedsUpdate = true
        if model.location == nil { updateHomeIfNeeded() }
    }
    private func updateHomeIfNeeded() {
        if homeNeedsUpdate { buildHome() }
        else if homeRecentNeedsUpdate { updateHomeRecent() }
    }
    private func buildHome() {
        homeNeedsUpdate = false
        let focusedButton = (window?.firstResponder as? SidebarKeyboardButton).flatMap {
            $0.isDescendant(of: homeView) ? $0 : nil
        }
        homeView.arrangedSubviews.forEach { homeView.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: L("홈", "Home")); heading.font = .systemFont(ofSize: 28, weight: .bold)
        homeView.addArrangedSubview(heading)
        let subtitle = NSTextField(labelWithString: L("파일과 폴더를 한곳에서 탐색하세요.", "Your files and folders, in one place."))
        subtitle.textColor = .secondaryLabelColor; homeView.addArrangedSubview(subtitle)
        if preferences.showHomeFavorites {
            homeSection(L("빠른 접근", "Quick Access"), expanded: preferences.homeFavoritesExpanded, action: #selector(toggleHomeFavoritesExpanded(_:)))
            if preferences.homeFavoritesExpanded { for url in favorites { locationButton(displayName(url), symbol: "folder.fill", url: url, in: homeView) } }
        }
        if preferences.showHomeVolumes {
            homeSection(L("드라이브", "Drives"), expanded: preferences.homeVolumesExpanded, action: #selector(toggleHomeVolumesExpanded(_:)))
            if preferences.homeVolumesExpanded { for volume in volumes where volume.isLocal != false {
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
            } }
            let networkVolumes = volumes.filter { $0.isLocal == false }
            if preferences.homeVolumesExpanded && !networkVolumes.isEmpty {
                section(L("네트워크 위치", "Network Locations"), in: homeView)
                for volume in networkVolumes {
                    locationButton(volume.name, symbol: "network", url: volume.url, in: homeView)
                }
            }
        }
        if preferences.showHomeRecent {
            homeSection(L("최근 위치", "Recent Locations"), expanded: preferences.homeRecentExpanded, action: #selector(toggleHomeRecentExpanded(_:)))
            if preferences.homeRecentExpanded {
                homeView.addArrangedSubview(homeRecentView)
                homeRecentView.widthAnchor.constraint(equalTo: homeView.widthAnchor, constant: -64).isActive = true
            }
        }
        updateHomeRecent()
        if let focusedButton { restoreHomeFocus(from: focusedButton) }
    }
    private func updateHomeRecent() {
        homeRecentNeedsUpdate = false
        let focusedButton = (window?.firstResponder as? SidebarKeyboardButton).flatMap {
            $0.isDescendant(of: homeRecentView) ? $0 : nil
        }
        homeRecentView.arrangedSubviews.forEach { homeRecentView.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard homeRecentView.superview === homeView else { return }
        if recent.isEmpty {
            homeRecentView.addArrangedSubview(NSTextField(labelWithString: L("방문한 폴더가 여기에 표시됩니다.", "Folders you visit will appear here.")))
        } else {
            for url in recent { locationButton(url.path, symbol: "clock", url: url, in: homeRecentView) }
            let clear = SidebarKeyboardButton(title: L("최근 기록 지우기", "Clear Recent Locations"), target: self, action: #selector(clearRecent(_:)))
            clear.bezelStyle = .rounded
            homeRecentView.addArrangedSubview(clear)
        }
        if let focusedButton { restoreHomeFocus(from: focusedButton) }
    }
    private func restoreHomeFocus(from previous: SidebarKeyboardButton) {
        let buttons = homeKeyboardButtons
        let replacement = buttons.first {
            $0.action == previous.action && $0.accessibilityLabel() == previous.accessibilityLabel()
                && ($0 as? LocationButton)?.url == (previous as? LocationButton)?.url
        }
        if let button = replacement ?? buttons.first { focusHomeButton(button) }
    }
    private var homeKeyboardButtons: [SidebarKeyboardButton] {
        homeView.arrangedSubviews.flatMap { view in
            (view as? NSStackView)?.arrangedSubviews ?? [view]
        }.compactMap { $0 as? SidebarKeyboardButton }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled }
    }
    private func focusHomeButton(_ button: SidebarKeyboardButton) {
        guard window?.makeFirstResponder(button) == true else { return }
        homeView.layoutSubtreeIfNeeded()
        _ = button.scrollToVisible(button.bounds)
    }
    fileprivate func moveHomeFocus(from button: SidebarKeyboardButton, by offset: Int) -> Bool {
        guard button.isDescendant(of: homeView) else { return false }
        let buttons = homeKeyboardButtons
        if let index = buttons.firstIndex(of: button), buttons.indices.contains(index + offset) {
            focusHomeButton(buttons[index + offset])
        }
        return true
    }
    fileprivate func activateHomeButton(_ button: SidebarKeyboardButton) -> Bool {
        guard homeKeyboardButtons.contains(button) else { return false }
        button.performClick(nil)
        return true
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
        default: ids = Set(table.selectedRowIndexes.compactMap { detailItem(at: $0, in: detailRows)?.id }); offset = scroll.contentView.bounds.origin.y
        }
        model.savePosition(selection: ids, scrollOffset: offset)
    }
    private func navigate(_ url: URL?) {
        folderSizeTask?.cancel(); folderSizeTask = nil
        completionTask?.cancel(); completionGeneration += 1
        suggestions = []; pathField.removeAllItems()
        pathField.stringValue = url?.path ?? ""
        window?.makeFirstResponder(nil)
        savePosition(); model.navigate(url); applyFolderViewPreference()
    }
    private var effectiveViewSize: BrowserViewSize {
        preferences.synchronizedFolderLayout?.size
            ?? model.location.flatMap { preferences.folderViewPreference(for: $0)?.size } ?? preferences.viewSize
    }
    private var activeEffectiveViewSize: BrowserViewSize {
        preferences.synchronizedFolderLayout?.size
            ?? activeModel.location.flatMap { preferences.folderViewPreference(for: $0)?.size } ?? preferences.viewSize
    }
    private func applyFolderViewPreference() {
        if let layout = preferences.synchronizedFolderLayout {
            appliedSharedFolderLayout = true
            model.applySharedFolderLayout(layout)
            return
        }
        guard let url = model.location, let folder = preferences.folderViewPreference(for: url) else { return }
        model.setViewMode(folder.mode)
    }
    private func render() {
        let autoFitLoadCompleted = autoFitObservedLoading && !model.isLoading
        autoFitObservedLoading = model.isLoading
        let gitLoadCompleted = gitObservedLoading && !model.isLoading
        gitObservedLoading = model.isLoading
        if model.location == nil || !showsGitColumns {
            if gitLocation != nil {
                resetGitCommits()
                gitTask?.cancel(); gitTask = nil; gitGeneration += 1; gitLocation = nil; gitStatuses = [:]; gitChangedPaths = []
            }
        } else if !model.isLoading, let location = model.location, gitLocation != location || gitLoadCompleted {
            refreshGitStatuses(for: location)
        }
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
        folderFilter.synchronize(with: model, visible: preferences.showFilterHeader)
        updateShelf()
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
        if refreshButton.toolTip != refreshTitle {
            refreshButton.image = model.isLoading ? Self.stopLoadingImage : Self.refreshImage
            refreshButton.toolTip = refreshTitle
            refreshButton.setAccessibilityLabel(refreshTitle)
        }
        if model.viewMode == .adaptive && !model.isLoading {
            adaptiveResolvedMode = adaptivePolicy.resolve(items: model.items, availableWidth: content.bounds.width)
        }
        let showsGrid = model.location != nil && primaryRenderedViewMode == .grid
        let showsList = model.location != nil && primaryRenderedViewMode == .list
        let showsColumns = model.location != nil && primaryRenderedViewMode == .columns
        let detailsWereHidden = scroll.isHidden
        scroll.isHidden = model.location == nil || showsGrid || showsList || showsColumns
        // A hidden table still participates in AppKit's window bookkeeping.
        // Detach it when another view is showing so discarded cells can be released.
        if scroll.isHidden {
            scroll.removeFromSuperview()
        } else if scroll.superview == nil {
            scroll.frame = detailHost.bounds
            detailHost.addSubview(scroll)
        }
        gridView.isHidden = model.location == nil || !showsGrid
        listView.isHidden = model.location == nil || !showsList
        columnView.isHidden = model.location == nil || !showsColumns
        homeScroll.isHidden = model.location != nil
        if model.location == nil {
            lastRecordedLocation = nil
            updateHomeIfNeeded()
        }
        var revealEntry = false
        if let target = pendingEntrySelection, !model.isLoading {
            pendingEntrySelection = nil
            if target.deletingLastPathComponent().standardizedFileURL == model.location,
               model.items.contains(where: { $0.id == target.path }) {
                revealEntry = true
                model.savePosition(selection: [target.path], scrollOffset: model.history.current.scrollOffset)
            }
        }
        let sortDescriptor = NSSortDescriptor(key: model.sortOrder.field.rawValue, ascending: model.sortOrder.ascending)
        if table.sortDescriptors.first != sortDescriptor { table.sortDescriptors = [sortDescriptor] }
        let rows = detailDisplayRows(items: model.items, grouping: model.grouping)
        if detailPresentationNeedsReload || (detailsWereHidden && !scroll.isHidden) || detailRows != rows {
            detailRows = rows
            table.reloadData()
            detailPresentationNeedsReload = false
        } else if gitLoadCompleted {
            updateVisibleGitCells()
        }
        if autoFitLoadCompleted { startFolderSizeCalculationIfNeeded() }
        if autoFitLoadCompleted && preferences.autoSizeColumnsInDetailsLayout && primaryRenderedViewMode == .details && !model.items.isEmpty {
            autoFitColumns(nil)
        }
        let selected = detailSelectionRows(ids: model.history.current.selection, in: detailRows)
        table.selectRowIndexes(selected, byExtendingSelection: false)
        gridView.apply(viewSize: effectiveViewSize)
        listView.apply(viewSize: effectiveViewSize)
        gridView.showsThumbnails = preferences.showThumbnails; listView.showsThumbnails = preferences.showThumbnails
        let selection = model.history.current.selection
        let scrollOffset = model.history.current.scrollOffset
        if showsGrid {
            gridView.update(items: model.items, selection: selection, scrollOffset: scrollOffset, grouping: model.grouping)
            if revealEntry { gridView.revealSelection() }
        }
        if showsList {
            listView.update(items: model.items, selection: selection, scrollOffset: scrollOffset, grouping: model.grouping)
            if revealEntry { listView.revealSelection() }
        }
        columnView.showHidden = model.showHidden
        columnView.sortOrder = model.sortOrder
        columnView.showsThumbnails = preferences.showThumbnails
        if showsColumns {
            columnView.update(baseURL: model.location, items: model.items, selection: selection)
        } else {
            columnView.update(baseURL: nil, items: [], selection: [])
        }
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
        else if model.location != nil && model.items.isEmpty {
            message.stringValue = model.nameFilter.isEmpty
                ? L("이 폴더는 비어 있습니다.", "This folder is empty.")
                : L("일치하는 이름이 없습니다.", "No matching names.")
        }
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
        updateInfoPane()
        if model.location == nil { status.stringValue = L("준비됨", "Ready"); return }
        status.stringValue = "\(model.items.count) " + L("개 항목", "items")
        let selectedItems = primarySelectedItems
        if !selectedItems.isEmpty {
            status.stringValue += "  ·  \(selectedItems.count) " + L("개 선택", "selected")
            let bytes = selectedItems.reduce(Int64(0)) { total, item in
                item.isDirectory ? total : total + (item.size ?? 0)
            }
            status.stringValue += " · " + formatByteCount(bytes, unit: preferences.sizeUnit)
        }
        if model.isLoading { status.stringValue += " · " + L("읽는 중…", "Loading…") }
        if model.wasCancelled { status.stringValue += " · " + L("읽기 중단 · 불완전한 목록일 수 있음", "Loading stopped · List may be incomplete") }
        if model.location != nil {
            if watcherStatus == .connecting { status.stringValue += " · " + L("자동 갱신 연결 중…", "Connecting automatic refresh…") }
            else if watcherStatus == .unavailable { status.stringValue += " · " + L("자동 갱신 사용 불가", "Automatic refresh unavailable") }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { detailRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard detailRows.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
        if case let .header(title) = detailRows[row] {
            guard key == "name" else { return nil }
            let id = NSUserInterfaceItemIdentifier("DetailGroupHeader")
            let label = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? { let label = NSTextField(labelWithString: ""); label.identifier = id; label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold); label.textColor = .secondaryLabelColor; return label }()
            label.stringValue = title; label.setAccessibilityLabel(title); return label
        }
        guard let item = detailItem(at: row, in: detailRows) else { return nil }
        let id = NSUserInterfaceItemIdentifier(key)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id, icon: key == "name")
        switch key {
        case "name":
            cell.textField?.stringValue = item.displayName(showExtensions: preferences.showExtensions)
            cell.toolTip = item.name
            cell.imageView?.image = fileIcon(for: item, showsThumbnails: preferences.showThumbnails)
        case "syncStatus":
            let status = cloudStateTitle(item.cloudState)
            cell.textField?.stringValue = item.cloudState == nil ? "—" : status
            cell.toolTip = status
        case "git", "gitCommitDate", "gitCommitMessage", "gitCommitAuthor", "gitCommitSHA":
            updateGitCell(cell, column: key, item: item)
        case "tag": cell.textField?.stringValue = item.tags.isEmpty ? "—" : item.tags.joined(separator: ", ")
        case "path": cell.textField?.stringValue = item.url.deletingLastPathComponent().standardizedFileURL.path
        case "created": cell.textField?.stringValue = item.created.map(dateFormatter.string) ?? "—"
        case "modified": cell.textField?.stringValue = item.modified.map(dateFormatter.string) ?? "—"
        case "kind": cell.textField?.stringValue = item.kind == "Folder" ? L("폴더", "Folder") : (item.kind == "File" ? L("파일", "File") : item.kind)
        case "size": cell.textField?.stringValue = item.isDirectory && !preferences.calculateFolderSizes ? "—" : item.size.map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
        default: break
        }
        cell.textField?.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
        return cell
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard detailRows.indices.contains(row) else { return false }; if case .header = detailRows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { detailItem(at: row, in: detailRows) != nil }
    private func refreshGitStatuses(for location: URL) {
        resetGitCommits()
        gitTask?.cancel(); gitGeneration += 1; let request = gitGeneration
        gitLocation = location; gitStatuses = [:]; gitChangedPaths = []
        gitTask = Task { [weak self] in
            guard let self else { return }
            defer { if request == gitGeneration { gitTask = nil } }
            do {
                let snapshot = try await GitProvider().snapshot(at: location)
                guard !Task.isCancelled, request == gitGeneration, model.location == location else { return }
                var statuses: [String: String] = [:], changed: [String] = []
                for entry in snapshot.entries {
                    let path = snapshot.root.appendingPathComponent(entry.path).standardizedFileURL.path
                    statuses[path] = "\(entry.indexStatus)\(entry.workTreeStatus)"; changed.append(path)
                }
                gitCommitRoot = snapshot.root
                gitStatuses = statuses; gitChangedPaths = changed.sorted(); updateVisibleGitCells()
            } catch is CancellationError { return }
            catch {
                guard request == gitGeneration, model.location == location else { return }
                gitStatuses = [:]; gitChangedPaths = []
            }
        }
    }
    private var showsGitColumns: Bool {
        preferences.showGitStatusColumn || preferences.showGitCommitDateColumn
            || preferences.showGitCommitMessageColumn || preferences.showGitCommitAuthorColumn
            || preferences.showGitCommitSHAColumn
    }
    private func resetGitCommits() {
        gitCommitTask?.cancel()
        gitCommitTask = nil
        gitCommitRoot = nil
        gitCommits.removeAll()
        gitCommitRequested.removeAll()
        gitCommitQueue.removeAll()
    }
    private func requestGitCommit(for item: FileItem) {
        guard !item.isDirectory, !model.isLoading, gitLocation == model.location,
              let root = gitCommitRoot, gitCommitRequested.insert(item.url).inserted else { return }
        gitCommitQueue.append(item.url)
        guard gitCommitTask == nil else { return }
        let generation = gitGeneration
        gitCommitTask = Task { [weak self] in
            while !Task.isCancelled, let url = self?.gitCommitQueue.popLast() {
                let commit = try? await GitProvider().lastCommit(for: url, in: root)
                guard !Task.isCancelled, let self, self.gitGeneration == generation,
                      self.gitLocation == self.model.location else { return }
                if let commit {
                    self.gitCommits[url] = commit
                    self.updateVisibleGitCells(committedItem: url)
                }
            }
            if !Task.isCancelled, self?.gitGeneration == generation { self?.gitCommitTask = nil }
        }
    }
    private func updateVisibleGitCells(committedItem: URL? = nil) {
        guard !scroll.isHidden else { return }
        let columns = table.tableColumns.enumerated().filter { _, column in
            let key = column.identifier.rawValue
            return !column.isHidden && (key.hasPrefix("gitCommit") || (committedItem == nil && key == "git"))
        }
        guard !columns.isEmpty else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<(visible.location + visible.length) {
            guard let item = detailItem(at: row, in: detailRows),
                  committedItem == nil || committedItem == item.url else { continue }
            for (index, column) in columns {
                let key = column.identifier.rawValue
                if let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView {
                    updateGitCell(cell, column: key, item: item)
                }
            }
        }
    }
    private func updateGitCell(_ cell: NSTableCellView, column: String, item: FileItem) {
        if column == "git" {
            cell.textField?.stringValue = gitStatus(for: item)
            return
        }
        requestGitCommit(for: item)
        let value = gitCommitValue(column, for: item)
        cell.textField?.stringValue = value
        cell.toolTip = gitCommits[item.url].map { column == "gitCommitSHA" ? $0.sha : value }
    }
    private func gitCommitValue(_ column: String, for item: FileItem) -> String {
        guard gitLocation == model.location, let commit = gitCommits[item.url] else { return "—" }
        switch column {
        case "gitCommitDate": return dateFormatter.string(from: commit.date)
        case "gitCommitMessage": return commit.subject
        case "gitCommitAuthor": return commit.author
        default: return String(commit.sha.prefix(12))
        }
    }
    private func gitStatus(for item: FileItem) -> String {
        let path = item.url.standardizedFileURL.path
        if let exact = gitStatuses[path] { return exact }
        if item.isDirectory {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            if gitChangedPaths.contains(where: { $0.hasPrefix(prefix) }) { return "••" }
        }
        return ""
    }
    private func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = id
#if RELEASE_PERFORMANCE_QA
        if countsSoakDetailCells { soakDetailCells.add(cell) }
#endif
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
        guard !rendering else { return }
        setSecondaryActive(false); savePosition(allowWhileLoading: true); updateStatus()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let item = detailItem(at: row, in: detailRows) else { return nil }
        return item.url as NSURL
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
        guard !rendering, let descriptor = tableView.sortDescriptors.first,
              let field = SortField(rawValue: descriptor.key ?? "") else { return }
        savePosition()
        var order = model.sortOrder
        order.field = field
        order.ascending = descriptor.ascending
        setPrimarySort(order)
    }
    @objc func openLocation(_ sender: LocationButton) {
        if sender.url == nil { goHome(sender); return }
        let fromHome = sender.isDescendant(of: homeView)
        navigate(sender.url)
        if fromHome { setSecondaryActive(false); focusFiles(nil) }
    }
    @objc func goBack(_ sender: Any?) { if secondaryActive { secondaryPane?.goBack() } else { window?.makeFirstResponder(nil); savePosition(); model.back(); applyFolderViewPreference() } }
    @objc func goForward(_ sender: Any?) { if secondaryActive { secondaryPane?.goForward() } else { window?.makeFirstResponder(nil); savePosition(); model.forward(); applyFolderViewPreference() } }
    @objc func goUp(_ sender: Any?) {
        if secondaryActive { secondaryPane?.goUp() }
        else if let url = model.location {
            if preferences.scrollToPreviousFolderOnUp { pendingEntrySelection = url.standardizedFileURL }
            navigate(url.deletingLastPathComponent())
        }
    }
    func handleBackgroundDoubleClick() {
        guard preferences.doubleClickToGoUp else { return }
        goUp(nil)
    }
    @objc func refresh(_ sender: Any?) {
        FileIconCache.shared.removeAll()
        detailPresentationNeedsReload = true
        if secondaryActive { secondaryPane?.refresh() }
        else {
            if model.failure != nil || watcherStatus == .unavailable { updateWatcher(force: true) }
            savePosition()
            model.reload()
        }
    }
    @objc func refreshOrStop(_ sender: Any?) {
        if activeModel.isLoading { stopLoading(sender) } else { refresh(sender) }
    }
    @objc func stopLoading(_ sender: Any?) {
        if secondaryActive { secondaryPane?.stopLoading(); return }
        pendingRefresh = false
        model.cancelLoad()
    }
    @objc func focusPath(_ sender: Any?) { if secondaryActive { secondaryPane?.focusPath() } else { window?.makeFirstResponder(pathField); pathField.selectText(nil) } }
    @objc func clearSelection(_ sender: Any?) {
        if secondaryActive { secondaryPane?.clearSelection(); return }
        switch primaryRenderedViewMode {
        case .grid: gridView.replaceSelection(with: [])
        case .list: listView.replaceSelection(with: [])
        case .columns: columnView.replaceSelection(with: [])
        default: table.deselectAll(nil)
        }
    }
    @objc func invertSelection(_ sender: Any?) {
        if secondaryActive { secondaryPane?.invertSelection(); return }
        switch primaryRenderedViewMode {
        case .grid: gridView.invertSelection()
        case .list: listView.invertSelection()
        case .columns: columnView.invertSelection()
        default:
            let itemRows = IndexSet(detailRows.indices.filter { detailItem(at: $0, in: detailRows) != nil })
            let inverted = itemRows.subtracting(table.selectedRowIndexes)
            table.selectRowIndexes(inverted, byExtendingSelection: false)
        }
    }
    private func updateSort(field: SortField? = nil, ascending: Bool? = nil,
                            placement: SortDirectoryPlacement? = nil, toggleDirection: Bool = false) {
        if secondaryActive {
            secondaryPane?.updateSort(field: field, ascending: ascending, placement: placement, toggleDirection: toggleDirection)
            return
        }
        savePosition(); var order = model.sortOrder
        if let field { order.field = field }
        if let ascending { order.ascending = ascending }
        if let placement { order.directoryPlacement = placement }
        if toggleDirection { order.ascending.toggle() }
        setPrimarySort(order)
    }
    private func setPrimarySort(_ order: FilesCore.SortOrder) {
        if preferences.syncFolderLayouts { preferences.updateSharedFolderLayout { $0.sort = order } }
        else { model.sort(order) }
    }
    @objc func sortByName(_ sender: Any?) { updateSort(field: .name) }
    @objc func sortByCreated(_ sender: Any?) { updateSort(field: .created) }
    @objc func sortByModified(_ sender: Any?) { updateSort(field: .modified) }
    @objc func sortBySize(_ sender: Any?) { updateSort(field: .size) }
    @objc func sortByKind(_ sender: Any?) { updateSort(field: .kind) }
    @objc func sortBySyncStatus(_ sender: Any?) { updateSort(field: .syncStatus) }
    @objc func sortByTag(_ sender: Any?) { updateSort(field: .tag) }
    @objc func sortByPath(_ sender: Any?) { updateSort(field: .path) }
    @objc func sortAscending(_ sender: Any?) { updateSort(ascending: true) }
    @objc func sortDescending(_ sender: Any?) { updateSort(ascending: false) }
    @objc func toggleSortDirection(_ sender: Any?) { updateSort(toggleDirection: true) }
    @objc func sortFoldersFirst(_ sender: Any?) { updateSort(placement: .foldersFirst) }
    @objc func sortFilesFirst(_ sender: Any?) { updateSort(placement: .filesFirst) }
    @objc func sortMixed(_ sender: Any?) { updateSort(placement: .mixed) }
    @objc func toggleFilterHeader(_ sender: Any?) {
        guard activeModel.location != nil else { return }
        preferences.setShowFilterHeader(!preferences.showFilterHeader)
        if preferences.showFilterHeader {
            if secondaryActive { secondaryPane?.focusFilter() }
            else { window?.makeFirstResponder(folderFilter) }
        } else {
            focusFiles(nil)
        }
    }
    @objc func toggleShelfPane(_ sender: Any?) {
        preferences.setShowShelfPane(!preferences.showShelfPane)
    }
    @objc func addSelectionToShelf(_ sender: Any?) {
        let urls = activeSelectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        preferences.addToShelf(urls)
        preferences.setShowShelfPane(true)
    }
    private func updateShelf() {
        shelf.isHidden = !preferences.showShelfPane
        shelfToggle.contentTintColor = preferences.showShelfPane ? .systemBlue : .labelColor
        shelf.update(entries: preferences.shelfEntries, destination: activeModel.location)
    }
    private func performShelfOperation(_ operation: ShelfPane.Operation, entries: [ShelfEntry]) {
        if operation == .remove {
            preferences.removeFromShelf(entries)
            return
        }
        guard let destination = activeModel.location else { return }
        let sources = entries.map(\.url)
        let validate: () -> Bool = { [weak self] in
            guard let self else { return false }
            let stale = entries.filter { !$0.isCurrent }
            guard !stale.isEmpty else { return true }
            self.preferences.removeFromShelf(stale)
            guard let window = self.window else { return false }
            let alert = NSAlert()
            alert.messageText = L("모음에 담은 항목이 변경되었습니다", "Shelf items have changed")
            alert.informativeText = stale.map(\.url.path).joined(separator: "\n")
            alert.beginSheetModal(for: window)
            return false
        }
        guard validate() else { return }
        switch operation {
        case .copy: prepareCopy(sources: sources, destination: destination, validateSources: validate)
        case .move: prepareMove(sources: sources, destination: destination, validateSources: validate)
        case .trash: confirmTrash(sources, validateSources: validate)
        case .remove: break
        }
    }
    @objc func showSearch(_ sender: Any?) {
        guard let root = activeModel.location else { return }
        let panel = searchWindow ?? SearchWindow()
        searchWindow = panel
        panel.present(root: root, showHidden: activeModel.showHidden, onReveal: searchResultRevealer())
    }
    private func searchResultRevealer() -> (FileItem) -> Void {
        let sourcePane = secondaryActive ? secondaryPane : nil
        return { [weak self, weak sourcePane] item in
            guard let self else { return }
            let target = item.url.standardizedFileURL
            self.window?.makeKeyAndOrderFront(nil)
            if let sourcePane, sourcePane === self.secondaryPane {
                sourcePane.revealSearchResult(target, isHidden: item.isHidden)
            } else {
                self.setSecondaryActive(false)
                self.model.setNameFilter("")
                if item.isHidden { self.model.showHidden = true }
                self.pendingEntrySelection = target
                self.navigate(target.deletingLastPathComponent())
            }
        }
    }
    @objc func showInfo(_ sender: Any?) {
        let items = activeSelectedItems
        guard !items.isEmpty else { return }
        if infoWindow == nil { infoWindow = FileInfoWindow() }
        infoWindow?.present(items: items)
    }
    @objc func toggleInfoPane(_ sender: Any?) { preferences.setShowInfoPane(!preferences.showInfoPane) }
    @objc func showInfoPaneDetails(_ sender: Any?) { preferences.setInfoPaneTab(.details) }
    @objc func showInfoPanePreview(_ sender: Any?) { preferences.setInfoPaneTab(.preview) }
    private func updateInfoPane() {
        let visible = preferences.showInfoPane && compactOverlayState == nil
        if inspector.isHidden == visible {
            if !visible { inspectorWidth?.isActive = false }
            inspector.isHidden = !visible
            if visible { inspectorWidth?.isActive = true }
            rootSplit.adjustSubviews()
        }
        if visible {
            inspector.update(items: activeSelectedItems, tab: preferences.infoPaneTab, sizeUnit: preferences.sizeUnit)
        } else {
            inspector.clear()
        }
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
        setPrimaryViewMode(mode)
    }
    private func setPrimaryViewMode(_ mode: BrowserViewMode) {
        if preferences.syncFolderLayouts {
            preferences.updateSharedFolderLayout { $0.mode = mode }
            return
        }
        model.setViewMode(mode)
        if let location = model.location, let saved = preferences.folderViewPreference(for: location) {
            preferences.setFolderViewPreference(FolderViewPreference(mode: mode, size: saved.size), for: location)
        }
    }
    @objc func toggleFavorite(_ sender: Any?) {
        guard let url = activeModel.location else { return }
        preferences.toggleFavorite(url)
    }
    @objc func toggleSelectedFavorite(_ sender: Any?) {
        if activeSelectedItems.count == 1, let item = activeSelectedItems.first, item.isBrowsable { preferences.toggleFavorite(item.url) }
        else if let location = activeModel.location { preferences.toggleFavorite(location) }
    }
    private var contextFolderURL: URL? {
        if activeSelectedItems.count == 1, let item = activeSelectedItems.first, item.isBrowsable { return item.url }
        return activeSelectedItems.isEmpty ? activeModel.location : nil
    }
    private func commandFolderURL(_ sender: Any?) -> URL? {
        if let item = sender as? NSMenuItem, let url = item.representedObject as? URL { return url }
        if let button = sender as? LocationButton { return button.url }
        return contextFolderURL
    }
    @objc func openInNewTab(_ sender: Any?) {
        guard let url = contextFolderURL else { return }
        (NSApp.delegate as? AppDelegate)?.openFolderInNewTab(url)
    }
    @objc func openInNewWindow(_ sender: Any?) {
        guard let url = contextFolderURL else { return }
        (NSApp.delegate as? AppDelegate)?.openFolderInNewWindow(url)
    }
    @objc func openInNewPane(_ sender: Any?) {
        guard let url = commandFolderURL(sender) else { return }
        if let secondaryPane { secondaryPane.openLocation(url); setSecondaryActive(true) }
        else { installSecondaryPane(axis: .vertical, snapshot: TabSnapshot(location: url, sortOrder: SortOrder(directoryPlacement: preferences.defaultSortDirectoryPlacement), showHidden: preferences.showHidden, viewMode: model.viewMode)) }
    }
    @objc func openLocationInNewTab(_ sender: Any?) {
        guard let url = commandFolderURL(sender) else { return }
        (NSApp.delegate as? AppDelegate)?.openFolderInNewTab(url)
    }
    @objc func openLocationInNewWindow(_ sender: Any?) {
        guard let url = commandFolderURL(sender) else { return }
        (NSApp.delegate as? AppDelegate)?.openFolderInNewWindow(url)
    }
    @objc func openLocationInOtherPane(_ sender: Any?) { openInNewPane(sender) }
    @objc func openSelection(_ sender: Any?) {
        if secondaryActive { secondaryPane?.openSelected(); return }
        if primaryRenderedViewMode == .grid, let item = gridView.selectedItems.first { openGridItem(item); return }
        if primaryRenderedViewMode == .list, let item = listView.selectedItems.first { openRenderedItem(item); return }
        if primaryRenderedViewMode == .columns, let item = columnView.selectedItems.first { openRenderedItem(item); return }
        if sender as? NSTableView === table && table.clickedRow < 0 { return }
        let rows = table.selectedRowIndexes
        guard let first = rows.first, let item = detailItem(at: first, in: detailRows) else { return }
        openItem(item)
    }
    private func openGridItem(_ item: FileItem) {
        openRenderedItem(item)
    }
    private func openRenderedItem(_ item: FileItem) {
        openItem(item)
    }
    private func openItem(_ item: FileItem) {
        if item.isBrowsable && preferences.openFoldersInNewTab { (NSApp.delegate as? AppDelegate)?.openFolderInNewTab(item.url) }
        else if item.isBrowsable { navigate(item.url) }
        else if ArchiveFormat.detect(item.url).map({ ArchiveCapabilityMatrix.capabilities(for: $0).browse }) == true { presentArchive(item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }
    private func presentArchive(_ url: URL) {
        let controller = archiveWindow ?? ArchiveWindow(); archiveWindow = controller; controller.present(archiveURL: url)
    }
    @objc func openArchive(_ sender: Any?) {
        guard activeSelectedItems.count == 1, let item = activeSelectedItems.first,
              ArchiveFormat.detect(item.url).map({ ArchiveCapabilityMatrix.capabilities(for: $0).browse }) == true else { return }
        presentArchive(item.url)
    }
    @objc func createArchive(_ sender: Any?) {
        let sources = activeSelectedItems.map(\.url)
        guard !sources.isEmpty, !activeModel.isLoading, !ArchiveCreationWindow.isRunning, let parent = activeModel.location, let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip, UTType(filenameExtension: "7z")!]; panel.canCreateDirectories = true; panel.isExtensionHidden = false
        panel.nameFieldStringValue = sources.count == 1 ? sources[0].deletingPathExtension().lastPathComponent + ".zip" : L("압축 파일.zip", "Archive.zip")
        panel.directoryURL = parent; panel.prompt = L("압축", "Compress")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            ArchiveCreationWindow.start(sources: sources, destination: destination) { self.refreshActivePane() }
        }
    }
    private var selectedArchiveURLs: [URL] {
        let urls = activeSelectedItems.map(\.url)
        return !urls.isEmpty && urls.allSatisfy { ArchiveFormat.detect($0).map { ArchiveCapabilityMatrix.capabilities(for: $0).extract } == true } ? urls : []
    }
    @objc func extractArchivesHere(_ sender: Any?) { startArchiveExtraction(.here) }
    @objc func extractArchivesSmart(_ sender: Any?) { startArchiveExtraction(.smart) }
    @objc func extractArchivesToChildFolders(_ sender: Any?) { startArchiveExtraction(.childFolder) }
    @objc func setAsDesktopWallpaper(_ sender: Any?) {
        guard activeSelectedItems.count == 1, let url = activeSelectedItems.first?.url,
              !activeSelectedItems[0].isBrowsable, NSImage(contentsOf: url) != nil else { return }
        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens
        let previous = screens.map { ($0, workspace.desktopImageURL(for: $0), workspace.desktopImageOptions(for: $0) ?? [:]) }
        do {
            for screen in screens { try workspace.setDesktopImageURL(url, for: screen, options: workspace.desktopImageOptions(for: screen) ?? [:]) }
        } catch {
            for (screen, oldURL, options) in previous { if let oldURL { try? workspace.setDesktopImageURL(oldURL, for: screen, options: options) } }
            showEntryError(L("데스크탑 배경을 설정하지 못했습니다.", "The desktop wallpaper could not be set."))
        }
    }
    @objc func setAsAppBackground(_ sender: Any?) {
        guard activeSelectedItems.count == 1, let source = activeSelectedItems.first?.url,
              !activeSelectedItems[0].isBrowsable, NSImage(contentsOf: source) != nil else { return }
        let store = AppBackgroundStore()
        Task { [weak self] in
            do {
                let installed = try await Task.detached(priority: .userInitiated) { try store.install(from: source) }.value
                self?.preferences.setAppBackground(installed)
            } catch { self?.showEntryError(L("앱 배경을 설정하지 못했습니다.", "The app background could not be set.")) }
        }
    }
    @objc func clearAppBackground(_ sender: Any?) {
        preferences.setAppBackground(nil)
        let store = AppBackgroundStore()
        Task.detached { try? store.remove() }
    }
    private var selectedRotatableImageURLs: [URL] {
        let urls = activeSelectedItems.map(\.url)
        return !urls.isEmpty && urls.allSatisfy(ImageRotationEngine.canRotate) ? urls : []
    }
    @objc func rotateImagesLeft(_ sender: Any?) { startImageRotation(.left) }
    @objc func rotateImagesRight(_ sender: Any?) { startImageRotation(.right) }
    private func startImageRotation(_ direction: ImageRotationDirection) {
        let urls = selectedRotatableImageURLs
        guard !urls.isEmpty, !ImageRotationWindow.isRunning else { return }
        let target = activeModel
        ImageRotationWindow.start(urls: urls, direction: direction) { target.reload() }
    }
    @objc func installCertificates(_ sender: Any?) { openSelectedUsingSystemHandler(matching: SystemContentCompatibility.isCertificate, failure: L("인증서 가져오기 화면을 열지 못했습니다.", "The certificate import UI could not be opened.")) }
    @objc func installFonts(_ sender: Any?) { openSelectedUsingSystemHandler(matching: SystemContentCompatibility.isFont, failure: L("글꼴 설치 화면을 열지 못했습니다.", "The font installation UI could not be opened.")) }
    @objc func playAllMedia(_ sender: Any?) { openSelectedUsingSystemHandler(matching: SystemContentCompatibility.isMedia, failure: L("선택한 미디어를 열지 못했습니다.", "The selected media could not be opened.")) }
    private func openSelectedUsingSystemHandler(matching predicate: (URL) -> Bool, failure: String) {
        let urls = activeSelectedItems.map(\.url)
        guard !urls.isEmpty, urls.allSatisfy(predicate) else { return }
        var failed = false
        for url in urls where !NSWorkspace.shared.open(url) { failed = true }
        if failed { showEntryError(failure) }
    }
    @objc func toggleFocusedSelection(_ sender: Any?) {
        if secondaryActive { secondaryPane?.toggleFocusedSelection(); return }
        guard let item = activeSelectedItems.first else { return }
        var ids = Set(activeSelectedItems.map(\.id)); ids.remove(item.id)
        if primaryRenderedViewMode == .grid { gridView.replaceSelection(with: ids) }
        else if primaryRenderedViewMode == .list { listView.replaceSelection(with: ids) }
        else if primaryRenderedViewMode == .columns { columnView.replaceSelection(with: ids) }
        else { table.selectRowIndexes(detailSelectionRows(ids: ids, in: detailRows), byExtendingSelection: false) }
    }
    @objc func openAllTagged(_ sender: Any?) {
        let urls = activeSelectedItems.map(\.url), root = activeModel.location, showHidden = activeModel.showHidden
        guard !urls.isEmpty, let root else { return }
        let revealResult = searchResultRevealer()
        Task { [weak self] in
            let tag = await Task.detached { () -> String? in
                for url in urls {
                    guard let snapshot = try? FileTagService().snapshot(url) else { continue }
                    if let tag = snapshot.tags.first { return tag }
                }
                return nil
            }.value
            guard let self, let tag else { return }
            let panel = self.searchWindow ?? SearchWindow()
            self.searchWindow = panel
            panel.presentTagSearch(tag: tag, root: root, showHidden: showHidden, onReveal: revealResult) { [weak self] item in
                self?.openItem(item)
            }
        }
    }
    @objc func removeTags(_ sender: Any?) {
        let urls = activeSelectedItems.map(\.url); guard !urls.isEmpty else { return }
        Task { [weak self] in
            let failures = await Task.detached { () -> Int in
                var failures = 0
                for url in urls {
                    do { let snapshot = try FileTagService().snapshot(url); if !snapshot.tags.isEmpty { _ = try FileTagService().setTags([], at: url, expectedIdentity: snapshot.identity) } }
                    catch { failures += 1 }
                }
                return failures
            }.value
            guard let self else { return }; self.refreshActivePane()
            if failures > 0 { self.showEntryError(L("일부 항목의 Finder 태그를 제거하지 못했습니다.", "Finder tags could not be removed from some items.")) }
        }
    }
    private var canAutoFitColumns: Bool {
        secondaryActive ? secondaryPane?.canAutoFitColumns == true : primaryRenderedViewMode == .details && !model.items.isEmpty
    }
    @objc func autoFitColumns(_ sender: Any?) {
        if secondaryActive { secondaryPane?.autoFitColumns(); return }
        guard canAutoFitColumns else { return }
        fitDetailColumns(in: table, rowCount: model.items.count) { [self] identifier, row in
            let item = model.items[row]
            switch identifier.rawValue {
            case "name": return item.displayName(showExtensions: preferences.showExtensions)
            case "syncStatus": return item.cloudState.map { cloudStateTitle($0) } ?? "—"
            case "git": return gitStatus(for: item)
            case "gitCommitDate", "gitCommitMessage", "gitCommitAuthor", "gitCommitSHA": return gitCommitValue(identifier.rawValue, for: item)
            case "created": return item.created.map(dateFormatter.string) ?? "—"
            case "modified": return item.modified.map(dateFormatter.string) ?? "—"
            case "kind": return item.kind == "Folder" ? L("폴더", "Folder") : (item.kind == "File" ? L("파일", "File") : item.kind)
            case "size": return item.isDirectory && !preferences.calculateFolderSizes ? "—" : item.size.map { formatByteCount($0, unit: preferences.sizeUnit) } ?? "—"
            default: return ""
            }
        }
    }
    private func updateGrouping(field: FileGroupField? = nil, ascending: Bool? = nil,
                                dateUnit: FileGroupDateUnit? = nil, toggleDirection: Bool = false,
                                cycleDateUnit: Bool = false) {
        var options = activeModel.grouping
        if let field { options.field = field }
        if let ascending { options.ascending = ascending }
        if toggleDirection { options.ascending.toggle() }
        if let dateUnit { options.dateUnit = dateUnit }
        if cycleDateUnit {
            options.dateUnit = switch options.dateUnit { case .year: .month; case .month: .day; case .day: .year }
        }
        if preferences.syncFolderLayouts { preferences.updateSharedFolderLayout { $0.grouping = options } }
        else { activeModel.setGrouping(options) }
    }
    @objc func groupByNone(_ sender: Any?) { updateGrouping(field: FileGroupField.none) }
    @objc func groupByName(_ sender: Any?) { updateGrouping(field: .name) }
    @objc func groupByCreated(_ sender: Any?) { updateGrouping(field: .created) }
    @objc func groupByModified(_ sender: Any?) { updateGrouping(field: .modified) }
    @objc func groupBySize(_ sender: Any?) { updateGrouping(field: .size) }
    @objc func groupByKind(_ sender: Any?) { updateGrouping(field: .kind) }
    @objc func groupBySyncStatus(_ sender: Any?) { updateGrouping(field: .syncStatus) }
    @objc func groupByTag(_ sender: Any?) { updateGrouping(field: .tag) }
    @objc func groupByFolderPath(_ sender: Any?) { updateGrouping(field: .path) }
    @objc func groupByModifiedYear(_ sender: Any?) { updateGrouping(field: .modified, dateUnit: .year) }
    @objc func groupByModifiedMonth(_ sender: Any?) { updateGrouping(field: .modified, dateUnit: .month) }
    @objc func groupByModifiedDay(_ sender: Any?) { updateGrouping(field: .modified, dateUnit: .day) }
    @objc func groupByCreatedYear(_ sender: Any?) { updateGrouping(field: .created, dateUnit: .year) }
    @objc func groupByCreatedMonth(_ sender: Any?) { updateGrouping(field: .created, dateUnit: .month) }
    @objc func groupByCreatedDay(_ sender: Any?) { updateGrouping(field: .created, dateUnit: .day) }
    @objc func groupAscending(_ sender: Any?) { updateGrouping(ascending: true) }
    @objc func groupDescending(_ sender: Any?) { updateGrouping(ascending: false) }
    @objc func toggleGroupDirection(_ sender: Any?) { updateGrouping(toggleDirection: true) }
    @objc func groupDateByYear(_ sender: Any?) { updateGrouping(dateUnit: .year) }
    @objc func groupDateByMonth(_ sender: Any?) { updateGrouping(dateUnit: .month) }
    @objc func toggleGroupDateUnit(_ sender: Any?) { updateGrouping(cycleDateUnit: true) }
    private func startArchiveExtraction(_ placement: ArchiveExtractionPlacement) {
        let archives = selectedArchiveURLs
        guard !archives.isEmpty, let parent = activeModel.location, !ArchiveExtractionWindow.isRunning else { return }
        let targetModel = activeModel
        ArchiveExtractionWindow.start(archives: archives, parent: parent, placement: placement) { targetModel.reload() }
    }
    @objc func downloadCloudSelection(_ sender: Any?) { performCloudOperation(evict: false) }
    @objc func evictCloudSelection(_ sender: Any?) { performCloudOperation(evict: true) }
    private func performCloudOperation(evict: Bool) {
        guard activeSelectedItems.count == 1, let url = activeSelectedItems.first?.url else { return }
        Task { [weak self, cloudProvider] in
            do {
                try await Task.detached(priority: .userInitiated) { evict ? try cloudProvider.evictLocalCopy(url) : try cloudProvider.requestDownload(url) }.value
                guard let self else { return }; self.refreshActivePane()
            } catch {
                self?.showEntryError(evict ? L("로컬 복사본을 정리하지 못했습니다.", "The local copy could not be removed.") : L("클라우드 항목 다운로드를 시작하지 못했습니다.", "The cloud item download could not be started."))
            }
        }
    }
    private enum NewItemKind: CaseIterable {
        case folder, file, symbolicLink, template

        var title: String {
            switch self {
            case .folder: L("폴더", "Folder")
            case .file: L("빈 파일", "Empty File")
            case .symbolicLink: L("심볼릭 링크", "Symbolic Link")
            case .template: L("템플릿으로 파일 만들기", "File from Template")
            }
        }
    }

    private var canAddItem: Bool {
        activeModel.location != nil && !activeModel.isLoading && !activeModel.wasCancelled
            && activeModel.failure == nil && !fileOperationIsRunning && window?.attachedSheet == nil
    }

    @objc func addItem(_ sender: Any?) {
        guard canAddItem, let parent = activeModel.location, let window else { return }
        let origin = activeModel
        let alert = NSAlert()
        alert.messageText = L("새 항목", "New Item")
        alert.informativeText = parent.path
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        choices.addItems(withTitles: NewItemKind.allCases.map(\.title))
        choices.setAccessibilityLabel(L("새 항목 유형", "New Item Type"))
        alert.accessoryView = choices
        alert.addButton(withTitle: L("계속", "Continue"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = choices
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard response == .alertFirstButtonReturn,
                  NewItemKind.allCases.indices.contains(choices.indexOfSelectedItem) else { return }
            let kind = NewItemKind.allCases[choices.indexOfSelectedItem]
            Task { @MainActor in
                guard let self, let window, window.isVisible, self.canAddItem,
                      self.activeModel === origin, origin.location == parent else { return }
                switch kind {
                case .folder: self.createFolder(nil)
                case .file: self.createFile(nil)
                case .symbolicLink: self.createSymbolicLinkFromDialog(nil)
                case .template: self.chooseFileTemplate(in: parent, model: origin)
                }
            }
        }
    }

    private func chooseFileTemplate(in parent: URL, model: BrowserModel) {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.prompt = L("템플릿 선택", "Choose Template")
        picker.message = L("새 파일의 내용으로 사용할 파일을 선택하세요.", "Choose an existing file to use as the template.")
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let template = picker.url else { return }
            Task { @MainActor in
                guard window.isVisible, self.canAddItem, self.activeModel === model, model.location == parent else { return }
                self.promptForTemplateName(template, in: parent, model: model)
            }
        }
    }

    private func promptForTemplateName(_ template: URL, in parent: URL, model: BrowserModel) {
        guard let window, let destination = ShelfEntry(parent) else { return }
        let alert = NSAlert()
        alert.messageText = L("템플릿으로 파일 만들기", "File from Template")
        alert.informativeText = parent.path
        let field = NSTextField(string: template.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.setAccessibilityLabel(L("파일 이름", "File name"))
        alert.accessoryView = field
        alert.addButton(withTitle: L("만들기", "Create"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.fileOperationIsRunning,
                  self.activeModel === model, model.location == parent, destination.isCurrent else { return }
            let name = field.stringValue
            Self.entryOperationRunning = true
            Task {
                defer { Self.entryOperationRunning = false }
                do {
                    let report = try await CopyEngine.instantiateTemplate(template, in: parent, name: name,
                                                                          journalDirectory: self.undoJournalDirectory)
                    if let item = report.items.first, item.state == "completed" {
                        if model.location == parent {
                            if model === self.model { self.pendingEntrySelection = item.target.standardizedFileURL }
                            if name.hasPrefix(".") { self.preferences.setShowHidden(true) }
                            model.reload()
                        }
                        if let warning = report.journalError { self.showEntryError(warning) }
                    } else if report.items.first?.state == "conflict" {
                        self.showEntryError(self.entryOperationMessage(EntryOperationError.conflict))
                    } else {
                        self.showEntryError(report.journalError ?? report.items.first?.message
                            ?? L("템플릿을 복사하지 못했습니다.", "Could not copy the template."))
                    }
                } catch {
                    self.showEntryError(self.entryOperationMessage(error))
                }
            }
        }
    }

    @objc func createFolder(_ sender: Any?) { promptForEntryName(source: nil) }
    @objc func createFile(_ sender: Any?) {
        guard let parent = activeModel.location, let window else { return }
        let alert = NSAlert(); alert.messageText = L("새 파일", "New File")
        alert.informativeText = parent.path
        let field = NSTextField(string: L("새 문서.txt", "New Document.txt")); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.setAccessibilityLabel(L("파일 이름", "File name")); alert.accessoryView = field
        alert.addButton(withTitle: L("만들기", "Create")); alert.addButton(withTitle: L("취소", "Cancel")); alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !Self.entryOperationRunning else { return }
            Self.entryOperationRunning = true
            Task {
                defer { Self.entryOperationRunning = false }
                do {
                    let result = try await EntryOperations.createFile(in: parent, name: field.stringValue, journalDirectory: Self.operationJournalDirectory)
                    if field.stringValue.hasPrefix(".") { self.preferences.setShowHidden(true) }
                    if self.activeModel.location == parent { self.pendingEntrySelection = result.target.standardizedFileURL; self.activeModel.reload() }
                    if let warning = result.journalWarning { self.showEntryError(warning) }
                } catch { self.showEntryError(self.entryOperationMessage(error)) }
            }
        }
    }
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
                    MoveWindow.start(sources: sources, destination: result.target, conflictPolicy: .skip,
                                     journalDirectory: self.undoJournalDirectory) {
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
    @objc func createSymbolicLink(_ sender: Any?) {
        guard activeSelectedItems.count == 1, let parent = activeModel.location, let window else { return }
        promptCreateSymbolicLink(to: activeSelectedItems[0].url, in: parent, window: window)
    }
    @objc func createSymbolicLinkFromDialog(_ sender: Any?) {
        guard let parent = activeModel.location, let window, !Self.entryOperationRunning else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = L("선택", "Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let source = panel.url else { return }
            self.promptCreateSymbolicLink(to: source, in: parent, window: window)
        }
    }
    private func promptCreateSymbolicLink(to source: URL, in parent: URL, window: NSWindow) {
        let sourceName = source.lastPathComponent
        let base = (sourceName as NSString).deletingPathExtension
        let ext = (sourceName as NSString).pathExtension
        let suggested = ext.isEmpty ? "\(sourceName) alias" : "\(base) alias.\(ext)"
        let alert = NSAlert(); alert.messageText = L("심볼릭 링크 만들기", "Create Symbolic Link")
        alert.informativeText = L("macOS 심볼릭 링크를 현재 폴더에 만듭니다.", "Create a macOS symbolic link in the current folder.")
        let field = NSTextField(string: suggested); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.setAccessibilityLabel(L("심볼릭 링크 이름", "Symbolic link name")); alert.accessoryView = field
        alert.addButton(withTitle: L("만들기", "Create")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !Self.entryOperationRunning else { return }
            Self.entryOperationRunning = true
            Task {
                defer { Self.entryOperationRunning = false }
                do {
                    let target = try await EntryOperations.createSymbolicLink(to: source, in: parent, name: field.stringValue)
                    if self.activeModel.location == parent { self.pendingEntrySelection = target.standardizedFileURL; self.activeModel.reload() }
                } catch {
                    let message: String
                    switch error {
                    case EntryOperationError.invalidName: message = L("사용할 수 없는 링크 이름입니다.", "The link name is invalid.")
                    case EntryOperationError.conflict: message = L("같은 이름의 항목이 있습니다. 기존 항목은 변경하지 않았습니다.", "An item with this name exists. It was not changed.")
                    case EntryOperationError.sourceChanged: message = L("원본 또는 상위 폴더가 변경됐습니다. 새로고침 후 다시 시도하세요.", "The source or parent changed. Refresh and try again.")
                    default: message = error.localizedDescription
                    }
                    self.showEntryError(message)
                }
            }
        }
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
        confirmTrash(activeSelectedItems.map(\.url))
    }
    private func confirmTrash(_ selected: [URL], validateSources: @escaping () -> Bool = { true }) {
        guard let window else { return }
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
            guard validateSources() else { return }
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
            if let source, preferences.showFileExtensionWarning,
               changesFileExtension(originalName: source.name, newName: name, isDirectory: source.isDirectory) {
                let warning = NSAlert(); warning.messageText = L("파일 확장자를 변경하시겠습니까?", "Change the file extension?")
                warning.informativeText = L("확장자를 변경하면 파일을 여는 앱이 달라지거나 파일을 사용하지 못할 수 있습니다.", "Changing the extension may change which app opens the file or make it unusable.")
                warning.addButton(withTitle: L("확장자 변경", "Change Extension")); warning.addButton(withTitle: L("취소", "Cancel"))
                warning.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.executeEntryNameChange(source: source, name: name, parent: parent, targetModel: targetModel) }
                }
            } else {
                executeEntryNameChange(source: source, name: name, parent: parent, targetModel: targetModel)
            }
        }
    }
    private func executeEntryNameChange(source: FileItem?, name: String, parent: URL, targetModel: BrowserModel) {
        guard !Self.entryOperationRunning, !CopyWindow.isRunning else { return }
        Self.entryOperationRunning = true
        Task {
            defer { Self.entryOperationRunning = false }
            do {
                let journal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
                    .appendingPathComponent("operations")
                let result: EntryOperationResult
                if let source { result = try await EntryOperations.rename(source.url, to: name, expectedIdentity: source.identity, journalDirectory: journal) }
                else { result = try await EntryOperations.createFolder(in: parent, name: name, journalDirectory: journal) }
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
    private func showEntryError(_ message: String) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert(); alert.messageText = L("파일 작업 안내", "File operation notice")
        alert.informativeText = message; alert.beginSheetModal(for: window)
    }
    private func entryOperationMessage(_ error: Error) -> String {
        switch error {
        case EntryOperationError.invalidName: return L("이름을 입력하세요. /, :, NUL 및 . 또는 .. 이름은 사용할 수 없습니다.", "Enter a name without /, :, NUL; . and .. are not allowed.")
        case EntryOperationError.conflict: return L("같은 이름의 항목이 있습니다. 기존 항목은 변경하지 않았습니다.", "An item with this name exists. It was not changed.")
        case EntryOperationError.sourceChanged: return L("원본 또는 상위 폴더가 변경됐습니다. 새로고침 후 다시 시도하세요.", "The source or parent changed. Refresh and try again.")
        default: return error.localizedDescription
        }
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
    private var flattenCandidate: FileItem? {
        guard preferences.showFlattenOptions, !activeModel.isLoading, !fileOperationIsRunning,
              activeSelectedItems.count == 1, let item = activeSelectedItems.first,
              item.isBrowsable, !item.isSymbolicLink else { return nil }
        return item
    }
    @objc func flattenFolder(_ sender: Any?) {
        guard let item = flattenCandidate, let window else { return }
        let targetModel = activeModel
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await FolderFlattenPlan.make(for: item.url)
                guard self.window?.isVisible == true, !self.fileOperationIsRunning else { return }
                guard !plan.sources.isEmpty else {
                    self.showEntryError(L("상위로 옮길 하위 항목이 없습니다.", "There are no nested items to move."))
                    return
                }
                let alert = NSAlert()
                alert.messageText = L("폴더 펼치기", "Flatten Folder")
                alert.informativeText = L("하위 항목 \(plan.sources.count)개를 아래 폴더로 옮깁니다. 이름이 겹치는 항목은 건너뛰며 폴더 구조는 유지합니다.",
                                          "Move \(plan.sources.count) nested items into the folder below. Name conflicts are skipped and the folder structure is retained.")
                    + "\n\n" + plan.destination.path
                alert.addButton(withTitle: L("펼치기", "Flatten"))
                alert.addButton(withTitle: L("취소", "Cancel"))
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn, let self, !self.fileOperationIsRunning else { return }
                    MoveWindow.start(sources: plan.sources, destination: plan.destination, flattenPlan: plan,
                                     journalDirectory: self.undoJournalDirectory) {
                        targetModel.reload()
                    }
                }
            } catch {
                self.showEntryError(error.localizedDescription)
            }
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
    @objc func undoLastFileTransfer(_ sender: Any?) {
        guard !fileOperationIsRunning, window?.attachedSheet == nil,
              let pending = EntryOperations.PendingTransferUndo.latest(in: undoJournalDirectory) else { return }
        switch pending {
        case let .copy(record): confirmUndoCopy(record)
        case let .move(record): confirmUndoMove(record)
        }
    }
    @objc func undoLastMove(_ sender: Any?) {
        guard !fileOperationIsRunning, window?.attachedSheet == nil,
              let record = EntryOperations.latestUndoMove(journalDirectory: undoJournalDirectory) else { return }
        confirmUndoMove(record)
    }
    private func confirmUndoMove(_ record: MoveUndoRecord) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("마지막 이동 실행 취소", "Undo Last Move")
        alert.informativeText = L("이동한 항목을 원래 위치로 되돌립니다. 이동 후 변경됐거나 원래 위치에 충돌이 있는 항목은 건너뜁니다.",
                                  "Return moved items to their original locations. Items changed after the move or whose original location now conflicts will be skipped.") +
            "\n\n" + L("항목: ", "Items: ") + "\(record.items.count)"
        alert.addButton(withTitle: L("실행 취소", "Undo"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.fileOperationIsRunning,
                  let current = EntryOperations.latestUndoMove(journalDirectory: self.undoJournalDirectory),
                  current.operationId == record.operationId else { return }
            Self.entryOperationRunning = true
            Task {
                let report = await EntryOperations.undoMove(current, journalDirectory: self.undoJournalDirectory)
                Self.pendingMoveRedo = report.redo
                Self.entryOperationRunning = false
                self.refreshAfterUndo()
                self.showMoveUndoResult(report)
            }
        }
    }
    @objc func undoLastCopy(_ sender: Any?) {
        guard !fileOperationIsRunning, window?.attachedSheet == nil,
              let record = CopyEngine.latestUndoCopy(journalDirectory: undoJournalDirectory) else { return }
        confirmUndoCopy(record)
    }
    private func confirmUndoCopy(_ record: CopyUndoRecord) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("마지막 복사 실행 취소", "Undo Last Copy")
        alert.informativeText = L("이 앱이 마지막 복사 작업에서 만든 항목을 삭제합니다. 복사 후 변경되거나 다른 항목으로 교체된 결과는 보존합니다.",
                                  "Delete items created by this app's last copy operation. Results changed or replaced after the copy will be preserved.") +
            "\n\n" + L("항목: ", "Items: ") + "\(record.items.count)"
        alert.addButton(withTitle: L("실행 취소", "Undo"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.fileOperationIsRunning,
                  let current = CopyEngine.latestUndoCopy(journalDirectory: self.undoJournalDirectory),
                  current.operationId == record.operationId else { return }
            Self.entryOperationRunning = true
            Task {
                let report = await CopyEngine.undoCopy(current, journalDirectory: self.undoJournalDirectory)
                Self.pendingMoveRedo = nil
                Self.entryOperationRunning = false
                self.refreshAfterUndo()
                self.showCopyUndoResult(report)
            }
        }
    }
    private var availableMoveRedo: MoveRedoRecord? {
        guard !fileOperationIsRunning, window?.attachedSheet == nil, let record = Self.pendingMoveRedo else { return nil }
        if let latest = EntryOperations.PendingTransferUndo.latest(in: undoJournalDirectory),
           latest.completedAt > record.undoneAt {
            Self.pendingMoveRedo = nil
            return nil
        }
        return record
    }
    @objc func redoLastMove(_ sender: Any?) {
        guard let record = availableMoveRedo, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("이동 다시 실행", "Redo Move")
        alert.informativeText = L("원래 대상으로 다시 이동합니다. 원본이 변경됐거나 대상에 같은 이름이 있는 항목은 건너뜁니다.",
                                  "Move items to their previous destinations. Changed sources and occupied destinations are skipped.")
        alert.addButton(withTitle: L("다시 실행", "Redo"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                guard let latest = self.availableMoveRedo, latest.undoneAt == record.undoneAt else { return }
                Self.pendingMoveRedo = nil
                Self.entryOperationRunning = true
                let result = await EntryOperations.redoMove(record, journalDirectory: self.undoJournalDirectory)
                Self.entryOperationRunning = false
                self.refreshAfterUndo()
                let completed = result.filter { $0.state == "completed" }.count
                let failures = result.filter { $0.state != "completed" }.map { $0.source.path + "\n" + ($0.message ?? "") }
                let summary = L("다시 이동: \(completed)/\(result.count)", "Moved again: \(completed)/\(result.count)")
                self.showEntryError(([summary] + failures).joined(separator: "\n\n"))
            }
        }
    }
    private func refreshAfterUndo() {
        savePosition()
        model.reload()
        secondaryPane?.model.reload()
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
        filePasteboard.clearContents()
        filePasteboard.writeObjects(urls)
    }
    func cutFilesToClipboard() {
        guard canCutFiles else { return }
        let urls = activeSelectedItems.map { $0.url as NSURL }
        filePasteboard.clearContents()
        filePasteboard.writeObjects(urls)
        filePasteboard.setData(Data([1]), forType: Self.cutPasteboardType)
    }
    @objc func copyItemPath(_ sender: Any?) { copyPaths(activeSelectedItems.map(\.url), quoted: false) }
    @objc func copyItemPathWithQuotes(_ sender: Any?) { copyPaths(activeSelectedItems.map(\.url), quoted: true) }
    @objc func copyCurrentPath(_ sender: Any?) { copyPaths(activeModel.location.map { [$0] } ?? [], quoted: false) }
    @objc func copyCurrentPathWithQuotes(_ sender: Any?) { copyPaths(activeModel.location.map { [$0] } ?? [], quoted: true) }
    private func copyPaths(_ urls: [URL], quoted: Bool) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatCopiedPaths(urls, quoted: quoted), forType: .string)
    }
    private var clipboardFiles: [URL] {
        (filePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private static let cutPasteboardType = NSPasteboard.PasteboardType("org.files-community.filesmac.cut")
    private var clipboardIsCut: Bool { filePasteboard.data(forType: Self.cutPasteboardType) != nil }
    var canCopyFiles: Bool { !activeModel.isLoading && !activeSelectedItems.isEmpty }
    var canCutFiles: Bool { canCopyFiles && !MoveWindow.isRunning && !Self.entryOperationRunning }
    var canPasteFiles: Bool {
        activeModel.location != nil && !activeModel.isLoading && !CopyWindow.isRunning && !MoveWindow.isRunning
            && !Self.entryOperationRunning && !clipboardFiles.isEmpty
    }
    func pasteFilesFromClipboard() {
        guard canPasteFiles, let destination = activeModel.location else { return }
        pasteClipboard(to: destination)
    }
    @objc func pasteFilesToSelection(_ sender: Any?) {
        guard canPasteToSelection, let destination = activeSelectedItems.first?.url else { return }
        pasteClipboard(to: destination)
    }
    private func pasteClipboard(to destination: URL) {
        let sources = clipboardFiles
        if clipboardIsCut {
            prepareMove(sources: sources, destination: destination, onStarted: { [filePasteboard] in
                filePasteboard.clearContents()
            })
        } else { prepareCopy(sources: sources, destination: destination) }
    }
    private var canPasteToSelection: Bool {
        canPasteFiles && activeSelectedItems.count == 1 && activeSelectedItems[0].isBrowsable
    }
    @objc func pasteFilesAsSymbolicLinks(_ sender: Any?) {
        guard canPasteFiles, let destination = activeModel.location, let window else { return }
        let sources = clipboardFiles
        let targetModel = activeModel
        Self.entryOperationRunning = true
        Task {
            var failures: [String] = []
            for source in sources {
                do { _ = try await EntryOperations.createSymbolicLink(to: source, in: destination, name: source.lastPathComponent) }
                catch { failures.append(source.lastPathComponent + ": " + entryOperationMessage(error)) }
            }
            Self.entryOperationRunning = false
            if targetModel.location?.standardizedFileURL == destination.standardizedFileURL { targetModel.reload() }
            if !failures.isEmpty, window.isVisible {
                let alert = NSAlert(); alert.messageText = L("일부 심볼릭 링크를 만들지 못했습니다", "Some Symbolic Links Were Not Created")
                alert.informativeText = failures.joined(separator: "\n"); _ = await alert.beginSheetModal(for: window)
            }
        }
    }
    private func prepareCopy(sources: [URL], destination: URL, validateSources: @escaping () -> Bool = { true }) {
        guard !Self.entryOperationRunning, !CopyWindow.isRunning, !FolderMergeWindow.isRunning, let window else { return }
        let targetModel = activeModel
        let canMergeFolders = sources.contains { hasFolderMergeConflict(source: $0, destination: destination) }
        let alert = NSAlert()
        alert.messageText = L("복사 시 이름 충돌 처리", "Copy conflict policy")
        alert.informativeText = L("대상: ", "Destination: ") + destination.path + "\n" +
            L("\(sources.count)개 항목을 복사합니다. 이번 작업에서 이름이 겹치면 적용할 정책을 선택하세요. 기존 항목은 덮어쓰지 않습니다.", "Copy \(sources.count) items. Choose how this job handles conflicting names. Existing items are never overwritten.")
        if canMergeFolders { alert.addButton(withTitle: L("폴더 병합", "Merge Folders")) }
        alert.addButton(withTitle: L("양쪽 유지", "Keep Both"))
        let skip = alert.addButton(withTitle: L("건너뛰기", "Skip Conflicts"))
        skip.keyEquivalent = "s"
        skip.keyEquivalentModifierMask = [.command]
        let cancel = alert.addButton(withTitle: L("취소", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        let journals = undoJournalDirectory
        let comparison = addConflictComparison(to: alert, sources: sources, destination: destination)
        alert.beginSheetModal(for: window) { response in
            comparison.cancel()
            if canMergeFolders, response == .alertFirstButtonReturn {
                guard validateSources() else { return }
                FolderMergeWindow.start(sources: sources, destination: destination) { targetModel.reload() }
                return
            }
            let keepResponse: NSApplication.ModalResponse = canMergeFolders ? .alertSecondButtonReturn : .alertFirstButtonReturn
            let skipResponse = NSApplication.ModalResponse(rawValue: keepResponse.rawValue + 1)
            guard response == keepResponse || response == skipResponse else { return }
            guard validateSources() else { return }
            CopyWindow.start(sources: sources, destination: destination,
                             conflictPolicy: response == keepResponse ? .keepBoth : .skip,
                             journalDirectory: journals) {
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
    private func prepareMove(sources: [URL], destination: URL, validateSources: @escaping () -> Bool = { true }, onStarted: (() -> Void)? = nil) {
        guard !Self.entryOperationRunning, !MoveWindow.isRunning, let window else { return }
        let targetModel = activeModel
        let alert = NSAlert()
        alert.messageText = L("이동 시 이름 충돌 처리", "Move conflict policy")
        alert.informativeText = L("대상: ", "Destination: ") + destination.path + "\n" +
            L("\(sources.count)개 항목을 이동합니다. 이번 작업에서 이름이 겹치면 적용할 정책을 선택하세요.", "Moving \(sources.count) items. Choose how this job handles conflicting names.")
        let skip = alert.addButton(withTitle: L("건너뛰기", "Skip Conflicts"))
        skip.keyEquivalent = "s"
        skip.keyEquivalentModifierMask = [.command]
        alert.addButton(withTitle: L("교체", "Replace Existing"))
        let cancel = alert.addButton(withTitle: L("취소", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        let journals = undoJournalDirectory
        let comparison = addConflictComparison(to: alert, sources: sources, destination: destination)
        alert.beginSheetModal(for: window) { response in
            comparison.cancel()
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            guard validateSources() else { return }
            onStarted?()
            MoveWindow.start(sources: sources, destination: destination,
                             conflictPolicy: response == .alertSecondButtonReturn ? .replace : .skip,
                             journalDirectory: journals) {
                targetModel.reload()
            }
        }
    }
    private enum ConflictPreviewPart: Sendable {
        case text(String)
        case thumbnail(CGImage, label: String)
    }

    private func addConflictComparison(to alert: NSAlert, sources: [URL], destination: URL) -> Task<Void, Never> {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let details = NSTextView(frame: scroll.contentView.bounds)
        details.autoresizingMask = [.width]
        details.isEditable = false
        details.isSelectable = true
        details.textContainerInset = NSSize(width: 6, height: 6)
        details.textContainer?.widthTracksTextView = true
        details.setAccessibilityLabel(L("원본과 기존 대상 비교", "Source and Existing Destination Comparison"))
        details.string = L("기존 대상을 확인하는 중…", "Checking existing destinations…")
        scroll.documentView = details
        alert.accessoryView = scroll

        let sizeUnit = preferences.sizeUnit
        return Task { [weak details] in
            let worker = Task.detached(priority: .userInitiated) { () -> [ConflictPreviewPart] in
                func describe(_ url: URL, info: stat) -> String {
                    let type = info.st_mode & S_IFMT
                    let kind: String = switch type {
                    case S_IFDIR: L("폴더", "Folder")
                    case S_IFLNK: L("심볼릭 링크", "Symbolic Link")
                    case S_IFREG: L("파일", "File")
                    default: L("기타", "Other")
                    }
                    let bytes = type == S_IFREG ? formatByteCount(info.st_size, unit: sizeUnit) : "—"
                    let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
                        .formatted(date: .abbreviated, time: .shortened)
                    return "\(url.path)\n\(kind) · \(bytes) · \(date)"
                }

                func preview(_ url: URL, expected: stat) -> ConflictPreviewPart {
                    let unavailable = ConflictPreviewPart.text(L("미리보기 없음", "Preview unavailable"))
                    guard expected.st_mode & S_IFMT == S_IFREG else { return unavailable }
                    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard descriptor >= 0 else { return unavailable }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var actual = stat()
                    guard fstat(descriptor, &actual) == 0, actual.st_mode & S_IFMT == S_IFREG,
                          actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else { return unavailable }
                    let limit = 4096
                    guard let data = try? handle.read(upToCount: limit + 1) else {
                        return actual.st_size == 0 ? .text(L("빈 파일", "Empty file")) : unavailable
                    }
                    let visualLimit = 8 * 1024 * 1024
                    let type = UTType(filenameExtension: url.pathExtension)
                    let isPDF = type?.conforms(to: .pdf) == true || data.starts(with: "%PDF-".utf8)
                    if isPDF || type?.conforms(to: .image) == true {
                        guard actual.st_size <= visualLimit, !Task.isCancelled,
                              let _ = try? handle.seek(toOffset: 0),
                              let contents = try? handle.read(upToCount: visualLimit + 1),
                              contents.count <= visualLimit else { return unavailable }
                        let image: CGImage?
                        if isPDF {
                            image = Self.conflictPDFThumbnail(contents)
                        } else if let source = CGImageSourceCreateWithData(contents as CFData, nil) {
                            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 240
                            ] as CFDictionary)
                        } else { image = nil }
                        guard let image else { return unavailable }
                        let label = isPDF ? L("PDF 첫 페이지", "PDF first page") : L("이미지 미리보기", "Image preview")
                        return .thumbnail(image, label: label)
                    }
                    let truncated = data.count > limit || actual.st_size > Int64(data.count)
                    let bytes = data.prefix(limit)
                    // The byte limit may fall in the middle of a UTF-8 scalar.
                    var text = String(data: bytes, encoding: .utf8)
                    if text == nil && truncated && !bytes.isEmpty {
                        for count in 1...min(3, bytes.count) {
                            if let prefix = String(data: bytes.dropLast(count), encoding: .utf8) {
                                text = prefix
                                break
                            }
                        }
                    }
                    guard let text, text.unicodeScalars.allSatisfy({
                        !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"
                    }) else { return unavailable }
                    return .text(text + (truncated ? "\n…" : ""))
                }

                var pairs: [ConflictPreviewPart] = []
                for source in sources.prefix(12) {
                    guard !Task.isCancelled else { return [] }
                    let target = destination.appendingPathComponent(source.lastPathComponent)
                    var targetInfo = stat()
                    guard lstat(target.path, &targetInfo) == 0 else { continue }
                    var sourceInfo = stat()
                    let sourceExists = lstat(source.path, &sourceInfo) == 0
                    let original = sourceExists
                        ? describe(source, info: sourceInfo)
                        : source.path + "\n" + L("정보를 읽을 수 없습니다.", "Unable to read information.")
                    pairs.append(.text(L("원본", "Source") + "\n" + original + "\n"))
                    if sourceExists { pairs.append(preview(source, expected: sourceInfo)) }
                    pairs.append(.text("\n" + L("기존 대상", "Existing Destination") + "\n"
                        + describe(target, info: targetInfo) + "\n"))
                    pairs.append(preview(target, expected: targetInfo))
                    pairs.append(.text("\n\n"))
                }
                if pairs.isEmpty {
                    pairs.append(.text(L("확인한 항목에 표시할 기존 대상이 없습니다.", "No existing destinations to display for the checked items.")))
                }
                if sources.count > 12 {
                    pairs.append(.text(L("처음 12개 원본을 확인했습니다.", "Checked the first 12 source items.")))
                }
                return pairs
            }
            let comparison = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            let rendered = NSMutableAttributedString()
            let textStyle: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.textColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
            for part in comparison {
                switch part {
                case let .text(text):
                    rendered.append(NSAttributedString(string: text, attributes: textStyle))
                case let .thumbnail(image, label):
                    rendered.append(NSAttributedString(string: label + "\n", attributes: textStyle))
                    let scale = min(1, 160 / CGFloat(max(image.width, image.height)))
                    let thumbnailSize = NSSize(width: CGFloat(image.width) * scale,
                                               height: CGFloat(image.height) * scale)
                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = NSTextAttachmentCell(imageCell:
                        NSImage(cgImage: image, size: thumbnailSize))
                    rendered.append(NSAttributedString(attachment: attachment))
                }
            }
            details?.textStorage?.setAttributedString(rendered)
        }
    }

    private nonisolated static func conflictPDFThumbnail(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.isUnlocked,
              let page = document.page(at: 1) else { return nil }
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let rotated = abs(page.rotationAngle % 180) == 90
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let longestSide = max(size.width, size.height)
        let width = max(1, Int((240 * (size.width / longestSide)).rounded()))
        let height = max(1, Int((240 * (size.height / longestSide)).rounded()))
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(frame)
        canvas.concatenate(page.getDrawingTransform(.cropBox, rect: frame, rotate: 0, preserveAspectRatio: true))
        canvas.drawPDFPage(page)
        return canvas.makeImage()
    }
    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
    }
    private func primaryDropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, let item = detailItem(at: row, in: detailRows), item.isBrowsable { return item.url }
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
        openURLsInTerminal(urls)
    }
    private func openURLsInTerminal(_ urls: [URL]) {
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
    @objc func openInDeveloperApplication(_ sender: Any?) {
        guard let path = preferences.developerApplicationPath else {
            showEntryError(L("개발자 도구 설정에서 앱을 먼저 선택하세요.", "Choose an application in Developer Tools settings first.")); return
        }
        let application = URL(fileURLWithPath: path)
        let urls = activeSelectedItems.map(\.url).isEmpty ? [activeModel.location].compactMap { $0 } : activeSelectedItems.map(\.url)
        guard !urls.isEmpty, FileManager.default.fileExists(atPath: application.path) else {
            showEntryError(L("선택한 개발 앱 또는 열 위치를 찾을 수 없습니다.", "The selected developer app or location could not be found.")); return
        }
        Task { @MainActor in
            do { try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) }
            catch { showEntryError(L("개발 앱에서 열지 못했습니다: ", "Could not open in developer application: ") + error.localizedDescription) }
        }
    }
    @objc func editInTextEdit(_ sender: Any?) {
        let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let urls = activeSelectedItems.filter { !$0.isBrowsable }.map(\.url)
        guard !urls.isEmpty, FileManager.default.fileExists(atPath: application.path) else { return }
        Task { @MainActor in
            do { try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) }
            catch { showEntryError(L("TextEdit에서 열지 못했습니다: ", "Could not open in TextEdit: ") + error.localizedDescription) }
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
        else {
            FileIconCache.shared.invalidateFileIcons()
            if preferences.showThumbnails { detailPresentationNeedsReload = true }
            savePosition()
            model.reload()
        }
    }

}

@MainActor
final class LocationButton: SidebarKeyboardButton { var url: URL? }

@MainActor
final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class BrowserFileTable: NSTableView, NSMenuItemValidation {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && row(at: convert(event.locationInWindow, from: nil)) < 0 {
            deselectAll(nil); (window?.windowController as? BrowserWindow)?.handleBackgroundDoubleClick(); return
        }
        super.mouseDown(with: event)
    }
    @objc func cut(_ sender: Any?) { (window?.windowController as? BrowserWindow)?.cutFilesToClipboard() }
    @objc func copy(_ sender: Any?) { (window?.windowController as? BrowserWindow)?.copyFilesToClipboard() }
    @objc func paste(_ sender: Any?) { (window?.windowController as? BrowserWindow)?.pasteFilesFromClipboard() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let browser = window?.windowController as? BrowserWindow
        if item.action == #selector(cut(_:)) { return browser?.canCutFiles == true }
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

private enum TabSplitEdge {
    case left, right, top, bottom

    var axis: SplitAxis { self == .left || self == .right ? .vertical : .horizontal }
    var isPrimary: Bool { self == .left || self == .top }

    static func at(_ point: NSPoint, in bounds: NSRect, flipped: Bool) -> Self? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        let edges: [(Self, CGFloat)] = [(.left, x), (.right, 1 - x),
                                       (.top, flipped ? y : 1 - y), (.bottom, flipped ? 1 - y : y)]
        guard let closest = edges.min(by: { $0.1 < $1.1 }), closest.1 < 0.25 else { return nil }
        return closest.0
    }
}

private final class WorkspaceTabDragHandle: NSView, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("org.taro6222.files-for-mac.tab")
    private let symbol = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
    private var initialEvent: NSEvent?

    init() {
        super.init(frame: .zero)
        let label = L("탭을 끌어 분할", "Drag Tab to Split")
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        symbol?.draw(in: NSRect(x: 5, y: 5, width: 16, height: 16))
    }

    override func mouseDown(with event: NSEvent) { initialEvent = event }
    override func mouseUp(with event: NSEvent) { initialEvent = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let initialEvent, let symbol,
              hypot(event.locationInWindow.x - initialEvent.locationInWindow.x,
                    event.locationInWindow.y - initialEvent.locationInWindow.y) >= 4 else { return }
        self.initialEvent = nil
        let payload = NSPasteboardItem()
        payload.setString("tab", forType: Self.dragType)
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(bounds, contents: symbol)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

private final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    private var dropEdge: TabSplitEdge? {
        didSet { if oldValue != dropEdge { updateDropIndicator() } }
    }
    private let dropIndicator = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        wantsLayer = true
        dropIndicator.isHidden = true
        dropIndicator.zPosition = 1
        layer?.addSublayer(dropIndicator)
        registerForDraggedTypes([WorkspaceTabDragHandle.dragType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func tabDrop(_ sender: any NSDraggingInfo) -> (BrowserWindow, BrowserWindow, TabSplitEdge)? {
        guard let handle = sender.draggingSource as? WorkspaceTabDragHandle,
              let source = handle.window?.windowController as? BrowserWindow,
              let target = window?.windowController as? BrowserWindow,
              target.canAcceptTabSplit(from: source),
              let edge = TabSplitEdge.at(convert(sender.draggingLocation, from: nil), in: bounds, flipped: isFlipped)
        else { return nil }
        return (source, target, edge)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropEdge = tabDrop(sender)?.2
        return dropEdge == nil ? [] : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropEdge = nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropEdge = nil }
        guard let (source, target, edge) = tabDrop(sender) else { return false }
        return target.splitByDroppingTab(from: source, at: edge)
    }

    private func updateDropIndicator() {
        guard let dropEdge else { dropIndicator.isHidden = true; return }
        let edge: CGRectEdge = switch dropEdge {
        case .left: .minXEdge
        case .right: .maxXEdge
        case .top: .maxYEdge
        case .bottom: .minYEdge
        }
        let depth = dropEdge.axis == .vertical ? bounds.width : bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropIndicator.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.frame = bounds.divided(atDistance: min(5, depth), from: edge).slice
        dropIndicator.isHidden = false
        CATransaction.commit()
    }

    func applyInitialRatio(_ ratio: Double) {
        let ratio = min(0.8, max(0.2, ratio))
        if isVertical {
            resizeSideBySide(primaryFraction: ratio)
        } else {
            setPosition(bounds.height * ratio, ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard isVertical, arrangedSubviews.count == 2, oldSize.width > 0 else {
            adjustSubviews()
            return
        }
        resizeSideBySide(primaryFraction: arrangedSubviews[0].frame.width / oldSize.width)
    }

    private func resizeSideBySide(primaryFraction: CGFloat) {
        let divider = min(dividerThickness, bounds.width)
        let left = min(max(0, bounds.width * primaryFraction), bounds.width - divider)
        arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        arrangedSubviews[1].frame = NSRect(x: left + divider, y: 0,
            width: bounds.width - left - divider, height: bounds.height)
        needsDisplay = true
    }
}

private final class TabScrollStackView: NSStackView {
    var onTabScroll: ((Double, Double) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .began || event.phase.isEmpty else { return }
        onTabScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
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
    fileprivate func canAcceptTabSplit(from source: BrowserWindow) -> Bool {
        guard let window, let sourceWindow = source.window else { return false }
        return !isRestoringSplitWorkspace && !source.isRestoringSplitWorkspace
            && secondaryPane == nil && source.secondaryPane == nil
            && window.attachedSheet == nil && sourceWindow.attachedSheet == nil
    }

    fileprivate func splitByDroppingTab(from source: BrowserWindow, at edge: TabSplitEdge) -> Bool {
        guard canAcceptTabSplit(from: source) else { return false }
        let dragged = source.tabSnapshot()
        let current = tabSnapshot()
        installSecondaryPane(axis: edge.axis, snapshot: edge.isPrimary ? current : dragged, activate: !edge.isPrimary)
        if edge.isPrimary { model.restore(dragged); focusFiles(nil) }
        window?.makeKeyAndOrderFront(nil)
        if source !== self { source.close() }
        return true
    }

    private func embedPane(_ pane: NSView, in host: NSView) {
        // The divider sizes the host independently of its pane's preferred content size.
        pane.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    @objc func splitVertically(_ sender: Any?) { installSecondaryPane(axis: .vertical) }
    @objc func splitHorizontally(_ sender: Any?) { installSecondaryPane(axis: .horizontal) }
    @objc func arrangePanesVertically(_ sender: Any?) { arrangePanes(axis: .vertical) }
    @objc func arrangePanesHorizontally(_ sender: Any?) { arrangePanes(axis: .horizontal) }
    private func arrangePanes(axis: SplitAxis) {
        guard secondaryPane != nil else { return }
        workspaceSplit.isVertical = axis == .vertical; workspaceSplit.adjustSubviews()
        let dimension = workspaceSplit.isVertical ? workspaceSplit.bounds.width : workspaceSplit.bounds.height
        if dimension > 0 { workspaceSplit.setPosition(dimension * 0.5, ofDividerAt: 0) }
    }
    @objc func focusOtherPane(_ sender: Any?) {
        guard secondaryPane != nil else { return }
        setSecondaryActive(!secondaryActive)
        focusFiles(nil)
    }
    @objc func toggleDualPane(_ sender: Any?) {
        if secondaryPane == nil { installSecondaryPane(axis: .vertical) } else { closeSecondaryPane(sender) }
    }
    @objc func openCurrentFolderInOtherPane(_ sender: Any?) {
        guard let location = activeModel.location else { return }
        if secondaryActive { setSecondaryActive(false); navigate(location) }
        else if let secondaryPane { secondaryPane.openLocation(location); setSecondaryActive(true); secondaryPane.focusFiles() }
        else { installSecondaryPane(axis: .vertical, snapshot: TabSnapshot(location: location, sortOrder: SortOrder(directoryPlacement: preferences.defaultSortDirectoryPlacement), showHidden: preferences.showHidden, viewMode: model.viewMode)) }
    }
    @objc func closeSecondaryPane(_ sender: Any?) {
        guard let secondaryPane else { return }
        secondaryPane.shutdown(); secondaryPane.removeFromSuperview()
        secondaryPaneHost.removeFromSuperview()
        self.secondaryPane = nil; secondaryPaneID = nil; secondaryActive = false
        updateShelf()
        updateInfoPane()
        content.wantsLayer = true; content.layer?.borderWidth = 0
        focusFiles(nil)
    }
    @objc func closeActivePane(_ sender: Any?) {
        guard let secondaryPane else { return }
        if secondaryActive { closeSecondaryPane(sender); return }
        let replacement = secondaryPane.snapshot()
        closeSecondaryPane(sender); model.restore(replacement)
    }
    private func installSecondaryPane(axis: SplitAxis, snapshot: TabSnapshot? = nil, id: UUID? = nil,
                                      ratio: Double = 0.5, activate: Bool = true) {
        workspaceSplit.isVertical = axis == .vertical
        if secondaryPane == nil {
            let paneSnapshot = snapshot ?? TabSnapshot(location: activeModel.location,
                                                        sortOrder: SortOrder(directoryPlacement: preferences.defaultSortDirectoryPlacement),
                                                        showHidden: preferences.showHidden,
                                                        viewMode: activeModel.viewMode)
            let pane = SecondaryBrowserPane(snapshot: paneSnapshot, preferences: preferences)
            pane.onActivate = { [weak self] in self?.setSecondaryActive(true) }
            pane.onLocationChange = { [weak self] in self?.updateShelf() }
            pane.onSelectionChange = { [weak self] in self?.updateInfoPane() }
            pane.onOpenFolderInNewTab = { (NSApp.delegate as? AppDelegate)?.openFolderInNewTab($0) }
            pane.onFileDrop = { [weak self] sources, destination, intent in
                guard let self else { return false }
                if intent == .move { self.prepareMove(sources: sources, destination: destination) }
                else { self.prepareCopy(sources: sources, destination: destination) }
                return true
            }
            pane.setContextMenu(table.menu)
            secondaryPane = pane
            secondaryPaneID = id ?? UUID()
            workspaceSplit.addArrangedSubview(secondaryPaneHost)
            embedPane(pane, in: secondaryPaneHost)
        }
        setSecondaryActive(activate)
        window?.contentView?.layoutSubtreeIfNeeded()
        workspaceSplit.adjustSubviews()
        let dimension = workspaceSplit.isVertical ? workspaceSplit.bounds.width : workspaceSplit.bounds.height
        if dimension > 0 { workspaceSplit.applyInitialRatio(ratio) }
        if activate { secondaryPane?.focusFiles() }
    }
    private func restoreWorkspace(_ state: SplitTabState) {
        guard state.panes.count == 2 else { return }
        isRestoringSplitWorkspace = true
        let secondary = state.panes[1]
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRestoringSplitWorkspace = false }
            installSecondaryPane(axis: state.axis, snapshot: secondary.tab, id: secondary.id,
                                 ratio: state.ratio, activate: state.activePaneID == secondary.id)
        }
    }
    private func setSecondaryActive(_ active: Bool) {
        secondaryActive = active && secondaryPane != nil
        updateShelf()
        updateInfoPane()
        secondaryPane?.setActive(secondaryActive)
        content.wantsLayer = true
        content.layer?.borderWidth = secondaryActive ? 0 : (secondaryPane == nil ? 0 : 2)
        content.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    private func preferencesChanged() {
        detailPresentationNeedsReload = true
        FileIconCache.shared.configure(enabled: preferences.enableThumbnailCache, limitMiB: preferences.thumbnailCacheLimitMiB)
        updateInfoPane()
        if preferences.syncFolderLayouts || appliedSharedFolderLayout {
            appliedSharedFolderLayout = preferences.syncFolderLayouts
            applyFolderViewPreference()
        }
        window?.appearance = Self.appearance(preferences.appearance)
        applyAppBackground()
        toolbar.isHidden = !preferences.showToolbar
        bottom.isHidden = !preferences.showStatusBar
        sidebarContainer.isHidden = !preferences.showSidebar
        applyColumnVisibility()
        applyContextMenuVisibility()
        rootSplit.adjustSubviews()
        rootSplit.layoutSubtreeIfNeeded()
        buildSidebar()
        rebuildToolbar(force: true)
        if !preferences.showFilterHeader { model.setNameFilter("") }
        secondaryPane?.applyPreferences()
        if preferences.calculateFolderSizes { startFolderSizeCalculationIfNeeded() } else { folderSizeTask?.cancel(); folderSizeTask = nil }
        invalidateHome()
        if model.showHidden != preferences.showHidden {
            savePosition(); model.showHidden = preferences.showHidden; model.reload()
        } else if !rendering {
            savePosition(); render()
        }
    }
    private func applyAppBackground() {
        content.setPresentation(fit: preferences.appBackgroundFit, opacity: preferences.appBackgroundOpacity,
                                horizontal: preferences.appBackgroundHorizontalAlignment, vertical: preferences.appBackgroundVerticalAlignment)
        let valid = content.setImage(at: preferences.appBackgroundPath)
        if !valid { preferences.setAppBackground(nil); return }
        let enabled = content.image != nil
        scroll.drawsBackground = !enabled; table.backgroundColor = enabled ? .clear : .controlBackgroundColor
        gridView.applyBackground(enabled: enabled); listView.applyBackground(enabled: enabled); columnView.applyBackground(enabled: enabled)
        secondaryPane?.applyPreferences()
    }
    private func startFolderSizeCalculationIfNeeded() {
        guard folderSizeTask == nil else { return }
        guard preferences.calculateFolderSizes, !model.isLoading, let location = model.location else { return }
        let folders = model.loadedItems.filter(\.isBrowsable).map(\.url)
        guard !folders.isEmpty else { return }
        folderSizeTask = Task { [weak self] in
            let sizes = await FolderSizeCalculator().sizes(of: folders)
            guard !Task.isCancelled else { return }
            self?.model.applyDirectorySizes(sizes, at: location)
            self?.folderSizeTask = nil
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
    @objc private func pinSidebarLocation(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL, !favorites.contains(url) { preferences.toggleFavorite(url) }
    }
    @objc private func unpinSidebarLocation(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL, favorites.contains(url) { preferences.toggleFavorite(url) }
    }
    @objc private func copyLocationItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL])
    }
    @objc private func openLocationInTerminal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURLsInTerminal([url])
    }
    @objc private func showOptions(_ sender: NSButton) {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === optionsMenu else { return }
        menu.removeAllItems()
        let entries: [(String, Selector, Bool)] = [
            (L("정보 pane 표시", "Show Information Pane"), #selector(toggleInfoPane(_:)), preferences.showInfoPane),
            (L("모든 폴더에서 같은 보기 사용", "Use the Same View in All Folders"),
             #selector(toggleFolderLayoutSynchronization(_:)), preferences.syncFolderLayouts),
            (L("임시 파일 모음", "Shelf"), #selector(toggleShelfPane(_:)), preferences.showShelfPane),
            (L("현재 폴더 필터", "Filter Current Folder"), #selector(toggleFilterHeader(_:)), preferences.showFilterHeader),
            (L("사이드바 표시", "Show Sidebar"), #selector(toggleSidebarVisibility(_:)), preferences.showSidebar),
            (L("툴바 표시", "Show Toolbar"), #selector(toggleToolbar(_:)), preferences.showToolbar),
            (L("상태 막대 표시", "Show Status Bar"), #selector(toggleStatusBar(_:)), preferences.showStatusBar),
            (L("파일 확장자 표시", "Show File Extensions"), #selector(toggleExtensions(_:)), preferences.showExtensions),
            (L("숨김 항목 표시", "Show Hidden Files"), #selector(toggleHidden(_:)), preferences.showHidden),
            (L("생성일 열 표시", "Show Date Created Column"), #selector(toggleCreatedColumn(_:)), preferences.showCreatedColumn),
            (L("수정일 열 표시", "Show Date Modified Column"), #selector(toggleDateColumn(_:)), preferences.showDateColumn),
            (L("종류 열 표시", "Show Kind Column"), #selector(toggleTypeColumn(_:)), preferences.showTypeColumn),
            (L("크기 열 표시", "Show Size Column"), #selector(toggleSizeColumn(_:)), preferences.showSizeColumn),
            (L("Git 상태 열 표시", "Show Git Status Column"), #selector(toggleGitColumn(_:)), preferences.showGitStatusColumn),
            (L("Git 커밋 날짜 열 표시", "Show Git Commit Date Column"), #selector(toggleGitCommitDateColumn(_:)), preferences.showGitCommitDateColumn),
            (L("Git 커밋 메시지 열 표시", "Show Git Commit Message Column"), #selector(toggleGitCommitMessageColumn(_:)), preferences.showGitCommitMessageColumn),
            (L("Git 커밋 작성자 열 표시", "Show Git Commit Author Column"), #selector(toggleGitCommitAuthorColumn(_:)), preferences.showGitCommitAuthorColumn),
            (L("Git 커밋 SHA 열 표시", "Show Git Commit SHA Column"), #selector(toggleGitCommitSHAColumn(_:)), preferences.showGitCommitSHAColumn),
            (L("동기화 상태 열 표시", "Show Sync Status Column"), #selector(toggleSyncStatusColumn(_:)), preferences.showSyncStatusColumn),
            (L("Finder 태그 열 표시", "Show Finder Tags Column"), #selector(toggleTagColumn(_:)), preferences.showFileTagColumn),
            (L("폴더 경로 열 표시", "Show Folder Path Column"), #selector(togglePathColumn(_:)), preferences.showPathColumn),
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
            item.state = activeEffectiveViewSize == size ? .on : .off
        }
        if let location = model.location, !preferences.syncFolderLayouts {
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
    @objc func toggleSidebarVisibility(_ sender: Any?) { preferences.setShowSidebar(!preferences.showSidebar) }
    @objc func toggleToolbar(_ sender: Any?) { preferences.setShowToolbar(!preferences.showToolbar) }
    @objc private func toggleStatusBar(_ sender: Any?) { preferences.setShowStatusBar(!preferences.showStatusBar) }
    @objc private func toggleCreatedColumn(_ sender: Any?) { preferences.setShowCreatedColumn(!preferences.showCreatedColumn) }
    @objc private func toggleDateColumn(_ sender: Any?) { preferences.setShowDateColumn(!preferences.showDateColumn) }
    @objc private func toggleTypeColumn(_ sender: Any?) { preferences.setShowTypeColumn(!preferences.showTypeColumn) }
    @objc private func toggleSizeColumn(_ sender: Any?) { preferences.setShowSizeColumn(!preferences.showSizeColumn) }
    @objc private func toggleGitColumn(_ sender: Any?) { preferences.setShowGitStatusColumn(!preferences.showGitStatusColumn) }
    @objc private func toggleGitCommitDateColumn(_ sender: Any?) {
        preferences.setShowGitCommitDateColumn(!preferences.showGitCommitDateColumn)
    }
    @objc private func toggleGitCommitMessageColumn(_ sender: Any?) {
        preferences.setShowGitCommitMessageColumn(!preferences.showGitCommitMessageColumn)
    }
    @objc private func toggleGitCommitAuthorColumn(_ sender: Any?) {
        preferences.setShowGitCommitAuthorColumn(!preferences.showGitCommitAuthorColumn)
    }
    @objc private func toggleGitCommitSHAColumn(_ sender: Any?) {
        preferences.setShowGitCommitSHAColumn(!preferences.showGitCommitSHAColumn)
    }
    @objc private func toggleSyncStatusColumn(_ sender: Any?) { preferences.setShowSyncStatusColumn(!preferences.showSyncStatusColumn) }
    @objc private func toggleTagColumn(_ sender: Any?) { preferences.setShowFileTagColumn(!preferences.showFileTagColumn) }
    @objc private func togglePathColumn(_ sender: Any?) { preferences.setShowPathColumn(!preferences.showPathColumn) }
    private func applyColumnVisibility() {
        table.tableColumn(withIdentifier: .init("created"))?.isHidden = !preferences.showCreatedColumn
        table.tableColumn(withIdentifier: .init("modified"))?.isHidden = !preferences.showDateColumn
        table.tableColumn(withIdentifier: .init("kind"))?.isHidden = !preferences.showTypeColumn
        table.tableColumn(withIdentifier: .init("size"))?.isHidden = !preferences.showSizeColumn
        table.tableColumn(withIdentifier: .init("git"))?.isHidden = !preferences.showGitStatusColumn
        table.tableColumn(withIdentifier: .init("gitCommitDate"))?.isHidden = !preferences.showGitCommitDateColumn
        table.tableColumn(withIdentifier: .init("gitCommitMessage"))?.isHidden = !preferences.showGitCommitMessageColumn
        table.tableColumn(withIdentifier: .init("gitCommitAuthor"))?.isHidden = !preferences.showGitCommitAuthorColumn
        table.tableColumn(withIdentifier: .init("gitCommitSHA"))?.isHidden = !preferences.showGitCommitSHAColumn
        table.tableColumn(withIdentifier: .init("syncStatus"))?.isHidden = !preferences.showSyncStatusColumn
        table.tableColumn(withIdentifier: .init("tag"))?.isHidden = !preferences.showFileTagColumn
        table.tableColumn(withIdentifier: .init("path"))?.isHidden = !preferences.showPathColumn
    }
    private func applyContextMenuVisibility() {
        table.menu?.items.first { $0.action == #selector(flattenFolder(_:)) }?.isHidden = !preferences.showFlattenOptions
        compressionMenuItems.forEach { $0.isHidden = !preferences.showCompressionOptions }
        openTerminalMenuItem?.isHidden = !preferences.showOpenTerminal
        createFolderWithSelectionMenuItem?.isHidden = !preferences.showCreateFolderWithSelection
        pinToSidebarMenuItem?.isHidden = !preferences.showPinToSidebar
        shareMenuItem?.isHidden = !preferences.showSendToMenu
        copyPathMenuItems.forEach { $0.isHidden = !preferences.showCopyPath }
        openInNewTabMenuItem?.isHidden = !preferences.showOpenInNewTab
        openInNewWindowMenuItem?.isHidden = !preferences.showOpenInNewWindow
        openInNewPaneMenuItem?.isHidden = !preferences.showOpenInNewPane
        editTagsMenuItem?.isHidden = !preferences.showEditTagsMenu
        createSymbolicLinkMenuItem?.isHidden = !preferences.showCreateShortcut
    }
    @objc private func setViewSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = BrowserViewSize(rawValue: raw) else { return }
        setEffectiveViewSize(size)
    }
    private func setEffectiveViewSize(_ size: BrowserViewSize) {
        if preferences.syncFolderLayouts {
            preferences.updateSharedFolderLayout { $0.size = size }
            return
        }
        if let location = activeModel.location, preferences.folderViewPreference(for: location) != nil {
            preferences.setFolderViewPreference(FolderViewPreference(mode: activeModel.viewMode, size: size), for: location)
        } else { preferences.setViewSize(size) }
    }
    @objc func useCardsLayout(_ sender: Any?) {
        if secondaryActive { secondaryPane?.setViewMode(.grid) } else { setPrimaryViewMode(.grid) }
    }
    @objc func toggleFolderLayoutSynchronization(_ sender: Any?) {
        guard activeModel.location != nil else { return }
        preferences.setFolderLayoutSynchronization(!preferences.syncFolderLayouts,
            initial: SharedFolderLayout(mode: activeModel.viewMode, size: activeEffectiveViewSize,
                                        sort: activeModel.sortOrder, grouping: activeModel.grouping))
    }
    @objc func decreaseViewSize(_ sender: Any?) {
        guard let index = BrowserViewSize.allCases.firstIndex(of: activeEffectiveViewSize), index > 0 else { return }
        setEffectiveViewSize(BrowserViewSize.allCases[index - 1])
    }
    @objc func increaseViewSize(_ sender: Any?) {
        guard let index = BrowserViewSize.allCases.firstIndex(of: activeEffectiveViewSize), index < BrowserViewSize.allCases.count - 1 else { return }
        setEffectiveViewSize(BrowserViewSize.allCases[index + 1])
    }
    @objc private func saveFolderView(_ sender: Any?) {
        guard let location = model.location else { return }
        preferences.setFolderViewPreference(FolderViewPreference(mode: model.viewMode, size: effectiveViewSize), for: location)
    }
    @objc private func clearFolderView(_ sender: Any?) {
        guard let location = model.location else { return }
        preferences.removeFolderViewPreference(for: location); render()
    }
    @objc func showToolbarSettings(_ sender: Any?) {
        if toolbarSettingsWindow == nil { toolbarSettingsWindow = ToolbarSettingsWindow(preferences: preferences) }
        toolbarSettingsWindow?.present()
    }
    @objc private func toggleHomeFavorites(_ sender: Any?) { preferences.toggleSection(.favorites) }
    @objc private func toggleHomeVolumes(_ sender: Any?) { preferences.toggleSection(.volumes) }
    @objc private func toggleHomeRecent(_ sender: Any?) { preferences.toggleSection(.recent) }
    @objc private func toggleHomeFavoritesExpanded(_ sender: Any?) { preferences.toggleHomeSectionExpanded(.favorites) }
    @objc private func toggleHomeVolumesExpanded(_ sender: Any?) { preferences.toggleHomeSectionExpanded(.volumes) }
    @objc private func toggleHomeRecentExpanded(_ sender: Any?) { preferences.toggleHomeSectionExpanded(.recent) }

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
            self.invalidateHome()
        }
    }
    private func refreshCloudLocations() {
        cloudTask?.cancel()
        cloudTask = Task { [weak self, cloudProvider] in
            let result = await Task.detached(priority: .utility) { cloudProvider.locations() }.value
            guard let self, !Task.isCancelled else { return }
            self.cloudLocations = result; self.buildSidebar()
        }
    }

    private var fileOperationIsRunning: Bool {
        Self.entryOperationRunning || CopyWindow.isRunning || MoveWindow.isRunning || FolderMergeWindow.isRunning ||
        DeletionWindow.isRunning || PermanentDeleteWindow.isRunning || RestoreWindow.isRunning || BatchRenameWindow.isRunning
    }

    private func isLocalVolumeRoot(_ url: URL?) -> Bool {
        guard let url else { return false }
        return volumes.contains { $0.isLocal == true && $0.url.path == url.standardizedFileURL.path }
    }
    private var canOpenStorageSettings: Bool {
        activeSelectedItems.isEmpty && isLocalVolumeRoot(activeModel.location)
    }
    @objc func openStorageSettings(_ sender: Any?) {
        guard canOpenStorageSettings else { return }
        presentStorageSettings()
    }
    @objc func openFinderTrash(_ sender: Any?) {
        guard openSystemURL(URL.trashDirectory) else {
            showEntryError(L("Dock의 휴지통을 클릭해 Finder에서 여세요.", "Click Trash in the Dock to open it in Finder."))
            return
        }
    }
    @objc private func openStorageSettingsForVolume(_ sender: NSMenuItem) {
        guard isLocalVolumeRoot(sender.representedObject as? URL) else { return }
        presentStorageSettings()
    }
    private func presentStorageSettings() {
        let storage = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        guard openSystemURL(storage) else {
            showEntryError(L("시스템 설정에서 일반 → 저장 공간을 여세요.", "In System Settings, open General → Storage."))
            return
        }
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
    @objc func goHome(_ sender: Any?) { navigate(nil); setSecondaryActive(false); focusFiles(nil) }
    @objc func focusFiles(_ sender: Any?) {
        if secondaryActive { secondaryPane?.focusFiles() }
        else if model.location == nil {
            if let first = homeKeyboardButtons.first { focusHomeButton(first) }
            else { focusSidebar(nil) }
        }
        else if primaryRenderedViewMode == .grid { gridView.focus() }
        else if primaryRenderedViewMode == .list { listView.focus() }
        else if primaryRenderedViewMode == .columns { columnView.focus() }
        else { window?.makeFirstResponder(table) }
    }
    @objc func focusSidebar(_ sender: Any?) {
        if !sidebarContainer.isHidden, let first = sidebar.arrangedSubviews.first { window?.makeFirstResponder(first) }
    }
    @objc func openViewOptions(_ sender: Any?) {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: content.bounds.maxX - 200, y: content.bounds.maxY), in: content)
    }
    @objc func showCommandPalette(_ sender: Any?) { commandPalette.present(relativeTo: window) }
    @objc func toggleFullScreen(_ sender: Any?) { window?.toggleFullScreen(sender) }
    @objc func enterCompactOverlay(_ sender: Any?) {
        guard compactOverlayState == nil, let window else { return }
        compactOverlayState = (window.frame, window.minSize, window.level, window.collectionBehavior)
        updateInfoPane()
        window.minSize = NSSize(width: 360, height: 420)
        window.level = .floating
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let size = NSSize(width: min(460, visible.width), height: min(620, visible.height))
        window.setFrame(NSRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20,
                               width: size.width, height: size.height), display: true, animate: false)
    }
    @objc func exitCompactOverlay(_ sender: Any?) {
        guard let state = compactOverlayState, let window else { return }
        compactOverlayState = nil
        updateInfoPane()
        window.level = state.level; window.collectionBehavior = state.behavior; window.minSize = state.minSize
        window.setFrame(state.frame, display: true, animate: false)
    }
    @objc func toggleCompactOverlay(_ sender: Any?) {
        compactOverlayState == nil ? enterCompactOverlay(sender) : exitCompactOverlay(sender)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(splitVertically(_:)), #selector(splitHorizontally(_:)): return true
        case #selector(arrangePanesVertically(_:)), #selector(arrangePanesHorizontally(_:)), #selector(focusOtherPane(_:)), #selector(openCurrentFolderInOtherPane(_:)): return secondaryPane != nil
        case #selector(toggleDualPane(_:)): return true
        case #selector(toggleShelfPane(_:)):
            menuItem.state = preferences.showShelfPane ? .on : .off
            return true
        case #selector(toggleFolderLayoutSynchronization(_:)):
            menuItem.state = preferences.syncFolderLayouts ? .on : .off
            return activeModel.location != nil
        case #selector(openStorageSettings(_:)): return canOpenStorageSettings
        case #selector(toggleInfoPane(_:)):
            menuItem.state = preferences.showInfoPane ? .on : .off
            return true
        case #selector(showInfoPaneDetails(_:)), #selector(showInfoPanePreview(_:)):
            let tab: InfoPaneTab = menuItem.action == #selector(showInfoPaneDetails(_:)) ? .details : .preview
            menuItem.state = preferences.infoPaneTab == tab ? .on : .off
            return !inspector.isHidden
        case #selector(addSelectionToShelf(_:)): return !activeSelectedItems.isEmpty
        case #selector(toggleFilterHeader(_:)):
            menuItem.state = preferences.showFilterHeader ? .on : .off
            return activeModel.location != nil
        case #selector(useCardsLayout(_:)): return activeModel.location != nil
        case #selector(sortBySyncStatus(_:)): menuItem.state = activeModel.sortOrder.field == .syncStatus ? .on : .off; return activeModel.location != nil
        case #selector(groupBySyncStatus(_:)): menuItem.state = activeModel.grouping.field == .syncStatus ? .on : .off; return activeModel.location != nil
        case #selector(sortByTag(_:)): menuItem.state = activeModel.sortOrder.field == .tag ? .on : .off; return activeModel.location != nil
        case #selector(groupByTag(_:)): menuItem.state = activeModel.grouping.field == .tag ? .on : .off; return activeModel.location != nil
        case #selector(sortByPath(_:)): menuItem.state = activeModel.sortOrder.field == .path ? .on : .off; return activeModel.location != nil
        case #selector(groupByFolderPath(_:)): menuItem.state = activeModel.grouping.field == .path ? .on : .off; return activeModel.location != nil
        case #selector(pasteFilesToSelection(_:)): return canPasteToSelection
        case #selector(pasteFilesAsSymbolicLinks(_:)): return canPasteFiles
        case #selector(decreaseViewSize(_:)): return BrowserViewSize.allCases.firstIndex(of: activeEffectiveViewSize) != 0
        case #selector(increaseViewSize(_:)): return BrowserViewSize.allCases.firstIndex(of: activeEffectiveViewSize) != BrowserViewSize.allCases.count - 1
        case #selector(enterCompactOverlay(_:)):
            menuItem.state = compactOverlayState != nil ? .on : .off; return compactOverlayState == nil
        case #selector(exitCompactOverlay(_:)): return compactOverlayState != nil
        case #selector(toggleCompactOverlay(_:)):
            menuItem.state = compactOverlayState != nil ? .on : .off; return true
        case #selector(closeSecondaryPane(_:)), #selector(closeActivePane(_:)): return secondaryPane != nil
        case #selector(redoLastMove(_:)): return availableMoveRedo != nil
        case #selector(undoLastFileTransfer(_:)):
            return !fileOperationIsRunning && window?.attachedSheet == nil &&
                EntryOperations.PendingTransferUndo.latest(in: undoJournalDirectory) != nil
        case #selector(undoLastMove(_:)):
            return !fileOperationIsRunning && window?.attachedSheet == nil &&
                EntryOperations.latestUndoMove(journalDirectory: undoJournalDirectory) != nil
        case #selector(undoLastCopy(_:)):
            return canUndoCopy(journalDirectory: undoJournalDirectory)
        case #selector(deleteSelection(_:)): return canDeleteSelection
        case #selector(restoreSelection(_:)): return canRestoreSelection
        case #selector(permanentlyDeleteSelection(_:)): return canPermanentDeleteSelection
        case #selector(moveSelection(_:)): return canMoveSelection
        case #selector(flattenFolder(_:)): return flattenCandidate != nil
        case #selector(createFolder(_:)): return activeModel.location != nil && !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning
        case #selector(createFile(_:)): return activeModel.location != nil && !activeModel.isLoading && !Self.entryOperationRunning
        case #selector(addItem(_:)): return canAddItem
        case #selector(createFolderFromSelection(_:)): return activeModel.location != nil && !activeModel.isLoading && !activeSelectedItems.isEmpty && !Self.entryOperationRunning && !MoveWindow.isRunning
        case #selector(extractArchivesHere(_:)), #selector(extractArchivesSmart(_:)), #selector(extractArchivesToChildFolders(_:)): return activeModel.location != nil && !activeModel.isLoading && !selectedArchiveURLs.isEmpty && !ArchiveExtractionWindow.isRunning
        case #selector(setAsDesktopWallpaper(_:)), #selector(setAsAppBackground(_:)): return activeSelectedItems.count == 1 && !activeSelectedItems[0].isBrowsable && NSImage(contentsOf: activeSelectedItems[0].url) != nil
        case #selector(clearAppBackground(_:)): return preferences.appBackgroundPath != nil
        case #selector(rotateImagesLeft(_:)), #selector(rotateImagesRight(_:)): return !ImageRotationWindow.isRunning && !selectedRotatableImageURLs.isEmpty
        case #selector(installCertificates(_:)): return !activeSelectedItems.isEmpty && activeSelectedItems.map(\.url).allSatisfy(SystemContentCompatibility.isCertificate)
        case #selector(installFonts(_:)): return !activeSelectedItems.isEmpty && activeSelectedItems.map(\.url).allSatisfy(SystemContentCompatibility.isFont)
        case #selector(playAllMedia(_:)): return !activeSelectedItems.isEmpty && activeSelectedItems.map(\.url).allSatisfy(SystemContentCompatibility.isMedia)
        case #selector(toggleFocusedSelection(_:)): return !activeSelectedItems.isEmpty
        case #selector(openAllTagged(_:)), #selector(removeTags(_:)): return !activeSelectedItems.isEmpty && activeSelectedItems.contains { ((try? FileTagService().snapshot($0.url).tags.isEmpty) == false) }
        case #selector(autoFitColumns(_:)): return canAutoFitColumns
        case #selector(groupByNone(_:)): menuItem.state = activeModel.grouping.field == .none ? .on : .off; return activeModel.location != nil
        case #selector(groupByName(_:)): menuItem.state = activeModel.grouping.field == .name ? .on : .off; return activeModel.location != nil
        case #selector(groupByCreated(_:)): menuItem.state = activeModel.grouping.field == .created ? .on : .off; return activeModel.location != nil
        case #selector(groupByModified(_:)): menuItem.state = activeModel.grouping.field == .modified ? .on : .off; return activeModel.location != nil
        case #selector(groupBySize(_:)): menuItem.state = activeModel.grouping.field == .size ? .on : .off; return activeModel.location != nil
        case #selector(groupByKind(_:)): menuItem.state = activeModel.grouping.field == .kind ? .on : .off; return activeModel.location != nil
        case #selector(groupByModifiedYear(_:)), #selector(groupDateByYear(_:)):
            menuItem.state = activeModel.grouping.field == .modified && activeModel.grouping.dateUnit == .year ? .on : .off
            return menuItem.action == #selector(groupByModifiedYear(_:)) ? activeModel.location != nil : activeModel.grouping.field == .modified
        case #selector(groupByModifiedMonth(_:)), #selector(groupDateByMonth(_:)):
            menuItem.state = activeModel.grouping.field == .modified && activeModel.grouping.dateUnit == .month ? .on : .off
            return menuItem.action == #selector(groupByModifiedMonth(_:)) ? activeModel.location != nil : activeModel.grouping.field == .modified
        case #selector(groupByModifiedDay(_:)):
            menuItem.state = activeModel.grouping.field == .modified && activeModel.grouping.dateUnit == .day ? .on : .off
            return activeModel.location != nil
        case #selector(groupByCreatedYear(_:)):
            menuItem.state = activeModel.grouping.field == .created && activeModel.grouping.dateUnit == .year ? .on : .off
            return activeModel.location != nil
        case #selector(groupByCreatedMonth(_:)):
            menuItem.state = activeModel.grouping.field == .created && activeModel.grouping.dateUnit == .month ? .on : .off
            return activeModel.location != nil
        case #selector(groupByCreatedDay(_:)):
            menuItem.state = activeModel.grouping.field == .created && activeModel.grouping.dateUnit == .day ? .on : .off
            return activeModel.location != nil
        case #selector(groupAscending(_:)): menuItem.state = activeModel.grouping.ascending ? .on : .off; return activeModel.grouping.field != .none
        case #selector(groupDescending(_:)): menuItem.state = !activeModel.grouping.ascending ? .on : .off; return activeModel.grouping.field != .none
        case #selector(toggleGroupDirection(_:)): return activeModel.grouping.field != .none
        case #selector(toggleGroupDateUnit(_:)): return activeModel.grouping.field == .modified || activeModel.grouping.field == .created
        case #selector(createSymbolicLink(_:)): return activeModel.location != nil && activeSelectedItems.count == 1 && !activeModel.isLoading && !Self.entryOperationRunning
        case #selector(createSymbolicLinkFromDialog(_:)): return activeModel.location != nil && !activeModel.isLoading && !Self.entryOperationRunning
        case #selector(toggleSelectedFavorite(_:)): return activeModel.location != nil && (activeSelectedItems.isEmpty || (activeSelectedItems.count == 1 && activeSelectedItems[0].isBrowsable))
        case #selector(renameSelection(_:)): return activeModel.location != nil && activeSelectedItems.count == 1 && !activeModel.isLoading && !Self.entryOperationRunning && !CopyWindow.isRunning
        case #selector(batchRenameSelection(_:)): return activeModel.location != nil && activeSelectedItems.count > 1 && !activeModel.isLoading && !BatchRenameWindow.isRunning
        case #selector(retryAutomaticRefresh(_:)): return model.location != nil && watcherStatus != .active
        case #selector(copySelection(_:)): return !CopyWindow.isRunning && !activeModel.isLoading && !activeSelectedItems.isEmpty
        case #selector(copyItemPath(_:)), #selector(copyItemPathWithQuotes(_:)): return !activeModel.isLoading && !activeSelectedItems.isEmpty
        case #selector(copyCurrentPath(_:)), #selector(copyCurrentPathWithQuotes(_:)): return activeModel.location != nil
        case #selector(stopLoading(_:)): return secondaryActive ? secondaryPane?.model.isLoading == true : model.isLoading
        case #selector(goBack(_:)): return secondaryActive ? !(secondaryPane?.model.history.back.isEmpty ?? true) : !model.history.back.isEmpty
        case #selector(goForward(_:)): return secondaryActive ? !(secondaryPane?.model.history.forward.isEmpty ?? true) : !model.history.forward.isEmpty
        case #selector(goUp(_:)): return secondaryActive ? secondaryPane?.model.location != nil : model.location != nil && model.location?.path != "/"
        case #selector(openSelection(_:)): return !activeSelectedItems.isEmpty && activeModel.location != nil
        case #selector(showInfo(_:)): return !activeSelectedItems.isEmpty && activeModel.location != nil
        case #selector(showQuickLook(_:)): return !activeSelectedItems.isEmpty
        case #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)), #selector(openInNewPane(_:)): return contextFolderURL != nil
        case #selector(openArchive(_:)): return activeSelectedItems.count == 1 && activeSelectedItems.first.map { ArchiveFormat.detect($0.url).map { ArchiveCapabilityMatrix.capabilities(for: $0).browse } == true } == true
        case #selector(createArchive(_:)): return !ArchiveCreationWindow.isRunning && !activeModel.isLoading && !activeSelectedItems.isEmpty
        case #selector(downloadCloudSelection(_:)): return activeSelectedItems.count == 1 && activeSelectedItems.first.map { cloudProvider.capabilities(for: $0.url).downloadNow } == true
        case #selector(evictCloudSelection(_:)): return activeSelectedItems.count == 1 && activeSelectedItems.first.map { cloudProvider.capabilities(for: $0.url).evictLocalCopy } == true
        case #selector(revealSelection(_:)), #selector(shareSelection(_:)), #selector(openWithApplication(_:)): return !activeSelectedItems.isEmpty && activeModel.location != nil
        case #selector(openInDeveloperApplication(_:)): return activeModel.location != nil && preferences.developerApplicationPath != nil
        case #selector(editInTextEdit(_:)): return !activeSelectedItems.isEmpty && activeSelectedItems.allSatisfy { !$0.isBrowsable }
        case #selector(openInTerminal(_:)): return activeModel.location != nil
        default: return true
        }
    }
    private func canUndoCopy(journalDirectory: URL) -> Bool {
        !fileOperationIsRunning && window?.attachedSheet == nil &&
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
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49,
           (window?.windowController as? BrowserWindow)?.activateHomeButton(self) == true { return }
        if modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            let offset = event.keyCode == 125 ? 1 : -1
            if (window?.windowController as? BrowserWindow)?.moveHomeFocus(from: self, by: offset) == true { return }
            guard let stack = superview as? NSStackView else { super.keyDown(with: event); return }
            let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.isEnabled }
            if let index = buttons.firstIndex(of: self) {
                let next = index + offset
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
#if DEBUG
    var qaSidebarVisible: Bool { !sidebarContainer.isHidden }
    var qaHasAppBackground: Bool { content.image != nil }
    var qaGitLoading: Bool { gitTask != nil }
    var qaGitMarkedRows: Int { model.items.filter { !gitStatus(for: $0).isEmpty }.count }
    var qaGitColumnVisible: Bool { table.tableColumns.contains { $0.identifier.rawValue == "git" && !$0.isHidden } }
    var qaVisibleDetailColumns: Set<String> { Set(table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }) }
    var qaCreatedColumnWidth: CGFloat? { table.tableColumn(withIdentifier: .init("created"))?.width }
    var qaIsCompactOverlay: Bool { compactOverlayState != nil }
    var qaLocationMenuActions: Set<String> {
        Set(sidebar.arrangedSubviews.compactMap { $0 as? LocationButton }.flatMap { $0.menu?.items ?? [] }
            .compactMap { $0.action.map(NSStringFromSelector) })
    }
    var qaCollapsedHomeSectionCount: Int {
        homeView.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0.title.hasPrefix("▸ ") }.count
    }
    var qaDetailGroupTitles: [String] { detailRows.compactMap { if case let .header(title) = $0 { return title }; return nil } }
    var qaVisibleContextActions: Set<String> { Set((table.menu?.items ?? []).filter { !$0.isHidden }.compactMap { $0.action.map(NSStringFromSelector) }) }
    var qaThumbnailPolicyApplied: Bool {
        gridView.showsThumbnails == preferences.showThumbnails && listView.showsThumbnails == preferences.showThumbnails
            && columnView.showsThumbnails == preferences.showThumbnails && (secondaryPane?.qaThumbnailPolicyApplied ?? true)
    }
#endif
    static func runUIVerification(output: String) async {
        let fm = FileManager.default
        let requestedDestination = URL(fileURLWithPath: output, isDirectory: true)
        let suite = "FilesMac.UIVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks: [String: Bool] = [:]
        var metrics: [String: Double] = [:]
        do {
            try fm.createDirectory(at: requestedDestination, withIntermediateDirectories: true)
            let destination = requestedDestination.standardizedFileURL
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
            try? fm.removeItem(at: archiveFixture)
            _ = try await ZipArchiveProvider().create(from: [fixture.appendingPathComponent("00000-한글-é-📁-long-file-name.txt")], at: archiveFixture)
            let qaCloudStorage = destination.appendingPathComponent("qa-cloud-storage", isDirectory: true)
            let qaICloud = destination.appendingPathComponent("qa-icloud", isDirectory: true)
            try fm.createDirectory(at: qaCloudStorage.appendingPathComponent("Dropbox-personal", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: qaCloudStorage.appendingPathComponent("OneDrive-work", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: qaICloud, withIntermediateDirectories: true)
            let qaCloudProvider = CloudLocationProvider(cloudStorageRoot: qaCloudStorage, iCloudDriveRoot: qaICloud)
            let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [fixture])
            let dark = ProcessInfo.processInfo.environment["FILES_UI_QA_THEME"] == "dark"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var storageRequests: [URL] = []
            let controller = BrowserWindow(preferences: preferences, restoresFrame: false, cloudProvider: qaCloudProvider,
                                           openSystemURL: { storageRequests.append($0); return true })
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
            checks["cloudLocations"] = controller.cloudLocations.count == 3 && controller.cloudLocations.allSatisfy { $0.state == .unknown }
            try capture("home")
            let sampleVolumes = controller.volumes
            let local = MountedVolume(url: fixture, name: "QA Local", isLocal: true)
            let network = MountedVolume(url: gridFolder, name: "QA Network", isLocal: false)
            controller.volumes = [local, network]
            controller.buildSidebar()
            controller.buildHome()
            let storageAction = #selector(openStorageSettingsForVolume(_:))
            let homeDrives = controller.homeView.arrangedSubviews.compactMap { $0 as? VolumeCardView }
                .flatMap { $0.arrangedSubviews.compactMap { $0 as? LocationButton } }
            let sidebarDrives = controller.sidebar.arrangedSubviews.compactMap { $0 as? LocationButton }
            let homeCommand = homeDrives.first { $0.url == local.url }?.menu?.items.first { $0.action == storageAction }
            let sideCommand = sidebarDrives.first { $0.url == local.url }?.menu?.items.first { $0.action == storageAction }
            for item in [homeCommand, sideCommand].compactMap({ $0 }) {
                NSApp.sendAction(storageAction, to: item.target, from: item)
            }
            checks["storageSettingsVolumeMenus"] = storageRequests.count == 2
                && !(homeDrives + sidebarDrives).filter { $0.url == network.url }
                    .contains { $0.menu?.items.contains { $0.action == storageAction } == true }
            let storageMenu = NSMenuItem(title: "", action: #selector(openStorageSettings(_:)), keyEquivalent: "")
            controller.openStorageSettings(nil)
            let homeWasDisabled = !controller.validateMenuItem(storageMenu) && storageRequests.count == 2
            controller.navigate(fixture)
            let volumeEnabled = controller.validateMenuItem(storageMenu)
            controller.openStorageSettings(nil)
            controller.navigate(gridFolder)
            controller.openStorageSettings(nil)
            checks["storageSettingsCurrentVolume"] = homeWasDisabled && volumeEnabled && !controller.validateMenuItem(storageMenu)
                && storageRequests.map(\.absoluteString) == Array(repeating: "x-apple.systempreferences:com.apple.settings.Storage", count: 3)
            let trashEntry = CommandPaletteCatalog.entries(from: NSApp.mainMenu)
                .first { $0.item.action == #selector(openFinderTrash(_:)) }
            if let trashEntry {
                NSApp.sendAction(#selector(openFinderTrash(_:)), to: controller, from: trashEntry.item)
            }
            checks["finderTrashHandoff"] = storageRequests.count == 4 && storageRequests.last == URL.trashDirectory
            controller.navigate(nil)
            controller.volumes = sampleVolumes
            controller.buildSidebar()
            controller.buildHome()
            let backgroundFixture = destination.appendingPathComponent("background-fixture.png")
            let backgroundImage = NSImage(size: NSSize(width: 96, height: 64)); backgroundImage.lockFocus()
            NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.62, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 96, height: 64).fill()
            NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.18, alpha: 1).setFill(); NSRect(x: 48, y: 0, width: 48, height: 64).fill(); backgroundImage.unlockFocus()
            guard let backgroundTIFF = backgroundImage.tiffRepresentation, let backgroundBitmap = NSBitmapImageRep(data: backgroundTIFF),
                  let backgroundPNG = backgroundBitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try backgroundPNG.write(to: backgroundFixture)
            let qaBackgroundStore = AppBackgroundStore(directory: destination.appendingPathComponent("app-background-store", isDirectory: true))
            let qaBackground = try qaBackgroundStore.install(from: backgroundFixture)
            preferences.setAppBackground(qaBackground)
            checks["appBackgroundApplied"] = controller.qaHasAppBackground && preferences.appBackgroundPath == qaBackground.path
            let invalidBackground = destination.appendingPathComponent("invalid-background.txt"); try Data("not an image".utf8).write(to: invalidBackground)
            checks["appBackgroundRejectsNonImage"] = (try? qaBackgroundStore.install(from: invalidBackground)) == nil
            try capture("app-background")
            func qaImageOrientation(_ url: URL) -> Int {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
                return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            }
            ImageRotationWindow.start(urls: [backgroundFixture], direction: .right) {}
            let rotateRightWait = ContinuousClock.now
            while ImageRotationWindow.qaLatest?.qaRunning == true && rotateRightWait.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["imageRotateRight"] = ImageRotationWindow.qaLatest?.qaSucceeded == true && qaImageOrientation(backgroundFixture) == 6
            try capture("image-rotation", view: ImageRotationWindow.qaLatest?.window?.contentView); ImageRotationWindow.qaLatest?.close(); window.makeKeyAndOrderFront(nil)
            ImageRotationWindow.start(urls: [backgroundFixture], direction: .left) {}
            let rotateLeftWait = ContinuousClock.now
            while ImageRotationWindow.qaLatest?.qaRunning == true && rotateLeftWait.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["imageRotateLeft"] = ImageRotationWindow.qaLatest?.qaSucceeded == true && qaImageOrientation(backgroundFixture) == 1
            ImageRotationWindow.qaLatest?.close(); window.makeKeyAndOrderFront(nil)
            checks["minimumWindow"] = window.frame.size == NSSize(width: 900, height: 600)
            let paletteEntries = CommandPaletteCatalog.entries(from: NSApp.mainMenu)
            checks["commandPaletteIndexesMenus"] = paletteEntries.count >= 20
            checks["commandPaletteStableIDs"] = Set(paletteEntries.map(\.id)).count == paletteEntries.count
            checks["createShortcutFromDialogCommand"] = paletteEntries.contains { $0.item.action == #selector(createSymbolicLinkFromDialog(_:)) }
            checks["createFileCommand"] = paletteEntries.contains { $0.item.action == #selector(createFile(_:)) }
            checks["toggleFullScreenCommand"] = paletteEntries.contains { $0.item.action == #selector(toggleFullScreen(_:)) }
            let preCompactFrame = window.frame, preCompactMinimum = window.minSize
            controller.enterCompactOverlay(nil)
            checks["compactOverlayEntered"] = controller.qaIsCompactOverlay && window.level == .floating
                && window.collectionBehavior.contains(.canJoinAllSpaces) && window.frame.width <= 460
            controller.toggleCompactOverlay(nil)
            checks["compactOverlayRestored"] = !controller.qaIsCompactOverlay && window.level == .normal
                && window.frame == preCompactFrame && window.minSize == preCompactMinimum
            checks["compactOverlayCommands"] = [#selector(enterCompactOverlay(_:)), #selector(exitCompactOverlay(_:)),
                #selector(toggleCompactOverlay(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["closeActivePaneCommand"] = paletteEntries.contains { $0.item.action == #selector(closeActivePane(_:)) }
            checks["locationOpenCommands"] = [#selector(openLocationInNewTab(_:)), #selector(openLocationInNewWindow(_:)),
                #selector(openLocationInOtherPane(_:))].allSatisfy { controller.qaLocationMenuActions.contains(NSStringFromSelector($0)) }
            checks["locationContextCommands"] = [#selector(copyLocationItem(_:)), #selector(openLocationInTerminal(_:)),
                #selector(pinSidebarLocation(_:)), #selector(unpinSidebarLocation(_:))].allSatisfy {
                    controller.qaLocationMenuActions.contains(NSStringFromSelector($0))
                }
            let locationItem = NSMenuItem(); locationItem.representedObject = gridFolder
            controller.copyLocationItem(locationItem)
            let copiedLocations = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            controller.pinSidebarLocation(locationItem)
            let pinnedLocation = preferences.favorites.contains(gridFolder)
            controller.unpinSidebarLocation(locationItem)
            checks["locationCopyPinCommands"] = copiedLocations == [gridFolder] && pinnedLocation && !preferences.favorites.contains(gridFolder)
            checks["themeCommands"] = [#selector(AppDelegate.setDarkTheme(_:)), #selector(AppDelegate.setLightTheme(_:)), #selector(AppDelegate.setDefaultTheme(_:)), #selector(AppDelegate.toggleAppTheme(_:))].allSatisfy { action in
                paletteEntries.contains { $0.item.action == action }
            }
            checks["existingWindowCommands"] = [#selector(AppDelegate.newWindow(_:)), #selector(AppDelegate.reopenClosedTab(_:)), #selector(AppDelegate.showReleaseNotes(_:)), #selector(splitHorizontally(_:)), #selector(splitVertically(_:)), #selector(toggleSidebarVisibility(_:)), #selector(toggleToolbar(_:)), #selector(showToolbarSettings(_:))].allSatisfy { action in
                paletteEntries.contains { $0.item.action == action }
            }
            checks["existingOpenAndHiddenCommands"] = [#selector(toggleHidden(_:)), #selector(AppDelegate.showGeneralSettings(_:)), #selector(openInDeveloperApplication(_:))].allSatisfy { action in
                paletteEntries.contains { $0.item.action == action }
            }
            checks["nativeTabCommands"] = [#selector(AppDelegate.nextTab(_:)), #selector(AppDelegate.previousTab(_:)),
                #selector(AppDelegate.closeSelectedTab(_:)), #selector(AppDelegate.closeAllTabs(_:)),
                #selector(AppDelegate.closeOtherTabs(_:)), #selector(AppDelegate.closeTabsToLeft(_:)),
                #selector(AppDelegate.closeTabsToRight(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["diagnosticAndHelpCommands"] = [#selector(AppDelegate.openHelp(_:)), #selector(AppDelegate.openLogFile(_:)),
                #selector(AppDelegate.openLogFileLocation(_:)), #selector(AppDelegate.openSettingsFile(_:)),
                #selector(AppDelegate.openRepositoryInIDE(_:)), #selector(editInTextEdit(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["archivePlacementCommands"] = [#selector(extractArchivesHere(_:)), #selector(extractArchivesSmart(_:)), #selector(extractArchivesToChildFolders(_:))].allSatisfy { action in
                paletteEntries.contains { $0.item.action == action }
            }
            checks["desktopWallpaperCommand"] = paletteEntries.contains { $0.item.action == #selector(setAsDesktopWallpaper(_:)) }
            checks["appBackgroundCommands"] = [#selector(setAsAppBackground(_:)), #selector(clearAppBackground(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["imageRotationCommands"] = [#selector(rotateImagesLeft(_:)), #selector(rotateImagesRight(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["systemInstallAndMediaCommands"] = [#selector(installCertificates(_:)), #selector(installFonts(_:)), #selector(playAllMedia(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["selectionAndTagCommands"] = [#selector(toggleFocusedSelection(_:)), #selector(openAllTagged(_:)), #selector(removeTags(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["autoFitColumnsCommand"] = paletteEntries.contains { $0.item.action == #selector(autoFitColumns(_:)) }
            let groupingActions: [Selector] = [#selector(groupByNone(_:)), #selector(groupByName(_:)), #selector(groupByCreated(_:)), #selector(groupByModified(_:)), #selector(groupBySize(_:)), #selector(groupByKind(_:)), #selector(groupByCreatedYear(_:)), #selector(groupByCreatedMonth(_:)), #selector(groupByCreatedDay(_:)), #selector(groupByModifiedYear(_:)), #selector(groupByModifiedMonth(_:)), #selector(groupByModifiedDay(_:)), #selector(groupAscending(_:)), #selector(groupDescending(_:)), #selector(toggleGroupDirection(_:)), #selector(groupDateByYear(_:)), #selector(groupDateByMonth(_:)), #selector(toggleGroupDateUnit(_:))]
            checks["groupingCommands"] = groupingActions.allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            checks["commandPaletteSearch"] = CommandPaletteCatalog.filtered(paletteEntries, query: L("숨김", "hidden")).contains { $0.item.action == #selector(toggleHidden(_:)) }
            controller.showCommandPalette(nil); try await Task.sleep(for: .milliseconds(50))
            controller.commandPalette.qaSetQuery(L("숨김", "hidden"))
            checks["commandPaletteWindow"] = controller.commandPalette.window?.isVisible == true
                && controller.commandPalette.qaSearchFocused && controller.commandPalette.qaVisibleCount >= 1
            try capture("command-palette", view: controller.commandPalette.window?.contentView)
            controller.commandPalette.close(); window.makeKeyAndOrderFront(nil)
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.showAbout(nil); try await Task.sleep(for: .milliseconds(50))
                checks["aboutWindow"] = delegate.qaReleaseInfoVisible && delegate.qaReleaseInfoText.contains("Files v4.2.9")
                try capture("about", view: delegate.qaReleaseInfoContentView); delegate.qaReleaseInfoContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showReleaseNotes(nil); try await Task.sleep(for: .milliseconds(50))
                checks["releaseNotesWindow"] = delegate.qaReleaseInfoVisible && delegate.qaReleaseInfoText.contains(L("개발 프리뷰", "Development Preview"))
                try capture("release-notes", view: delegate.qaReleaseInfoContentView); delegate.qaReleaseInfoContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showShortcutSettings(nil); try await Task.sleep(for: .milliseconds(50))
                checks["shortcutSettingsCommands"] = delegate.qaShortcutRowCount >= 15
                checks["shortcutSettingsWindow"] = delegate.qaShortcutWindowVisible
                try capture("keyboard-shortcuts", view: delegate.qaShortcutContentView)
                delegate.qaShortcutContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showAdvancedSettings(nil); try await Task.sleep(for: .milliseconds(50))
                checks["advancedSettingsWindow"] = delegate.qaAdvancedSettingsVisible
                let cache = FileIconCache()
                let cacheFile = FileItem(url: fixture.appendingPathComponent("cache-check"), name: "cache-check",
                                         isDirectory: false, identity: "qa-identity", size: 1)
                var reads = 0
                let iconLoader: (String) -> NSImage = { _ in
                    reads += 1
                    let image = NSImage(size: NSSize(width: 16, height: 16))
                    if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                        image.addRepresentation(bitmap)
                    }
                    return image
                }
                cache.configure(enabled: true, limitMiB: 8)
                _ = cache.icon(for: cacheFile, load: iconLoader)
                _ = cache.icon(for: cacheFile, load: iconLoader)
                let reuses = reads == 1
                _ = cache.icon(for: cacheFile.replacingSize(2), load: iconLoader)
                let invalidates = reads == 2
                let genericIcon = cache.genericIcon(forExtension: "txt")
                cache.invalidateFileIcons()
                _ = cache.icon(for: cacheFile, load: iconLoader)
                checks["fileIconInvalidationKeepsGenericIcon"] = reads == 3
                    && cache.genericIcon(forExtension: "txt") === genericIcon
                cache.removeAll()
                _ = cache.icon(for: cacheFile, load: iconLoader)
                cache.configure(enabled: false, limitMiB: 8)
                _ = cache.icon(for: cacheFile, load: iconLoader)
                _ = cache.icon(for: cacheFile, load: iconLoader)
                checks["previewCacheLifecycle"] = reuses && invalidates && reads == 6
                try capture("advanced-settings", view: delegate.qaAdvancedSettingsContentView)
                delegate.qaAdvancedSettingsContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showGeneralSettings(nil); try await Task.sleep(for: .milliseconds(50)); let widgetsBefore = delegate.qaGeneralWidgetStates
                let sizeUnitBefore = delegate.qaGeneralSizeUnit; let newTabBefore = delegate.qaGeneralOpenFoldersInNewTab
                let defaultSortBefore = delegate.qaGeneralDefaultSortDirectoryPlacement
                let autoSizeColumnsBefore = delegate.qaGeneralAutoSizeColumnsInDetailsLayout
                let calculateFolderSizesBefore = delegate.qaGeneralCalculateFolderSizes
                let showThumbnailsBefore = delegate.qaGeneralShowThumbnails
                let doubleClickToGoUpBefore = delegate.qaGeneralDoubleClickToGoUp
                let reverseTabScrollBefore = delegate.qaGeneralReverseTabScrollDirection
                let startupTabBefore = delegate.qaGeneralOpenNewTabOnStartup
                let newTabPoliciesBefore = delegate.qaGeneralNewTabPolicies
                let revealBefore = delegate.qaGeneralScrollToPreviousFolderOnUp
                let extensionWarningBefore = delegate.qaGeneralShowFileExtensionWarning
                let contextMenuBefore = delegate.qaGeneralContextMenuStates
                delegate.qaToggleGeneralWidgets(); delegate.qaToggleGeneralOpenNewTabOnStartup(); delegate.qaToggleGeneralNewTabPolicies(); delegate.qaToggleGeneralSizeUnit(); delegate.qaCycleGeneralDefaultSortDirectoryPlacement(); delegate.qaToggleGeneralAutoSizeColumnsInDetailsLayout(); delegate.qaToggleGeneralCalculateFolderSizes(); delegate.qaToggleGeneralShowThumbnails(); delegate.qaToggleGeneralDoubleClickToGoUp(); delegate.qaToggleGeneralReverseTabScrollDirection(); delegate.qaToggleGeneralOpenFoldersInNewTab(); delegate.qaToggleGeneralScrollToPreviousFolderOnUp(); delegate.qaToggleGeneralShowFileExtensionWarning(); delegate.qaToggleGeneralContextMenuItems(); let widgetsAfter = delegate.qaGeneralWidgetStates
                let contextMenuAfter = delegate.qaGeneralContextMenuStates
                let contextMenusToggled = contextMenuBefore?.count == contextMenuAfter?.count
                    && zip(contextMenuBefore ?? [], contextMenuAfter ?? []).allSatisfy { $0 != $1 }
                checks["generalSettingsScrollReachable"] = delegate.qaGeneralSettingsScrollReachable
                checks["generalSettingsWindow"] = delegate.qaGeneralSettingsVisible && widgetsBefore != nil && widgetsAfter != nil
                    && widgetsAfter!.0 != widgetsBefore!.0 && widgetsAfter!.1 != widgetsBefore!.1 && widgetsAfter!.2 != widgetsBefore!.2
                    && delegate.qaGeneralSizeUnit != sizeUnitBefore
                    && delegate.qaGeneralDefaultSortDirectoryPlacement != defaultSortBefore
                    && delegate.qaGeneralAutoSizeColumnsInDetailsLayout != autoSizeColumnsBefore
                    && delegate.qaGeneralCalculateFolderSizes != calculateFolderSizesBefore
                    && delegate.qaGeneralShowThumbnails != showThumbnailsBefore
                    && delegate.qaGeneralDoubleClickToGoUp != doubleClickToGoUpBefore
                    && delegate.qaGeneralReverseTabScrollDirection != reverseTabScrollBefore
                    && delegate.qaGeneralOpenNewTabOnStartup != startupTabBefore
                    && delegate.qaGeneralNewTabPolicies?.0 != newTabPoliciesBefore?.0
                    && delegate.qaGeneralNewTabPolicies?.1 != newTabPoliciesBefore?.1
                    && delegate.qaGeneralOpenFoldersInNewTab != newTabBefore
                    && delegate.qaGeneralScrollToPreviousFolderOnUp != revealBefore
                    && delegate.qaGeneralShowFileExtensionWarning != extensionWarningBefore
                    && contextMenusToggled
                preferences.setShowCompressionOptions(false); preferences.setShowOpenTerminal(false); preferences.setShowCreateFolderWithSelection(false); preferences.setShowPinToSidebar(false); preferences.setShowSendToMenu(false); preferences.setShowCopyPath(false); preferences.setShowOpenInNewTab(false); preferences.setShowOpenInNewWindow(false); preferences.setShowOpenInNewPane(false); preferences.setShowEditTagsMenu(false); preferences.setShowCreateShortcut(false)
                checks["contextMenuCompressionVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(createArchive(_:))))
                checks["contextMenuTerminalVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(openInTerminal(_:))))
                checks["contextMenuFolderVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(createFolderFromSelection(_:))))
                checks["contextMenuPinVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(toggleSelectedFavorite(_:))))
                checks["contextMenuShareVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(shareSelection(_:))))
                checks["contextMenuCopyPathVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(copyItemPath(_:))))
                    && !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(copyCurrentPath(_:))))
                checks["contextMenuOpenDestinationVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(openInNewTab(_:))))
                    && !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(openInNewWindow(_:))))
                    && !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(openInNewPane(_:))))
                checks["contextMenuEditTagsVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(showInfo(_:))))
                checks["contextMenuCreateShortcutVisibilityPreference"] = !controller.qaVisibleContextActions.contains(NSStringFromSelector(#selector(createSymbolicLink(_:))))
                preferences.setShowCompressionOptions(true); preferences.setShowOpenTerminal(true); preferences.setShowCreateFolderWithSelection(true); preferences.setShowPinToSidebar(true); preferences.setShowSendToMenu(true); preferences.setShowCopyPath(true); preferences.setShowOpenInNewTab(true); preferences.setShowOpenInNewWindow(true); preferences.setShowOpenInNewPane(true); preferences.setShowEditTagsMenu(true); preferences.setShowCreateShortcut(true)
                controller.closeSecondaryPane(nil)
                controller.navigate(fixture)
                let paneSourceWait = ContinuousClock.now
                while controller.model.isLoading && paneSourceWait.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
                preferences.setCalculateFolderSizes(true)
                let folderSizeWait = ContinuousClock.now
                while controller.model.items.first(where: { $0.name == "000-grid-folder" })?.size != 21 && folderSizeWait.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
                checks["folderSizeCalculation"] = controller.model.items.first(where: { $0.name == "000-grid-folder" })?.size == 21
                preferences.setCalculateFolderSizes(false)
                preferences.setShowThumbnails(false)
                checks["thumbnailPolicyPrimary"] = controller.qaThumbnailPolicyApplied
                controller.clearSelection(nil)
                let expectedPaneURL = controller.contextFolderURL
                controller.openInNewPane(nil); try await Task.sleep(for: .milliseconds(50))
                let openedPaneState = controller.workspaceSnapshot()
                checks["openCurrentFolderInNewPane"] = expectedPaneURL != nil && openedPaneState.panes.count == 2 && openedPaneState.panes[1].tab.location == expectedPaneURL
                checks["thumbnailPolicyBothPanes"] = controller.qaThumbnailPolicyApplied
                preferences.setShowThumbnails(true)
                controller.setSecondaryActive(false)
                controller.toggleFilterHeader(nil)
                let filterFocused = controller.folderFilter.currentEditor() != nil
                controller.folderFilter.stringValue = "LONG-FILE-NAME"
                controller.folderFilter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.folderFilter))
                checks["folderFilterMatchesNames"] = filterFocused && controller.model.items.count == 1
                    && controller.model.items.first?.name.contains("long-file-name") == true
                    && controller.secondaryPane?.model.nameFilter == ""
                let otherFilterLoad = ContinuousClock.now
                while controller.secondaryPane?.model.isLoading == true && elapsed(otherFilterLoad) < 10 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                controller.secondaryPane?.qaEnterFilter("000-grid")
                checks["folderFilterSplitIsolation"] = controller.secondaryPane?.model.items.map(\.name) == ["000-grid-folder"]
                    && controller.model.nameFilter == "LONG-FILE-NAME"
                controller.toggleFilterHeader(nil)
                checks["folderFilterClearsOnClose"] = controller.folderFilter.isHidden
                    && controller.model.nameFilter.isEmpty && controller.model.items.count == 10_000
                    && controller.secondaryPane?.model.nameFilter == ""
                controller.arrangePanesHorizontally(nil); checks["arrangePanesHorizontally"] = controller.workspaceSnapshot().axis == .horizontal
                controller.arrangePanesVertically(nil); checks["arrangePanesVertically"] = controller.workspaceSnapshot().axis == .vertical
                let activePaneBeforeFocus = controller.workspaceSnapshot().activePaneID
                controller.focusOtherPane(nil); checks["focusOtherPane"] = controller.workspaceSnapshot().activePaneID != activePaneBeforeFocus
                controller.openCurrentFolderInOtherPane(nil); try await Task.sleep(for: .milliseconds(50))
                let otherPaneState = controller.workspaceSnapshot()
                checks["openCurrentFolderInOtherPane"] = otherPaneState.panes.count == 2
                    && otherPaneState.panes[0].tab.location == otherPaneState.panes[1].tab.location
                controller.toggleDualPane(nil); checks["toggleDualPaneCloses"] = !controller.workspaceSnapshot().isSplit
                controller.toggleDualPane(nil); checks["toggleDualPaneOpens"] = controller.workspaceSnapshot().isSplit
                controller.model.setViewMode(.grid)
                controller.focusOtherPane(nil)
                let gridResponder = window.firstResponder as? NSView
                checks["splitFocusReturnsToVisibleGrid"] = !controller.secondaryActive
                    && gridResponder?.isDescendant(of: controller.gridView) == true
                controller.focusOtherPane(nil)
                controller.closeSecondaryPane(nil)
                checks["closingSplitFocusesVisibleGrid"] = (window.firstResponder as? NSView)?
                    .isDescendant(of: controller.gridView) == true
                controller.model.setViewMode(.details)

                let primaryHistory = NavigationHistory(current: NavigationEntry(url: columnFolder),
                    back: [NavigationEntry(url: fixture)])
                let secondaryHistory = NavigationHistory(current: NavigationEntry(url: gridFolder),
                    forward: [NavigationEntry(url: columnFolder)])
                let primary = PaneSnapshot(tab: TabSnapshot(history: primaryHistory, viewMode: .grid))
                let secondary = PaneSnapshot(tab: TabSnapshot(history: secondaryHistory, viewMode: .list))
                let splitStore = WorkspaceSessionStore(defaults: defaults, key: "qaSplitWorkspace")
                for axis in SplitAxis.allCases {
                    try splitStore.save([SplitTabState(primary: primary, secondary: secondary,
                        axis: axis, ratio: 0.35, activePaneID: secondary.id)])
                    let restored = BrowserWindow(preferences: preferences, restoresFrame: false,
                                                initialWorkspace: splitStore.load().first)
                    checks["tabSplitRejectsPendingSession_\(axis.rawValue)"] =
                        !restored.canAcceptTabSplit(from: controller) && !controller.canAcceptTabSplit(from: restored)
                    restored.showWindow(nil)
                    let restoreStart = ContinuousClock.now
                    while (restored.secondaryPane == nil || restored.model.isLoading || restored.secondaryPane?.model.isLoading == true)
                            && elapsed(restoreStart) < 10 {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    restored.window?.contentView?.layoutSubtreeIfNeeded()
                    let actual = restored.workspaceSnapshot()
                    metrics["restoredSplitRatio_\(axis.rawValue)"] = actual.ratio
                    checks["splitWorkspaceRestores_\(axis.rawValue)"] = actual.axis == axis
                        && abs(actual.ratio - 0.35) < 0.01
                        && actual.activePaneID == secondary.id
                        && actual.panes.map(\.id) == [primary.id, secondary.id]
                        && actual.panes.map { $0.tab.location?.path } == [columnFolder.path, gridFolder.path]
                        && actual.panes.map { $0.tab.viewMode } == [.grid, .list]
                        && actual.panes.first?.tab.history.back.map { $0.url?.path } == [fixture.path]
                        && actual.panes.last?.tab.history.forward.map { $0.url?.path } == [columnFolder.path]
                    if axis == .vertical, let restoredWindow = restored.window {
                        let split = restored.workspaceSplit
                        let dividerX = restored.primaryPaneHost.frame.maxX + split.dividerThickness / 2
                        let targetX = split.bounds.width * 0.55
                        func dividerEvent(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
                            NSEvent.mouseEvent(with: type,
                                location: split.convert(NSPoint(x: x, y: split.bounds.midY), to: nil),
                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: restoredWindow.windowNumber, context: nil, eventNumber: 0,
                                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                        }
                        if let down = dividerEvent(.leftMouseDown, x: dividerX),
                           let drag = dividerEvent(.leftMouseDragged, x: targetX),
                           let up = dividerEvent(.leftMouseUp, x: targetX) {
                            // NSSplitView consumes these events in its mouse-down tracking loop.
                            NSApp.postEvent(up, atStart: true)
                            NSApp.postEvent(drag, atStart: true)
                            split.mouseDown(with: down)
                            let draggedRatio = restored.workspaceSnapshot().ratio
                            metrics["draggedSplitRatio"] = draggedRatio
                            checks["sideBySideTracksDividerDrag"] = abs(draggedRatio - 0.55) < 0.03
                        } else { checks["sideBySideTracksDividerDrag"] = false }
                        split.setPosition(split.bounds.width * 0.60, ofDividerAt: 0)
                        let adjustedRatio = restored.workspaceSnapshot().ratio
                        var narrowFrame = restoredWindow.frame
                        narrowFrame.size.width = restoredWindow.minSize.width
                        restoredWindow.setFrame(narrowFrame, display: true)
                        restoredWindow.contentView?.layoutSubtreeIfNeeded()
                        let narrowRatio = restored.workspaceSnapshot().ratio
                        metrics["adjustedSplitRatio"] = adjustedRatio
                        metrics["minimumWidthSplitRatio"] = narrowRatio
                        checks["sideBySideKeepsAdjustedRatioAtMinimumWidth"] = abs(adjustedRatio - 0.60) < 0.01
                            && abs(narrowRatio - adjustedRatio) < 0.01
                            && abs(restoredWindow.frame.width - restoredWindow.minSize.width) < 1
                        restored.focusOtherPane(nil)
                        restored.focusPath(nil)
                        checks["sideBySideCanFocusPrimaryPathAtMinimumWidth"] = !restored.secondaryActive
                            && restored.pathField.frame.width > 0 && restored.pathField.currentEditor() != nil
                        restored.focusOtherPane(nil)
                        restored.focusPath(nil)
                        checks["sideBySideCanUseSecondaryPathAtMinimumWidth"] = restored.secondaryActive
                            && restored.secondaryPane?.qaSubmitFocusedPath(columnFolder) == true
                            && restored.secondaryPane?.model.location?.path == columnFolder.path
                    }
                    restored.close()
                }
                let dropBounds = NSRect(x: 0, y: 0, width: 400, height: 300)
                checks["tabSplitRecognizesFourEdges"] =
                    TabSplitEdge.at(NSPoint(x: 10, y: 150), in: dropBounds, flipped: false) == .left
                    && TabSplitEdge.at(NSPoint(x: 390, y: 150), in: dropBounds, flipped: false) == .right
                    && TabSplitEdge.at(NSPoint(x: 200, y: 290), in: dropBounds, flipped: false) == .top
                    && TabSplitEdge.at(NSPoint(x: 200, y: 10), in: dropBounds, flipped: true) == .top
                    && TabSplitEdge.at(NSPoint(x: 200, y: 10), in: dropBounds, flipped: false) == .bottom
                    && TabSplitEdge.at(NSPoint(x: 200, y: 150), in: dropBounds, flipped: false) == nil
                for (edge, expectedAxis, first, last) in [
                    (TabSplitEdge.left, SplitAxis.vertical, gridFolder, columnFolder),
                    (.right, .vertical, columnFolder, gridFolder),
                    (.top, .horizontal, gridFolder, columnFolder),
                    (.bottom, .horizontal, columnFolder, gridFolder)
                ] {
                    let source = BrowserWindow(preferences: preferences, restoresFrame: false, initialSnapshot: secondary.tab)
                    let target = BrowserWindow(preferences: preferences, restoresFrame: false, initialSnapshot: primary.tab)
                    source.showWindow(nil)
                    target.showWindow(nil)
                    if let sourceWindow = source.window, let targetWindow = target.window {
                        targetWindow.addTabbedWindow(sourceWindow, ordered: .above)
                        sourceWindow.makeKeyAndOrderFront(nil)
                    }
                    let wasTabbed = target.window?.tabbedWindows?.contains { $0 === source.window } == true
                    var closedSourceState: SplitTabState?
                    var hadContentDuringClose = false
                    source.onClose = { [weak source] in
                        closedSourceState = source?.workspaceSnapshot()
                        hadContentDuringClose = source?.window?.contentView != nil
                    }
                    let dropped = target.splitByDroppingTab(from: source, at: edge)
                    let closeStart = ContinuousClock.now
                    while closedSourceState == nil && elapsed(closeStart) < 2 {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let state = target.workspaceSnapshot()
                    checks["tabSplitDrop_\(edge)"] = dropped && state.axis == expectedAxis
                        && state.panes.map { $0.tab.location?.path } == [first.path, last.path]
                        && state.activePane.tab.location?.path == gridFolder.path
                        && state.activePane.tab.viewMode == .list
                        && state.activePane.tab.history.forward.map { $0.url?.path } == [columnFolder.path]
                        && !target.canAcceptTabSplit(from: source)
                        && wasTabbed && target.window?.isVisible == true
                        && target.window?.tabbedWindows?.contains { $0 === source.window } != true
                    checks["tabClosePreservesWorkspace_\(edge)"] = hadContentDuringClose
                        && closedSourceState?.activePane.tab.location?.path == gridFolder.path
                        && closedSourceState?.activePane.tab.viewMode == .list
                        && closedSourceState?.activePane.tab.history.forward.map { $0.url?.path } == [columnFolder.path]
                        && source.window?.contentView == nil
                    target.close()
                }
                let sameTab = BrowserWindow(preferences: preferences, restoresFrame: false, initialSnapshot: primary.tab)
                sameTab.showWindow(nil)
                let splitSameTab = sameTab.splitByDroppingTab(from: sameTab, at: .right)
                let sameTabState = sameTab.workspaceSnapshot()
                checks["tabSplitKeepsSameTabOpen"] = splitSameTab && sameTab.window?.isVisible == true
                    && sameTabState.panes.map { $0.tab.location?.path } == [columnFolder.path, columnFolder.path]
                    && !sameTab.splitByDroppingTab(from: sameTab, at: .bottom)
                    && sameTab.workspaceSnapshot().panes.map(\.id) == sameTabState.panes.map(\.id)
                sameTab.close()
                window.makeKeyAndOrderFront(nil)
                try capture("general-settings", view: delegate.qaGeneralSettingsContentView)
                delegate.qaToggleGeneralWidgets(); delegate.qaToggleGeneralOpenNewTabOnStartup(); delegate.qaToggleGeneralNewTabPolicies(); delegate.qaToggleGeneralSizeUnit(); delegate.qaCycleGeneralDefaultSortDirectoryPlacement(); delegate.qaToggleGeneralAutoSizeColumnsInDetailsLayout(); delegate.qaToggleGeneralCalculateFolderSizes(); delegate.qaToggleGeneralShowThumbnails(); delegate.qaToggleGeneralDoubleClickToGoUp(); delegate.qaToggleGeneralReverseTabScrollDirection(); delegate.qaToggleGeneralOpenFoldersInNewTab(); delegate.qaToggleGeneralScrollToPreviousFolderOnUp(); delegate.qaToggleGeneralShowFileExtensionWarning(); delegate.qaToggleGeneralContextMenuItems(); delegate.qaGeneralSettingsContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showArchiveCapabilities(nil); try await Task.sleep(for: .milliseconds(50))
                checks["archiveCapabilitiesWindow"] = delegate.qaArchiveCapabilitiesVisible
                try capture("archive-capabilities", view: delegate.qaArchiveCapabilitiesContentView)
                delegate.qaArchiveCapabilitiesContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                delegate.showRemoteConnections(nil); try await Task.sleep(for: .milliseconds(50))
                delegate.qaCreateRemoteProfile(); try await Task.sleep(for: .milliseconds(50))
                checks["remoteConnectionsWindow"] = delegate.qaRemoteConnectionsVisible && delegate.qaRemoteProfileCount == 2
                checks["smbConnectCommand"] = delegate.qaSMBConnectEnabled
                checks["sftpTrustCommand"] = delegate.qaSFTPTrustEnabled
                checks["sftpIdentityCommand"] = delegate.qaSFTPIdentityEnabled
                checks["sftpConnectionGate"] = delegate.qaSFTPConnectDisabled
                checks["sftpDownloadGate"] = delegate.qaSFTPDownloadDisabled
                checks["ftpCredentialGate"] = delegate.qaFTPConnectDisabled
                try capture("remote-connections", view: delegate.qaRemoteConnectionsContentView)
                delegate.qaRemoteConnectionsContentView?.window?.close(); window.makeKeyAndOrderFront(nil)
                let remoteModel = try RemoteBrowserModel(path: "/team") { path in
                    if path == "/team" { return [.init(name: "Folder", remotePath: "/team/Folder", isDirectory: true), .init(name: "한글 file.txt", remotePath: "/team/한글 file.txt")] }
                    return [.init(name: "nested.txt", remotePath: path + "/nested.txt")]
                }
                var requestedRemoteDownload: String?
                let remotePane = RemoteBrowserWindow(title: "QA SFTP", model: remoteModel) { entry, _ in requestedRemoteDownload = entry.remotePath }
                remotePane.present(); try await Task.sleep(for: .milliseconds(50))
                checks["remoteBrowserRows"] = remotePane.qaRowCount == 2 && remotePane.qaPath == "/team"
                checks["remoteBrowserAccessibility"] = remotePane.qaAccessibilityReady
                remotePane.qaSelect(row: 0); checks["remoteBrowserFolderNotDownloadable"] = !remotePane.qaDownloadEnabled
                remotePane.qaOpen(row: 0); try await Task.sleep(for: .milliseconds(50))
                let openedRemoteFolder = remotePane.qaPath == "/team/Folder" && remotePane.qaRowCount == 1
                remotePane.qaBack(); try await Task.sleep(for: .milliseconds(50)); let remoteBack = remotePane.qaPath == "/team"
                remotePane.qaForward(); try await Task.sleep(for: .milliseconds(50)); let remoteForward = remotePane.qaPath == "/team/Folder"
                remotePane.qaUp(); try await Task.sleep(for: .milliseconds(50)); let remoteUp = remotePane.qaPath == "/team"
                checks["remoteBrowserNavigation"] = openedRemoteFolder && remoteBack && remoteForward && remoteUp
                remotePane.qaSelect(row: 1); remotePane.qaOpen(row: 1); checks["remoteBrowserDownloadSelection"] = remotePane.qaDownloadEnabled && remotePane.qaDeleteUnavailable && requestedRemoteDownload == "/team/한글 file.txt"
                try capture("remote-browser", view: remotePane.qaContentView); remotePane.close(); window.makeKeyAndOrderFront(nil)
                let gitPanel = GitWindow(); gitPanel.present(location: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
                let gitLoad = ContinuousClock.now
                while !gitPanel.qaLoaded && gitLoad.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
                checks["gitWindow"] = gitPanel.window?.isVisible == true && gitPanel.qaLoaded && gitPanel.qaBranch != nil
                checks["gitAccessibility"] = gitPanel.qaAccessibilityReady
                checks["gitSupportBoundary"] = gitPanel.qaSupportBoundaryVisible
                checks["gitMenuCommand"] = paletteEntries.contains { $0.item.action == #selector(AppDelegate.showGitStatus(_:)) }
                checks["gitInitAndSyncCommands"] = [#selector(AppDelegate.initializeGitRepository(_:)),
                    #selector(AppDelegate.synchronizeGitRepository(_:))].allSatisfy { action in
                        paletteEntries.contains { $0.item.action == action }
                    }
                try capture("git-status", view: gitPanel.window?.contentView); gitPanel.close(); window.makeKeyAndOrderFront(nil)
                var clonedLocation: URL?
                let clonePanel = GitCloneWindow { clonedLocation = $0 }
                clonePanel.present(); let cloneDestination = destination.appendingPathComponent("git-clone-ui", isDirectory: true); try? fm.removeItem(at: cloneDestination)
                clonePanel.qaClone(source: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true), destination: cloneDestination)
                let cloneWait = ContinuousClock.now
                while clonePanel.qaRunning && cloneWait.duration(to: .now) < .seconds(20) { try await Task.sleep(for: .milliseconds(20)) }
                checks["gitCloneWindow"] = clonePanel.qaSucceeded && clonedLocation?.standardizedFileURL.path == cloneDestination.standardizedFileURL.path && fm.fileExists(atPath: cloneDestination.appendingPathComponent(".git", isDirectory: true).path)
                checks["gitCloneAccessibility"] = clonePanel.qaAccessibilityReady
                checks["gitCloneMenuCommand"] = paletteEntries.contains { $0.item.action == #selector(AppDelegate.showGitClone(_:)) }
                try capture("git-clone", view: clonePanel.window?.contentView); clonePanel.close(); window.makeKeyAndOrderFront(nil)
                let qaGitFile = cloneDestination.appendingPathComponent("qa-untracked.txt")
                try Data("Git column QA".utf8).write(to: qaGitFile, options: .atomic)
                let gitList = BrowserWindow(preferences: preferences, restoresFrame: false, initialLocation: cloneDestination, cloudProvider: qaCloudProvider)
                gitList.showWindow(nil)
                let hiddenGitWait = ContinuousClock.now
                while gitList.model.isLoading && hiddenGitWait.duration(to: .now) < .seconds(15) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let skippedHiddenGit = !gitList.model.isLoading && gitList.gitLocation == nil && !gitList.qaGitLoading
                preferences.setShowGitStatusColumn(true)
                preferences.setShowGitCommitDateColumn(true)
                preferences.setShowGitCommitMessageColumn(true)
                preferences.setShowGitCommitAuthorColumn(true)
                preferences.setShowGitCommitSHAColumn(true)
                let gitListWait = ContinuousClock.now
                while (gitList.model.isLoading || gitList.qaGitLoading) && gitListWait.duration(to: .now) < .seconds(15) { try await Task.sleep(for: .milliseconds(20)) }
                checks["gitFileColumn"] = gitList.qaGitColumnVisible && gitList.qaGitMarkedRows > 0
                let commitColumns = ["gitCommitDate", "gitCommitMessage", "gitCommitAuthor", "gitCommitSHA"]
                let shaIndex = gitList.table.column(withIdentifier: .init("gitCommitSHA"))
                if shaIndex >= 0, let row = gitList.detailRows.indices.first(where: {
                    detailItem(at: $0, in: gitList.detailRows)?.name == "README.md"
                }), let tracked = detailItem(at: row, in: gitList.detailRows) {
                    gitList.table.moveColumn(shaIndex, toColumn: 1)
                    gitList.table.scrollRowToVisible(row)
                    gitList.table.layoutSubtreeIfNeeded()
                    let shaCell = gitList.table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTableCellView
                    gitList.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    for key in commitColumns {
                        let column = gitList.table.tableColumn(withIdentifier: .init(key))
                        _ = gitList.tableView(gitList.table, viewFor: column, row: row)
                    }
                    let metadataWait = ContinuousClock.now
                    while gitList.gitCommits[tracked.url] == nil && metadataWait.duration(to: .now) < .seconds(10) {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    checks["gitCommitColumns"] = commitColumns.allSatisfy {
                        gitList.qaVisibleDetailColumns.contains($0) && gitList.gitCommitValue($0, for: tracked) != "—"
                    } && gitList.gitCommitValue("gitCommitSHA", for: tracked).count == 12
                    checks["gitCommitUpdatesVisibleCellInPlace"] = shaCell != nil
                        && gitList.table.view(atColumn: 1, row: row, makeIfNecessary: false) === shaCell
                        && shaCell?.textField?.stringValue == gitList.gitCommitValue("gitCommitSHA", for: tracked)
                        && gitList.table.selectedRowIndexes == IndexSet(integer: row)
                } else { checks["gitCommitColumns"] = false }
                try capture("git-file-column", view: gitList.window?.contentView)
                preferences.setShowGitStatusColumn(false)
                preferences.setShowGitCommitDateColumn(false)
                preferences.setShowGitCommitMessageColumn(false)
                preferences.setShowGitCommitAuthorColumn(false)
                preferences.setShowGitCommitSHAColumn(false)
                checks["hiddenGitColumnsSkipMetadata"] = skippedHiddenGit && gitList.gitLocation == nil
                    && gitList.gitCommitTask == nil && !gitList.qaGitLoading && gitList.qaGitMarkedRows == 0
                gitList.close(); window.makeKeyAndOrderFront(nil)
            } else { checks["shortcutSettingsWindow"] = false }
            controller.showToolbarSettings(nil); try await Task.sleep(for: .milliseconds(50))
            checks["toolbarSettingsWindow"] = controller.toolbarSettingsWindow?.window?.isVisible == true
                && controller.toolbarSettingsWindow?.qaRowCount == BrowserToolbarItem.allCases.count
            try capture("toolbar-settings", view: controller.toolbarSettingsWindow?.window?.contentView)
            controller.toolbarSettingsWindow?.close(); window.makeKeyAndOrderFront(nil)
            let toolbarTestFrame = window.frame
            window.setFrame(NSRect(origin: toolbarTestFrame.origin, size: NSSize(width: 700, height: toolbarTestFrame.height)), display: true)
            root.layoutSubtreeIfNeeded()
            controller.rebuildToolbar(force: true)
            let overflowTitles = controller.toolbarOverflow.itemArray.map(\.title)
            checks["toolbarCompactOverflow"] = controller.toolbarCompact == true
                && overflowTitles.contains(L("숨김 항목 전환", "Toggle Hidden Files"))
                && overflowTitles.contains(L("즐겨찾기 전환", "Toggle Favorite"))
            window.setFrame(toolbarTestFrame, display: true); root.layoutSubtreeIfNeeded(); controller.rebuildToolbar(force: true)
            preferences.toggleToolbarItem(.favorite)
            checks["toolbarVisibilityPreference"] = preferences.hiddenToolbarItems.contains(.favorite)
                && !controller.toolbarOverflow.itemArray.map(\.title).contains(L("즐겨찾기 전환", "Toggle Favorite"))
            preferences.toggleToolbarItem(.favorite)
            preferences.setShowToolbar(false); preferences.setShowStatusBar(false); preferences.setShowSidebar(false)
            checks["browserChromeVisibilityPreference"] = controller.toolbar.isHidden && controller.bottom.isHidden && !controller.qaSidebarVisible
            preferences.setShowToolbar(true); preferences.setShowStatusBar(true); preferences.setShowSidebar(true)
            checks["browserChromeVisibilityRestored"] = !controller.toolbar.isHidden && !controller.bottom.isHidden && controller.qaSidebarVisible
            preferences.setShowCreatedColumn(true); preferences.setShowDateColumn(false); preferences.setShowTypeColumn(false); preferences.setShowSizeColumn(false); preferences.setShowGitStatusColumn(true)
            preferences.setShowFileTagColumn(true); preferences.setShowPathColumn(true)
            checks["createdDateColumn"] = controller.qaVisibleDetailColumns.contains("created")
                && (controller.qaCreatedColumnWidth ?? 0) >= 70
            checks["detailColumnVisibilityPreference"] = controller.qaVisibleDetailColumns.isSuperset(of: ["name", "created", "git", "tag", "path"])
                && controller.qaVisibleDetailColumns.isDisjoint(with: ["modified", "kind", "size"])
            checks["tagAndPathColumnMetrics"] = (controller.table.tableColumn(withIdentifier: .init("tag"))?.width ?? 0) >= 70
                && (controller.table.tableColumn(withIdentifier: .init("path"))?.width ?? 0) >= 70
            preferences.setShowCreatedColumn(false); preferences.setShowDateColumn(true); preferences.setShowTypeColumn(true); preferences.setShowSizeColumn(true); preferences.setShowGitStatusColumn(false)
            preferences.setShowFileTagColumn(false); preferences.setShowPathColumn(false)
            preferences.setHomeSectionExpanded(.favorites, expanded: false)
            preferences.setHomeSectionExpanded(.volumes, expanded: false)
            preferences.setHomeSectionExpanded(.recent, expanded: false)
            controller.buildHome()
            checks["homeWidgetExpansion"] = controller.qaCollapsedHomeSectionCount == 3
            preferences.setHomeSectionExpanded(.favorites, expanded: true)
            preferences.setHomeSectionExpanded(.volumes, expanded: true)
            preferences.setHomeSectionExpanded(.recent, expanded: true)
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
            appearanceSettings.qaChangeBackgroundPresentation()
            checks["appBackgroundPresentation"] = preferences.appBackgroundFit == .fit
                && preferences.appBackgroundHorizontalAlignment == .trailing
                && preferences.appBackgroundVerticalAlignment == .top
                && abs(preferences.appBackgroundOpacity - 0.45) < 0.001
            try capture("appearance-settings", view: appearanceSettings.window?.contentView)
            appearanceSettings.qaResetFolderViews()
            checks["folderSettingsResetAll"] = appearanceSettings.qaFolderCount == 0
            preferences.setAppBackgroundPresentation(fit: .fill, opacity: 1, horizontal: .center, vertical: .center)
            appearanceSettings.qaClearAppBackground()
            checks["appBackgroundCleared"] = preferences.appBackgroundPath == nil && !controller.qaHasAppBackground
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
            if let first = controller.model.items.first {
                controller.model.savePosition(selection: [first.id], scrollOffset: 0)
                controller.groupBySize(nil); let ascendingGroups = controller.qaDetailGroupTitles
                controller.groupDescending(nil); let descendingGroups = controller.qaDetailGroupTitles
                checks["detailGroupingRows"] = ascendingGroups.count > 1
                    && !controller.qaDetailGroupTitles.contains("")
                    && descendingGroups == Array(ascendingGroups.reversed())
                    && controller.primarySelectedItems.map(\.id) == [first.id]
                controller.groupByModifiedMonth(nil)
                checks["groupingStatePersistence"] = controller.model.snapshot.grouping == .init(field: .modified, ascending: false, dateUnit: .month)
                controller.groupByCreatedDay(nil)
                checks["createdDateGrouping"] = !controller.qaDetailGroupTitles.isEmpty
                    && !controller.qaDetailGroupTitles.contains(L("알 수 없음", "Unknown"))
                    && controller.model.snapshot.grouping == .init(field: .created, ascending: false, dateUnit: .day)
                controller.groupByNone(nil)
            } else { checks["detailGroupingRows"] = false }
            for column in controller.table.tableColumns where !column.isHidden { column.width = column.minWidth }
            controller.autoFitColumns(nil)
            checks["autoFitColumns"] = controller.table.tableColumn(withIdentifier: .init("name"))?.width ?? 0 > 70
                && controller.table.tableColumns.filter { !$0.isHidden }.allSatisfy { $0.width >= $0.minWidth && $0.width <= 720 }
            controller.showSearch(nil); controller.searchWindow?.qaSearch("long-file-name", scope: .currentFolder)
            let searchStart = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && searchStart.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["searchWindow"] = controller.searchWindow?.window?.isVisible == true
            checks["searchResults"] = controller.searchWindow?.qaResultCount == 1
            checks["searchCapability"] = controller.searchWindow?.qaShowsDirectEnumeration == true
            try capture("search", view: controller.searchWindow?.window?.contentView)
            let searchHit = fixture.appendingPathComponent("00000-한글-é-📁-long-file-name.txt")
            let revealedSearchHit = controller.searchWindow?.qaRevealResult(named: searchHit.lastPathComponent) == true
            let postSearchRefresh = ContinuousClock.now
            while controller.model.isLoading && postSearchRefresh.duration(to: .now) < .seconds(30) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["searchParentFolderRevealsItem"] = revealedSearchHit && controller.model.location == fixture.standardizedFileURL
                && controller.primarySelectedItems.map(\.id) == [searchHit.path]
                && controller.searchWindow?.window?.isVisible == false
            let searchPanel = SearchWindow()
            var openedSearchResult: URL?
            searchPanel.present(root: columnFolder, showHidden: false, onReveal: { _ in },
                                onOpen: { openedSearchResult = $0.url })
            searchPanel.qaSearch("leaf.txt", scope: .currentFolder)
            let searchKeyboardStart = ContinuousClock.now
            while searchPanel.qaIsSearching && elapsed(searchKeyboardStart) < 5 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let keyboardResult = searchPanel.qaOpenResultWithKeyboard()
            checks["searchKeyboardFocusesResult"] = keyboardResult.focusedResult
            checks["searchKeyboardOpensResult"] = keyboardResult.closed
                && openedSearchResult?.standardizedFileURL.path == columnFolder.appendingPathComponent("leaf.txt").standardizedFileURL.path
            searchPanel.close()
            window.makeKeyAndOrderFront(nil)
            controller.addSelectionToShelf(nil)
            controller.addSelectionToShelf(nil)
            checks["shelfAddsSelectedFileOnce"] = !controller.shelf.isHidden
                && preferences.shelfEntries.map(\.url.path) == [searchHit.path]
            controller.shelf.qaRemoveFirst()
            checks["shelfRemovalPreservesOriginal"] = preferences.shelfEntries.isEmpty && fm.fileExists(atPath: searchHit.path)
            controller.toggleShelfPane(nil)
            checks["shelfToggleHidesPane"] = controller.shelf.isHidden
            controller.toggleInfoPane(nil)
            let inspectorStart = ContinuousClock.now
            while !controller.inspector.qaDetails.contains(searchHit.path) && elapsed(inspectorStart) < 5 {
                try await Task.sleep(for: .milliseconds(20))
            }
            checks["infoPaneDetails"] = !controller.inspector.isHidden
                && controller.inspector.qaTitle == searchHit.lastPathComponent
                && controller.inspector.qaDetails.contains(searchHit.path)
            root.layoutSubtreeIfNeeded()
            checks["infoPaneReadableWidth"] = controller.inspector.frame.width >= 220
            controller.showInfoPanePreview(nil)
            checks["infoPanePreview"] = controller.inspector.qaPreviewURL?.path == searchHit.path
            try capture("info-pane-preview")
            controller.table.selectRowIndexes([0, 1, 2], byExtendingSelection: false)
            let previewItems = controller.primarySelectedItems
            if previewItems.count == 3, previewItems[0].isDirectory, !previewItems[1].isDirectory {
                let inspector = controller.inspector
                let startsAtFolder = inspector.qaTitle == previewItems[0].name && inspector.qaPreviewURL == nil
                    && inspector.qaPreviewNavigation?.previous == false && inspector.qaPreviewNavigation?.next == true
                inspector.qaNextPreview()
                let showsFile = inspector.qaPreviewURL?.path == previewItems[1].url.path
                inspector.qaNextPreview()
                let reachesEnd = inspector.qaTitle == previewItems[2].name && inspector.qaPreviewNavigation?.next == false
                inspector.qaPreviousPreview()
                checks["infoPaneMultiItemPreview"] = startsAtFolder && showsFile && reachesEnd
                    && inspector.qaPreviewURL?.path == previewItems[1].url.path
                    && controller.primarySelectedItems == previewItems
            } else {
                checks["infoPaneMultiItemPreview"] = false
            }
            controller.toggleInfoPane(nil)
            checks["infoPaneReleasesPreview"] = controller.inspector.isHidden && controller.inspector.qaPreviewURL == nil
            controller.showInfoPaneDetails(nil)
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
            controller.infoWindow?.qaInspectSignature()
            let signatureStart = ContinuousClock.now
            while controller.infoWindow?.qaSignatureLoaded != true && signatureStart.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            checks["fileInfoSignature"] = controller.infoWindow?.qaSignatureLoaded == true
            checks["fileInfoScrollsAtMinimumSize"] = controller.infoWindow?.qaCanReachSignature() == true
            try capture("file-info", view: controller.infoWindow?.window?.contentView)
            controller.infoWindow?.close(); window.makeKeyAndOrderFront(nil)
            let taggedURL = controller.activeSelectedItems.first?.url
            controller.openAllTagged(nil)
            let tagSearchStart = ContinuousClock.now
            while (controller.searchWindow?.qaTagFilter != "QA" || controller.searchWindow?.qaIsSearching == true)
                && tagSearchStart.duration(to: .now) < .seconds(20) { try await Task.sleep(for: .milliseconds(10)) }
            checks["openAllTaggedAlternative"] = controller.searchWindow?.qaTagFilter == "QA" && (controller.searchWindow?.qaResultCount ?? 0) >= 1
            controller.searchWindow?.close(); window.makeKeyAndOrderFront(nil)
            controller.removeTags(nil)
            let tagRemovalStart = ContinuousClock.now
            func tagsAreEmpty(at url: URL?) -> Bool {
                guard let url, let snapshot = try? FileTagService().snapshot(url) else { return false }
                return snapshot.tags.isEmpty
            }
            while !tagsAreEmpty(at: taggedURL) && tagRemovalStart.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            checks["removeTagsCommand"] = tagsAreEmpty(at: taggedURL)
            if let taggedURL, let snapshot = try? FileTagService().snapshot(taggedURL) {
                _ = try? FileTagService().setTags(["QA", "검토"], at: taggedURL, expectedIdentity: snapshot.identity)
            }
            controller.toggleFocusedSelection(nil)
            checks["toggleFocusedSelection"] = controller.table.selectedRowIndexes.isEmpty
            if let folderIndex = controller.model.items.firstIndex(where: \.isDirectory) {
                controller.table.selectRowIndexes([folderIndex], byExtendingSelection: false); controller.showInfo(nil)
                let folderInfoStart = ContinuousClock.now
                while controller.infoWindow?.qaLoaded != true && folderInfoStart.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
                let icon = NSImage(size: NSSize(width: 32, height: 32)); icon.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill(); icon.unlockFocus()
                controller.infoWindow?.qaApplyFolderIcon(icon); let customIconSaved = controller.infoWindow?.qaIconOperationSucceeded == true
                controller.infoWindow?.qaApplyFolderIcon(nil)
                checks["folderIconCustomization"] = customIconSaved && controller.infoWindow?.qaIconOperationSucceeded == true
                controller.infoWindow?.close(); window.makeKeyAndOrderFront(nil)
            } else { checks["folderIconCustomization"] = false }
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
            controller.searchWindow?.present(root: projectRoot, showHidden: false, onReveal: controller.searchResultRevealer())
            controller.searchWindow?.qaSearchSpotlight("SearchRouter", scope: .descendants)
            let spotlightHit = ContinuousClock.now
            while controller.searchWindow?.qaIsSearching == true && spotlightHit.duration(to: .now) < .seconds(15) { try await Task.sleep(for: .milliseconds(20)) }
            checks["spotlightContentHit"] = controller.searchWindow?.qaContainsResult(named: "LocalSearch.swift") == true
            let indexedFile = projectRoot.appendingPathComponent("Sources/FilesCore/LocalSearch.swift")
            if let panel = controller.searchWindow {
                panel.present(root: columnFolder, showHidden: false, onReveal: controller.searchResultRevealer())
                panel.qaSearchSpotlight("SearchRouter", scope: .indexedLocations)
                let indexedSearch = ContinuousClock.now
                while panel.qaIsSearching && elapsed(indexedSearch) < 15 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                checks["spotlightFindsResultOutsideCurrentFolder"] = !panel.qaIsSearching
                    && panel.qaContainsResult(at: indexedFile)
                checks["directSearchRestoresFolderScope"] = panel.qaReturnToFileNameSearch()
            }
            controller.searchWindow?.close(); window.makeKeyAndOrderFront(nil)
            controller.model.savePosition(selection: [searchHit.path], scrollOffset: 0)
            controller.render()
            controller.showQuickLook(nil); try await Task.sleep(for: .milliseconds(500))
            checks["quickLookWindow"] = controller.quickLook.qaVisible
            checks["quickLookItems"] = controller.quickLook.qaItemCount == 1
            checks["quickLookSelectedFile"] = controller.quickLook.qaCurrentURL?.standardizedFileURL.path == searchHit.path
            try capture("quick-look", view: controller.quickLook.qaContentView)
            QuickLookController().close()
            checks["quickLookIgnoresUnrelatedClose"] = controller.quickLook.qaVisible
                && controller.quickLook.qaCurrentURL?.standardizedFileURL.path == searchHit.path
            controller.quickLook.close(); window.makeKeyAndOrderFront(nil)
            checks["quickLookClearsItemsOnClose"] = controller.quickLook.qaItemCount == 0
                && !controller.quickLook.qaProvidesItems
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
            let placementSources = destination.appendingPathComponent("archive-placement-sources", isDirectory: true)
            let singleRoot = placementSources.appendingPathComponent("single-root", isDirectory: true)
            try fm.createDirectory(at: singleRoot, withIntermediateDirectories: true)
            try Data("single".utf8).write(to: singleRoot.appendingPathComponent("single.txt"))
            let secondSource = placementSources.appendingPathComponent("second.txt")
            try Data("second".utf8).write(to: secondSource)
            let singleArchive = destination.appendingPathComponent("single-tree.zip")
            let multipleArchive = destination.appendingPathComponent("multiple-roots.zip")
            try? fm.removeItem(at: singleArchive); try? fm.removeItem(at: multipleArchive)
            _ = try await ZipArchiveProvider().create(from: [singleRoot], at: singleArchive)
            _ = try await ZipArchiveProvider().create(from: [singleRoot, secondSource], at: multipleArchive)
            func verifyPlacement(_ archive: URL, placement: ArchiveExtractionPlacement, parentName: String, expected: String, checkName: String) async throws {
                let parent = destination.appendingPathComponent(parentName, isDirectory: true)
                try? fm.removeItem(at: parent)
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                ArchiveExtractionWindow.start(archives: [archive], parent: parent, placement: placement) {}
                let start = ContinuousClock.now
                while ArchiveExtractionWindow.qaLatest?.qaRunning == true && start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
                checks[checkName] = ArchiveExtractionWindow.qaLatest?.qaSucceeded == true && fm.fileExists(atPath: parent.appendingPathComponent(expected).path)
                if checkName == "archivePlacementSmartMany" { try capture("archive-placement", view: ArchiveExtractionWindow.qaLatest?.window?.contentView) }
                ArchiveExtractionWindow.qaLatest?.close(); window.makeKeyAndOrderFront(nil)
            }
            try await verifyPlacement(singleArchive, placement: .here, parentName: "placement-here", expected: "single-root/single.txt", checkName: "archivePlacementHere")
            try await verifyPlacement(singleArchive, placement: .smart, parentName: "placement-smart-one", expected: "single-root/single.txt", checkName: "archivePlacementSmartOne")
            try await verifyPlacement(multipleArchive, placement: .smart, parentName: "placement-smart-many", expected: "multiple-roots/second.txt", checkName: "archivePlacementSmartMany")
            try await verifyPlacement(singleArchive, placement: .childFolder, parentName: "placement-child", expected: "single-tree/single-root/single.txt", checkName: "archivePlacementChild")
            let formatFixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("Tests/FilesCoreTests/Fixtures", isDirectory: true)
            var extraFormatsPassed = true
            for (name, expectedName) in [("libarchive-empty.7z", "empty"), ("libarchive-noeof.rar", "test.txt")] {
                controller.presentArchive(formatFixtureRoot.appendingPathComponent(name))
                let formatLoad = ContinuousClock.now
                while controller.archiveWindow?.qaLoaded != true && formatLoad.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
                extraFormatsPassed = extraFormatsPassed && controller.archiveWindow?.qaEntryCount == 1
                let destination = destination.appendingPathComponent("extract-\(name)", isDirectory: true); try? fm.removeItem(at: destination); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                controller.archiveWindow?.qaExtract(to: destination)
                let formatExtract = ContinuousClock.now
                while controller.archiveWindow?.qaIsRunning == true && formatExtract.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
                extraFormatsPassed = extraFormatsPassed && controller.archiveWindow?.qaSucceeded == true && fm.fileExists(atPath: destination.appendingPathComponent(expectedName).path)
                controller.archiveWindow?.close(); window.makeKeyAndOrderFront(nil)
            }
            checks["sevenZipAndRarExtraction"] = extraFormatsPassed
            let createdArchive = destination.appendingPathComponent("created-by-ui.zip")
            try? fm.removeItem(at: createdArchive)
            ArchiveCreationWindow.start(sources: [fixture.appendingPathComponent("00000-한글-é-📁-long-file-name.txt")], destination: createdArchive) {}
            let archiveCreate = ContinuousClock.now
            while ArchiveCreationWindow.qaLatest?.qaRunning == true && archiveCreate.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            let createdEntries = try ZipArchiveProvider().entries(at: createdArchive)
            checks["archiveCreation"] = ArchiveCreationWindow.qaLatest?.qaSucceeded == true && createdEntries.count == 1
            try capture("archive-creation", view: ArchiveCreationWindow.qaLatest?.window?.contentView)
            ArchiveCreationWindow.qaLatest?.close(); window.makeKeyAndOrderFront(nil)
            let createdSevenZip = destination.appendingPathComponent("created-by-ui.7z"); try? fm.removeItem(at: createdSevenZip)
            ArchiveCreationWindow.start(sources: [fixture.appendingPathComponent("00000-한글-é-📁-long-file-name.txt")], destination: createdSevenZip) {}
            let sevenZipCreate = ContinuousClock.now
            while ArchiveCreationWindow.qaLatest?.qaRunning == true && sevenZipCreate.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            let createdSevenZipEntries = try ZipArchiveProvider().entries(at: createdSevenZip)
            checks["sevenZipCreation"] = ArchiveCreationWindow.qaLatest?.qaSucceeded == true && createdSevenZipEntries.count == 1
            ArchiveCreationWindow.qaLatest?.close(); window.makeKeyAndOrderFront(nil)
            let cancellationSource = destination.appendingPathComponent("archive-cancel-source.bin")
            try Data(repeating: 0x5a, count: 16 * 1024 * 1024).write(to: cancellationSource)
            let cancelledArchive = destination.appendingPathComponent("cancelled-by-ui.7z"); try? fm.removeItem(at: cancelledArchive)
            ArchiveCreationWindow.start(sources: [cancellationSource], destination: cancelledArchive) {}
            ArchiveCreationWindow.qaLatest?.qaCancel()
            let cancellationWait = ContinuousClock.now
            while ArchiveCreationWindow.qaLatest?.qaRunning == true && cancellationWait.duration(to: .now) < .seconds(2) { try await Task.sleep(for: .milliseconds(10)) }
            let cancellationDirectoryNames = try fm.contentsOfDirectory(atPath: destination.path)
            checks["archiveCreationCancellation"] = ArchiveCreationWindow.qaLatest?.qaRunning == false && !fm.fileExists(atPath: cancelledArchive.path) && cancellationDirectoryNames.allSatisfy { !$0.hasPrefix(".files-create-") }
            ArchiveCreationWindow.qaLatest?.close(); try? fm.removeItem(at: cancellationSource); window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            let metadataRefresh = ContinuousClock.now
            while controller.model.isLoading && metadataRefresh.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            controller.focusFiles(nil)
            checks["fileListFocus"] = window.firstResponder === controller.table
            controller.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            controller.invertSelection(nil)
            checks["invertSelectionCommand"] = controller.table.selectedRowIndexes.count == controller.model.items.count - 2
            controller.clearSelection(nil)
            checks["clearSelectionCommand"] = controller.table.selectedRowIndexes.isEmpty
            checks["selectionCommandsCatalog"] = [#selector(clearSelection(_:)), #selector(invertSelection(_:))].allSatisfy { action in
                paletteEntries.contains { $0.item.action == action }
            }
            controller.sortFilesFirst(nil)
            let filesFirst = controller.model.sortOrder.directoryPlacement == .filesFirst
                && controller.model.items.first?.isBrowsable == false
            controller.sortFoldersFirst(nil)
            let foldersFirst = controller.model.sortOrder.directoryPlacement == .foldersFirst
                && controller.model.items.first?.isBrowsable == true
            controller.sortMixed(nil); controller.sortBySize(nil); controller.sortDescending(nil)
            let descendingSize = controller.model.sortOrder.directoryPlacement == .mixed
                && controller.model.sortOrder.field == .size && !controller.model.sortOrder.ascending
            controller.toggleSortDirection(nil)
            checks["sortCommands"] = filesFirst && foldersFirst && descendingSize && controller.model.sortOrder.ascending
            controller.sortByCreated(nil)
            checks["createdDateSorting"] = controller.model.sortOrder.field == .created
            controller.sortByTag(nil); controller.groupByTag(nil)
            checks["finderTagSortAndGroupCommands"] = controller.model.sortOrder.field == .tag
                && controller.model.grouping.field == .tag
                && [#selector(sortByTag(_:)), #selector(groupByTag(_:))].allSatisfy { action in
                    paletteEntries.contains { $0.item.action == action }
                }
            let syncColumnID = NSUserInterfaceItemIdentifier("syncStatus")
            let syncColumn = controller.table.tableColumn(withIdentifier: syncColumnID)
            let syncColumnStartsHidden = syncColumn?.isHidden == true
            controller.toggleSyncStatusColumn(nil)
            controller.sortBySyncStatus(nil); controller.groupBySyncStatus(nil)
            let syncColumnVisible = syncColumn?.isHidden == false && syncColumn?.resizingMask.contains(.userResizingMask) == true
            checks["syncStatusColumnAndCommands"] = syncColumnStartsHidden && syncColumnVisible
                && controller.model.sortOrder.field == .syncStatus && controller.model.grouping.field == .syncStatus
                && controller.model.items.allSatisfy { $0.cloudState == nil }
                && [#selector(sortBySyncStatus(_:)), #selector(groupBySyncStatus(_:))].allSatisfy { action in
                    paletteEntries.contains { $0.item.action == action }
                }
            controller.toggleSyncStatusColumn(nil)
            controller.sortByPath(nil); controller.groupByFolderPath(nil)
            checks["folderPathSortAndGroupCommands"] = controller.model.sortOrder.field == .path
                && controller.model.grouping.field == .path
                && [#selector(sortByPath(_:)), #selector(groupByFolderPath(_:))].allSatisfy { action in
                    paletteEntries.contains { $0.item.action == action }
                }
            controller.groupByNone(nil)
            checks["sortCommandsCatalog"] = [#selector(sortByName(_:)), #selector(sortByCreated(_:)), #selector(sortByModified(_:)), #selector(sortBySize(_:)),
                #selector(sortByKind(_:)), #selector(sortAscending(_:)), #selector(sortDescending(_:)),
                #selector(toggleSortDirection(_:)), #selector(sortFoldersFirst(_:)), #selector(sortFilesFirst(_:)),
                #selector(sortMixed(_:))].allSatisfy { action in paletteEntries.contains { $0.item.action == action } }
            controller.sortByName(nil); controller.sortFoldersFirst(nil)
            try capture("files-top")
            let newItemCommand = paletteEntries.first { $0.item.action == #selector(addItem(_:)) }
            if let newItemCommand, controller.validateMenuItem(newItemCommand.item) {
                NSApp.sendAction(#selector(addItem(_:)), to: controller, from: newItemCommand.item)
            }
            func descendant<T: NSView>(of view: NSView?, matching type: T.Type) -> T? {
                guard let view else { return nil }
                if let match = view as? T { return match }
                return view.subviews.lazy.compactMap { descendant(of: $0, matching: type) }.first
            }
            if let chooser = window.attachedSheet,
               let types = descendant(of: chooser.contentView, matching: NSPopUpButton.self) {
                let matches = types.itemTitles == NewItemKind.allCases.map(\.title)
                types.selectItem(at: 1)
                window.endSheet(chooser, returnCode: .alertFirstButtonReturn)
                let newItemWait = ContinuousClock.now
                while (window.attachedSheet == nil || window.attachedSheet === chooser) && elapsed(newItemWait) < 3 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let fileSheet = window.attachedSheet
                let defaultName = L("새 문서.txt", "New Document.txt")
                func containsName(_ view: NSView) -> Bool {
                    (view as? NSTextField)?.stringValue == defaultName || view.subviews.contains(where: containsName)
                }
                checks["newItemChooserRoutesToFile"] = matches && fileSheet !== chooser
                    && fileSheet?.contentView.map(containsName) == true
                if let fileSheet { window.endSheet(fileSheet, returnCode: .alertSecondButtonReturn) }
            } else {
                checks["newItemChooserRoutesToFile"] = false
                if let chooser = window.attachedSheet { window.endSheet(chooser, returnCode: .alertSecondButtonReturn) }
            }
            if let folderRow = controller.detailRows.indices.first(where: {
                detailItem(at: $0, in: controller.detailRows)?.url.path == gridFolder.path
            }) {
                let menu = NSMenuItem(title: "", action: #selector(flattenFolder(_:)), keyEquivalent: "")
                controller.table.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
                let hiddenByDefault = !controller.validateMenuItem(menu)
                preferences.setShowFlattenOptions(true)
                let folderEnabled = controller.validateMenuItem(menu)
                controller.table.selectRowIndexes(IndexSet(integer: 9_999), byExtendingSelection: false)
                checks["flattenFolderMenu"] = hiddenByDefault && folderEnabled && !controller.validateMenuItem(menu)
                    && paletteEntries.contains { $0.item.action == #selector(flattenFolder(_:)) }
                preferences.setShowFlattenOptions(false)
            } else { checks["flattenFolderMenu"] = false }
            controller.table.selectRowIndexes(IndexSet(integer: 9_999), byExtendingSelection: false)
            let scrollStart = ContinuousClock.now
            controller.table.scrollRowToVisible(9_999)
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            metrics["scrollToLastRowDisplaySeconds"] = elapsed(scrollStart)
            checks["lastRowVisible"] = NSLocationInRange(9_999, controller.table.rows(in: controller.table.visibleRect))
            controller.savePosition()
            let row = 9_999
            let nameColumn = controller.table.column(withIdentifier: .init("name"))
            if nameColumn >= 0,
               let visibleCell = controller.table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) {
                controller.render()
                checks["unchangedDetailsKeepVisibleCell"] = controller.table
                    .view(atColumn: nameColumn, row: row, makeIfNecessary: false) === visibleCell
                    && controller.table.selectedRowIndexes == IndexSet(integer: row)
            } else {
                checks["unchangedDetailsKeepVisibleCell"] = false
            }
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
            controller.cutFilesToClipboard()
            checks["cutClipboardCommand"] = controller.clipboardIsCut && controller.canPasteFiles
            checks["clipboardTransferCommandsCatalog"] = [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                #selector(NSText.paste(_:))].allSatisfy { action in
                    paletteEntries.contains { $0.item.action == action }
                }
            controller.copyFilesToClipboard()
            checks["copyClipboardClearsCutIntent"] = !controller.clipboardIsCut && controller.canPasteFiles
            checks["pasteVariantCommands"] = controller.canPasteToSelection
                && [#selector(pasteFilesToSelection(_:)), #selector(pasteFilesAsSymbolicLinks(_:))].allSatisfy { action in
                    paletteEntries.contains { $0.item.action == action }
                }
            controller.model.setGrouping(.init(field: .name)); controller.render()
            checks["gridGroupingSections"] = controller.gridView.qaSectionCount > 1
                && !controller.gridView.qaSectionTitles.contains("")
                && controller.gridView.selectedItems.map(\.id) == [gridFolder.path]
            controller.model.setGrouping(FileGroupOptions()); controller.render()
            preferences.setViewSize(.large)
            checks["largeViewSizeApplied"] = controller.gridView.qaItemSize == NSSize(width: 142, height: 124)
                && controller.listView.qaRowHeight == 38
            preferences.setViewSize(.medium)
            controller.useCardsLayout(nil)
            controller.decreaseViewSize(nil)
            let decreasedViewSize = preferences.viewSize == .small
            controller.increaseViewSize(nil); controller.increaseViewSize(nil)
            checks["layoutSizeCommands"] = controller.model.viewMode == .grid
                && decreasedViewSize && preferences.viewSize == .large
            checks["layoutSizeCommandsCatalog"] = [#selector(useCardsLayout(_:)), #selector(decreaseViewSize(_:)),
                #selector(increaseViewSize(_:))].allSatisfy { action in
                    paletteEntries.contains { $0.item.action == action }
                }
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
            controller.model.setGrouping(.init(field: .kind)); controller.render()
            checks["listGroupingRows"] = controller.listView.qaGroupTitles.count > 1
                && !controller.listView.qaGroupTitles.contains("")
                && controller.listView.selectedItems.map(\.id) == [gridFolder.path]
            controller.model.setGrouping(FileGroupOptions()); controller.render()
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
            preferences.setDoubleClickToGoUp(false); controller.handleBackgroundDoubleClick()
            let disabledBackgroundStayed = controller.model.location == columnFolder.standardizedFileURL
            preferences.setDoubleClickToGoUp(true); controller.handleBackgroundDoubleClick()
            let backgroundUpStart = ContinuousClock.now
            while controller.model.isLoading && backgroundUpStart.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            checks["doubleClickBackgroundGoUp"] = disabledBackgroundStayed && controller.model.location == gridFolder.standardizedFileURL
            controller.navigate(columnFolder)
            let adaptiveReloadStart = ContinuousClock.now
            while controller.model.isLoading && adaptiveReloadStart.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
            controller.model.setViewMode(.adaptive); controller.render()
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            checks["adaptiveMediaUsesGrid"] = controller.model.viewMode == .adaptive
                && controller.primaryRenderedViewMode == .grid && !controller.gridView.isHidden
            controller.model.setViewMode(.details); controller.render()
            checks["adaptiveManualChoiceWins"] = controller.model.viewMode == .details
                && controller.primaryRenderedViewMode == .details && !controller.scroll.isHidden
            controller.goUp(nil)
            let revealParentStart = ContinuousClock.now
            while controller.model.isLoading && revealParentStart.duration(to: .now) < .seconds(10) {
                try await Task.sleep(for: .milliseconds(10))
            }
            checks["revealPreviousFolderOnUp"] = controller.model.location == gridFolder.standardizedFileURL
                && controller.model.history.current.selection == [columnFolder.path]
                && controller.table.selectedRowIndexes.count == 1
            preferences.setFolderViewPreference(FolderViewPreference(mode: .grid, size: .large), for: columnFolder)
            controller.navigate(fixture); controller.navigate(columnFolder); controller.render()
            checks["folderViewApplied"] = controller.model.viewMode == .grid && controller.effectiveViewSize == .large
            controller.toggleFolderLayoutSynchronization(nil)
            controller.navigate(gridFolder)
            controller.splitVertically(nil)
            controller.secondaryPane?.setViewMode(.list)
            controller.sortBySize(nil)
            controller.groupByName(nil)
            controller.decreaseViewSize(nil)
            checks["sharedFolderLayoutAcrossPanes"] = preferences.syncFolderLayouts
                && controller.model.viewMode == .list && controller.secondaryPane?.model.viewMode == .list
                && controller.model.sortOrder.field == .size && controller.secondaryPane?.model.sortOrder.field == .size
                && controller.model.grouping.field == .name && controller.secondaryPane?.model.grouping.field == .name
                && controller.effectiveViewSize == .medium
            controller.closeSecondaryPane(nil)
            controller.navigate(columnFolder)
            controller.toggleFolderLayoutSynchronization(nil)
            checks["sharedFolderLayoutRestoresSavedView"] = !preferences.syncFolderLayouts
                && controller.model.viewMode == .grid && controller.effectiveViewSize == .large
            controller.model.sort(SortOrder())
            controller.model.setGrouping(FileGroupOptions())
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
            let idleImage = cancellable.refreshButton.image
            cancellable.navigate(denied)
            let loadingImage = cancellable.refreshButton.image
            cancellable.render()
            checks["loadingButtonReusesSymbol"] = idleImage != nil && loadingImage != nil
                && idleImage !== loadingImage && cancellable.refreshButton.image === loadingImage
            let hadStopLabel = cancellable.refreshButton.accessibilityLabel() == L("읽기 중단", "Stop Loading")
            cancellable.refreshButton.performClick(nil)
            checks["stopButtonCancels"] = hadStopLabel && cancellable.model.wasCancelled && !cancellable.model.isLoading
                && cancellable.refreshButton.accessibilityLabel() == L("새로고침", "Refresh")
            checks["loadingButtonRestoresRefreshSymbol"] = cancellable.refreshButton.image === idleImage
            checks["cancelledRecoveryVisible"] = !cancellable.recoveryActions.isHidden
            try capture("cancelled", view: cancellable.window?.contentView)
            try await Task.sleep(for: .milliseconds(400))
            cancellable.requestWatcherRefresh(for: denied)
            checks["cancelledReadStaysStopped"] = cancellable.model.wasCancelled && !cancellable.model.isLoading
                && cancellable.model.items.isEmpty && !cancellable.message.isHidden
            cancellable.retryButton.performClick(nil)
            let cancelledRetryStart = ContinuousClock.now
            while cancellable.model.isLoading && elapsed(cancelledRetryStart) < 3 {
                try await Task.sleep(for: .milliseconds(10))
            }
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
        let suite = "FilesMac.M2UIVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            // Use the same path spelling as the model when the fixture is under /private/tmp.
            let fixture = root.standardizedFileURL
            let source = fixture.appendingPathComponent("source", isDirectory: true)
            let target = fixture.appendingPathComponent("target", isDirectory: true)
            let journals = fixture.appendingPathComponent("journals", isDirectory: true)
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
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let controller = BrowserWindow(preferences: preferences, restoresFrame: false,
                                           undoJournalDirectory: journals, filePasteboard: pasteboard)
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
            func capture(_ name: String, view: NSView = content) throws {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
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
            checks["secondaryNavigationAccessibilityLabels"] = secondary.qaNavigationAccessibility()
            let initialNavigation = secondary.qaNavigationEnabled
            checks["secondaryHiddenAccessibilityPress"] = secondary.qaPressHiddenAccessibility()
            try await controller.waitForFolderQA { !secondary.model.isLoading }
            guard let secondaryMerge = secondary.model.items.first(where: { $0.url.standardizedFileURL == mergeTarget.standardizedFileURL }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            secondary.model.savePosition(selection: [secondaryMerge.id], scrollOffset: 0)
            secondary.model.setViewMode(.grid)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            checks["secondaryGridSelection"] = secondary.selectedItems.map(\.id) == [secondaryMerge.id]
            controller.model.setViewMode(.grid)
            let primaryGridIntegration = (controller.gridView.contextMenu === controller.table.menu,
                                          controller.gridView.qaHasDropHandler,
                                          controller.gridView.qaPasteboardURL(at: 0))
            let secondaryGridIntegration = secondary.qaGridIntegration()
            checks["gridContextCommands"] = primaryGridIntegration.0 && secondaryGridIntegration.menu
            let contextActions = Set(controller.table.menu?.items.compactMap(\.action) ?? [])
            checks["systemOpenCommands"] = [#selector(revealSelection(_:)), #selector(shareSelection(_:)), #selector(openInTerminal(_:)), #selector(openWithApplication(_:))].allSatisfy(contextActions.contains)
            checks["archiveContextCommands"] = [#selector(openArchive(_:)), #selector(createArchive(_:))].allSatisfy(contextActions.contains)
            checks["cloudContextCommands"] = [#selector(downloadCloudSelection(_:)), #selector(evictCloudSelection(_:))].allSatisfy(contextActions.contains)
            let ordinaryProviderCapabilities = CloudLocationProvider().capabilities(for: target)
            checks["cloudCommandsConservative"] = !ordinaryProviderCapabilities.downloadNow
                && !ordinaryProviderCapabilities.evictLocalCopy
                && !ordinaryProviderCapabilities.keepDownloaded
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
            checks["secondaryNavigationAccessibilityState"] = initialNavigation == [false, false, true]
                && secondary.qaNavigationEnabled == [false, true, true]
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
            controller.model.setViewMode(.columns)
            let primaryColumnIntegration = (controller.columnView.qaHasDropHandler, controller.columnView.qaPasteboardURL())
            let secondaryColumnIntegration = secondary.qaColumnIntegration
            checks["columnContextCommands"] = primaryColumnIntegration.0 && secondaryColumnIntegration.ready
            checks["columnDragSources"] = primaryColumnIntegration.1 != nil && secondaryColumnIntegration.source != nil
            controller.model.setViewMode(.details)
            let newFile = target.appendingPathComponent("while-hidden.txt")
            try Data().write(to: newFile)
            controller.model.reload(); try await settle()
            controller.model.savePosition(selection: [newFile.path], scrollOffset: 0)
            controller.model.setViewMode(.grid)
            checks["gridRefreshesOnActivation"] = controller.gridView.selectedItems.map(\.id) == [newFile.path]
            controller.model.setViewMode(.details)
            try fm.removeItem(at: newFile)
            controller.model.reload(); try await settle()
            secondary.model.setViewMode(.adaptive)
            let adaptiveStart = ContinuousClock.now
            while secondary.model.isLoading && elapsed(adaptiveStart) < 10 {
                try await Task.sleep(for: .milliseconds(10))
            }
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
            let unifiedUndo = NSMenuItem(title: "", action: #selector(undoLastFileTransfer(_:)), keyEquivalent: "z")
            checks["unifiedUndoRoutesToCopy"] = controller.validateMenuItem(unifiedUndo)
            controller.undoLastFileTransfer(unifiedUndo)
            guard let confirmation = window.attachedSheet else { throw CocoaError(.validationMissingMandatoryProperty) }
            window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
            let undoWait = ContinuousClock.now
            while (BrowserWindow.entryOperationRunning || window.attachedSheet == nil || window.attachedSheet === confirmation)
                && elapsed(undoWait) < 5 {
                try await Task.sleep(for: .milliseconds(20))
            }
            let resultSheet = window.attachedSheet
            checks["undoCompleted"] = !BrowserWindow.entryOperationRunning && resultSheet != nil && resultSheet !== confirmation
                && CopyEngine.latestUndoCopy(journalDirectory: journals) == nil
            if let resultSheet { window.endSheet(resultSheet) }
            controller.closeSecondaryPane(nil); controller.refresh(nil); try await settle()
            checks["undoUpdatesList"] = !controller.model.items.contains { $0.name == "new.txt" }
            checks["undoPreservesExisting"] = fm.fileExists(atPath: mergeTarget.appendingPathComponent("keep.txt").path)
                && !fm.fileExists(atPath: mergeTarget.appendingPathComponent("nested.txt").path)
            try capture("after-undo")
            let redoSource = source.appendingPathComponent("redo-move.txt")
            let redoTarget = target.appendingPathComponent("redo-move.txt")
            try Data("redo".utf8).write(to: redoSource)
            _ = try await EntryOperations.move([redoSource], to: target, journalDirectory: journals)
            func confirmAndDismissResult(_ action: () -> Void) async throws -> Bool {
                action()
                guard let confirmation = window.attachedSheet else { return false }
                window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
                let wait = ContinuousClock.now
                while (BrowserWindow.entryOperationRunning || window.attachedSheet == nil || window.attachedSheet === confirmation)
                    && elapsed(wait) < 5 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let result = window.attachedSheet, result !== confirmation else { return false }
                window.endSheet(result)
                let dismissWait = ContinuousClock.now
                while window.attachedSheet != nil && elapsed(dismissWait) < 3 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                return window.attachedSheet == nil
            }
            let movedBack = try await confirmAndDismissResult { controller.undoLastFileTransfer(unifiedUndo) }
            let replayAvailable = movedBack && fm.fileExists(atPath: redoSource.path) && controller.availableMoveRedo != nil
            let replayed = try await confirmAndDismissResult { controller.redoLastMove(nil) }
            checks["redoMoveCommand"] = replayAvailable && replayed && !fm.fileExists(atPath: redoSource.path)
                && (try? Data(contentsOf: redoTarget)) == Data("redo".utf8)
                && controller.availableMoveRedo == nil
            let template = source.appendingPathComponent("new.txt")
            controller.promptForTemplateName(template, in: target, model: controller.model)
            if let templateSheet = window.attachedSheet,
               let field = templateSheet.initialFirstResponder as? NSTextField {
                field.stringValue = "from-template.txt"
                window.endSheet(templateSheet, returnCode: .alertFirstButtonReturn)
                let templateWait = ContinuousClock.now
                let output = target.appendingPathComponent("from-template.txt")
                while (!fm.fileExists(atPath: output.path) || BrowserWindow.entryOperationRunning)
                    && elapsed(templateWait) < 5 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                checks["templateNameAndContents"] = (try? Data(contentsOf: output)) == Data("new".utf8)
                    && (try? Data(contentsOf: template)) == Data("new".utf8)
            } else {
                checks["templateNameAndContents"] = false
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            }
            let existing = target.appendingPathComponent("conflict.txt")
            let copySource = source.appendingPathComponent("conflict.txt")
            func keyboardEvent(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)
            }
            controller.navigate(source)
            try await settle()
            window.makeKeyAndOrderFront(nil)
            controller.focusFiles(nil)
            let conflictRow = controller.detailRows.indices.first { detailItem(at: $0, in: controller.detailRows)?.id == copySource.path }
            if let conflictRow, let down = keyboardEvent("\u{f701}", code: 125) {
                for _ in 0...conflictRow { window.sendEvent(down) }
            }
            let sourceSelected = controller.activeSelectedItems.map(\.id) == [copySource.path]
            let copied = NSApp.sendAction(#selector(NSText.copy(_:)), to: window.firstResponder, from: nil)
                && controller.clipboardFiles.map(\.path) == [copySource.path]
            let openedHome = NSApp.sendAction(#selector(goHome(_:)), to: controller, from: nil)
                && controller.model.location == nil
            if let down = keyboardEvent("\u{f701}", code: 125), let open = keyboardEvent("\r", code: 36) {
                window.sendEvent(down)
                window.sendEvent(open)
            }
            try await settle()
            let pasted = NSApp.sendAction(#selector(NSText.paste(_:)), to: window.firstResponder, from: nil)
                && window.attachedSheet != nil
            diagnostics["keyboardCopyRoute"] = [
                "sourceSelected": sourceSelected, "copied": copied,
                "openedHome": openedHome, "openedDestination": controller.model.location == target,
                "handledPaste": pasted,
            ]
            checks["copyResponderWorkflowThroughHome"] = sourceSelected && copied && openedHome && pasted
                && controller.model.location == target && controller.clipboardFiles.map(\.path) == [copySource.path]
            func hasConflictComparison(in view: NSView, source: URL, existing: URL) -> Bool {
                if let text = view as? NSTextView,
                   text.accessibilityLabel() == L("원본과 기존 대상 비교", "Source and Existing Destination Comparison") {
                    return text.string.contains(source.path) && text.string.contains(existing.path)
                        && text.string.contains(formatByteCount(6, unit: preferences.sizeUnit))
                        && text.string.components(separatedBy: .newlines).contains("source")
                        && text.string.components(separatedBy: .newlines).contains("target")
                        && !text.isEditable
                }
                return view.subviews.contains { hasConflictComparison(in: $0, source: source, existing: existing) }
            }
            func waitForConflictComparison(_ source: URL) async -> Bool {
                let start = ContinuousClock.now
                while elapsed(start) < 3, let view = window.attachedSheet?.contentView {
                    if hasConflictComparison(in: view, source: source, existing: existing) { return true }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return false
            }
            checks["copyConflictComparison"] = await waitForConflictComparison(copySource)
            if let sheet = window.attachedSheet,
               let skip = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                   context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) {
                checks["copyConflictKeyboardShortcut"] = sheet.performKeyEquivalent(with: skip)
                let start = ContinuousClock.now
                var copy: CopyWindow?
                repeat {
                    try await Task.sleep(for: .milliseconds(20))
                    copy = NSApp.windows.compactMap { $0.windowController as? CopyWindow }.first
                } while (copy == nil || CopyWindow.isRunning) && elapsed(start) < 5
                checks["copyConflictAccessibleResult"] = copy?.qaAccessibleResult == true
                    && (try? Data(contentsOf: copySource)) == Data("source".utf8)
                    && (try? Data(contentsOf: existing)) == Data("target".utf8)
                    && !fm.fileExists(atPath: target.appendingPathComponent("conflict (2).txt").path)
                if let resultWindow = copy?.window,
                   let close = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: resultWindow.windowNumber,
                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    checks["copyResultKeyboardClose"] = resultWindow.performKeyEquivalent(with: close) && !resultWindow.isVisible
                } else { checks["copyResultKeyboardClose"] = false }
            } else { checks["copyConflictKeyboardShortcut"] = false }
            let moveSource = source.appendingPathComponent("conflict.txt")
            controller.prepareMove(sources: [moveSource], destination: target)
            checks["moveConflictComparison"] = await waitForConflictComparison(moveSource)
            if let sheet = window.attachedSheet,
               let skip = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                   context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) {
                checks["moveConflictKeyboardShortcut"] = sheet.performKeyEquivalent(with: skip)
                let start = ContinuousClock.now
                var move: MoveWindow?
                repeat {
                    try await Task.sleep(for: .milliseconds(20))
                    move = NSApp.windows.compactMap { $0.windowController as? MoveWindow }.first
                } while (move == nil || MoveWindow.isRunning) && elapsed(start) < 5
                checks["moveConflictAccessibleResult"] = move?.qaAccessibleConflict == true
                    && (try? Data(contentsOf: moveSource)) == Data("source".utf8)
                    && (try? Data(contentsOf: existing)) == Data("target".utf8)
                if let resultWindow = move?.window,
                   let close = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: resultWindow.windowNumber,
                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    checks["moveResultKeyboardClose"] = resultWindow.performKeyEquivalent(with: close) && !resultWindow.isVisible
                } else { checks["moveResultKeyboardClose"] = false }
            } else { checks["moveConflictKeyboardShortcut"] = false }
            let imageFile = source.appendingPathComponent("preview.png")
            let pdfFile = source.appendingPathComponent("preview.pdf")
            let canvas = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            for (url, color) in [(imageFile, NSColor.red), (target.appendingPathComponent(imageFile.lastPathComponent), .green)] {
                canvas.setFillColor(color.cgColor)
                canvas.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
                let png = NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!
                try png.write(to: url)
            }
            for (url, color) in [(pdfFile, NSColor.blue), (target.appendingPathComponent(pdfFile.lastPathComponent), .yellow)] {
                var page = CGRect(x: 0, y: 0, width: 80, height: 60)
                let pdf = CGContext(url as CFURL, mediaBox: &page, nil)!
                pdf.beginPDFPage(nil)
                pdf.setFillColor(color.cgColor)
                pdf.fill(page)
                pdf.endPDFPage()
                pdf.closePDF()
            }
            let damagedPDF = source.appendingPathComponent("damaged.pdf")
            let damagedImage = source.appendingPathComponent("damaged.png")
            let linkedImage = source.appendingPathComponent("linked.png")
            let lockedPDF = source.appendingPathComponent("locked.pdf")
            let oversizedImage = source.appendingPathComponent("oversized.png")
            let damagedContent = Data("qa-damaged-document".utf8)
            for file in [damagedPDF, damagedImage] {
                try damagedContent.write(to: file)
                try damagedContent.write(to: target.appendingPathComponent(file.lastPathComponent))
            }
            try fm.createSymbolicLink(at: linkedImage, withDestinationURL: imageFile)
            try fm.createSymbolicLink(at: target.appendingPathComponent(linkedImage.lastPathComponent),
                                      withDestinationURL: target.appendingPathComponent(imageFile.lastPathComponent))
            var lockedPage = CGRect(x: 0, y: 0, width: 80, height: 60)
            guard let lockedContext = CGContext(lockedPDF as CFURL, mediaBox: &lockedPage, [
                kCGPDFContextOwnerPassword: "fixture-owner",
                kCGPDFContextUserPassword: "fixture-password"
            ] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
            lockedContext.beginPDFPage(nil)
            lockedContext.fill(lockedPage)
            lockedContext.endPDFPage()
            lockedContext.closePDF()
            guard let lockedDocument = CGPDFDocument(lockedPDF as CFURL), lockedDocument.isEncrypted,
                  !lockedDocument.isUnlocked else { throw CocoaError(.fileReadCorruptFile) }
            try fm.copyItem(at: lockedPDF, to: target.appendingPathComponent(lockedPDF.lastPathComponent))
            try fm.copyItem(at: imageFile, to: oversizedImage)
            let oversizedHandle = try FileHandle(forWritingTo: oversizedImage)
            try oversizedHandle.truncate(atOffset: 8 * 1024 * 1024 + 1)
            try oversizedHandle.close()
            try fm.copyItem(at: oversizedImage, to: target.appendingPathComponent(oversizedImage.lastPathComponent))
            controller.prepareCopy(sources: [damagedPDF, damagedImage, linkedImage, lockedPDF, oversizedImage, imageFile, pdfFile],
                                   destination: target)
            if let sheet = window.attachedSheet, let sheetView = sheet.contentView {
                func attachmentColors(in view: NSView) -> [String] {
                    if let storage = (view as? NSTextView)?.textStorage {
                        var colors: [String] = []
                        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                            guard let attachment = value as? NSTextAttachment,
                                  let cell = attachment.attachmentCell as? NSTextAttachmentCell,
                                  let image = cell.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                            let pixels = NSBitmapImageRep(cgImage: image)
                            guard let color = pixels.colorAt(x: image.width / 2, y: image.height / 2)?
                                .usingColorSpace(.deviceRGB) else { return }
                            let (red, green, blue) = (color.redComponent, color.greenComponent, color.blueComponent)
                            switch (red > 0.7, green > 0.7, blue > 0.7) {
                            case (true, false, false): colors.append("red")
                            case (false, true, false): colors.append("green")
                            case (false, false, true): colors.append("blue")
                            case (true, true, false): colors.append("yellow")
                            default: colors.append("unknown")
                            }
                        }
                        return colors
                    }
                    return view.subviews.flatMap { attachmentColors(in: $0) }
                }
                let start = ContinuousClock.now
                var colors = attachmentColors(in: sheetView)
                while colors.count < 4 && elapsed(start) < 4 {
                    try await Task.sleep(for: .milliseconds(20))
                    colors = attachmentColors(in: sheetView)
                }
                diagnostics["conflictThumbnailColors"] = colors
                checks["conflictImageAndPDFThumbnails"] = colors == ["red", "green", "blue", "yellow"]
                func comparisonScroll(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
                    return view.subviews.lazy.compactMap(comparisonScroll).first
                }
                if let scroll = comparisonScroll(in: sheetView), let text = scroll.documentView as? NSTextView,
                   let layout = text.layoutManager, let container = text.textContainer,
                   let storage = text.textStorage {
                    let unavailable = L("미리보기 없음", "Preview unavailable")
                    let lines = text.string.components(separatedBy: .newlines)
                    for (file, key) in [(damagedPDF, "DamagedPDF"), (damagedImage, "DamagedImage"),
                                        (linkedImage, "SymbolicLink"), (lockedPDF, "LockedPDF"),
                                        (oversizedImage, "OversizedImage")] {
                        let paths = [file.path, target.appendingPathComponent(file.lastPathComponent).path]
                        checks["conflictPreviewRejects" + key] = paths.allSatisfy { path in
                            guard let index = lines.firstIndex(of: path), lines.indices.contains(index + 2) else { return false }
                            return lines[index + 2] == unavailable
                        }
                    }
                    var lastAttachment = NSRange(location: NSNotFound, length: 0)
                    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { attachment, range, _ in
                        if attachment != nil { lastAttachment = range }
                    }
                    text.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    try capture("conflict-preview-top", view: scroll)
                    if lastAttachment.location != NSNotFound {
                        text.scrollRangeToVisible(lastAttachment)
                        let glyphs = layout.glyphRange(forCharacterRange: lastAttachment, actualCharacterRange: nil)
                        let origin = text.textContainerOrigin
                        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                            .offsetBy(dx: origin.x, dy: origin.y)
                        checks["conflictPreviewScrolls"] = scroll.contentView.bounds.minY > 0
                            && bounds.height > 0 && text.visibleRect.contains(bounds)
                        try capture("conflict-preview-bottom", view: scroll)
                    } else { checks["conflictPreviewScrolls"] = false }
                } else { checks["conflictPreviewScrolls"] = false }
                window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
            } else { checks["conflictImageAndPDFThumbnails"] = false }
            let iconCache = FileIconCache()
            var resolutions = 0
            let lookup: (String) -> UTType? = { _ in resolutions += 1; return .plainText }
            let icon = iconCache.genericIcon(forExtension: "txt", resolve: lookup)
            let reused = iconCache.genericIcon(forExtension: "txt", resolve: lookup) === icon
            iconCache.removeAll()
            _ = iconCache.genericIcon(forExtension: "txt", resolve: lookup)
            checks["genericIconExtensionCache"] = reused && resolutions == 2
            let cancelSamples = CopyWindow.qaCancellationFeedback(
                sources: [source.appendingPathComponent("conflict.txt")], destination: target)
            checks["copyCancellationFeedback"] = cancelSamples?.count == 20
            diagnostics["copyCancellationFeedbackSeconds"] = cancelSamples
            let cancellationSource = source.appendingPathComponent("cancel-verify.bin")
            try Data(repeating: 0x5A, count: 8 * 1024 * 1024).write(to: cancellationSource)
            diagnostics["copyCancellationDuringVerification"] = try await CopyWindow.qaCancellationDuringVerification(
                source: cancellationSource, destination: target, journals: journals)
            checks["copyCancellationDuringVerification"] = true
            let recoveryFolder = root.appendingPathComponent("recoverable", isDirectory: true)
            try fm.createDirectory(at: recoveryFolder, withIntermediateDirectories: false)
            controller.navigate(recoveryFolder)
            try await controller.waitForFolderQA { !controller.model.isLoading && controller.watcherStatus == .active }
            let previousWatcher = try { () throws -> DirectoryWatcher in
                guard let watcher = controller.watcher else { throw CocoaError(.validationMissingMandatoryProperty) }
                return watcher
            }()
            try fm.removeItem(at: recoveryFolder)
            try await controller.waitForFolderQA { controller.model.failure == .notFound }
            try fm.createDirectory(at: recoveryFolder, withIntermediateDirectories: false)
            try Data().write(to: recoveryFolder.appendingPathComponent("recovered.txt"))
            controller.retryButton.performClick(nil)
            try await controller.waitForFolderQA {
                !controller.model.isLoading && controller.watcherStatus == .active
                    && controller.watcher !== previousWatcher && controller.model.items.map(\.name) == ["recovered.txt"]
            }
            try Data().write(to: recoveryFolder.appendingPathComponent("noticed.txt"))
            try await controller.waitForFolderQA { controller.model.items.contains { $0.name == "noticed.txt" } }
            checks["folderReplacementRestoresAutomaticRefresh"] = controller.recoveryActions.isHidden
            await controller.volumeTask?.value
            let shareName = "QA Network Share"
            let network = MountedVolume(url: recoveryFolder, name: shareName, isLocal: false)
            let local = MountedVolume(url: target, name: "QA Local Disk", isLocal: true)
            controller.volumes = [network, local]
            controller.invalidateHome()
            controller.goHome(nil)
            let networkButton = controller.homeView.arrangedSubviews.compactMap { $0 as? LocationButton }
                .first { $0.url == network.url }
            let homeCards = controller.homeView.arrangedSubviews.compactMap { $0 as? VolumeCardView }
                .flatMap { $0.arrangedSubviews.compactMap { $0 as? LocationButton } }
            checks["homeNetworkLocationOpensMountedPath"] = networkButton?.accessibilityLabel() == shareName
                && homeCards.contains { $0.url == local.url } && !homeCards.contains { $0.url == network.url }
            preferences.setShowSidebar(false)
            controller.goHome(nil)
            func sendHomeKey(_ keyCode: UInt16, characters: String) {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                else { return }
                window.sendEvent(event)
            }
            let startsOnHome = window.firstResponder === controller.homeKeyboardButtons.first
                && controller.sidebarContainer.isHidden
            sendHomeKey(125, characters: "\u{f701}")
            let reachesFavorite = (window.firstResponder as? LocationButton)?.url == target
            sendHomeKey(125, characters: "\u{f701}")
            let drivesAction = #selector(toggleHomeVolumesExpanded(_:))
            let reachesDrives = (window.firstResponder as? NSButton)?.action == drivesAction
            sendHomeKey(36, characters: "\r")
            let retainsFocus = (window.firstResponder as? NSButton)?.action == drivesAction
                && !preferences.homeVolumesExpanded
            sendHomeKey(49, characters: " ")
            sendHomeKey(125, characters: "\u{f701}")
            let reachesLocal = (window.firstResponder as? LocationButton)?.title == local.name
            sendHomeKey(125, characters: "\u{f701}")
            let reachesNetwork = (window.firstResponder as? LocationButton)?.title == shareName
            sendHomeKey(126, characters: "\u{f700}")
            let returnsToLocal = (window.firstResponder as? LocationButton)?.title == local.name
            sendHomeKey(125, characters: "\u{f701}")
            sendHomeKey(36, characters: "\r")
            checks["homeKeyboardReachesNetworkAndFocusesFiles"] = startsOnHome && reachesFavorite && reachesDrives
                && retainsFocus && reachesLocal && reachesNetwork && returnsToLocal
                && window.firstResponder === controller.table
            checks["homeNetworkLocationOpensMountedPath"] = checks["homeNetworkLocationOpensMountedPath"] == true
                && controller.model.location == network.url
            controller.goHome(nil)
            let homeContent = controller.homeView.arrangedSubviews.first
            let currentNetworkButton = controller.homeView.arrangedSubviews.compactMap { $0 as? LocationButton }
                .first { $0.url == network.url && $0.title == shareName }
            controller.render()
            checks["homeReusesUnchangedViews"] = homeContent != nil
                && controller.homeView.arrangedSubviews.first === homeContent
            preferences.clearRecent()
            preferences.recordVisit(recoveryFolder)
            let recentPath = recoveryFolder.standardizedFileURL.path
            let recentButton = controller.homeRecentView.arrangedSubviews.compactMap { $0 as? LocationButton }
                .first { $0.url?.path == recentPath && $0.title == recentPath }
            if let recentButton { controller.focusHomeButton(recentButton) }
            preferences.recordVisit(source)
            let recentButtons = controller.homeRecentView.arrangedSubviews.compactMap { $0 as? LocationButton }
            let recentOrderUpdated = recentButtons.compactMap { $0.url?.path } == [source.standardizedFileURL.path, recentPath]
            let otherHomeViewsReused = controller.homeView.arrangedSubviews.first === homeContent
                && controller.homeView.arrangedSubviews.contains { $0 === currentNetworkButton }
            let recentFocusRestored = (window.firstResponder as? LocationButton)?.url?.path == recentPath
            diagnostics["homeRecentRefresh"] = [recentOrderUpdated, otherHomeViewsReused, recentFocusRestored]
            checks["homeRecentRefresh"] = recentOrderUpdated && otherHomeViewsReused && recentFocusRestored
            func showsHomeVolumeEntries() -> Bool {
                controller.homeView.arrangedSubviews.contains {
                    ($0 as? LocationButton)?.title == shareName || $0 is VolumeCardView
                }
            }
            preferences.setHomeSectionExpanded(.volumes, expanded: false)
            let hidesWhenCollapsed = !showsHomeVolumeEntries()
            preferences.setHomeSectionExpanded(.volumes, expanded: true)
            let restoresWhenExpanded = showsHomeVolumeEntries()
            preferences.setSection(.volumes, visible: false)
            checks["homeVolumesSettingHidesNetworkLocations"] = hidesWhenCollapsed
                && restoresWhenExpanded && !showsHomeVolumeEntries()
            let palette = controller.commandPalette
            func pathEditorIsFocused() -> Bool {
                guard let editor = controller.pathField.currentEditor() else { return false }
                return window.firstResponder === editor
            }
            func sendPaletteKey(_ keyCode: UInt16, characters: String) {
                guard let panel = palette.window, let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
                ) else { return }
                panel.sendEvent(event)
            }
            controller.focusPath(nil)
            controller.showCommandPalette(nil)
            try await Task.sleep(for: .milliseconds(50))
            palette.qaSetQuery(L("이름 변경…", "Rename…"))
            sendPaletteKey(36, characters: "\r")
            checks["paletteRejectsUnavailableCommand"] = palette.window?.isVisible == true
                && palette.qaStatus == L("현재 문맥에서 사용할 수 없습니다", "Unavailable in the current context")
            sendPaletteKey(53, characters: "\u{1b}")
            try await Task.sleep(for: .milliseconds(100))
            checks["paletteEscapeRestoresPathEditor"] = palette.window?.isVisible == false && pathEditorIsFocused()
            controller.navigate(recoveryFolder)
            try await settle()
            controller.focusFiles(nil)
            controller.showCommandPalette(nil)
            try await Task.sleep(for: .milliseconds(50))
            palette.qaSetQuery(L("경로 입력", "Go to Path"))
            sendPaletteKey(36, characters: "\r")
            try await Task.sleep(for: .milliseconds(100))
            checks["paletteReturnExecutesInBrowser"] = palette.window?.isVisible == false && pathEditorIsFocused()
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
    private func waitForFolderQA(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.validationMissingMandatoryProperty) }
            try await Task.sleep(for: .milliseconds(20))
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

#if RELEASE_PERFORMANCE_QA
@MainActor
private final class ReleaseScrollDriver: NSObject {
    private var displayLink: CADisplayLink?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var step: ((Int) -> Void)?
    private var tick = 0

    func run(in view: NSView, step: @escaping (Int) -> Void) async -> Bool {
        self.step = step
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            self?.finish(false)
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = view.displayLink(target: self, selector: #selector(advance(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func advance(_ link: CADisplayLink) {
        tick += 1
        if tick <= 360 { step?(tick) }
        else { finish(true) }
    }

    private func finish(_ completed: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        step = nil
        continuation?.resume(returning: completed)
        continuation = nil
    }
}

private struct ReleaseSoakFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct ReleaseSoakSample: Encodable {
    let cycle: Int
    let rssBytes: UInt64
    let physicalFootprintBytes: UInt64
    let retainedPrimaryDetailCells: Int
    let elapsedSeconds: Double
}

private enum ReleaseSoakWorkload: String, Encodable {
    case full
    case navigation
    case tabs
    case windows
}

private struct ReleaseSoakReport: Encodable {
    let state: String
    let workload: ReleaseSoakWorkload
    let targetSeconds: Int
    let elapsedSeconds: Double
    let cycles: Int
    let peakRSSBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let samples: [ReleaseSoakSample]
    let error: String?
}

extension BrowserWindow {
    static func measureReleasePerformance(fixture path: String) async {
        let environment = ProcessInfo.processInfo.environment
        guard let processStart = environment["FILES_PERFORMANCE_START_NS"].flatMap(UInt64.init),
              let output = environment["FILES_PERFORMANCE_REPORT"],
              let expected = environment["FILES_PERFORMANCE_COUNT"].flatMap(Int.init),
              let idle = environment["FILES_PERFORMANCE_IDLE_SECONDS"].flatMap(Int.init) else {
            exit(2)
        }

        let suite = "FilesMac.ReleasePerformance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "showThumbnails")
        let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
        let controller = BrowserWindow(preferences: preferences, restoresFrame: false)
        var status: Int32 = 1
        defer {
            controller.close()
            defaults.removePersistentDomain(forName: suite)
            exit(status)
        }
        guard let window = controller.window, let content = window.contentView else { return }
        window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 600), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Yield to the event loop before checking the first responder and display.
        await Task.yield()
        controller.focusSidebar(nil)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard window.isVisible, window.firstResponder is SidebarKeyboardButton else { return }
        let ready = DispatchTime.now().uptimeNanoseconds
        guard ready >= processStart else { return }

        if idle > 0 {
            try? await Task.sleep(for: .seconds(idle))
        }
        let idleRSS = currentResidentBytes()
        let location = URL(fileURLWithPath: path, isDirectory: true)
        let started = DispatchTime.now().uptimeNanoseconds
        controller.navigate(location)
        var firstDisplay: UInt64?
        var peakRSS = idleRSS
        while true {
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            let now = DispatchTime.now().uptimeNanoseconds
            if firstDisplay == nil, controller.table.numberOfRows >= 100,
               controller.table.rows(in: controller.table.visibleRect).length > 0 {
                firstDisplay = now
            }
            peakRSS = max(peakRSS, currentResidentBytes())
            if !controller.model.isLoading { break }
            guard now - started < 90_000_000_000 else { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        guard let firstDisplay, controller.model.failure == nil, idleRSS > 0,
              controller.table.numberOfRows == expected else { return }
        var samples: [String: Double] = [
            "startupSeconds": Double(ready - processStart) / 1e9,
            "firstDisplaySeconds": Double(firstDisplay - started) / 1e9,
            "listingSeconds": Double(finished - started) / 1e9,
            "idleRSSBytes": Double(idleRSS),
            "peakSampledRSSBytes": Double(peakRSS)
        ]
        if environment["FILES_PERFORMANCE_SCROLL"] == "1" {
            // Let Instruments settle before scrolling a populated window.
            try? await Task.sleep(for: .seconds(2))
            let clip = controller.scroll.contentView
            let maxOffset = max(0, controller.table.bounds.height - clip.bounds.height)
            guard maxOffset > 0 else { return }
            let control = environment["FILES_PERFORMANCE_SCROLL_PACING"] == "control"
            let marker = NSView(frame: NSRect(x: 24, y: 24, width: 64, height: 64))
            if control {
                marker.wantsLayer = true
                marker.layer?.backgroundColor = NSColor.systemBlue.cgColor
                content.addSubview(marker, positioned: .above, relativeTo: nil)
            }
            let scrollStart = DispatchTime.now().uptimeNanoseconds
            func scrollStep(_ tick: Int) {
                if control {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    marker.layer?.backgroundColor = (tick.isMultiple(of: 2) ? NSColor.systemBlue : .systemOrange).cgColor
                    CATransaction.commit()
                    return
                }
                let offset = min(maxOffset, CGFloat(tick * 12))
                clip.scroll(to: NSPoint(x: 0, y: offset))
                controller.scroll.reflectScrolledClipView(clip)
            }
            if control || environment["FILES_PERFORMANCE_SCROLL_PACING"] == "display" {
                guard await ReleaseScrollDriver().run(in: clip, step: scrollStep) else { return }
            } else {
                for tick in 1...360 {
                    scrollStep(tick)
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            if control {
                samples["controlSteps"] = 360
            } else {
                guard clip.bounds.minY > 0 else { return }
                samples["scrollSteps"] = 360
                samples["scrollDistancePoints"] = Double(clip.bounds.minY)
            }
            let scrollEnd = DispatchTime.now().uptimeNanoseconds
            samples["scrollStartedUptimeSeconds"] = Double(scrollStart) / 1e9
            samples["scrollEndedUptimeSeconds"] = Double(scrollEnd) / 1e9
            samples["scrollDurationSeconds"] = Double(scrollEnd - scrollStart) / 1e9
            try? await Task.sleep(for: .seconds(1))
        }
        do {
            try JSONEncoder().encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
            status = 0
        } catch {
            fputs("Performance report: \(error)\n", stderr)
        }
    }

    static func runReleaseSoak(directory: String) async {
        let environment = ProcessInfo.processInfo.environment
        guard let duration = environment["FILES_SOAK_SECONDS"].flatMap(Int.init), duration > 0,
              let workload = ReleaseSoakWorkload(rawValue: environment["FILES_SOAK_WORKLOAD"] ?? "full") else {
            fputs("Expected a positive soak duration and workload full, navigation, tabs, or windows.\n", stderr)
            exit(2)
        }

        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let fm = FileManager.default
        let suite = "FilesMac.ReleaseSoak.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "showThumbnails")
        let preferences = BrowserPreferences(defaults: defaults, initialFavorites: [])
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let transferSource = source.appendingPathComponent("payload.bin")
        let journals = root.appendingPathComponent("journals")
        let payload = Data(repeating: 0x5A, count: 1_048_576)
        let browser = BrowserWindow(preferences: preferences, restoresFrame: false)
        browser.countsSoakDetailCells = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let clock = ContinuousClock()
        let start = clock.now
        var cycles = 0
        var peakRSS: UInt64 = 0
        var samples: [ReleaseSoakSample] = []
        var lastSample = start
        var peakPhysicalFootprint: UInt64 = 0

        func elapsedSeconds() -> Double {
            let time = start.duration(to: clock.now).components
            return Double(time.seconds) + Double(time.attoseconds) / 1e18
        }

        func report(state: String, error: String? = nil) throws {
            let report = ReleaseSoakReport(state: state, workload: workload, targetSeconds: duration,
                elapsedSeconds: elapsedSeconds(), cycles: cycles, peakRSSBytes: peakRSS,
                peakPhysicalFootprintBytes: peakPhysicalFootprint,
                samples: samples, error: error)
            try encoder.encode(report).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        }

        func measureMemory(recordSample: Bool) throws {
            var info = task_vm_info_data_t()
            let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            var count = mach_msg_type_number_t(capacity)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            let footprintEnd = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)!
                + MemoryLayout<mach_vm_size_t>.size
            guard result == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size >= footprintEnd,
                  info.resident_size > 0, info.phys_footprint > 0 else {
                throw ReleaseSoakFailure("Unable to read process RSS and physical footprint")
            }
            peakRSS = max(peakRSS, info.resident_size)
            peakPhysicalFootprint = max(peakPhysicalFootprint, info.phys_footprint)
            if recordSample {
                samples.append(.init(cycle: cycles, rssBytes: info.resident_size,
                    physicalFootprintBytes: info.phys_footprint,
                    retainedPrimaryDetailCells: autoreleasepool { browser.soakDetailCells.allObjects.count },
                    elapsedSeconds: elapsedSeconds()))
                lastSample = clock.now
            }
        }

        func exerciseSecondaryWindow(relativeTo window: NSWindow) async throws {
            let usesNativeTabs = workload != .windows
            var tab: BrowserWindow? = BrowserWindow(preferences: preferences,
                restoresFrame: false, initialLocation: destination)
            weak let releasedTab = tab
            weak let releasedWindow = tab?.window
            weak var releasedWatcher: DirectoryWatcher?
            var didClose = false
            do {
                guard let tab, let tabWindow = tab.window else { throw ReleaseSoakFailure("Missing tab") }
                if !usesNativeTabs { tabWindow.tabbingMode = .disallowed }
                tab.showWindow(nil)
                if usesNativeTabs {
                    window.addTabbedWindow(tabWindow, ordered: .above)
                    guard window.tabbedWindows?.count == 2 else { throw ReleaseSoakFailure("Tab did not attach") }
                } else if (tabWindow.tabbedWindows?.count ?? 1) != 1 || (window.tabbedWindows?.count ?? 1) != 1 {
                    throw ReleaseSoakFailure("Standalone window joined a tab group")
                }
                try await tab.waitForSoakListing(at: destination, count: 0)
                releasedWatcher = tab.watcher

                if workload == .full {
                    let copy = await CopyEngine.run(sources: [transferSource], destination: destination,
                        journalDirectory: journals, cancellation: CopyCancellation(), recordUndo: false)
                    guard copy.state == "completed", copy.journalError == nil else {
                        throw ReleaseSoakFailure("Copy failed: \(copy.state)")
                    }
                    // Wait for the real directory watcher to surface the published file.
                    try await tab.waitForSoakListing(at: destination, count: 1)
                    let result = destination.appendingPathComponent(transferSource.lastPathComponent)
                    guard try Data(contentsOf: result) == payload else { throw ReleaseSoakFailure("Copy content mismatch") }
                    try fm.removeItem(at: result)
                    try await tab.waitForSoakListing(at: destination, count: 0)
                }
                tab.onClose = { didClose = true }
                tab.close()
                let closeDeadline = clock.now.advanced(by: .seconds(5))
                while !didClose {
                    guard clock.now < closeDeadline else { throw ReleaseSoakFailure("Tab close callback did not run") }
                    try await Task.sleep(for: .milliseconds(20))
                }
                tab.onClose = nil
            }
            tab = nil
            let cleanupDeadline = clock.now.advanced(by: .seconds(10))
            while releasedTab != nil || releasedWatcher != nil || releasedWindow != nil {
                guard clock.now < cleanupDeadline else {
                    throw ReleaseSoakFailure("Closed browser retained: \(releasedTab != nil); "
                        + "watcher retained: \(releasedWatcher != nil); window retained: \(releasedWindow != nil)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (window.tabbedWindows?.count ?? 1) == 1 else { throw ReleaseSoakFailure("Closed tab remained in the window group") }
            if workload == .full { try fm.removeItem(at: journals) }
        }

        var exitCode: Int32 = 1
        defer {
            browser.close()
            defaults.removePersistentDomain(forName: suite)
            exit(exitCode)
        }
        do {
            guard let window = browser.window else { throw ReleaseSoakFailure("Missing browser window") }
            try fm.createDirectory(at: source, withIntermediateDirectories: false)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            try payload.write(to: transferSource)
            for index in 0..<128 {
                try Data().write(to: source.appendingPathComponent("file-\(index).txt"))
            }
            browser.showWindow(nil)
            try report(state: "running")

            // The same window, preference store and process span all cycles.
            repeat {
                browser.navigate(source)
                try await browser.waitForSoakListing(at: source, count: 129)

                if workload != .navigation {
                    try await exerciseSecondaryWindow(relativeTo: window)
                }
                // Return through history so the repeated workload keeps one forward
                // entry instead of retaining two additional entries per cycle.
                browser.goBack(nil)
                guard browser.model.location == nil, browser.model.history.back.isEmpty,
                      browser.model.history.forward.count == 1 else {
                    throw ReleaseSoakFailure("Navigation history did not return to its expected size")
                }
                guard browser.scroll.superview == nil else {
                    throw ReleaseSoakFailure("The details view is still attached on Home")
                }
                cycles += 1
                try measureMemory(recordSample: cycles == 1 || lastSample.duration(to: clock.now) >= .seconds(30))
                try report(state: "running")
                try await Task.sleep(for: .seconds(2))
            } while start.duration(to: clock.now) < .seconds(duration)

            try measureMemory(recordSample: true)
            try report(state: "completed")
            exitCode = 0
        } catch {
            let detail = String(describing: error)
            try? report(state: "failed", error: detail)
            fputs("Release soak: \(detail)\n", stderr)
        }
    }

    private func waitForSoakListing(at location: URL, count: Int) async throws {
        let expectedPath = location.standardizedFileURL.path
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.isLoading || model.location?.path != expectedPath
                || model.items.count != count || watcherStatus != .active {
            if model.failure != nil || ContinuousClock.now >= deadline {
                let actualLocation = model.location?.lastPathComponent ?? "none"
                throw ReleaseSoakFailure(
                    "Expected \(count) rows at \(location.lastPathComponent) with an active watcher. "
                    + "Actual: \(model.items.count) rows at \(actualLocation), "
                    + "loading=\(model.isLoading), watcher=\(watcherStatus), loadFailed=\(model.failure != nil)"
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        guard scroll.superview === detailHost, table.numberOfRows == count else {
            throw ReleaseSoakFailure("The details view is detached or has an unexpected row count")
        }
    }

    private static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        let capacity = MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
#endif
