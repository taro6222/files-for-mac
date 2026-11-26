import AppKit
import FilesCore

@MainActor
final class ArchiveCapabilitiesWindow: NSWindowController {
    private let sevenZipSplit = NSTextField(labelWithString: "")
    private let sevenZipPassword = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("압축 포맷 지원", "Archive Format Support"); panel.isReleasedWhenClosed = false; panel.center()
        let grid = NSGridView(); grid.translatesAutoresizingMaskIntoConstraints = false; grid.rowSpacing = 10; grid.columnSpacing = 18
        let headers = [L("포맷", "Format"), L("탐색", "Browse"), L("추출", "Extract"), L("생성", "Create"), L("수정", "Update"), L("암호", "Password"), L("분할", "Split")]
        grid.addRow(with: headers.map { let label = NSTextField(labelWithString: $0); label.font = .boldSystemFont(ofSize: NSFont.systemFontSize); return label })
        func mark(_ supported: Bool) -> NSTextField { let label = NSTextField(labelWithString: supported ? L("지원", "Yes") : L("미지원", "No")); label.textColor = supported ? .systemGreen : .secondaryLabelColor; return label }
        for item in ArchiveCapabilityMatrix.current {
            let password: NSTextField
            if item.format == .sevenZip { sevenZipPassword.stringValue = L("확인 중", "Checking"); sevenZipPassword.textColor = .secondaryLabelColor; password = sevenZipPassword }
            else if item.password { password = NSTextField(labelWithString: L("생성·추출", "Create/extract")); password.textColor = .systemGreen }
            else { password = mark(false) }
            let split: NSTextField
            if item.format == .sevenZip { sevenZipSplit.stringValue = L("확인 중", "Checking"); sevenZipSplit.textColor = .secondaryLabelColor; split = sevenZipSplit }
            else { split = mark(item.splitVolumes) }
            grid.addRow(with: [NSTextField(labelWithString: item.format.rawValue.uppercased()), mark(item.browse), mark(item.extract), mark(item.create), mark(item.update), password, split])
        }
        let note = NSTextField(wrappingLabelWithString: L("암호 열에는 지원하는 작업을 표시합니다. 포맷과 설치된 앱에서 확인한 기능만 사용할 수 있습니다.", "The password column lists supported operations. Availability depends on the format and verified app components."))
        let stack = NSStackView(views: [grid, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -24), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    func present() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); task?.cancel()
        task = Task { [weak self] in
            do {
                let backend = try await ArchiveReadBackend.resolve(for: URL(fileURLWithPath: "/format.7z"))
                guard let self, !Task.isCancelled else { return }
                let supported = backend.supportsPassword(for: URL(fileURLWithPath: "/format.7z"))
                self.sevenZipPassword.stringValue = supported ? L("생성·추출", "Create/extract") : L("미지원", "No")
                self.sevenZipPassword.textColor = supported ? .systemGreen : .secondaryLabelColor
                self.sevenZipSplit.stringValue = supported ? L("생성·탐색·추출", "Create/browse/extract") : L("미지원", "No")
                self.sevenZipSplit.textColor = supported ? .systemGreen : .secondaryLabelColor
            } catch { guard let self, !Task.isCancelled else { return }; self.sevenZipPassword.stringValue = L("확인 실패", "Unavailable"); self.sevenZipPassword.textColor = .secondaryLabelColor; self.sevenZipSplit.stringValue = L("확인 실패", "Unavailable"); self.sevenZipSplit.textColor = .secondaryLabelColor }
        }
    }
#if DEBUG
    var qaSevenZipSplit: String { sevenZipSplit.stringValue }
    var qaSevenZipPassword: String { sevenZipPassword.stringValue }
#endif
}
