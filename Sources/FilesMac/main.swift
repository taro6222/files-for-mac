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
    private var gitWindow: GitWindow?
    private var gitCloneWindow: GitCloneWindow?
    private var releaseInfoWindow: ReleaseInfoWindow?
    private var developerSettingsWindow: DeveloperSettingsWindow?
    private var advancedSettingsWindow: AdvancedSettingsWindow?
    private var generalSettingsWindow: GeneralSettingsWindow?
    private var preferencesToken: UUID?
    private let diagnosticArtifacts = DiagnosticArtifacts()
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = try? diagnosticArtifacts.append(event: "application launched")
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
        var restored: [SplitTabState] = []
        if BrowserPreferences.shared.continueLastSession {
            restored = workspaceStore.load()
            if restored.isEmpty {
                restored = sessionStore.load().map { SplitTabState(primary: PaneSnapshot(tab: $0)) }
            }
        }
        if restored.isEmpty {
            let startup = BrowserPreferences.shared.startupLocationPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            var isDirectory: ObjCBool = false
            if let startup, FileManager.default.fileExists(atPath: startup.path, isDirectory: &isDirectory), isDirectory.boolValue {
                makeBrowser(location: startup)
            } else { newWindow(nil) }
        }
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
    func openFolderInNewTab(_ url: URL) { makeBrowser(location: url, tabbedTo: currentBrowser) }
    func openFolderInNewWindow(_ url: URL) { makeBrowser(location: url) }
    @objc func duplicateTab(_ sender: Any?) {
        guard let current = currentBrowser else { return }
        makeBrowser(workspace: current.workspaceSnapshot(), tabbedTo: current)
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let workspace = closedWorkspaces.popLast() else { return }
        makeBrowser(workspace: workspace, tabbedTo: currentBrowser)
    }
    private var currentTabGroup: [NSWindow] { currentBrowser?.window?.tabbedWindows ?? currentBrowser?.window.map { [$0] } ?? [] }
    @objc func nextTab(_ sender: Any?) { currentBrowser?.window?.selectNextTab(sender) }
    @objc func previousTab(_ sender: Any?) { currentBrowser?.window?.selectPreviousTab(sender) }
    @objc func closeSelectedTab(_ sender: Any?) { currentBrowser?.window?.performClose(sender) }
    @objc func closeAllTabs(_ sender: Any?) { currentTabGroup.forEach { $0.performClose(sender) } }
    @objc func closeOtherTabs(_ sender: Any?) {
        guard let selected = currentBrowser?.window else { return }
        currentTabGroup.filter { $0 !== selected }.forEach { $0.performClose(sender) }
    }
    @objc func closeTabsToLeft(_ sender: Any?) {
        guard let selected = currentBrowser?.window, let index = currentTabGroup.firstIndex(where: { $0 === selected }) else { return }
        currentTabGroup[..<index].forEach { $0.performClose(sender) }
    }
    @objc func closeTabsToRight(_ sender: Any?) {
        guard let selected = currentBrowser?.window, let index = currentTabGroup.firstIndex(where: { $0 === selected }) else { return }
        currentTabGroup[(index + 1)...].forEach { $0.performClose(sender) }
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
    @objc func setDarkTheme(_ sender: Any?) { BrowserPreferences.shared.setAppearance(.dark) }
    @objc func setLightTheme(_ sender: Any?) { BrowserPreferences.shared.setAppearance(.light) }
    @objc func setDefaultTheme(_ sender: Any?) { BrowserPreferences.shared.setAppearance(.system) }
    @objc func toggleAppTheme(_ sender: Any?) {
        BrowserPreferences.shared.setAppearance(BrowserPreferences.shared.appearance == .dark ? .light : .dark)
    }
    @objc func showAbout(_ sender: Any?) {
        if releaseInfoWindow == nil { releaseInfoWindow = ReleaseInfoWindow() }
        releaseInfoWindow?.present(.about)
    }
    @objc func showReleaseNotes(_ sender: Any?) {
        if releaseInfoWindow == nil { releaseInfoWindow = ReleaseInfoWindow() }
        releaseInfoWindow?.present(.releaseNotes)
    }
    @objc func showDeveloperSettings(_ sender: Any?) {
        if developerSettingsWindow == nil { developerSettingsWindow = DeveloperSettingsWindow(preferences: .shared) }
        developerSettingsWindow?.present()
    }
    @objc func showAdvancedSettings(_ sender: Any?) {
        if advancedSettingsWindow == nil { advancedSettingsWindow = AdvancedSettingsWindow(preferences: .shared) }
        advancedSettingsWindow?.present()
    }
    @objc func showGeneralSettings(_ sender: Any?) {
        if generalSettingsWindow == nil { generalSettingsWindow = GeneralSettingsWindow(preferences: .shared) }
        generalSettingsWindow?.present()
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
    @objc func showGitStatus(_ sender: Any?) {
        guard let location = currentBrowser?.activeLocation else { return }
        if gitWindow == nil { gitWindow = GitWindow() }
        gitWindow?.present(location: location)
    }
    @objc func showGitClone(_ sender: Any?) {
        if gitCloneWindow == nil { gitCloneWindow = GitCloneWindow { [weak self] location in self?.makeBrowser(location: location) } }
        gitCloneWindow?.present()
    }
    @objc func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/taro6222/files-for-mac") { NSWorkspace.shared.open(url) }
    }
    @objc func openLogFile(_ sender: Any?) {
        do { NSWorkspace.shared.open(try diagnosticArtifacts.append(event: "log opened")) }
        catch { NSSound.beep() }
    }
    @objc func openLogFileLocation(_ sender: Any?) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try diagnosticArtifacts.append(event: "log location revealed")]) }
        catch { NSSound.beep() }
    }
    @objc func openSettingsFile(_ sender: Any?) {
        do { NSWorkspace.shared.open(try diagnosticArtifacts.writeSettingsSnapshot(BrowserPreferences.shared.exportData())) }
        catch { NSSound.beep() }
    }
    @objc func openRepositoryInIDE(_ sender: Any?) { currentBrowser?.openInDeveloperApplication(sender) }
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
        if menuItem.action == #selector(showGitStatus(_:)) { return currentBrowser?.activeLocation != nil }
        if menuItem.action == #selector(openRepositoryInIDE(_:)) { return currentBrowser?.activeLocation != nil && BrowserPreferences.shared.developerApplicationPath != nil }
        if menuItem.action == #selector(nextTab(_:)) || menuItem.action == #selector(previousTab(_:)) { return currentTabGroup.count > 1 }
        if menuItem.action == #selector(closeSelectedTab(_:)) || menuItem.action == #selector(closeAllTabs(_:)) { return currentBrowser != nil }
        if menuItem.action == #selector(closeOtherTabs(_:)) { return currentTabGroup.count > 1 }
        if menuItem.action == #selector(closeTabsToLeft(_:)), let selected = currentBrowser?.window { return currentTabGroup.first.map { $0 !== selected } ?? false }
        if menuItem.action == #selector(closeTabsToRight(_:)), let selected = currentBrowser?.window { return currentTabGroup.last.map { $0 !== selected } ?? false }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let preferencesToken { BrowserPreferences.shared.removeObserver(preferencesToken) }
        try? workspaceStore.save(windows.map { $0.workspaceSnapshot() })
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CopyWindow.isRunning || DeletionWindow.isRunning || RestoreWindow.isRunning || MoveWindow.isRunning ||
              PermanentDeleteWindow.isRunning || BatchRenameWindow.isRunning || GitCloneWindow.isRunning || BrowserWindow.entryOperationRunning else { return .terminateNow }
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
        let about = appMenu.addItem(withTitle: L("Files macOS 정보", "About Files macOS"), action: #selector(showAbout(_:)), keyEquivalent: ""); about.target = self
        let releaseNotes = appMenu.addItem(withTitle: L("릴리스 노트…", "Release Notes…"), action: #selector(showReleaseNotes(_:)), keyEquivalent: ""); releaseNotes.target = self
        appMenu.addItem(.separator())
        let shortcuts = appMenu.addItem(withTitle: L("키보드 단축키…", "Keyboard Shortcuts…"), action: #selector(showShortcutSettings(_:)), keyEquivalent: ",")
        shortcuts.target = self
        let appearance = appMenu.addItem(withTitle: L("외형…", "Appearance…"), action: #selector(showAppearanceSettings(_:)), keyEquivalent: "")
        appearance.target = self
        let themeItem = appMenu.addItem(withTitle: L("테마", "Theme"), action: nil, keyEquivalent: "")
        let theme = NSMenu(title: themeItem.title); themeItem.submenu = theme
        theme.addItem(withTitle: L("시스템 설정 사용", "Use System Appearance"), action: #selector(setDefaultTheme(_:)), keyEquivalent: "")
        theme.addItem(withTitle: L("밝게", "Light"), action: #selector(setLightTheme(_:)), keyEquivalent: "")
        theme.addItem(withTitle: L("어둡게", "Dark"), action: #selector(setDarkTheme(_:)), keyEquivalent: "")
        theme.addItem(withTitle: L("밝게/어둡게 전환", "Toggle Light/Dark"), action: #selector(toggleAppTheme(_:)), keyEquivalent: "")
        theme.items.forEach { $0.target = self }
        let developer = appMenu.addItem(withTitle: L("개발자 도구…", "Developer Tools…"), action: #selector(showDeveloperSettings(_:)), keyEquivalent: ""); developer.target = self
        let general = appMenu.addItem(withTitle: L("일반 설정…", "General Settings…"), action: #selector(showGeneralSettings(_:)), keyEquivalent: ""); general.target = self
        let advanced = appMenu.addItem(withTitle: L("고급 설정…", "Advanced Settings…"), action: #selector(showAdvancedSettings(_:)), keyEquivalent: ""); advanced.target = self
        let archiveSupport = appMenu.addItem(withTitle: L("압축 포맷 지원…", "Archive Format Support…"), action: #selector(showArchiveCapabilities(_:)), keyEquivalent: "")
        archiveSupport.target = self
        let remoteConnections = appMenu.addItem(withTitle: L("원격 연결…", "Remote Connections…"), action: #selector(showRemoteConnections(_:)), keyEquivalent: "")
        remoteConnections.target = self
        let gitStatus = appMenu.addItem(withTitle: L("Git 상태…", "Git Status…"), action: #selector(showGitStatus(_:)), keyEquivalent: "")
        gitStatus.target = self
        let gitClone = appMenu.addItem(withTitle: L("Git 저장소 복제…", "Clone Git Repository…"), action: #selector(showGitClone(_:)), keyEquivalent: "")
        gitClone.target = self
        let openLog = appMenu.addItem(withTitle: L("진단 로그 열기", "Open Diagnostic Log"), action: #selector(openLogFile(_:)), keyEquivalent: ""); openLog.target = self
        let revealLog = appMenu.addItem(withTitle: L("진단 로그 위치 보기", "Reveal Diagnostic Log"), action: #selector(openLogFileLocation(_:)), keyEquivalent: ""); revealLog.target = self
        let openSettings = appMenu.addItem(withTitle: L("설정 스냅샷 열기", "Open Settings Snapshot"), action: #selector(openSettingsFile(_:)), keyEquivalent: ""); openSettings.target = self
        let repoIDE = appMenu.addItem(withTitle: L("현재 저장소를 개발 앱에서 열기", "Open Current Repository in Developer Application"), action: #selector(openRepositoryInIDE(_:)), keyEquivalent: ""); repoIDE.target = self
        let help = appMenu.addItem(withTitle: L("온라인 도움말", "Online Help"), action: #selector(openHelp(_:)), keyEquivalent: "?"); help.target = self
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
        let previousTab = file.addItem(withTitle: L("이전 탭", "Previous Tab"), action: #selector(previousTab(_:)), keyEquivalent: "{"); previousTab.target = self
        let nextTab = file.addItem(withTitle: L("다음 탭", "Next Tab"), action: #selector(nextTab(_:)), keyEquivalent: "}"); nextTab.target = self
        file.addItem(.separator())
        for (title, action) in [
            (L("현재 탭 닫기", "Close Selected Tab"), #selector(closeSelectedTab(_:))),
            (L("다른 탭 닫기", "Close Other Tabs"), #selector(closeOtherTabs(_:))),
            (L("왼쪽 탭 닫기", "Close Tabs to the Left"), #selector(closeTabsToLeft(_:))),
            (L("오른쪽 탭 닫기", "Close Tabs to the Right"), #selector(closeTabsToRight(_:))),
            (L("모든 탭 닫기", "Close All Tabs"), #selector(closeAllTabs(_:)))
        ] { let item = file.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self }
        file.addItem(.separator())
        file.addItem(withTitle: L("폴더 열기…", "Open Folder…"), action: #selector(BrowserWindow.chooseFolder(_:)), keyEquivalent: "o")
        file.addItem(withTitle: L("선택 항목 열기", "Open Selection"), action: #selector(BrowserWindow.openSelection(_:)), keyEquivalent: "\u{f701}")
        file.addItem(withTitle: L("압축 파일 탐색", "Browse Archive"), action: #selector(BrowserWindow.openArchive(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("선택 항목 압축…", "Compress Selection…"), action: #selector(BrowserWindow.createArchive(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("여기에 압축 해제", "Extract Here"), action: #selector(BrowserWindow.extractArchivesHere(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("여기에 스마트 압축 해제", "Extract Here Smart"), action: #selector(BrowserWindow.extractArchivesSmart(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("각 하위 폴더에 압축 해제", "Extract to Child Folders"), action: #selector(BrowserWindow.extractArchivesToChildFolders(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("데스크탑 배경으로 설정", "Set as Desktop Wallpaper"), action: #selector(BrowserWindow.setAsDesktopWallpaper(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("앱 배경으로 설정", "Set as App Background"), action: #selector(BrowserWindow.setAsAppBackground(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("앱 배경 지우기", "Clear App Background"), action: #selector(BrowserWindow.clearAppBackground(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("왼쪽으로 회전", "Rotate Left"), action: #selector(BrowserWindow.rotateImagesLeft(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("오른쪽으로 회전", "Rotate Right"), action: #selector(BrowserWindow.rotateImagesRight(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("인증서 설치…", "Install Certificate…"), action: #selector(BrowserWindow.installCertificates(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("글꼴 설치…", "Install Font…"), action: #selector(BrowserWindow.installFonts(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("선택 미디어 모두 재생", "Play All Selected Media"), action: #selector(BrowserWindow.playAllMedia(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("포커스 항목 선택 토글", "Toggle Focused Selection"), action: #selector(BrowserWindow.toggleFocusedSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("같은 Finder 태그 항목 찾기", "Find Items with Same Finder Tag"), action: #selector(BrowserWindow.openAllTagged(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Finder 태그 모두 제거", "Remove All Finder Tags"), action: #selector(BrowserWindow.removeTags(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("지금 다운로드", "Download Now"), action: #selector(BrowserWindow.downloadCloudSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("공간 비우기", "Free Up Space"), action: #selector(BrowserWindow.evictCloudSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Finder에서 보기", "Reveal in Finder"), action: #selector(BrowserWindow.revealSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("다른 앱으로 열기…", "Open With…"), action: #selector(BrowserWindow.openWithApplication(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("개발 앱에서 열기", "Open in Developer Application"), action: #selector(BrowserWindow.openInDeveloperApplication(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("TextEdit에서 편집", "Edit in TextEdit"), action: #selector(BrowserWindow.editInTextEdit(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("공유…", "Share…"), action: #selector(BrowserWindow.shareSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("터미널에서 열기", "Open in Terminal"), action: #selector(BrowserWindow.openInTerminal(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("정보 가져오기", "Get Info"), action: #selector(BrowserWindow.showInfo(_:)), keyEquivalent: "i")
        let preview = file.addItem(withTitle: L("훑어보기", "Quick Look"), action: #selector(BrowserWindow.showQuickLook(_:)), keyEquivalent: " ")
        preview.keyEquivalentModifierMask = []
        let folder = file.addItem(withTitle: L("새 폴더…", "New Folder…"), action: #selector(BrowserWindow.createFolder(_:)), keyEquivalent: "n")
        folder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("새 파일…", "New File…"), action: #selector(BrowserWindow.createFile(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("선택 항목으로 새 폴더…", "New Folder with Selection…"), action: #selector(BrowserWindow.createFolderFromSelection(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("대상을 선택해 심볼릭 링크 만들기…", "Create Symbolic Link to Chosen Item…"), action: #selector(BrowserWindow.createSymbolicLinkFromDialog(_:)), keyEquivalent: "")
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
        edit.addItem(withTitle: L("선택 해제", "Clear Selection"), action: #selector(BrowserWindow.clearSelection(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L("선택 반전", "Invert Selection"), action: #selector(BrowserWindow.invertSelection(_:)), keyEquivalent: "")
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
        go.addItem(withTitle: L("열 너비 자동 맞춤", "Auto Fit Columns"), action: #selector(BrowserWindow.autoFitColumns(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("사이드바 표시 전환", "Toggle Sidebar"), action: #selector(BrowserWindow.toggleSidebarVisibility(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("툴바 표시 전환", "Toggle Toolbar"), action: #selector(BrowserWindow.toggleToolbar(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("툴바 사용자 지정…", "Customize Toolbar…"), action: #selector(BrowserWindow.showToolbarSettings(_:)), keyEquivalent: "")
        let sortItem = go.addItem(withTitle: L("정렬", "Sort"), action: nil, keyEquivalent: "")
        let sort = NSMenu(title: sortItem.title); sortItem.submenu = sort
        for (title, action) in [
            (L("이름", "Name"), #selector(BrowserWindow.sortByName(_:))),
            (L("생성일", "Date Created"), #selector(BrowserWindow.sortByCreated(_:))),
            (L("수정일", "Date Modified"), #selector(BrowserWindow.sortByModified(_:))),
            (L("크기", "Size"), #selector(BrowserWindow.sortBySize(_:))),
            (L("종류", "Kind"), #selector(BrowserWindow.sortByKind(_:)))
        ] { sort.addItem(withTitle: title, action: action, keyEquivalent: "") }
        let groupItem = go.addItem(withTitle: L("그룹화", "Group By"), action: nil, keyEquivalent: "")
        let group = NSMenu(title: groupItem.title); groupItem.submenu = group
        for (title, action) in [
            (L("없음", "None"), #selector(BrowserWindow.groupByNone(_:))),
            (L("이름", "Name"), #selector(BrowserWindow.groupByName(_:))),
            (L("생성일", "Date Created"), #selector(BrowserWindow.groupByCreated(_:))),
            (L("수정일", "Date Modified"), #selector(BrowserWindow.groupByModified(_:))),
            (L("크기", "Size"), #selector(BrowserWindow.groupBySize(_:))),
            (L("종류", "Kind"), #selector(BrowserWindow.groupByKind(_:)))
        ] { group.addItem(withTitle: title, action: action, keyEquivalent: "") }
        let modifiedUnit = group.addItem(withTitle: L("수정일 단위", "Modified Date Unit"), action: nil, keyEquivalent: "")
        let units = NSMenu(title: modifiedUnit.title); modifiedUnit.submenu = units
        for (title, action) in [
            (L("연", "Year"), #selector(BrowserWindow.groupByModifiedYear(_:))),
            (L("월", "Month"), #selector(BrowserWindow.groupByModifiedMonth(_:))),
            (L("일", "Day"), #selector(BrowserWindow.groupByModifiedDay(_:))),
            (L("날짜 단위 전환", "Cycle Date Unit"), #selector(BrowserWindow.toggleGroupDateUnit(_:)))
        ] { units.addItem(withTitle: title, action: action, keyEquivalent: "") }
        let createdUnit = group.addItem(withTitle: L("생성일 단위", "Created Date Unit"), action: nil, keyEquivalent: "")
        let createdUnits = NSMenu(title: createdUnit.title); createdUnit.submenu = createdUnits
        for (title, action) in [
            (L("연", "Year"), #selector(BrowserWindow.groupByCreatedYear(_:))),
            (L("월", "Month"), #selector(BrowserWindow.groupByCreatedMonth(_:))),
            (L("일", "Day"), #selector(BrowserWindow.groupByCreatedDay(_:)))
        ] { createdUnits.addItem(withTitle: title, action: action, keyEquivalent: "") }
        group.addItem(.separator())
        for (title, action) in [
            (L("오름차순", "Ascending"), #selector(BrowserWindow.groupAscending(_:))),
            (L("내림차순", "Descending"), #selector(BrowserWindow.groupDescending(_:))),
            (L("그룹 방향 전환", "Toggle Group Direction"), #selector(BrowserWindow.toggleGroupDirection(_:))),
            (L("연 단위", "Group Dates by Year"), #selector(BrowserWindow.groupDateByYear(_:))),
            (L("월 단위", "Group Dates by Month"), #selector(BrowserWindow.groupDateByMonth(_:)))
        ] { group.addItem(withTitle: title, action: action, keyEquivalent: "") }
        sort.addItem(.separator())
        for (title, action) in [
            (L("오름차순", "Ascending"), #selector(BrowserWindow.sortAscending(_:))),
            (L("내림차순", "Descending"), #selector(BrowserWindow.sortDescending(_:))),
            (L("정렬 방향 전환", "Toggle Sort Direction"), #selector(BrowserWindow.toggleSortDirection(_:)))
        ] { sort.addItem(withTitle: title, action: action, keyEquivalent: "") }
        sort.addItem(.separator())
        for (title, action) in [
            (L("폴더 우선", "Folders First"), #selector(BrowserWindow.sortFoldersFirst(_:))),
            (L("파일 우선", "Files First"), #selector(BrowserWindow.sortFilesFirst(_:))),
            (L("파일과 폴더 함께", "Files and Folders Together"), #selector(BrowserWindow.sortMixed(_:)))
        ] { sort.addItem(withTitle: title, action: action, keyEquivalent: "") }
        go.addItem(.separator())
        let splitVertical = go.addItem(withTitle: L("좌우 분할", "Split Vertically"), action: #selector(BrowserWindow.splitVertically(_:)), keyEquivalent: "d")
        splitVertical.keyEquivalentModifierMask = [.command, .option]
        let splitHorizontal = go.addItem(withTitle: L("상하 분할", "Split Horizontally"), action: #selector(BrowserWindow.splitHorizontally(_:)), keyEquivalent: "d")
        splitHorizontal.keyEquivalentModifierMask = [.command, .option, .shift]
        let closeSplit = go.addItem(withTitle: L("보조 pane 닫기", "Close Secondary Pane"), action: #selector(BrowserWindow.closeSecondaryPane(_:)), keyEquivalent: "w")
        closeSplit.keyEquivalentModifierMask = [.command, .option]
        go.addItem(withTitle: L("pane 방향을 좌우로", "Arrange Panes Side by Side"), action: #selector(BrowserWindow.arrangePanesVertically(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("pane 방향을 상하로", "Arrange Panes Top and Bottom"), action: #selector(BrowserWindow.arrangePanesHorizontally(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("다른 pane에 초점", "Focus Other Pane"), action: #selector(BrowserWindow.focusOtherPane(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("현재 폴더를 다른 pane에서 열기", "Open Current Folder in Other Pane"), action: #selector(BrowserWindow.openCurrentFolderInOtherPane(_:)), keyEquivalent: "")
        go.addItem(withTitle: L("dual pane 전환", "Toggle Dual Pane"), action: #selector(BrowserWindow.toggleDualPane(_:)), keyEquivalent: "")
        go.addItem(.separator())
        let fullScreen = go.addItem(withTitle: L("전체 화면 전환", "Toggle Full Screen"), action: #selector(BrowserWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
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
    var qaSFTPTrustEnabled: Bool { remoteConnectionsWindow?.qaSFTPTrustEnabled() == true }
    var qaSFTPIdentityEnabled: Bool { remoteConnectionsWindow?.qaSFTPIdentityEnabled() == true }
    var qaSFTPConnectDisabled: Bool { remoteConnectionsWindow?.qaSFTPConnectDisabledWithoutTrustAndIdentity == true }
    var qaSFTPDownloadDisabled: Bool { remoteConnectionsWindow?.qaSFTPDownloadDisabledWithoutTrustAndIdentity == true }
    var qaFTPConnectDisabled: Bool { remoteConnectionsWindow?.qaFTPConnectDisabledWithoutCredential == true }
    var qaReleaseInfoVisible: Bool { releaseInfoWindow?.qaVisible == true }
    var qaReleaseInfoText: String { releaseInfoWindow?.qaText ?? "" }
    var qaReleaseInfoContentView: NSView? { releaseInfoWindow?.window?.contentView }
    var qaAdvancedSettingsVisible: Bool { advancedSettingsWindow?.qaVisible == true }
    var qaAdvancedSettingsContentView: NSView? { advancedSettingsWindow?.window?.contentView }
    var qaGeneralSettingsVisible: Bool { generalSettingsWindow?.qaVisible == true }
    var qaGeneralSettingsContentView: NSView? { generalSettingsWindow?.window?.contentView }
    var qaGeneralWidgetStates: (Bool, Bool, Bool)? { generalSettingsWindow?.qaWidgetStates }
    func qaToggleGeneralWidgets() { generalSettingsWindow?.qaToggleWidgets() }
    var qaGeneralSizeUnit: BrowserSizeUnit? { generalSettingsWindow?.qaSizeUnit }
    func qaToggleGeneralSizeUnit() { generalSettingsWindow?.qaToggleSizeUnit() }
    var qaGeneralOpenFoldersInNewTab: Bool? { generalSettingsWindow?.qaOpenFoldersInNewTab }
    func qaToggleGeneralOpenFoldersInNewTab() { generalSettingsWindow?.qaToggleOpenFoldersInNewTab() }
    var qaGeneralScrollToPreviousFolderOnUp: Bool? { generalSettingsWindow?.qaScrollToPreviousFolderOnUp }
    func qaToggleGeneralScrollToPreviousFolderOnUp() { generalSettingsWindow?.qaToggleScrollToPreviousFolderOnUp() }
    var qaGeneralShowFileExtensionWarning: Bool? { generalSettingsWindow?.qaShowFileExtensionWarning }
    func qaToggleGeneralShowFileExtensionWarning() { generalSettingsWindow?.qaToggleShowFileExtensionWarning() }
    var qaGeneralContextMenuStates: [Bool]? { generalSettingsWindow?.qaContextMenuStates }
    func qaToggleGeneralContextMenuItems() { generalSettingsWindow?.qaToggleContextMenuItems() }
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
