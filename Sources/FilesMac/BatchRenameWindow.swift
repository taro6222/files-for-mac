import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class BatchRenameWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [BatchRenameWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private var running = true
    private let label = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextView()
    private let closeButton = NSButton(title: L("닫기", "Close"), target: nil, action: #selector(closeWindow(_:)))

    static func start(requests: [BatchRenameRequest], completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        let controller = BatchRenameWindow(requests: requests)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
        Task {
            do { controller.finish(try await EntryOperations.batchRename(requests, journalDirectory: journals)) }
            catch { controller.fail(error) }
            completion()
        }
    }

    private init(requests: [BatchRenameRequest]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = L("일괄 이름 변경", "Batch Rename")
        window.delegate = self; window.center(); window.minSize = NSSize(width: 560, height: 300)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        label.stringValue = L("이름 변경 계획을 검사하는 중…", "Checking rename plan…"); stack.addArrangedSubview(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.string = requests.map { $0.source.lastPathComponent + " → " + $0.name }.joined(separator: "\n")
        scroll.documentView = details; stack.addArrangedSubview(scroll)
        closeButton.target = self; closeButton.isEnabled = false; stack.addArrangedSubview(closeButton)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func finish(_ report: BatchRenameResult) {
        running = false
        let completed = report.items.filter { $0.state == "completed" || $0.state == "unchanged" }.count
        switch report.state {
        case "completed":
            label.stringValue = L("일괄 이름 변경 완료", "Batch rename complete") + " · \(completed)/\(report.items.count)"
        case "failed":
            label.stringValue = L("일괄 이름 변경 중단", "Batch rename stopped") + " · \(completed)/\(report.items.count)"
        default:
            label.stringValue = L("이름 변경 계획을 적용하지 않았습니다", "Rename plan was not applied")
        }
        details.string = report.items.map { item in
            let state: String
            switch item.state {
            case "completed": state = L("완료", "Done")
            case "unchanged": state = L("변경 없음", "Unchanged")
            case "conflict": state = L("충돌", "Conflict")
            case "invalid": state = L("잘못된 이름", "Invalid")
            case "notFound": state = L("원본 없음", "Missing")
            default: state = L("실패", "Failed")
            }
            return "[\(state)] \(item.source.lastPathComponent) → \(item.target.lastPathComponent)" +
                (item.message.map { "\n  " + $0 } ?? "")
        }.joined(separator: "\n\n")
        if let error = report.journalError { details.string += "\n\n" + L("저널 저장 오류: ", "Journal error: ") + error }
        closeButton.isEnabled = true
    }
    private func fail(_ error: Error) { running = false; label.stringValue = L("일괄 이름 변경 실패", "Batch rename failed"); details.string = error.localizedDescription; closeButton.isEnabled = true }
    @objc private func closeWindow(_ sender: Any?) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !running }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
}

/// Keeps the input sheet open until its mode-specific values can produce a preview.
@MainActor
final class BatchRenameInputForm: NSObject, NSTextFieldDelegate {
    let stack = NSStackView()
    let mode = NSPopUpButton()
    let first = NSTextField()
    let second = NSTextField()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private weak var preview: NSButton?
    private let sourceCount: Int
    var isValid: Bool { validationIssue == nil }

    init(sourceCount: Int, preview: NSButton) {
        self.sourceCount = sourceCount; self.preview = preview
        super.init()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: 144)
        mode.addItems(withTitles: [L("찾기 및 바꾸기", "Find and Replace"), L("번호 매기기", "Numbering"), L("정규식", "Regular Expression")])
        mode.target = self; mode.action = #selector(modeChanged)
        first.placeholderString = L("찾을 문자열 / 기본 이름 / 정규식", "Find text / Base name / Regular expression")
        second.placeholderString = L("바꿀 문자열 / 시작 번호 / 치환식", "Replacement / Start number / Replacement template")
        first.setAccessibilityLabel(first.placeholderString); second.setAccessibilityLabel(second.placeholderString)
        first.delegate = self; second.delegate = self
        explanation.font = .systemFont(ofSize: 12); explanation.setAccessibilityLabel(L("입력 상태", "Input status"))
        for view in [mode, first, second, explanation] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        updateValidation()
    }
    private var validationIssue: String? {
        guard !first.stringValue.isEmpty else {
            switch mode.indexOfSelectedItem {
            case 1: return L("번호를 붙일 기본 이름을 입력하세요.", "Enter the base name for numbering.")
            case 2: return L("정규식을 입력하세요.", "Enter a regular expression.")
            default: return L("찾을 문자열을 입력하세요.", "Enter the text to find.")
            }
        }
        switch mode.indexOfSelectedItem {
        case 1:
            guard !first.stringValue.contains("/"), !first.stringValue.contains("\0") else {
                return L("기본 이름에 / 또는 NUL 문자를 사용할 수 없습니다.", "The base name cannot contain / or NUL characters.")
            }
            let number = second.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = number.isEmpty ? 1 : Int(number), start >= 0,
                  sourceCount > 0, start <= Int.max - (sourceCount - 1) else {
                return L("선택한 항목에 사용할 수 있는 시작 번호를 입력하세요.", "Enter a starting number that fits the selected items.")
            }
        case 2:
            do { _ = try NSRegularExpression(pattern: first.stringValue) }
            catch { return L("정규식을 해석할 수 없습니다. 식을 확인하세요.", "The regular expression is invalid. Check the pattern.") }
        default: break
        }
        return nil
    }
    @objc private func modeChanged() { updateValidation() }
    func controlTextDidChange(_ notification: Notification) { updateValidation() }
    private func updateValidation() {
        let issue = validationIssue
        preview?.isEnabled = issue == nil
        explanation.stringValue = issue ?? L("미리보기에서 변경될 이름과 충돌을 확인하세요.", "Review the resulting names and conflicts in the preview.")
    }
#if DEBUG
    static func verify(parent: NSWindow, output: URL) async -> [String: Bool] {
        guard parent.attachedSheet == nil else { return ["inputSheetAvailable": false] }
        let alert = NSAlert(); alert.messageText = L("일괄 이름 변경", "Batch Rename")
        alert.addButton(withTitle: L("미리보기", "Preview")); alert.addButton(withTitle: L("취소", "Cancel"))
        let form = BatchRenameInputForm(sourceCount: 5, preview: alert.buttons[0])
        alert.accessoryView = form.stack; alert.window.initialFirstResponder = form.first
        alert.beginSheetModal(for: parent) { _ in }
        try? await Task.sleep(for: .milliseconds(40))
        var checks = ["inputSheetVisible": alert.window.isVisible && alert.window.sheetParent === parent]
        func sample(_ name: String) -> Bool {
            let view = alert.window.contentView!
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                    context.setBlendMode(.destinationOver); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            do { try png.write(to: output.appendingPathComponent("batch-input-" + name + ".png")); return true }
            catch { return false }
        }
        checks["emptyInputDisablesPreview"] = !alert.buttons[0].isEnabled && !form.isValid && !form.explanation.stringValue.isEmpty
        checks["emptyInputCapture"] = sample("empty")
        form.mode.selectItem(at: 1); form.first.stringValue = "RenamedReference"; form.second.stringValue = "not-a-number"
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.second))
        checks["invalidNumberDisablesPreview"] = !alert.buttons[0].isEnabled && !form.isValid
        checks["invalidNumberCapture"] = sample("invalid-number")
        form.second.stringValue = String(Int.max); form.updateValidation()
        checks["overflowNumberDisablesPreview"] = !alert.buttons[0].isEnabled && !form.isValid
        form.first.stringValue = "invalid/name"; form.second.stringValue = "1"; form.updateValidation()
        checks["invalidBaseDisablesPreview"] = !alert.buttons[0].isEnabled && !form.isValid
        form.mode.selectItem(at: 2); form.first.stringValue = "["; form.modeChanged()
        checks["invalidRegexDisablesPreview"] = !alert.buttons[0].isEnabled && !form.isValid
        checks["invalidRegexCapture"] = sample("invalid-regex")
        form.first.stringValue = "^(.+)$"; form.second.stringValue = "$1"; form.updateValidation()
        checks["validRegexEnablesPreview"] = alert.buttons[0].isEnabled && form.isValid
        form.mode.selectItem(at: 1); form.first.stringValue = "RenamedReference"; form.second.stringValue = "1"; form.modeChanged()
        checks["validNumberEnablesPreview"] = alert.buttons[0].isEnabled && form.isValid
        checks["validInputCapture"] = sample("valid")
        alert.buttons[1].performClick(nil)
        try? await Task.sleep(for: .milliseconds(40))
        checks["cancelClosesInputSheet"] = parent.attachedSheet == nil
        return checks
    }
#endif
}
