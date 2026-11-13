import AppKit
import FilesCore

@MainActor
final class FileInfoWindow: NSWindowController {
    private let inspector = FilePropertiesInspector()
    private let details = NSStackView(), status = NSTextField(labelWithString: "")
    private let hashButton = NSButton(), hashProgress = NSProgressIndicator(), digest = NSTextField(wrappingLabelWithString: "")
    private var items: [FileItem] = [], properties: FileProperties?, inspectTask: Task<Void, Never>?, hashTask: Task<Void, Never>?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("정보", "Info"); panel.isReleasedWhenClosed = false; buildUI()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancelTasks() } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18); root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root); NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 8; root.addArrangedSubview(details)
        let separator = NSBox(); separator.boxType = .separator; root.addArrangedSubview(separator)
        let hashTitle = NSTextField(labelWithString: "SHA-256"); hashTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(hashTitle)
        let hashControls = NSStackView(); hashControls.orientation = .horizontal; hashControls.spacing = 8
        hashButton.title = L("해시 계산", "Calculate Hash"); hashButton.target = self; hashButton.action = #selector(toggleHash(_:)); hashControls.addArrangedSubview(hashButton)
        hashProgress.isIndeterminate = true; hashProgress.isHidden = true; hashControls.addArrangedSubview(hashProgress); root.addArrangedSubview(hashControls)
        digest.font = .monospacedSystemFont(ofSize: 11, weight: .regular); digest.isSelectable = true; digest.lineBreakMode = .byCharWrapping; root.addArrangedSubview(digest)
        status.textColor = .secondaryLabelColor; root.addArrangedSubview(status); root.addArrangedSubview(NSView())
    }
    func present(items: [FileItem]) {
        cancelTasks(); self.items = items; properties = nil; digest.stringValue = ""; hashProgress.isHidden = true
        rebuildDetails(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        guard items.count == 1 else { status.stringValue = L("\(items.count)개 항목", "\(items.count) items"); return }
        status.stringValue = L("속성을 읽는 중…", "Loading properties…")
        inspectTask = Task { [weak self, inspector] in
            do { let value = try await inspector.inspect(items[0].url); guard let self, !Task.isCancelled else { return }; self.properties = value; self.status.stringValue = ""; self.rebuildDetails() }
            catch { guard let self, !Task.isCancelled else { return }; self.status.stringValue = L("속성을 읽지 못했습니다: ", "Unable to load properties: ") + error.localizedDescription }
        }
    }
    private func rebuildDetails() {
        for view in details.arrangedSubviews { details.removeArrangedSubview(view); view.removeFromSuperview() }
        guard items.count == 1 else {
            row(L("선택", "Selection"), L("\(items.count)개 항목", "\(items.count) items"));
            let bytes = items.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : ($1.size ?? 0)) }; row(L("파일 크기 합계", "Total file size"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); hashButton.isEnabled = false; return
        }
        let item = items[0]; row(L("이름", "Name"), item.name); row(L("위치", "Location"), item.url.deletingLastPathComponent().path)
        guard let p = properties else { hashButton.isEnabled = !item.isDirectory; return }
        row(L("종류", "Kind"), p.typeIdentifier ?? item.kind); row(L("논리 크기", "Logical size"), size(p.logicalSize)); row(L("할당 크기", "Allocated size"), size(p.allocatedSize))
        row(L("수정", "Modified"), date(p.modified)); row(L("생성", "Created"), date(p.created)); row(L("추가", "Added"), date(p.added))
        row(L("소유자 / 그룹", "Owner / Group"), [p.owner, p.group].compactMap { $0 }.joined(separator: " / "))
        row(L("권한", "Permissions"), p.posixPermissions.map { String(format: "%04o", $0) } ?? "—")
        row(L("태그", "Tags"), p.tags.isEmpty ? "—" : p.tags.joined(separator: ", ")); row(L("볼륨", "Volume"), p.volumeName ?? "—")
        row(L("접근", "Access"), [p.isReadable ? "R" : "—", p.isWritable ? "W" : "—", p.isExecutable ? "X" : "—"].joined(separator: " "))
        hashButton.isEnabled = !p.isDirectory
    }
    private func row(_ label: String, _ value: String) { let field = NSTextField(wrappingLabelWithString: "\(label):  \(value)"); field.lineBreakMode = .byTruncatingMiddle; details.addArrangedSubview(field) }
    private func size(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
    private func date(_ value: Date?) -> String { value.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "—" }
    @objc private func toggleHash(_ sender: Any?) { hashTask == nil ? startHash() : cancelHash() }
    private func startHash() {
        guard items.count == 1, !items[0].isDirectory else { return }; let item = items[0]
        hashButton.title = L("취소", "Cancel"); hashProgress.isHidden = false; hashProgress.startAnimation(nil); digest.stringValue = ""
        hashTask = Task { [weak self, inspector] in
            do {
                let value = try await inspector.sha256(item.url)
                guard let self, !Task.isCancelled else { return }; self.digest.stringValue = value; self.finishHash()
            } catch is CancellationError { self?.status.stringValue = L("해시 계산을 취소했습니다.", "Hash calculation cancelled."); self?.finishHash() }
            catch { self?.status.stringValue = L("해시 계산 실패: ", "Hash failed: ") + error.localizedDescription; self?.finishHash() }
        }
    }
    private func cancelHash() { hashTask?.cancel() }
    private func finishHash() { hashTask = nil; hashButton.title = L("해시 계산", "Calculate Hash"); hashProgress.stopAnimation(nil); hashProgress.isHidden = true }
    private func cancelTasks() { inspectTask?.cancel(); inspectTask = nil; hashTask?.cancel(); hashTask = nil }
#if DEBUG
    var qaLoaded: Bool { properties != nil }
    var qaHashing: Bool { hashTask != nil }
    var qaDigest: String? { digest.stringValue.isEmpty ? nil : digest.stringValue }
    func qaStartHash() { startHash() }
#endif
}
