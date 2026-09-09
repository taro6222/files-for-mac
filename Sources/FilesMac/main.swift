import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [BrowserWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["FILES_UI_QA_OUTPUT"] {
            Task { @MainActor in await BrowserWindow.runUIVerification(output: output) }
            return
        }
        #endif
        newWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func newWindow(_ sender: Any?) {
        let controller = BrowserWindow()
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CopyWindow.isRunning || DeletionWindow.isRunning || RestoreWindow.isRunning || MoveWindow.isRunning ||
              PermanentDeleteWindow.isRunning || BrowserWindow.entryOperationRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("파일 작업이 진행 중입니다", "A file operation is running")
        alert.informativeText = L("작업 완료 후 종료하세요. 복사는 복사 창에서 취소할 수 있습니다.", "Quit after the operation finishes. Copies can be cancelled in the copy window.")
        alert.runModal()
        return .terminateCancel
    }
    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("Files macOS 종료", "Quit Files macOS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); fileItem.title = L("파일", "File"); menu.addItem(fileItem)
        let file = NSMenu(title: fileItem.title); fileItem.submenu = file
        let new = file.addItem(withTitle: L("새 창", "New Window"), action: #selector(newWindow(_:)), keyEquivalent: "n"); new.target = self
        file.addItem(withTitle: L("폴더 열기…", "Open Folder…"), action: #selector(BrowserWindow.chooseFolder(_:)), keyEquivalent: "o")
        file.addItem(withTitle: L("선택 항목 열기", "Open Selection"), action: #selector(BrowserWindow.openSelection(_:)), keyEquivalent: "\u{f701}")
        let folder = file.addItem(withTitle: L("새 폴더…", "New Folder…"), action: #selector(BrowserWindow.createFolder(_:)), keyEquivalent: "n")
        folder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("이름 변경…", "Rename…"), action: #selector(BrowserWindow.renameSelection(_:)), keyEquivalent: "")
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
        edit.addItem(.separator())
        edit.addItem(withTitle: L("복사", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("붙여넣기", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("모두 선택", "Select All"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
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
        go.addItem(withTitle: L("보기 옵션…", "View Options…"), action: #selector(BrowserWindow.openViewOptions(_:)), keyEquivalent: ",")
        NSApp.mainMenu = menu
    }
}

func L(_ ko: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("ko") == true ? ko : en
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
