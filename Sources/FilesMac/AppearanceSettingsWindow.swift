import AppKit
import FilesCore

@MainActor
final class AppearanceSettingsWindow: NSWindowController {
    private let preferences: BrowserPreferences
    private let picker = NSPopUpButton()
    private let shelfToggle = NSButton(checkboxWithTitle: L("툴바에 임시 모음 버튼 표시", "Show Shelf Button in Toolbar"), target: nil, action: nil)
    private let continueSession = NSButton(checkboxWithTitle: L("마지막 세션 계속", "Continue Last Session"), target: nil, action: nil)
    private let folderSummary = NSTextField(labelWithString: "")
    private let resetFolders = NSButton()
    private let backgroundSummary = NSTextField(labelWithString: "")
    private let clearBackground = NSButton()
    private let backgroundFit = NSPopUpButton()
    private let backgroundHorizontal = NSPopUpButton()
    private let backgroundVertical = NSPopUpButton()
    private let backgroundOpacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 590),
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
        shelfToggle.target = self
        shelfToggle.action = #selector(changeShelfToggle)
        stack.addArrangedSubview(shelfToggle)
        backgroundSummary.textColor = .secondaryLabelColor; stack.addArrangedSubview(backgroundSummary)
        let presentationTitle = NSTextField(labelWithString: L("배경 이미지 표시", "Background Image Presentation")); presentationTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(presentationTitle)
        backgroundFit.addItems(withTitles: [L("영역 채우기", "Fill"), L("전체 이미지 맞춤", "Fit"), L("영역에 늘이기", "Stretch")])
        backgroundHorizontal.addItems(withTitles: [L("왼쪽", "Left"), L("가운데", "Center"), L("오른쪽", "Right")])
        backgroundVertical.addItems(withTitles: [L("아래", "Bottom"), L("가운데", "Center"), L("위", "Top")])
        for popup in [backgroundFit, backgroundHorizontal, backgroundVertical] { popup.target = self; popup.action = #selector(changeBackgroundPresentation(_:)); stack.addArrangedSubview(popup) }
        let opacityRow = NSStackView(); opacityRow.orientation = .horizontal; opacityRow.spacing = 8
        opacityRow.addArrangedSubview(NSTextField(labelWithString: L("불투명도", "Opacity"))); backgroundOpacity.target = self; backgroundOpacity.action = #selector(changeBackgroundPresentation(_:)); opacityRow.addArrangedSubview(backgroundOpacity); stack.addArrangedSubview(opacityRow)
        clearBackground.title = L("사용자 지정 앱 배경 지우기", "Clear Custom App Background"); clearBackground.target = self; clearBackground.action = #selector(clearAppBackground(_:)); stack.addArrangedSubview(clearBackground)
        continueSession.target = self; continueSession.action = #selector(changeContinueSession(_:)); continueSession.setAccessibilityLabel(L("마지막 세션 계속", "Continue Last Session")); stack.addArrangedSubview(continueSession)
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        let folderTitle = NSTextField(labelWithString: L("폴더별 보기", "Per-folder views")); folderTitle.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(folderTitle)
        folderSummary.textColor = .secondaryLabelColor; stack.addArrangedSubview(folderSummary)
        resetFolders.title = L("모든 폴더별 보기 초기화", "Reset All Per-folder Views"); resetFolders.target = self; resetFolders.action = #selector(resetFolderViews(_:)); stack.addArrangedSubview(resetFolders)
    }
    func present() { sync(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    private func sync() {
        picker.selectItem(at: BrowserAppearance.allCases.firstIndex(of: preferences.appearance) ?? 0)
        continueSession.state = preferences.continueLastSession ? .on : .off
        shelfToggle.state = preferences.showShelfToggle ? .on : .off
        backgroundSummary.stringValue = preferences.appBackgroundPath == nil ? L("사용자 지정 앱 배경 없음", "No custom app background") : L("사용자 지정 앱 배경 사용 중", "Using a custom app background")
        clearBackground.isEnabled = preferences.appBackgroundPath != nil
        backgroundFit.selectItem(at: AppBackgroundFit.allCases.firstIndex(of: preferences.appBackgroundFit) ?? 0)
        backgroundHorizontal.selectItem(at: AppBackgroundHorizontalAlignment.allCases.firstIndex(of: preferences.appBackgroundHorizontalAlignment) ?? 1)
        backgroundVertical.selectItem(at: AppBackgroundVerticalAlignment.allCases.firstIndex(of: preferences.appBackgroundVerticalAlignment) ?? 1)
        backgroundOpacity.doubleValue = preferences.appBackgroundOpacity
        for control in [backgroundFit, backgroundHorizontal, backgroundVertical] { control.isEnabled = preferences.appBackgroundPath != nil }
        backgroundOpacity.isEnabled = preferences.appBackgroundPath != nil
        let count = preferences.folderViewPreferences.count
        folderSummary.stringValue = L("저장된 폴더 설정: \(count)개", "Saved folder settings: \(count)")
        resetFolders.isEnabled = count > 0
    }
    @objc private func changeAppearance(_ sender: Any?) {
        guard BrowserAppearance.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        preferences.setAppearance(BrowserAppearance.allCases[picker.indexOfSelectedItem])
    }
    @objc private func changeContinueSession(_ sender: Any?) { preferences.setContinueLastSession(continueSession.state == .on) }
    @objc private func changeShelfToggle() { preferences.setShowShelfToggle(shelfToggle.state == .on) }
    @objc private func resetFolderViews(_ sender: Any?) { preferences.resetFolderViewPreferences(); sync() }
    @objc private func clearAppBackground(_ sender: Any?) { preferences.setAppBackground(nil); let store = AppBackgroundStore(); Task.detached { try? store.remove() }; sync() }
    @objc private func changeBackgroundPresentation(_ sender: Any?) {
        preferences.setAppBackgroundPresentation(
            fit: AppBackgroundFit.allCases[max(0, backgroundFit.indexOfSelectedItem)], opacity: backgroundOpacity.doubleValue,
            horizontal: AppBackgroundHorizontalAlignment.allCases[max(0, backgroundHorizontal.indexOfSelectedItem)],
            vertical: AppBackgroundVerticalAlignment.allCases[max(0, backgroundVertical.indexOfSelectedItem)])
    }
#if DEBUG
    var qaSelection: BrowserAppearance { preferences.appearance }
    func qaSelect(_ appearance: BrowserAppearance) { picker.selectItem(at: BrowserAppearance.allCases.firstIndex(of: appearance) ?? 0); changeAppearance(nil) }
    func qaResetFolderViews() { resetFolderViews(nil) }
    var qaFolderCount: Int { preferences.folderViewPreferences.count }
    func qaSetContinueLastSession(_ value: Bool) { continueSession.state = value ? .on : .off; changeContinueSession(nil) }
    func qaClearAppBackground() { clearAppBackground(nil) }
    var qaBackgroundPresentation: (AppBackgroundFit, Double, AppBackgroundHorizontalAlignment, AppBackgroundVerticalAlignment) {
        (preferences.appBackgroundFit, preferences.appBackgroundOpacity, preferences.appBackgroundHorizontalAlignment, preferences.appBackgroundVerticalAlignment)
    }
    func qaChangeBackgroundPresentation() {
        backgroundFit.selectItem(at: 1); backgroundHorizontal.selectItem(at: 2); backgroundVertical.selectItem(at: 2); backgroundOpacity.doubleValue = 0.45
        changeBackgroundPresentation(nil)
    }
#endif
}
