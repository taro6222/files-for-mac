import AppKit
import FilesCore

@MainActor
final class ArchiveSaveSplitOptionsView: NSStackView {
    let button = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: L("분할 파일은 선택한 폴더에 .001부터 저장합니다. 전체 출력 한도는 8 GB입니다.", "Volumes are saved in the selected folder starting at .001. Total output is limited to 8 GB."))
    private let preferences: BrowserPreferences?
    var selected: ArchiveSplitSize { ArchiveSplitSize(rawValue: button.selectedTag()) ?? .none }
    var effectiveSelection: ArchiveSplitSize { button.isEnabled ? selected : .none }
    init(preferences: BrowserPreferences?) {
        self.preferences = preferences
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        for value in ArchiveSplitSize.allCases {
            var label = value == .none ? L("분할 안 함", "Do not split") : "\(value.rawValue) MiB"
            if let media = value.mediaName { label += " — " + media }
            button.addItem(withTitle: label); button.lastItem?.tag = value.rawValue
        }
        button.selectItem(withTag: (preferences?.archiveSplitSize ?? .none).rawValue)
        button.identifier = NSUserInterfaceItemIdentifier("archive-split-size")
        button.setAccessibilityLabel(L("분할 크기", "Split size")); button.target = self; button.action = #selector(change(_:))
        let title = NSTextField(labelWithString: L("분할 크기:", "Split size:")); title.widthAnchor.constraint(equalToConstant: 145).isActive = true
        button.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let row = NSStackView(views: [title, button]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        addArrangedSubview(row); addArrangedSubview(note)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 377).isActive = true
        update(supported: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(supported: Bool) { button.isEnabled = supported; note.isHidden = !supported || selected == .none }
    @objc private func change(_ sender: Any?) { preferences?.setArchiveSplitSize(selected); update(supported: button.isEnabled) }
}
