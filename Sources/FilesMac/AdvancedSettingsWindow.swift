import AppKit
import UniformTypeIdentifiers
import FilesCore

@MainActor
final class AdvancedSettingsWindow: NSWindowController {
    private let preferences: BrowserPreferences
    private let enableCache = NSButton(checkboxWithTitle: L("파일 미리보기 캐시 사용", "Cache File Previews"), target: nil, action: nil)
    private let cacheLimit = NSPopUpButton()
    private let clearCache = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(preferences: BrowserPreferences) {
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
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
        let cacheTitle = NSTextField(labelWithString: L("파일 미리보기 캐시", "File Preview Cache"))
        cacheTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(cacheTitle)
        enableCache.target = self
        enableCache.action = #selector(changeCacheEnabled(_:))
        stack.addArrangedSubview(enableCache)
        cacheLimit.addItems(withTitles: BrowserPreferences.thumbnailCacheLimits.map { "\($0) MiB" })
        cacheLimit.setAccessibilityLabel(L("미리보기 캐시 메모리 한도", "Preview Cache Memory Limit"))
        cacheLimit.target = self
        cacheLimit.action = #selector(changeCacheLimit(_:))
        clearCache.title = L("캐시 비우기", "Clear Cache")
        clearCache.bezelStyle = .rounded
        clearCache.target = self
        clearCache.action = #selector(clearPreviewCache(_:))
        let cacheControls = NSStackView(views: [
            NSTextField(labelWithString: L("메모리 한도", "Memory Limit")), cacheLimit, clearCache
        ])
        cacheControls.orientation = .horizontal
        stack.addArrangedSubview(cacheControls)
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        status.stringValue = ""
        syncCacheControls()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func syncCacheControls() {
        enableCache.state = preferences.enableThumbnailCache ? .on : .off
        cacheLimit.selectItem(at: BrowserPreferences.thumbnailCacheLimits.firstIndex(of: preferences.thumbnailCacheLimitMiB) ?? 0)
        cacheLimit.isEnabled = preferences.enableThumbnailCache
        clearCache.isEnabled = preferences.enableThumbnailCache
    }

    @objc private func changeCacheEnabled(_ sender: Any?) {
        preferences.setEnableThumbnailCache(enableCache.state == .on)
        syncCacheControls()
    }

    @objc private func changeCacheLimit(_ sender: Any?) {
        let limits = BrowserPreferences.thumbnailCacheLimits
        guard limits.indices.contains(cacheLimit.indexOfSelectedItem) else { return }
        preferences.setThumbnailCacheLimitMiB(limits[cacheLimit.indexOfSelectedItem])
    }

    @objc private func clearPreviewCache(_ sender: Any?) {
        FileIconCache.shared.removeAll()
        status.stringValue = L("미리보기 캐시를 비웠습니다.", "Preview cache cleared.")
    }
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
            do { try self.preferences.importData(Data(contentsOf: url)); self.syncCacheControls(); self.status.stringValue = L("설정을 가져왔습니다.", "Settings imported.") }
            catch { self.status.stringValue = L("설정 파일이 유효하지 않아 변경하지 않았습니다.", "The settings file is invalid; no settings were changed.") }
        }
    }
#if DEBUG
    var qaVisible: Bool { window?.isVisible == true }
#endif
}
