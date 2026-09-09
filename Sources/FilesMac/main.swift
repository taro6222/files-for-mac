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
        file.addItem(withTitle: L("창 닫기", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(); editItem.title = L("편집", "Edit"); menu.addItem(editItem)
        let edit = NSMenu(title: editItem.title); editItem.submenu = edit
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
