import AppKit
import FilesCore

@MainActor
final class FolderFilterField: NSSearchField, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        let title = L("현재 폴더 이름 필터", "Filter Names in This Folder")
        placeholderString = title
        setAccessibilityLabel(title)
        sendsSearchStringImmediately = true
        delegate = self
        target = self
        action = #selector(submit)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ notification: Notification) { submit() }

    @objc private func submit() { onChange?(stringValue) }

    func synchronize(with model: BrowserModel, visible: Bool) {
        isHidden = !visible || model.location == nil
        if stringValue != model.nameFilter { stringValue = model.nameFilter }
    }
}
