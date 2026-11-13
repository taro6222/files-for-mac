import AppKit
import FilesCore

@MainActor
final class ArchiveCapabilitiesWindow: NSWindowController {
    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("압축 포맷 지원", "Archive Format Support"); panel.isReleasedWhenClosed = false; panel.center()
        let grid = NSGridView(); grid.translatesAutoresizingMaskIntoConstraints = false; grid.rowSpacing = 10; grid.columnSpacing = 18
        let headers = [L("포맷", "Format"), L("탐색", "Browse"), L("추출", "Extract"), L("생성", "Create"), L("수정", "Update"), L("암호", "Password"), L("분할", "Split")]
        grid.addRow(with: headers.map { let label = NSTextField(labelWithString: $0); label.font = .boldSystemFont(ofSize: NSFont.systemFontSize); return label })
        func mark(_ supported: Bool) -> NSTextField { let label = NSTextField(labelWithString: supported ? L("지원", "Yes") : L("미지원", "No")); label.textColor = supported ? .systemGreen : .secondaryLabelColor; return label }
        for item in ArchiveCapabilityMatrix.current {
            grid.addRow(with: [NSTextField(labelWithString: item.format.rawValue.uppercased()), mark(item.browse), mark(item.extract), mark(item.create), mark(item.update), mark(item.password), mark(item.splitVolumes)])
        }
        let note = NSTextField(wrappingLabelWithString: L("실제 fixture로 검증한 기능만 지원으로 표시합니다. 7z/RAR은 탐색·안전 추출만 지원합니다.", "Only fixture-verified features are shown as supported. 7z/RAR support is limited to browsing and safe extraction."))
        let stack = NSStackView(views: [grid, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -24), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
}
