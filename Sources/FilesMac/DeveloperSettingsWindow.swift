import AppKit
import UniformTypeIdentifiers
import FilesCore

@MainActor
final class DeveloperSettingsWindow: NSWindowController {
    private let preferences: BrowserPreferences
    private let selectedApp = NSTextField(wrappingLabelWithString: "")

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 230),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("개발자 도구", "Developer Tools"); panel.isReleasedWhenClosed = false
        guard let content = panel.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L("폴더를 열 개발 앱", "Developer Application for Folders")); title.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(title)
        let note = NSTextField(wrappingLabelWithString: L("선택한 앱은 ‘개발 앱에서 열기’ 명령에 사용됩니다. 경로는 로컬 설정에만 저장됩니다.", "The selected app is used by Open in Developer Application. Its path is stored only in local preferences.")); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        stack.addArrangedSubview(selectedApp)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        controls.addArrangedSubview(NSButton(title: L("앱 선택…", "Choose Application…"), target: self, action: #selector(choose(_:))))
        controls.addArrangedSubview(NSButton(title: L("선택 해제", "Clear Selection"), target: self, action: #selector(clear(_:))))
        stack.addArrangedSubview(controls); content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() { sync(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    private func sync() { selectedApp.stringValue = preferences.developerApplicationPath ?? L("선택된 앱 없음", "No application selected") }
    @objc private func choose(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.title = L("개발 앱 선택", "Choose Developer Application")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in guard response == .OK else { return }; self?.preferences.setDeveloperApplication(panel.url); self?.sync() }
    }
    @objc private func clear(_ sender: Any?) { preferences.setDeveloperApplication(nil); sync() }
#if DEBUG
    var qaSelectedPath: String? { preferences.developerApplicationPath }
#endif
}
