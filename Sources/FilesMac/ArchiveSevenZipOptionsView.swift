import AppKit
import FilesCore

@MainActor
final class ArchiveSevenZipOptionsView: NSStackView, NSTextFieldDelegate {
    let dictionaryButton = NSPopUpButton(), wordButton = NSPopUpButton()
    let threadsField = NSTextField(), threadsStepper = NSStepper()
    let memoryLabel = NSTextField(wrappingLabelWithString: "")
    private let availableLabel = NSTextField(wrappingLabelWithString: "")
    private let memoryNote = NSTextField(wrappingLabelWithString: L("파일 크기와 내용에 따라 실제 사용량은 달라집니다.", "Actual memory use varies with file size and contents."))
    private var level: ArchiveCompressionLevel = .normal
    private var supported = false
    private let preferences: BrowserPreferences?
    var options: SevenZipCompressionOptions? {
        guard let threads = Int(threadsField.stringValue.trimmingCharacters(in: .whitespaces)),
              (1...SevenZipCompressionOptions.hostThreadCount).contains(threads),
              dictionaryButton.indexOfSelectedItem >= 0, wordButton.indexOfSelectedItem >= 0 else { return nil }
        let value = SevenZipCompressionOptions(dictionarySize: dictionaryButton.selectedItem!.tag,
                                              wordSize: wordButton.selectedItem!.tag, threadCount: threads)
        return value.isValid ? value : nil
    }
    init(preferences: BrowserPreferences?) {
        self.preferences = preferences
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let initial = preferences?.archiveSevenZipOptions ?? .init(threadCount: SevenZipCompressionOptions.hostThreadCount)
        for size in SevenZipCompressionOptions.dictionarySizes {
            let label = size == 0 ? L("자동", "Auto") : size < 1 << 20 ? "\(size >> 10) KiB" : "\(size >> 20) MiB"
            dictionaryButton.addItem(withTitle: label); dictionaryButton.lastItem?.tag = size
        }
        for size in SevenZipCompressionOptions.wordSizes {
            wordButton.addItem(withTitle: size == 0 ? L("자동", "Auto") : String(size)); wordButton.lastItem?.tag = size
        }
        dictionaryButton.selectItem(withTag: initial.dictionarySize); wordButton.selectItem(withTag: initial.wordSize)
        for button in [dictionaryButton, wordButton] { button.target = self; button.action = #selector(changeOption(_:)) }
        threadsField.stringValue = String(min(initial.threadCount, SevenZipCompressionOptions.hostThreadCount))
        threadsField.alignment = .right; threadsField.delegate = self
        threadsField.target = self; threadsField.action = #selector(changeOption(_:))
        threadsStepper.minValue = 1; threadsStepper.maxValue = Double(SevenZipCompressionOptions.hostThreadCount)
        threadsStepper.increment = 1; threadsStepper.integerValue = Int(threadsField.stringValue)!; threadsStepper.valueWraps = false
        threadsStepper.target = self; threadsStepper.action = #selector(stepThread(_:))
        let threads = NSStackView(views: [threadsField, threadsStepper, NSView()]); threads.orientation = .horizontal; threads.spacing = 8
        threadsStepper.widthAnchor.constraint(equalToConstant: 19).isActive = true
        threadsField.widthAnchor.constraint(equalToConstant: 95).isActive = true
        for (title, view, identifier) in [(L("사전 크기:", "Dictionary size:"), dictionaryButton as NSView, "archive-dictionary-size"),
                                          (L("워드 크기:", "Word size:"), wordButton, "archive-word-size"),
                                          (L("CPU 스레드:", "CPU threads:"), threads, "archive-cpu-threads")] {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 145).isActive = true
            view.widthAnchor.constraint(equalToConstant: 220).isActive = true
            view.identifier = NSUserInterfaceItemIdentifier(identifier)
            if let control = view as? NSControl { control.setAccessibilityLabel(title) }
            let row = NSStackView(views: [label, view]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            addArrangedSubview(row)
        }
        threadsField.setAccessibilityLabel(L("CPU 스레드", "CPU threads"))
        threadsField.identifier = NSUserInterfaceItemIdentifier("archive-thread-count")
        for label in [memoryLabel, availableLabel, memoryNote] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 377).isActive = true; addArrangedSubview(label)
        }
        update(level: .normal, supported: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(level: ArchiveCompressionLevel, supported: Bool) {
        self.level = level; self.supported = supported
        dictionaryButton.isEnabled = supported && level != .store; wordButton.isEnabled = dictionaryButton.isEnabled
        threadsField.isEnabled = supported; threadsStepper.isEnabled = supported
        refreshMemory()
    }
    @objc private func changeOption(_ sender: Any?) {
        if let options { threadsStepper.integerValue = options.threadCount; preferences?.setArchiveSevenZipOptions(options) }
        refreshMemory()
    }
    @objc private func stepThread(_ sender: NSStepper) { threadsField.stringValue = String(sender.integerValue); changeOption(sender) }
    func controlTextDidChange(_ notification: Notification) { changeOption(threadsField) }
    private func refreshMemory() {
        for label in [memoryLabel, availableLabel, memoryNote] { label.isHidden = !supported }
        guard supported else { return }
        if let estimate = options?.estimatedMemoryBytes(for: level) {
            memoryLabel.stringValue = L("예상 압축 메모리: 약 ", "Estimated compression memory: about ") + ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .binary)
        } else { memoryLabel.stringValue = L("CPU 스레드 수를 1~\(SevenZipCompressionOptions.hostThreadCount) 범위의 정수로 입력하세요.", "Enter a whole thread count from 1 to \(SevenZipCompressionOptions.hostThreadCount).") }
        if let available = SevenZipCompressionOptions.availableMemoryEstimate() {
            availableLabel.stringValue = L("사용 가능 메모리 추정: ", "Estimated available memory: ") + ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .binary)
        } else { availableLabel.stringValue = L("사용 가능 메모리: 확인할 수 없음", "Available memory: unavailable") }
    }
}
