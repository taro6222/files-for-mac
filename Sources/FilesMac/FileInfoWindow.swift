import AppKit
import FilesCore

@MainActor
final class FileInfoWindow: NSWindowController {
    private let inspector = FilePropertiesInspector()
    private let details = NSStackView(), status = NSTextField(labelWithString: "")
    private let hashButton = NSButton(), hashProgress = NSProgressIndicator(), digest = NSTextField(wrappingLabelWithString: "")
    private let tagField = NSTextField(), saveTagsButton = NSButton()
    private let signatureButton = NSButton(), signatureDetails = NSTextField(wrappingLabelWithString: "")
    private let chooseIconButton = NSButton(), resetIconButton = NSButton(), iconStatus = NSTextField(labelWithString: "")
    private var items: [FileItem] = [], properties: FileProperties?, inspectTask: Task<Void, Never>?, hashTask: Task<Void, Never>?, signatureTask: Task<Void, Never>?
    private var tagIdentity: String?

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
        let tagTitle = NSTextField(labelWithString: L("Finder 태그", "Finder Tags")); tagTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(tagTitle)
        let tagControls = NSStackView(); tagControls.orientation = .horizontal; tagControls.spacing = 8
        tagField.placeholderString = L("쉼표로 태그 구분", "Separate tags with commas"); tagField.setAccessibilityLabel(L("Finder 태그", "Finder Tags")); tagControls.addArrangedSubview(tagField)
        saveTagsButton.title = L("태그 저장", "Save Tags"); saveTagsButton.target = self; saveTagsButton.action = #selector(saveTags(_:)); tagControls.addArrangedSubview(saveTagsButton); root.addArrangedSubview(tagControls)
        let iconTitle = NSTextField(labelWithString: L("폴더 아이콘", "Folder Icon")); iconTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(iconTitle)
        let iconControls = NSStackView(); iconControls.orientation = .horizontal; iconControls.spacing = 8
        chooseIconButton.title = L("이미지 선택…", "Choose Image…"); chooseIconButton.target = self; chooseIconButton.action = #selector(chooseFolderIcon(_:)); iconControls.addArrangedSubview(chooseIconButton)
        resetIconButton.title = L("기본 아이콘 복원", "Restore Default Icon"); resetIconButton.target = self; resetIconButton.action = #selector(resetFolderIcon(_:)); iconControls.addArrangedSubview(resetIconButton)
        iconControls.addArrangedSubview(iconStatus); root.addArrangedSubview(iconControls)
        let separator = NSBox(); separator.boxType = .separator; root.addArrangedSubview(separator)
        let hashTitle = NSTextField(labelWithString: "SHA-256"); hashTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(hashTitle)
        let hashControls = NSStackView(); hashControls.orientation = .horizontal; hashControls.spacing = 8
        hashButton.title = L("해시 계산", "Calculate Hash"); hashButton.target = self; hashButton.action = #selector(toggleHash(_:)); hashControls.addArrangedSubview(hashButton)
        hashProgress.isIndeterminate = true; hashProgress.isHidden = true; hashControls.addArrangedSubview(hashProgress); root.addArrangedSubview(hashControls)
        digest.font = .monospacedSystemFont(ofSize: 11, weight: .regular); digest.isSelectable = true; digest.lineBreakMode = .byCharWrapping; root.addArrangedSubview(digest)
        let signatureSeparator = NSBox(); signatureSeparator.boxType = .separator; root.addArrangedSubview(signatureSeparator)
        let signatureTitle = NSTextField(labelWithString: L("코드 서명", "Code Signature")); signatureTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(signatureTitle)
        signatureButton.title = L("서명 확인", "Inspect Signature"); signatureButton.target = self; signatureButton.action = #selector(inspectSignature(_:)); root.addArrangedSubview(signatureButton)
        signatureDetails.isSelectable = true; signatureDetails.textColor = .secondaryLabelColor; root.addArrangedSubview(signatureDetails)
        status.textColor = .secondaryLabelColor; root.addArrangedSubview(status); root.addArrangedSubview(NSView())
    }
    func present(items: [FileItem]) {
        cancelTasks(); self.items = items; properties = nil; tagIdentity = nil; tagField.stringValue = ""; tagField.isEnabled = false; saveTagsButton.isEnabled = false; digest.stringValue = ""; hashProgress.isHidden = true; signatureDetails.stringValue = ""; signatureButton.isEnabled = items.count == 1; iconStatus.stringValue = ""
        let folderIconEnabled = items.count == 1 && items[0].isDirectory
        chooseIconButton.isEnabled = folderIconEnabled; resetIconButton.isEnabled = folderIconEnabled
        rebuildDetails(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        guard items.count == 1 else { status.stringValue = L("\(items.count)개 항목", "\(items.count) items"); return }
        status.stringValue = L("속성을 읽는 중…", "Loading properties…")
        inspectTask = Task { [weak self, inspector] in
            do {
                let value = try await inspector.inspect(items[0].url), tags = try FileTagService().snapshot(items[0].url)
                guard let self, !Task.isCancelled else { return }; self.properties = value; self.tagIdentity = tags.identity
                self.tagField.stringValue = tags.tags.joined(separator: ", "); self.status.stringValue = ""; self.rebuildDetails()
            }
            catch { guard let self, !Task.isCancelled else { return }; self.status.stringValue = L("속성을 읽지 못했습니다: ", "Unable to load properties: ") + error.localizedDescription }
        }
    }
    private func rebuildDetails() {
        for view in details.arrangedSubviews { details.removeArrangedSubview(view); view.removeFromSuperview() }
        guard items.count == 1 else {
            row(L("선택", "Selection"), L("\(items.count)개 항목", "\(items.count) items"));
            let bytes = items.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : ($1.size ?? 0)) }; row(L("파일 크기 합계", "Total file size"), formatByteCount(bytes, unit: BrowserPreferences.shared.sizeUnit)); hashButton.isEnabled = false; tagField.isEnabled = false; saveTagsButton.isEnabled = false; return
        }
        let item = items[0]; row(L("이름", "Name"), item.name); row(L("위치", "Location"), item.url.deletingLastPathComponent().path)
        guard let p = properties else { hashButton.isEnabled = !item.isDirectory; return }
        row(L("종류", "Kind"), p.typeIdentifier ?? item.kind); row(L("논리 크기", "Logical size"), size(p.logicalSize)); row(L("할당 크기", "Allocated size"), size(p.allocatedSize))
        row(L("수정", "Modified"), date(p.modified)); row(L("생성", "Created"), date(p.created)); row(L("추가", "Added"), date(p.added))
        row(L("소유자 / 그룹", "Owner / Group"), [p.owner, p.group].compactMap { $0 }.joined(separator: " / "))
        row(L("권한", "Permissions"), p.posixPermissions.map { String(format: "%04o", $0) } ?? "—")
        row(L("볼륨", "Volume"), p.volumeName ?? "—")
        row(L("접근", "Access"), [p.isReadable ? "R" : "—", p.isWritable ? "W" : "—", p.isExecutable ? "X" : "—"].joined(separator: " "))
        hashButton.isEnabled = !p.isDirectory; tagField.isEnabled = true; saveTagsButton.isEnabled = true
    }
    private func row(_ label: String, _ value: String) { let field = NSTextField(wrappingLabelWithString: "\(label):  \(value)"); field.lineBreakMode = .byTruncatingMiddle; details.addArrangedSubview(field) }
    private func size(_ value: Int64?) -> String { value.map { formatByteCount($0, unit: BrowserPreferences.shared.sizeUnit) } ?? "—" }
    private func date(_ value: Date?) -> String { value.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "—" }
    @objc private func toggleHash(_ sender: Any?) { hashTask == nil ? startHash() : cancelHash() }
    @objc private func saveTags(_ sender: Any?) {
        guard items.count == 1 else { return }
        let tags = tagField.stringValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        do {
            let saved = try FileTagService().setTags(tags, at: items[0].url, expectedIdentity: tagIdentity)
            tagIdentity = saved.identity; tagField.stringValue = saved.tags.joined(separator: ", "); status.stringValue = L("Finder 태그를 저장했습니다.", "Finder tags saved.")
        } catch FileTagError.changedIdentity { status.stringValue = L("파일이 외부에서 교체되어 태그를 저장하지 않았습니다.", "The file was replaced externally; tags were not saved.") }
        catch { status.stringValue = L("태그 저장 실패: ", "Unable to save tags: ") + error.localizedDescription }
    }
    @objc private func chooseFolderIcon(_ sender: Any?) {
        guard items.count == 1, items[0].isDirectory, let window else { return }
        let panel = NSOpenPanel(); panel.title = L("폴더 아이콘 이미지 선택", "Choose Folder Icon Image")
        panel.allowedContentTypes = [.image]; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url), let self else { return }
            self.applyFolderIcon(image)
        }
    }
    @objc private func resetFolderIcon(_ sender: Any?) { applyFolderIcon(nil) }
    private func applyFolderIcon(_ image: NSImage?) {
        guard items.count == 1, items[0].isDirectory else { return }
        let succeeded = NSWorkspace.shared.setIcon(image, forFile: items[0].url.path, options: [])
        iconStatus.stringValue = succeeded
            ? (image == nil ? L("기본 아이콘을 복원했습니다.", "Default icon restored.") : L("사용자 아이콘을 저장했습니다.", "Custom icon saved."))
            : L("아이콘을 변경하지 못했습니다.", "Unable to change the icon.")
    }
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
    @objc private func inspectSignature(_ sender: Any?) {
        guard items.count == 1, signatureTask == nil else { return }
        signatureButton.isEnabled = false; signatureDetails.stringValue = L("서명을 확인하는 중…", "Inspecting signature…")
        let url = items[0].url
        signatureTask = Task { [weak self] in
            let report = await CodeSignatureInspector.inspect(url)
            guard let self, !Task.isCancelled else { return }
            let state = switch report.state {
            case .valid: L("유효", "Valid")
            case .unsigned: L("서명되지 않음", "Unsigned")
            case .invalid: L("유효하지 않음", "Invalid")
            }
            var lines = [L("상태: ", "State: ") + state]
            if let value = report.identifier { lines.append("Identifier: " + value) }
            if let value = report.teamIdentifier { lines.append("Team: " + value) }
            if let value = report.format { lines.append("Format: " + value) }
            lines += report.authorities.map { "Authority: " + $0 }
            if let value = report.diagnostic, !value.isEmpty { lines.append(value) }
            signatureDetails.stringValue = lines.joined(separator: "\n")
            signatureTask = nil; signatureButton.isEnabled = true
        }
    }
    private func cancelTasks() { inspectTask?.cancel(); inspectTask = nil; hashTask?.cancel(); hashTask = nil; signatureTask?.cancel(); signatureTask = nil }
#if DEBUG
    var qaLoaded: Bool { properties != nil }
    var qaHashing: Bool { hashTask != nil }
    var qaDigest: String? { digest.stringValue.isEmpty ? nil : digest.stringValue }
    func qaStartHash() { startHash() }
    func qaSetTags(_ value: String) { tagField.stringValue = value; saveTags(nil) }
    var qaTags: [String] { (try? FileTagService().snapshot(items[0].url).tags) ?? [] }
    func qaInspectSignature() { inspectSignature(nil) }
    var qaSignatureLoaded: Bool { signatureTask == nil && !signatureDetails.stringValue.isEmpty }
    func qaApplyFolderIcon(_ image: NSImage?) { applyFolderIcon(image) }
    var qaIconOperationSucceeded: Bool { iconStatus.stringValue.contains(L("저장했습니다", "saved")) || iconStatus.stringValue.contains(L("복원했습니다", "restored")) }
#endif
}
