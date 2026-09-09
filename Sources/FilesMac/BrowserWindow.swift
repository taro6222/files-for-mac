import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class BrowserWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSMenuDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?
    private let model: BrowserModel
    private let table = BrowserFileTable()
    private let scroll = NSScrollView()
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
    private let refreshButton = NSButton()
    private let homeView = NSStackView()
    private let sidebar = NSStackView()
    private let content = NSView()
    private let preferences: BrowserPreferences
    private var preferencesToken: UUID?
    private var favorites: [URL] { preferences.favorites }
    private var recent: [URL] { preferences.recent }
    private let homeScroll = NSScrollView()
    private let optionsMenu = NSMenu()
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = 0
    private var suggestions: [String] = []
    private var lastRecordedLocation: URL?
    private var volumes: [VolumeSummary] = []
    private var volumeTask: Task<Void, Never>?
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

    init(preferences: BrowserPreferences = .shared, restoresFrame: Bool = true,
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
        w.contentView = BrowserBackgroundView()
        model.showHidden = preferences.showHidden
        setupUI(restoresLayout: restoresFrame)
        model.onChange = { [weak self] in self?.render() }
        preferencesToken = preferences.observe { [weak self] in self?.preferencesChanged() }
        model.navigate(nil)
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
                if let token = self.preferencesToken { self.preferences.removeObserver(token) }
                for token in self.observerTokens {
                    NotificationCenter.default.removeObserver(token)
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                }
                self.observerTokens.removeAll(); self.onClose?()
            }
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        split.addArrangedSubview(main)
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

        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 12, right: 14)
        configure(backButton, "chevron.left", L("뒤로", "Back"), #selector(goBack(_:)))
        configure(forwardButton, "chevron.right", L("앞으로", "Forward"), #selector(goForward(_:)))
        configure(upButton, "arrow.up", L("상위 폴더", "Enclosing Folder"), #selector(goUp(_:)))
        toolbar.addArrangedSubview(backButton); toolbar.addArrangedSubview(forwardButton); toolbar.addArrangedSubview(upButton)
        configure(refreshButton, "arrow.clockwise", L("새로고침", "Refresh"), #selector(refreshOrStop(_:)))
        toolbar.addArrangedSubview(refreshButton)
        pathField.numberOfVisibleItems = 8
        pathField.completes = false
        pathField.toolTip = L("경로 입력 후 아래 화살표로 추천 폴더를 선택하거나 Tab으로 완성", "Type a path, then use the dropdown or Tab to complete")
        pathField.font = .systemFont(ofSize: 13); pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = L("폴더 경로 입력", "Enter a folder path")
        pathField.target = self; pathField.action = #selector(submitPath(_:)); pathField.delegate = self
        pathField.setAccessibilityLabel(L("폴더 경로", "Folder path"))
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(pathField)
        configure(hiddenButton, "eye.slash", L("숨김 항목 표시", "Show Hidden Files"), #selector(toggleHidden(_:)))
        toolbar.addArrangedSubview(hiddenButton)
        toolbar.addArrangedSubview(button("pin", L("즐겨찾기 전환", "Toggle Favorite"), #selector(toggleFavorite(_:))))
        optionsMenu.delegate = self
        toolbar.addArrangedSubview(button("slider.horizontal.3", L("보기 옵션", "View Options"), #selector(showOptions(_:))))
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
        let phase = NSTextField(labelWithString: L("M2 · 탐색 및 복사", "M2 · Browse and copy"))
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
        let copy = menu.addItem(withTitle: L("선택 항목 복사…", "Copy Selection To…"), action: #selector(copySelection(_:)), keyEquivalent: ""); copy.target = self
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
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.alignment = .left; b.font = .systemFont(ofSize: 13)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading; b.imageHugsTitle = true
        b.toolTip = url?.path ?? title; b.setAccessibilityLabel(title)
        if let url, favorites.contains(url) {
            let menu = NSMenu(); menu.autoenablesItems = false
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
            b.menu = menu
        }
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
                let description = NSTextField(labelWithString: volume.capacityDescription)
                description.font = .systemFont(ofSize: 11); description.textColor = .secondaryLabelColor
                card.addArrangedSubview(description)
                if let total = volume.total, let available = volume.available, total > 0 {
                    let meter = NSLevelIndicator(); meter.levelIndicatorStyle = .continuousCapacity
                    meter.minValue = 0; meter.maxValue = 1; meter.doubleValue = min(1, max(0, 1 - Double(available) / Double(total)))
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
        let ids = Set(table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].id : nil })
        model.savePosition(selection: ids, scrollOffset: scroll.contentView.bounds.origin.y)
    }
    private func navigate(_ url: URL?) {
        completionTask?.cancel(); completionGeneration += 1
        suggestions = []; pathField.removeAllItems()
        pathField.stringValue = url?.path ?? ""
        window?.makeFirstResponder(nil)
        savePosition(); model.navigate(url)
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
        let refreshTitle = model.isLoading ? L("읽기 중단", "Stop Loading") : L("새로고침", "Refresh")
        refreshButton.image = NSImage(systemSymbolName: model.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: refreshTitle)
        refreshButton.toolTip = refreshTitle; refreshButton.setAccessibilityLabel(refreshTitle)
        scroll.isHidden = model.location == nil; homeScroll.isHidden = model.location != nil
        if model.location == nil { lastRecordedLocation = nil; buildHome() }
        table.reloadData()
        let selected = IndexSet(model.items.indices.filter { model.history.current.selection.contains(model.items[$0].id) })
        table.selectRowIndexes(selected, byExtendingSelection: false)
        if !model.isLoading {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: model.history.current.scrollOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            if model.history.current.scrollOffset == 0 && !model.items.isEmpty { table.scrollRowToVisible(0) }
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
        if model.location != nil && window?.firstResponder === window { window?.makeFirstResponder(table) }
    }
    private func updateStatus() {
        if model.location == nil { status.stringValue = L("준비됨", "Ready"); return }
        status.stringValue = "\(model.items.count) " + L("개 항목", "items")
        if !table.selectedRowIndexes.isEmpty {
            status.stringValue += "  ·  \(table.selectedRowIndexes.count) " + L("개 선택", "selected")
            let bytes = table.selectedRowIndexes.reduce(Int64(0)) { total, index in
                guard model.items.indices.contains(index), !model.items[index].isDirectory else { return total }
                return total + (model.items[index].size ?? 0)
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
    func tableViewSelectionDidChange(_ notification: Notification) { savePosition(allowWhileLoading: true); updateStatus() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let field = SortField(rawValue: descriptor.key ?? "") else { return }
        savePosition(); model.sort(SortOrder(field: field, ascending: descriptor.ascending))
    }
    @objc func openLocation(_ sender: LocationButton) { navigate(sender.url) }
    @objc func goBack(_ sender: Any?) { window?.makeFirstResponder(nil); savePosition(); model.back() }
    @objc func goForward(_ sender: Any?) { window?.makeFirstResponder(nil); savePosition(); model.forward() }
    @objc func goUp(_ sender: Any?) { if let url = model.location { navigate(url.deletingLastPathComponent()) } }
    @objc func refresh(_ sender: Any?) { savePosition(); model.reload() }
    @objc func refreshOrStop(_ sender: Any?) {
        if model.isLoading { stopLoading(sender) } else { refresh(sender) }
    }
    @objc func stopLoading(_ sender: Any?) {
        pendingRefresh = false
        model.cancelLoad()
    }
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
        let sameLocation = model.location == url.standardizedFileURL
        navigate(url)
        // An explicit selection may grant access after a previous registration failed.
        if sameLocation { updateWatcher(force: true) }
    }
    @objc func retryAutomaticRefresh(_ sender: Any?) { updateWatcher(force: true) }
    @objc func toggleHidden(_ sender: Any?) {
        preferences.setShowHidden(!preferences.showHidden)
    }
    @objc func toggleFavorite(_ sender: Any?) {
        guard let url = model.location else { return }
        preferences.toggleFavorite(url)
    }
    @objc func openSelection(_ sender: Any?) {
        if sender as? NSTableView === table && table.clickedRow < 0 { return }
        let rows = table.selectedRowIndexes
        guard let first = rows.first, model.items.indices.contains(first) else { return }
        let item = model.items[first]
        if item.isBrowsable { navigate(item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }
    @objc func copySelection(_ sender: Any?) {
        guard !CopyWindow.isRunning, !model.isLoading, let window else { return }
        let sources = table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].url : nil }
        guard !sources.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("여기에 복사", "Copy Here")
        panel.message = L("복사할 대상 폴더를 선택하세요. 같은 이름은 덮어쓰지 않고 건너뜁니다.", "Choose the destination folder. Existing names will be skipped.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            CopyWindow.start(sources: sources, destination: destination) { [weak self] in
                if self?.model.location?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                    self?.refresh(nil)
                }
            }
        }
    }
    @objc func revealSelection(_ sender: Any?) {
        let urls = table.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0].url : nil }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
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
private final class BrowserFileTable: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            (window?.windowController as? BrowserWindow)?.stopLoading(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private struct VolumeSummary: Sendable {
    let url: URL
    let name: String
    let total: Int64?
    let available: Int64?
    var capacityDescription: String {
        guard let total, let available else { return L("용량 정보 없음", "Capacity unavailable") }
        return ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + L(" 사용 가능 / ", " free of ") + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

extension BrowserWindow {
    private func preferencesChanged() {
        buildSidebar()
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
    }
    @objc private func toggleExtensions(_ sender: Any?) { preferences.setShowExtensions(!preferences.showExtensions) }
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
            let result = await Task.detached(priority: .utility) {
                let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
                return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).map { url in
                    let values = try? url.resourceValues(forKeys: keys)
                    return VolumeSummary(url: url, name: values?.volumeName ?? url.lastPathComponent,
                        total: values?.volumeTotalCapacity.map(Int64.init), available: values?.volumeAvailableCapacity.map(Int64.init))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.volumes = result; self.buildSidebar()
            if self.model.location == nil { self.buildHome() }
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
        if model.location == nil { focusSidebar(nil) } else { window?.makeFirstResponder(table) }
    }
    @objc func focusSidebar(_ sender: Any?) {
        if let first = sidebar.arrangedSubviews.first { window?.makeFirstResponder(first) }
    }
    @objc func openViewOptions(_ sender: Any?) {
        optionsMenu.popUp(positioning: nil, at: NSPoint(x: content.bounds.maxX - 200, y: content.bounds.maxY), in: content)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(retryAutomaticRefresh(_:)): return model.location != nil && watcherStatus != .active
        case #selector(copySelection(_:)): return !CopyWindow.isRunning && !model.isLoading && !table.selectedRowIndexes.isEmpty
        case #selector(stopLoading(_:)): return model.isLoading
        case #selector(goBack(_:)): return !model.history.back.isEmpty
        case #selector(goForward(_:)): return !model.history.forward.isEmpty
        case #selector(goUp(_:)): return model.location != nil && model.location?.path != "/"
        case #selector(openSelection(_:)), #selector(revealSelection(_:)): return !table.selectedRowIndexes.isEmpty && model.location != nil
        default: return true
        }
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
            for index in 0..<10_000 {
                let name = index == 0 ? "00000-한글-é-📁-long-file-name.txt" : String(format: "%05d-file.txt", index)
                try Data("fixture".utf8).write(to: fixture.appendingPathComponent(name))
            }
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
            root.layoutSubtreeIfNeeded()
            checks["historySelection"] = controller.table.selectedRowIndexes == IndexSet(integer: 9_999)
            checks["historyScroll"] = NSLocationInRange(9_999, controller.table.rows(in: controller.table.visibleRect))
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
