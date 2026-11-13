import AppKit
import FilesCore

@MainActor
final class GeneralSettingsWindow: NSWindowController {
    private let preferences: BrowserPreferences
    private let continueSession = NSButton(checkboxWithTitle: L("마지막 세션 계속", "Continue Last Session"), target: nil, action: nil)
    private let favorites = NSButton(checkboxWithTitle: L("홈에 빠른 접근 표시", "Show Quick Access on Home"), target: nil, action: nil)
    private let volumes = NSButton(checkboxWithTitle: L("홈에 드라이브 표시", "Show Drives on Home"), target: nil, action: nil)
    private let recent = NSButton(checkboxWithTitle: L("홈에 최근 위치 표시", "Show Recent Locations on Home"), target: nil, action: nil)
    private let startupLocation = NSTextField(wrappingLabelWithString: "")
    private let sizeUnit = NSPopUpButton()
    private let openFoldersInNewTab = NSButton(checkboxWithTitle: L("폴더를 새 탭에서 열기", "Open Folders in New Tabs"), target: nil, action: nil)
    private let scrollToPreviousFolderOnUp = NSButton(checkboxWithTitle: L("상위 이동 시 이전 폴더 표시", "Reveal Previous Folder When Going Up"), target: nil, action: nil)
    private let showFileExtensionWarning = NSButton(checkboxWithTitle: L("파일 확장자 변경 경고", "Warn When Changing File Extensions"), target: nil, action: nil)
    private let showCompressionOptions = NSButton(checkboxWithTitle: L("컨텍스트 메뉴에 압축 옵션 표시", "Show Compression Options in Context Menu"), target: nil, action: nil)
    private let showOpenTerminal = NSButton(checkboxWithTitle: L("컨텍스트 메뉴에 터미널 열기 표시", "Show Open in Terminal in Context Menu"), target: nil, action: nil)
    private let showCreateFolderWithSelection = NSButton(checkboxWithTitle: L("컨텍스트 메뉴에 선택 항목으로 폴더 만들기 표시", "Show New Folder with Selection in Context Menu"), target: nil, action: nil)
    private let showPinToSidebar = NSButton(checkboxWithTitle: L("컨텍스트 메뉴에 사이드바 고정 표시", "Show Pin to Sidebar in Context Menu"), target: nil, action: nil)

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("일반 설정", "General Settings"); panel.isReleasedWhenClosed = false
        guard let content = panel.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        let localeTitle = NSTextField(labelWithString: L("언어 및 지역", "Language & Region")); localeTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(localeTitle)
        let localeNote = NSTextField(wrappingLabelWithString: L("표시 언어와 날짜 형식은 macOS 시스템 설정을 따릅니다.", "Display language and date formats follow macOS System Settings.")); localeNote.textColor = .secondaryLabelColor; stack.addArrangedSubview(localeNote)
        let startupTitle = NSTextField(labelWithString: L("시작", "Startup")); startupTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(startupTitle)
        configure(continueSession, action: #selector(changeContinueSession(_:))); stack.addArrangedSubview(continueSession)
        let startupControls = NSStackView(); startupControls.orientation = .horizontal; startupControls.spacing = 8
        startupControls.addArrangedSubview(NSButton(title: L("시작 폴더 선택…", "Choose Startup Folder…"), target: self, action: #selector(chooseStartupLocation(_:))))
        startupControls.addArrangedSubview(NSButton(title: L("홈 사용", "Use Home"), target: self, action: #selector(clearStartupLocation(_:))))
        stack.addArrangedSubview(startupLocation); stack.addArrangedSubview(startupControls)
        let sizeTitle = NSTextField(labelWithString: L("파일 크기 단위", "File Size Units")); sizeTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(sizeTitle)
        sizeUnit.addItems(withTitles: [L("이진 단위 (1024)", "Binary units (1024)"), L("십진 단위 (1000)", "Decimal units (1000)")]); sizeUnit.target = self; sizeUnit.action = #selector(changeSizeUnit(_:)); stack.addArrangedSubview(sizeUnit)
        configure(openFoldersInNewTab, action: #selector(changeOpenFoldersInNewTab(_:))); stack.addArrangedSubview(openFoldersInNewTab)
        configure(scrollToPreviousFolderOnUp, action: #selector(changeScrollToPreviousFolderOnUp(_:))); stack.addArrangedSubview(scrollToPreviousFolderOnUp)
        configure(showFileExtensionWarning, action: #selector(changeShowFileExtensionWarning(_:))); stack.addArrangedSubview(showFileExtensionWarning)
        let contextTitle = NSTextField(labelWithString: L("컨텍스트 메뉴", "Context Menu")); contextTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(contextTitle)
        configure(showCompressionOptions, action: #selector(changeShowCompressionOptions(_:))); stack.addArrangedSubview(showCompressionOptions)
        configure(showOpenTerminal, action: #selector(changeShowOpenTerminal(_:))); stack.addArrangedSubview(showOpenTerminal)
        configure(showCreateFolderWithSelection, action: #selector(changeShowCreateFolderWithSelection(_:))); stack.addArrangedSubview(showCreateFolderWithSelection)
        configure(showPinToSidebar, action: #selector(changeShowPinToSidebar(_:))); stack.addArrangedSubview(showPinToSidebar)
        let homeTitle = NSTextField(labelWithString: L("홈 위젯", "Home Widgets")); homeTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(homeTitle)
        configure(favorites, action: #selector(changeFavorites(_:))); configure(volumes, action: #selector(changeVolumes(_:))); configure(recent, action: #selector(changeRecent(_:)))
        stack.addArrangedSubview(favorites); stack.addArrangedSubview(volumes); stack.addArrangedSubview(recent)
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func configure(_ button: NSButton, action: Selector) { button.target = self; button.action = action }
    func present() { sync(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    private func sync() {
        continueSession.state = preferences.continueLastSession ? .on : .off
        startupLocation.stringValue = preferences.startupLocationPath ?? L("시작 위치: 홈", "Startup location: Home")
        sizeUnit.selectItem(at: preferences.sizeUnit == .binary ? 0 : 1)
        openFoldersInNewTab.state = preferences.openFoldersInNewTab ? .on : .off
        scrollToPreviousFolderOnUp.state = preferences.scrollToPreviousFolderOnUp ? .on : .off
        showFileExtensionWarning.state = preferences.showFileExtensionWarning ? .on : .off
        showCompressionOptions.state = preferences.showCompressionOptions ? .on : .off
        showOpenTerminal.state = preferences.showOpenTerminal ? .on : .off
        showCreateFolderWithSelection.state = preferences.showCreateFolderWithSelection ? .on : .off
        showPinToSidebar.state = preferences.showPinToSidebar ? .on : .off
        favorites.state = preferences.showHomeFavorites ? .on : .off; volumes.state = preferences.showHomeVolumes ? .on : .off; recent.state = preferences.showHomeRecent ? .on : .off
    }
    @objc private func changeContinueSession(_ sender: Any?) { preferences.setContinueLastSession(continueSession.state == .on) }
    @objc private func chooseStartupLocation(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in guard response == .OK else { return }; self?.preferences.setStartupLocation(panel.url); self?.sync() }
    }
    @objc private func clearStartupLocation(_ sender: Any?) { preferences.setStartupLocation(nil); sync() }
    @objc private func changeSizeUnit(_ sender: Any?) { preferences.setSizeUnit(sizeUnit.indexOfSelectedItem == 0 ? .binary : .decimal) }
    @objc private func changeOpenFoldersInNewTab(_ sender: Any?) { preferences.setOpenFoldersInNewTab(openFoldersInNewTab.state == .on) }
    @objc private func changeScrollToPreviousFolderOnUp(_ sender: Any?) { preferences.setScrollToPreviousFolderOnUp(scrollToPreviousFolderOnUp.state == .on) }
    @objc private func changeShowFileExtensionWarning(_ sender: Any?) { preferences.setShowFileExtensionWarning(showFileExtensionWarning.state == .on) }
    @objc private func changeShowCompressionOptions(_ sender: Any?) { preferences.setShowCompressionOptions(showCompressionOptions.state == .on) }
    @objc private func changeShowOpenTerminal(_ sender: Any?) { preferences.setShowOpenTerminal(showOpenTerminal.state == .on) }
    @objc private func changeShowCreateFolderWithSelection(_ sender: Any?) { preferences.setShowCreateFolderWithSelection(showCreateFolderWithSelection.state == .on) }
    @objc private func changeShowPinToSidebar(_ sender: Any?) { preferences.setShowPinToSidebar(showPinToSidebar.state == .on) }
    @objc private func changeFavorites(_ sender: Any?) { preferences.setSection(.favorites, visible: favorites.state == .on) }
    @objc private func changeVolumes(_ sender: Any?) { preferences.setSection(.volumes, visible: volumes.state == .on) }
    @objc private func changeRecent(_ sender: Any?) { preferences.setSection(.recent, visible: recent.state == .on) }
#if DEBUG
    var qaVisible: Bool { window?.isVisible == true }
    var qaWidgetStates: (Bool, Bool, Bool) { (preferences.showHomeFavorites, preferences.showHomeVolumes, preferences.showHomeRecent) }
    var qaSizeUnit: BrowserSizeUnit { preferences.sizeUnit }
    var qaOpenFoldersInNewTab: Bool { preferences.openFoldersInNewTab }
    var qaScrollToPreviousFolderOnUp: Bool { preferences.scrollToPreviousFolderOnUp }
    var qaShowFileExtensionWarning: Bool { preferences.showFileExtensionWarning }
    var qaContextMenuStates: (Bool, Bool, Bool, Bool) { (preferences.showCompressionOptions, preferences.showOpenTerminal, preferences.showCreateFolderWithSelection, preferences.showPinToSidebar) }
    func qaToggleWidgets() { favorites.performClick(nil); volumes.performClick(nil); recent.performClick(nil) }
    func qaToggleSizeUnit() { sizeUnit.selectItem(at: sizeUnit.indexOfSelectedItem == 0 ? 1 : 0); changeSizeUnit(nil) }
    func qaToggleOpenFoldersInNewTab() { openFoldersInNewTab.performClick(nil) }
    func qaToggleScrollToPreviousFolderOnUp() { scrollToPreviousFolderOnUp.performClick(nil) }
    func qaToggleShowFileExtensionWarning() { showFileExtensionWarning.performClick(nil) }
    func qaToggleContextMenuItems() { showCompressionOptions.performClick(nil); showOpenTerminal.performClick(nil); showCreateFolderWithSelection.performClick(nil); showPinToSidebar.performClick(nil) }
#endif
}
