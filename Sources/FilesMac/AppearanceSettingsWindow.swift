import AppKit
import FilesCore

@MainActor
final class AppearanceSettingsWindow: NSWindowController {
    private let preferences: BrowserPreferences
    private let picker = NSPopUpButton()
    private let folderSummary = NSTextField(labelWithString: "")
    private let resetFolders = NSButton()

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = L("외형", "Appearance")
        panel.isReleasedWhenClosed = false
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let title = NSTextField(labelWithString: L("앱 테마", "App theme")); title.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(title)
        picker.addItems(withTitles: [L("시스템 설정 사용", "Use System Setting"), L("밝게", "Light"), L("어둡게", "Dark")])
        picker.target = self; picker.action = #selector(changeAppearance(_:)); picker.setAccessibilityLabel(L("앱 테마", "App theme")); stack.addArrangedSubview(picker)
        let material = NSTextField(wrappingLabelWithString: L("사이드바는 macOS 재질을 사용하며 대비 증가 및 투명도 감소 접근성 설정을 자동으로 따릅니다.", "The sidebar uses macOS material and automatically follows Increase Contrast and Reduce Transparency accessibility settings."))
        material.textColor = .secondaryLabelColor; stack.addArrangedSubview(material)
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        let folderTitle = NSTextField(labelWithString: L("폴더별 보기", "Per-folder views")); folderTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(folderTitle)
        folderSummary.textColor = .secondaryLabelColor; stack.addArrangedSubview(folderSummary)
        resetFolders.title = L("모든 폴더별 보기 초기화", "Reset All Per-folder Views"); resetFolders.target = self; resetFolders.action = #selector(resetFolderViews(_:)); stack.addArrangedSubview(resetFolders)
    }
    func present() { sync(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    private func sync() {
        picker.selectItem(at: BrowserAppearance.allCases.firstIndex(of: preferences.appearance) ?? 0)
        let count = preferences.folderViewPreferences.count
        folderSummary.stringValue = L("저장된 폴더 설정: \(count)개", "Saved folder settings: \(count)")
        resetFolders.isEnabled = count > 0
    }
    @objc private func changeAppearance(_ sender: Any?) {
        guard BrowserAppearance.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        preferences.setAppearance(BrowserAppearance.allCases[picker.indexOfSelectedItem])
    }
    @objc private func resetFolderViews(_ sender: Any?) { preferences.resetFolderViewPreferences(); sync() }
#if DEBUG
    var qaSelection: BrowserAppearance { preferences.appearance }
    func qaSelect(_ appearance: BrowserAppearance) { picker.selectItem(at: BrowserAppearance.allCases.firstIndex(of: appearance) ?? 0); changeAppearance(nil) }
    func qaResetFolderViews() { resetFolderViews(nil) }
    var qaFolderCount: Int { preferences.folderViewPreferences.count }
#endif
}
