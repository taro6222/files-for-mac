import AppKit
import UniformTypeIdentifiers
import FilesCore

@MainActor
final class AdvancedSettingsWindow: NSWindowController {
    private let preferences: BrowserPreferences
    private let status = NSTextField(wrappingLabelWithString: "")

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("고급 설정", "Advanced Settings"); panel.isReleasedWhenClosed = false
        guard let content = panel.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L("설정 백업", "Settings Backup")); title.font = .systemFont(ofSize: 15, weight: .semibold); stack.addArrangedSubview(title)
        let note = NSTextField(wrappingLabelWithString: L("현재 탐색·외형·툴바·폴더별 보기 설정을 버전이 지정된 JSON으로 내보내거나 가져옵니다. 가져오기 전에 전체 파일을 검증하며 실패하면 현재 설정을 변경하지 않습니다.", "Export or import current navigation, appearance, toolbar, and per-folder view settings as versioned JSON. The whole file is validated before import; failures leave current settings unchanged.")); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        controls.addArrangedSubview(NSButton(title: L("설정 내보내기…", "Export Settings…"), target: self, action: #selector(exportSettings(_:))))
        controls.addArrangedSubview(NSButton(title: L("설정 가져오기…", "Import Settings…"), target: self, action: #selector(importSettings(_:))))
        stack.addArrangedSubview(controls); status.textColor = .secondaryLabelColor; stack.addArrangedSubview(status)
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() { status.stringValue = ""; window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    @objc private func exportSettings(_ sender: Any?) {
        guard let window else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "FilesMac-Settings.json"; panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.preferences.exportData().write(to: url, options: .atomic); self.status.stringValue = L("설정을 내보냈습니다.", "Settings exported.") }
            catch { self.status.stringValue = L("설정을 내보내지 못했습니다: ", "Unable to export settings: ") + error.localizedDescription }
        }
    }
    @objc private func importSettings(_ sender: Any?) {
        guard let window else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.preferences.importData(Data(contentsOf: url)); self.status.stringValue = L("설정을 가져왔습니다.", "Settings imported.") }
            catch { self.status.stringValue = L("설정 파일이 유효하지 않아 변경하지 않았습니다.", "The settings file is invalid; no settings were changed.") }
        }
    }
#if DEBUG
    var qaVisible: Bool { window?.isVisible == true }
#endif
}
