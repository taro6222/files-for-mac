import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var windows: [BrowserWindow] = []
    private var closedWorkspaces: [SplitTabState] = []
    private let sessionStore = TabSessionStore()
    private let workspaceStore = WorkspaceSessionStore()
    private var shortcutPreferences: ShortcutPreferences!
    private var shortcutSettingsWindow: ShortcutSettingsWindow?
    private var appearanceSettingsWindow: AppearanceSettingsWindow?
    private var archiveCapabilitiesWindow: ArchiveCapabilitiesWindow?
    private var remoteConnectionsWindow: RemoteConnectionsWindow?
    private var preferencesToken: UUID?
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        preferencesToken = BrowserPreferences.shared.observe { [weak self] in self?.applyAppearance() }
        buildMenu()
        configureShortcuts()
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["FILES_UI_QA_OUTPUT"] {
            Task { @MainActor in await BrowserWindow.runUIVerification(output: output) }
            return
        }
        if let output = ProcessInfo.processInfo.environment["FILES_M2_UI_QA_OUTPUT"] {
            Task { @MainActor in await BrowserWindow.runM2UIVerification(output: output) }
            return
        }
        #endif
        var restored = workspaceStore.load()
        if restored.isEmpty {
            restored = sessionStore.load().map { SplitTabState(primary: PaneSnapshot(tab: $0)) }
        }
        if restored.isEmpty { newWindow(nil) }
        else {
            var first: BrowserWindow?
            for workspace in restored {
                let controller = makeBrowser(workspace: workspace, tabbedTo: first)
                if first == nil { first = controller }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    private var currentBrowser: BrowserWindow? {
        (NSApp.keyWindow?.windowController as? BrowserWindow) ?? (NSApp.mainWindow?.windowController as? BrowserWindow)
    }
    @discardableResult private func makeBrowser(location: URL? = nil, snapshot: TabSnapshot? = nil,
                                                 workspace: SplitTabState? = nil,
                                                 tabbedTo source: BrowserWindow? = nil) -> BrowserWindow {
        let controller = BrowserWindow(initialLocation: location, initialSnapshot: snapshot, initialWorkspace: workspace)
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            if let controller {
                self?.closedWorkspaces.append(controller.workspaceSnapshot())
                if let self, self.closedWorkspaces.count > 20 { self.closedWorkspaces.removeFirst(self.closedWorkspaces.count - 20) }
            }
            self?.windows.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
        if let sourceWindow = source?.window, let targetWindow = controller.window {
            sourceWindow.addTabbedWindow(targetWindow, ordered: .above)
            targetWindow.makeKeyAndOrderFront(nil)
        }
        return controller
    }
    @objc func newWindow(_ sender: Any?) { makeBrowser() }
    @objc func newTab(_ sender: Any?) { makeBrowser(tabbedTo: currentBrowser) }
    @objc func duplicateTab(_ sender: Any?) {
        guard let current = currentBrowser else { return }
        makeBrowser(workspace: current.workspaceSnapshot(), tabbedTo: current)
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let workspace = closedWorkspaces.popLast() else { return }
        makeBrowser(workspace: workspace, tabbedTo: currentBrowser)
    }
    @objc func showShortcutSettings(_ sender: Any?) {
        if shortcutSettingsWindow == nil {
            shortcutSettingsWindow = ShortcutSettingsWindow(preferences: shortcutPreferences,
                entries: CommandPaletteCatalog.entries(from: NSApp.mainMenu)) { [weak self] in self?.applyShortcuts() }
        }
        shortcutSettingsWindow?.present()
    }
    @objc func showAppearanceSettings(_ sender: Any?) {
        if appearanceSettingsWindow == nil { appearanceSettingsWindow = AppearanceSettingsWindow(preferences: .shared) }
        appearanceSettingsWindow?.present()
    }
    @objc func showArchiveCapabilities(_ sender: Any?) {
        if archiveCapabilitiesWindow == nil { archiveCapabilitiesWindow = ArchiveCapabilitiesWindow() }
        archiveCapabilitiesWindow?.present()
    }
    @objc func showRemoteConnections(_ sender: Any?) {
        if remoteConnectionsWindow == nil {
            #if DEBUG
            let qaRoot = ProcessInfo.processInfo.environment["FILES_UI_QA_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            #else
            let qaRoot: URL? = nil
            #endif
            let support = (qaRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FilesMac", isDirectory: true)).appendingPathComponent("remote-connections.json")
            remoteConnectionsWindow = RemoteConnectionsWindow(profileStore: RemoteProfileStore(fileURL: support))
        }
        remoteConnectionsWindow?.present()
    }
    private func applyAppearance() { NSApp.appearance = BrowserWindow.appearance(BrowserPreferences.shared.appearance) }
    private func configureShortcuts() {
        let entries = CommandPaletteCatalog.entries(from: NSApp.mainMenu)
        let known = Set(entries.compactMap { ShortcutBridge.commandID($0.item) })
        var factory: [String: KeyboardShortcut] = [:]
        for entry in entries {
            if let id = ShortcutBridge.commandID(entry.item), let shortcut = ShortcutBridge.shortcut(entry.item) { factory[id] = shortcut }
        }
        shortcutPreferences = ShortcutPreferences(factory: factory, knownCommandIDs: known); applyShortcuts()
    }
    private func applyShortcuts() { ShortcutBridge.apply(shortcutPreferences, to: NSApp.mainMenu) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedTab(_:)) { return !closedWorkspaces.isEmpty }
        if menuItem.action == #selector(duplicateTab(_:)) { return currentBrowser != nil }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let preferencesToken { BrowserPreferences.shared.removeObserver(preferencesToken) }
        try? workspaceStore.save(windows.map { $0.workspaceSnapshot() })
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CopyWindow.isRunning || DeletionWindow.isRunning || RestoreWindow.isRunning || MoveWindow.isRunning ||
              PermanentDeleteWindow.isRunning || BatchRenameWindow.isRunning || BrowserWindow.entryOperationRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("파일 작업이 진행 중입니다", "A file operation is running")
        alert.informativeText = L("작업 완료 후 종료하세요. 복사와 이동은 작업 창에서 취소할 수 있습니다.", "Quit after the operation finishes. Copies and moves can be cancelled in their operation windows.")
        alert.runModal()
        return .terminateCancel
    }
    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.title = "Files macOS"; menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let shortcuts = appMenu.addItem(withTitle: L("키보드 단축키…", "Keyboard Shortcuts…"), action: #selector(showShortcutSettings(_:)), keyEquivalent: ",")
        shortcuts.target = self
        let appearance = appMenu.addItem(withTitle: L("외형…", "Appearance…"), action: #selector(showAppearanceSettings(_:)), keyEquivalent: "")
        appearance.target = self
        let archiveSupport = appMenu.addItem(withTitle: L("압축 포맷 지원…", "Archive Format Support…"), action: #selector(showArchiveCapabilities(_:)), keyEquivalent: "")
        archiveSupport.target = self
        let remoteConnections = appMenu.addItem(withTitle: L("원격 연결…", "Remote Connections…"), action: #selector(showRemoteConnections(_:)), keyEquivalent: "")
        remoteConnections.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Files macOS 종료", "Quit Files macOS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); fileItem.title = L("파일", "File"); menu.addItem(fileItem)
        let file = NSMenu(title: fileItem.title); fileItem.submenu = file
        let new = file.addItem(withTitle: L("새 창", "New Window"), action: #selector(newWindow(_:)), keyEquivalent: "n"); new.target = self
        let newTab = file.addItem(withTitle: L("새 탭", "New Tab"), action: #selector(newTab(_:)), keyEquivalent: "t"); newTab.target = self
        let duplicate = file.addItem(withTitle: L("탭 복제", "Duplicate Tab"), action: #selector(duplicateTab(_:)), keyEquivalent: "d")
        duplicate.keyEquivalentModifierMask = [.command, .shift]; duplicate.target = self
        let reopen = file.addItem(withTitle: L("닫은 탭 다시 열기", "Reopen Closed Tab"), action: #selector(reopenClosedTab(_:)), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]; reopen.target = self
        file.addItem(withTitle: L("폴더 열기…", "Open Folder…"), action: #selector(BrowserWindow.chooseFolder(_:)), keyEquivalent: "o")
        file.addItem(withTitle: L("선택 항목 열기", "Open Selection"), action: #selector(BrowserWindow.openSelection(_:)), keyEquivalent: "\u{f701}")
        file.addItem(withTitle: L("압축 파일 탐색", "Browse Archive"), action: #selector(BrowserWindow.openArchive(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("선택 항목 압축…", "Compress Selection…"), action: #selector(BrowserWindow.createArchive(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("지금 다운로드", "Download Now"), action: #selector(BrowserWindow.downloadCloudSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("공간 비우기", "Free Up Space"), action: #selector(BrowserWindow.evictCloudSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Finder에서 보기", "Reveal in Finder"), action: #selector(BrowserWindow.revealSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("다른 앱으로 열기…", "Open With…"), action: #selector(BrowserWindow.openWithApplication(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("공유…", "Share…"), action: #selector(BrowserWindow.shareSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("터미널에서 열기", "Open in Terminal"), action: #selector(BrowserWindow.openInTerminal(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("정보 가져오기", "Get Info"), action: #selector(BrowserWindow.showInfo(_:)), keyEquivalent: "i")
        let preview = file.addItem(withTitle: L("훑어보기", "Quick Look"), action: #selector(BrowserWindow.showQuickLook(_:)), keyEquivalent: " ")
        preview.keyEquivalentModifierMask = []
        let folder = file.addItem(withTitle: L("새 폴더…", "New Folder…"), action: #selector(BrowserWindow.createFolder(_:)), keyEquivalent: "n")
        folder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("선택 항목으로 새 폴더…", "New Folder with Selection…"), action: #selector(BrowserWindow.createFolderFromSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("이름 변경…", "Rename…"), action: #selector(BrowserWindow.renameSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("일괄 이름 변경…", "Batch Rename…"), action: #selector(BrowserWindow.batchRenameSelection(_:)), keyEquivalent: "")
        let copy = file.addItem(withTitle: L("선택 항목 복사…", "Copy Selection To…"), action: #selector(BrowserWindow.copySelection(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command, .shift]
        let move = file.addItem(withTitle: L("선택 항목 이동…", "Move Selection To…"), action: #selector(BrowserWindow.moveSelection(_:)), keyEquivalent: "v")
        move.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("휴지통으로 이동", "Move to Trash"), action: #selector(BrowserWindow.deleteSelection(_:)), keyEquivalent: "\u{8}")
        file.addItem(withTitle: L("휴지통에서 복원…", "Restore From Trash…"), action: #selector(BrowserWindow.restoreSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("영구 삭제…", "Delete Permanently…"), action: #selector(BrowserWindow.permanentlyDeleteSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("창 닫기", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(); editItem.title = L("편집", "Edit"); menu.addItem(editItem)
        let edit = NSMenu(title: editItem.title); editItem.submenu = edit
        edit.addItem(withTitle: L("마지막 이동 실행 취소", "Undo Last Move"), action: #selector(BrowserWindow.undoLastMove(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: L("마지막 복사 실행 취소", "Undo Last Copy"), action: #selector(BrowserWindow.undoLastCopy(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("복사", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("붙여넣기", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("모두 선택", "Select All"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("현재 위치 검색…", "Search Current Location…"), action: #selector(BrowserWindow.showSearch(_:)), keyEquivalent: "f")
        let goItem = NSMenuItem(); goItem.title = L("이동", "Go"); menu.addItem(goItem)
        let go = NSMenu(title: goItem.title); goItem.submenu = go
        go.addItem(withTitle: L("뒤로", "Back"), action: #selector(BrowserWindow.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: L("앞으로", "Forward"), action: #selector(BrowserWindow.goForward(_:)), keyEquivalent: "]")
        go.addItem(withTitle: L("상위 폴더", "Enclosing Folder"), action: #selector(BrowserWindow.goUp(_:)), keyEquivalent: "\u{f700}")
        go.addItem(withTitle: L("경로 입력", "Go to Path"), action: #selector(BrowserWindow.focusPath(_:)), keyEquivalent: "l")
        go.addItem(withTitle: L("새로고침", "Refresh"), action: #selector(BrowserWindow.refresh(_:)), keyEquivalent: "r")
        let stop = go.addItem(withTitle: L("읽기 중단", "Stop Loading"), action: #selector(BrowserWindow.stopLoading(_:)), keyEquivalent: "\u{1b}")
        stop.keyEquivalentModifierMask = []
        go.addItem(withTitle: L("자동 갱신 다시 연결", "Reconnect Automatic Refresh"), action: #selector(BrowserWindow.retryAutomaticRefresh(_:)), keyEquivalent: "")
        let hidden = go.addItem(withTitle: L("숨김 항목 전환", "Toggle Hidden Files"), action: #selector(BrowserWindow.toggleHidden(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        let home = go.addItem(withTitle: L("홈", "Home"), action: #selector(BrowserWindow.goHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        let files = go.addItem(withTitle: L("파일 목록에 초점", "Focus File List"), action: #selector(BrowserWindow.focusFiles(_:)), keyEquivalent: "l")
        files.keyEquivalentModifierMask = [.command, .shift]
        let sidebar = go.addItem(withTitle: L("사이드바에 초점", "Focus Sidebar"), action: #selector(BrowserWindow.focusSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let palette = go.addItem(withTitle: L("명령 팔레트…", "Command Palette…"), action: #selector(BrowserWindow.showCommandPalette(_:)), keyEquivalent: "p")
        palette.keyEquivalentModifierMask = [.command, .shift]
        go.addItem(withTitle: L("보기 옵션…", "View Options…"), action: #selector(BrowserWindow.openViewOptions(_:)), keyEquivalent: "")
        go.addItem(.separator())
        let splitVertical = go.addItem(withTitle: L("좌우 분할", "Split Vertically"), action: #selector(BrowserWindow.splitVertically(_:)), keyEquivalent: "d")
        splitVertical.keyEquivalentModifierMask = [.command, .option]
        let splitHorizontal = go.addItem(withTitle: L("상하 분할", "Split Horizontally"), action: #selector(BrowserWindow.splitHorizontally(_:)), keyEquivalent: "d")
        splitHorizontal.keyEquivalentModifierMask = [.command, .option, .shift]
        let closeSplit = go.addItem(withTitle: L("보조 pane 닫기", "Close Secondary Pane"), action: #selector(BrowserWindow.closeSecondaryPane(_:)), keyEquivalent: "w")
        closeSplit.keyEquivalentModifierMask = [.command, .option]
        NSApp.mainMenu = menu
    }
#if DEBUG
    var qaShortcutRowCount: Int { shortcutSettingsWindow?.qaRowCount ?? 0 }
    var qaShortcutWindowVisible: Bool { shortcutSettingsWindow?.window?.isVisible == true }
    var qaShortcutContentView: NSView? { shortcutSettingsWindow?.window?.contentView }
    var qaArchiveCapabilitiesVisible: Bool { archiveCapabilitiesWindow?.window?.isVisible == true }
    var qaArchiveCapabilitiesContentView: NSView? { archiveCapabilitiesWindow?.window?.contentView }
    var qaRemoteConnectionsVisible: Bool { remoteConnectionsWindow?.window?.isVisible == true }
    var qaRemoteConnectionsContentView: NSView? { remoteConnectionsWindow?.window?.contentView }
    var qaRemoteProfileCount: Int { remoteConnectionsWindow?.qaProfileCount ?? -1 }
    var qaSMBConnectEnabled: Bool { remoteConnectionsWindow?.qaSMBConnectEnabled == true }
    func qaCreateRemoteProfile() { remoteConnectionsWindow?.qaCreateProfile() }
#endif
}

func L(_ ko: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("ko") == true ? ko : en
}

let app = NSApplication.shared
NSWindow.allowsAutomaticWindowTabbing = true
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
