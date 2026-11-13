import AppKit
import FilesCore

@MainActor
final class GitCloneWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private static var activeCount = 0
    static var isRunning: Bool { activeCount > 0 }
    private let provider: GitProvider
    private let onComplete: (URL) -> Void
    private var task: Task<Void, Never>?
    private let sourceField = NSTextField(), destinationField = NSTextField(), statusLabel = NSTextField(wrappingLabelWithString: "")
    private let chooseButton = NSButton(), cloneButton = NSButton(), cancelButton = NSButton()

    init(provider: GitProvider = .init(), onComplete: @escaping (URL) -> Void) {
        self.provider = provider; self.onComplete = onComplete
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("Git 저장소 복제", "Clone Git Repository"); panel.isReleasedWhenClosed = false; panel.delegate = self
        buildUI(); updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16); root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root); NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        sourceField.placeholderString = "https://, ssh://, file:///"; sourceField.setAccessibilityLabel(L("Git 원격 주소", "Git source URL"))
        sourceField.delegate = self; destinationField.delegate = self
        addRow(label: L("원본", "Source"), view: sourceField, to: root)
        let destinationRow = NSStackView(); destinationRow.orientation = .horizontal; destinationRow.spacing = 8; destinationRow.addArrangedSubview(destinationField)
        chooseButton.title = L("선택…", "Choose…"); chooseButton.target = self; chooseButton.action = #selector(chooseDestination(_:)); destinationRow.addArrangedSubview(chooseButton)
        destinationField.setAccessibilityLabel(L("복제 대상 폴더", "Clone destination folder")); addRow(label: L("대상", "Destination"), view: destinationRow, to: root)
        statusLabel.textColor = .secondaryLabelColor; statusLabel.setAccessibilityLabel(L("Git 복제 상태", "Git clone status")); root.addArrangedSubview(statusLabel)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8; controls.addArrangedSubview(NSView())
        cancelButton.title = L("중단", "Stop"); cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); controls.addArrangedSubview(cancelButton)
        cloneButton.title = L("복제", "Clone"); cloneButton.target = self; cloneButton.action = #selector(startClone(_:)); cloneButton.keyEquivalent = "\r"; controls.addArrangedSubview(cloneButton); root.addArrangedSubview(controls)
    }
    private func addRow(label: String, view: NSView, to root: NSStackView) {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
        let title = NSTextField(labelWithString: label); title.alignment = .right; title.widthAnchor.constraint(equalToConstant: 72).isActive = true
        row.addArrangedSubview(title); row.addArrangedSubview(view); root.addArrangedSubview(row)
    }
    func present() { statusLabel.stringValue = ""; window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); updateControls() }
    func windowWillClose(_ notification: Notification) { task?.cancel() }
    func controlTextDidChange(_ notification: Notification) { updateControls() }

    @objc private func chooseDestination(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.nameFieldLabel = L("폴더 이름:", "Folder name:"); panel.message = L("복제할 새 폴더의 위치와 이름을 선택하세요.", "Choose the location and name of the new clone folder.")
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.destinationField.stringValue = url.path; self?.updateControls() } }
    }
    @objc private func startClone(_ sender: Any?) {
        guard task == nil, let source = sourceURL(), !destinationField.stringValue.isEmpty else { return }
        let destination = URL(fileURLWithPath: destinationField.stringValue).standardizedFileURL
        statusLabel.stringValue = L("저장소를 staging 폴더에 복제하는 중…", "Cloning into a staging folder…")
        Self.activeCount += 1
        task = Task { [weak self] in
            guard let self else { return }
            defer { Self.activeCount -= 1; task = nil; updateControls() }
            do {
                let result = try await provider.clone(from: source, to: destination)
                statusLabel.stringValue = L("복제가 완료되었습니다.", "Clone completed."); onComplete(result)
            } catch is CancellationError { statusLabel.stringValue = L("복제가 중단되었으며 staging 파일을 정리했습니다.", "Clone cancelled and staging files were removed.") }
            catch { statusLabel.stringValue = errorText(error) }
        }
        updateControls()
    }
    @objc private func cancel(_ sender: Any?) { task?.cancel() }
    private func sourceURL() -> URL? {
        let value = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        guard let url = URL(string: value), url.scheme != nil else { return nil }
        return url
    }
    private func updateControls() {
        let running = task != nil
        sourceField.isEnabled = !running; destinationField.isEnabled = !running; chooseButton.isEnabled = !running
        cloneButton.isEnabled = !running && sourceURL() != nil && !destinationField.stringValue.isEmpty; cancelButton.isEnabled = running
    }
    private func errorText(_ error: Error) -> String {
        if error as? GitBackendError == .invalidLocation { return L("원본 주소 또는 대상 폴더가 올바르지 않거나 대상이 이미 존재합니다.", "The source or destination is invalid, or the destination already exists.") }
        return L("Git 복제에 실패했습니다: ", "Git clone failed: ") + String(describing: error)
    }
#if DEBUG
    func qaClone(source: URL, destination: URL) { sourceField.stringValue = source.absoluteString; destinationField.stringValue = destination.path; updateControls(); startClone(nil) }
    var qaRunning: Bool { task != nil }
    var qaSucceeded: Bool { task == nil && statusLabel.stringValue == L("복제가 완료되었습니다.", "Clone completed.") }
    var qaAccessibilityReady: Bool { sourceField.accessibilityLabel() != nil && destinationField.accessibilityLabel() != nil && statusLabel.accessibilityLabel() != nil }
#endif
}
