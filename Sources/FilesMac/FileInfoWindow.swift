import AppKit
import FilesCore

@MainActor
final class FileInfoWindow: NSWindowController, NSTextFieldDelegate {
    private let inspector = FilePropertiesInspector()
    private let scroll = NSScrollView()
    private let details = NSStackView(), status = NSTextField(labelWithString: "")
    private let permissionsButton = NSButton()
    private let hashButton = NSButton(), hashProgress = NSProgressIndicator(), digest = NSTextField(wrappingLabelWithString: "")
    private let hashAlgorithm = NSPopUpButton(), expectedHash = NSTextField(), compareHashButton = NSButton()
    private let hashStatus = NSTextField(wrappingLabelWithString: "")
    private let tagField = NSTextField(), saveTagsButton = NSButton()
    private let signatureButton = NSButton(), signatureDetails = NSTextField(wrappingLabelWithString: "")
    private let chooseIconButton = NSButton(), resetIconButton = NSButton(), iconStatus = NSTextField(labelWithString: "")
    private var items: [FileItem] = [], properties: FileProperties?, inspectTask: Task<Void, Never>?, hashTask: Task<Void, Never>?, signatureTask: Task<Void, Never>?
    private var tagIdentity: String?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("정보", "Info"); panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 420, height: 280)
        buildUI()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.window?.isVisible == false else { return }
                self?.cancelTasks()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildUI() {
        guard let window else { return }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel(L("파일 속성", "File Properties"))
        window.contentView = scroll
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18); root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 8; root.addArrangedSubview(details)
        permissionsButton.title = L("파일 권한…", "File Permissions…")
        permissionsButton.target = self; permissionsButton.action = #selector(showPermissions(_:))
        root.addArrangedSubview(permissionsButton)
        let tagTitle = NSTextField(labelWithString: L("Finder 태그", "Finder Tags")); tagTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(tagTitle)
        let tagControls = NSStackView(); tagControls.orientation = .horizontal; tagControls.spacing = 8
        tagField.isEditable = true
        tagField.placeholderString = L("쉼표로 태그 구분", "Separate tags with commas"); tagField.setAccessibilityLabel(L("Finder 태그", "Finder Tags")); tagControls.addArrangedSubview(tagField)
        saveTagsButton.title = L("태그 저장", "Save Tags"); saveTagsButton.target = self; saveTagsButton.action = #selector(saveTags(_:)); tagControls.addArrangedSubview(saveTagsButton); root.addArrangedSubview(tagControls)
        let iconTitle = NSTextField(labelWithString: L("폴더 아이콘", "Folder Icon")); iconTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(iconTitle)
        let iconControls = NSStackView(); iconControls.orientation = .horizontal; iconControls.spacing = 8
        chooseIconButton.title = L("이미지 선택…", "Choose Image…"); chooseIconButton.target = self; chooseIconButton.action = #selector(chooseFolderIcon(_:)); iconControls.addArrangedSubview(chooseIconButton)
        resetIconButton.title = L("기본 아이콘 복원", "Restore Default Icon"); resetIconButton.target = self; resetIconButton.action = #selector(resetFolderIcon(_:)); iconControls.addArrangedSubview(resetIconButton)
        iconControls.addArrangedSubview(iconStatus); root.addArrangedSubview(iconControls)
        let separator = NSBox(); separator.boxType = .separator; root.addArrangedSubview(separator)
        let hashTitle = NSTextField(labelWithString: L("해시", "Hashes")); hashTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(hashTitle)
        let hashControls = NSStackView(); hashControls.orientation = .horizontal; hashControls.spacing = 8
        hashAlgorithm.addItems(withTitles: FileHashAlgorithm.allCases.map(\.rawValue))
        hashAlgorithm.selectItem(withTitle: FileHashAlgorithm.sha256.rawValue)
        hashAlgorithm.setAccessibilityLabel(L("해시 알고리즘", "Hash algorithm"))
        hashAlgorithm.target = self; hashAlgorithm.action = #selector(changeHashAlgorithm(_:))
        hashControls.addArrangedSubview(hashAlgorithm)
        hashButton.title = L("해시 계산", "Calculate Hash"); hashButton.target = self; hashButton.action = #selector(toggleHash(_:)); hashControls.addArrangedSubview(hashButton)
        hashProgress.isIndeterminate = true; hashProgress.isHidden = true; hashControls.addArrangedSubview(hashProgress); root.addArrangedSubview(hashControls)
        digest.font = .monospacedSystemFont(ofSize: 11, weight: .regular); digest.isSelectable = true; digest.lineBreakMode = .byCharWrapping; root.addArrangedSubview(digest)
        let hashComparison = NSStackView(); hashComparison.orientation = .horizontal; hashComparison.spacing = 8
        expectedHash.placeholderString = L("비교할 해시값", "Expected hash")
        expectedHash.setAccessibilityLabel(L("비교할 해시값", "Expected hash"))
        expectedHash.target = self; expectedHash.action = #selector(compareEnteredHash(_:))
        expectedHash.delegate = self
        hashComparison.addArrangedSubview(expectedHash)
        compareHashButton.title = L("파일 비교…", "Compare File…")
        compareHashButton.target = self; compareHashButton.action = #selector(chooseHashComparison(_:))
        hashComparison.addArrangedSubview(compareHashButton)
        root.addArrangedSubview(hashComparison)
        hashStatus.textColor = .secondaryLabelColor; root.addArrangedSubview(hashStatus)
        let signatureSeparator = NSBox(); signatureSeparator.boxType = .separator; root.addArrangedSubview(signatureSeparator)
        let signatureTitle = NSTextField(labelWithString: L("코드 서명", "Code Signature")); signatureTitle.font = .systemFont(ofSize: 14, weight: .semibold); root.addArrangedSubview(signatureTitle)
        signatureButton.title = L("서명 확인", "Inspect Signature"); signatureButton.target = self; signatureButton.action = #selector(inspectSignature(_:)); root.addArrangedSubview(signatureButton)
        signatureDetails.isSelectable = true; signatureDetails.textColor = .secondaryLabelColor; root.addArrangedSubview(signatureDetails)
        status.textColor = .secondaryLabelColor; root.addArrangedSubview(status)
    }
    func present(items: [FileItem], editingTags: Bool = false) {
        cancelTasks(); self.items = items; properties = nil; tagIdentity = nil; tagField.stringValue = ""; tagField.isEnabled = false; saveTagsButton.isEnabled = false; digest.stringValue = ""; hashProgress.isHidden = true; signatureDetails.stringValue = ""; signatureButton.isEnabled = items.count == 1; iconStatus.stringValue = ""
        let folderIconEnabled = items.count == 1 && items[0].isDirectory
        permissionsButton.isEnabled = items.count == 1 && !items[0].isSymbolicLink
        expectedHash.stringValue = ""; hashStatus.stringValue = ""
        finishHash()
        chooseIconButton.isEnabled = folderIconEnabled; resetIconButton.isEnabled = folderIconEnabled
        rebuildDetails()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        guard items.count == 1 else { status.stringValue = L("\(items.count)개 항목", "\(items.count) items"); return }
        status.stringValue = L("속성을 읽는 중…", "Loading properties…")
        inspectTask = Task { [weak self, inspector] in
            do {
                let value = try await inspector.inspect(items[0].url), tags = try FileTagService().snapshot(items[0].url)
                guard let self, !Task.isCancelled else { return }; self.properties = value; self.tagIdentity = tags.identity
                self.tagField.stringValue = tags.tags.joined(separator: ", "); self.status.stringValue = ""; self.rebuildDetails()
                if editingTags, self.window?.isVisible == true {
                    self.scroll.layoutSubtreeIfNeeded()
                    self.tagField.scrollToVisible(self.tagField.bounds)
                    self.tagField.selectText(nil)
                }
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
    @objc private func showPermissions(_ sender: Any?) {
        _ = openPermissions()
    }
    private func openPermissions() -> FilePermissionsSheet? {
        guard items.count == 1, !items[0].isSymbolicLink, let window, window.attachedSheet == nil else { return nil }
        let item = items[0]
        let sheet = FilePermissionsSheet(url: item.url) { [weak self] in
            guard let self, self.items == [item] else { return }
            self.present(items: [item])
        }
        sheet.present(on: window)
        return sheet
    }
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
    @objc private func changeHashAlgorithm(_ sender: Any?) {
        digest.stringValue = ""
        updateHashComparison()
    }
    @objc private func compareEnteredHash(_ sender: Any?) {
        guard hashTask == nil else { return }
        if digest.stringValue.isEmpty { startHash() } else { updateHashComparison() }
    }
    func controlTextDidChange(_ notification: Notification) {
        updateHashComparison()
    }
    private func updateHashComparison() {
        let expected = expectedHash.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty, !digest.stringValue.isEmpty, let algorithm = selectedHashAlgorithm else {
            hashStatus.stringValue = ""; return
        }
        guard expected.utf8.count == algorithm.hexLength,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            hashStatus.stringValue = L("\(algorithm.rawValue) 해시값을 입력하세요.", "Enter a \(algorithm.rawValue) hash."); return
        }
        showHashMatch(expected == digest.stringValue)
    }
    private func showHashMatch(_ matches: Bool) {
        hashStatus.stringValue = matches ? L("해시값이 일치합니다.", "Hashes match.") : L("해시값이 다릅니다.", "Hashes differ.")
    }
    private var selectedHashAlgorithm: FileHashAlgorithm? {
        hashAlgorithm.titleOfSelectedItem.flatMap(FileHashAlgorithm.init(rawValue:))
    }
    @objc private func chooseHashComparison(_ sender: Any?) {
        guard let window, hashTask == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.startHash(comparing: url) }
        }
    }
    private func startHash(comparing comparisonURL: URL? = nil) {
        guard hashTask == nil, items.count == 1, !items[0].isDirectory, let algorithm = selectedHashAlgorithm else { return }
        let item = items[0]
        hashButton.title = L("취소", "Cancel"); hashProgress.isHidden = false; hashProgress.startAnimation(nil); digest.stringValue = ""
        hashStatus.stringValue = ""
        hashAlgorithm.isEnabled = false; compareHashButton.isEnabled = false; expectedHash.isEnabled = false
        if comparisonURL != nil { expectedHash.stringValue = "" }
        hashTask = Task { [weak self, inspector] in
            do {
                let value = try await inspector.hash(item.url, algorithm: algorithm)
                var comparison: String?
                if let comparisonURL { comparison = try await inspector.hash(comparisonURL, algorithm: algorithm) }
                try Task.checkCancellation()
                guard let self else { return }
                self.digest.stringValue = value
                if let comparison { self.showHashMatch(value == comparison) } else { self.updateHashComparison() }
                self.finishHash()
                self.announceHashResult()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.hashStatus.stringValue = L("해시 계산 실패: ", "Hash failed: ") + error.localizedDescription
                self.finishHash()
                self.announceHashResult()
            }
        }
    }
    private func cancelHash() {
        hashTask?.cancel()
        hashStatus.stringValue = L("해시 계산을 취소했습니다.", "Hash calculation cancelled.")
        finishHash()
        announceHashResult()
    }
    private func announceHashResult() {
        guard let window else { return }
        let message = hashStatus.stringValue.isEmpty ? L("해시 계산을 완료했습니다.", "Hash calculation complete.") : hashStatus.stringValue
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
    private func finishHash() {
        hashTask = nil
        hashButton.title = L("해시 계산", "Calculate Hash"); hashProgress.stopAnimation(nil); hashProgress.isHidden = true
        let enabled = items.count == 1 && !items[0].isDirectory
        hashButton.isEnabled = enabled; hashAlgorithm.isEnabled = enabled
        compareHashButton.isEnabled = enabled; expectedHash.isEnabled = enabled
    }
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
    func qaApplyFolderMode(acl: String? = nil, group: String? = nil, stopImmediately: Bool = false,
                           watchFiles: [URL] = []) async throws -> Bool {
        guard let sheet = openPermissions() else { return false }
        defer { sheet.dismissQA() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !sheet.qaReady && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await sheet.qaApplyDescendants(acl: acl, group: group, stopImmediately: stopImmediately, watchFiles: watchFiles)
    }
    func qaOwnerControlMatchesPrivileges() async throws -> Bool {
        guard let sheet = openPermissions() else { return false }
        defer { sheet.dismissQA() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !sheet.qaReady && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return sheet.qaReady && sheet.qaOwnerEnabled == FilePropertiesInspector.canChangeOwner
    }
    func qaChangePermissions(to mode: Int, acl: String? = nil, addEveryoneRule: Bool = false, group: String? = nil) async throws -> Bool {
        guard let sheet = openPermissions() else { return false }
        let deadline = ContinuousClock.now + .seconds(5)
        while !sheet.qaReady && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let changed: Bool
        if let group {
            changed = try await sheet.qaSetGroup(group)
        } else if addEveryoneRule {
            changed = try await sheet.qaAddEveryoneRule()
        } else {
            changed = acl.map({ sheet.qaSetACL($0) }) ?? sheet.qaSetMode(mode)
        }
        guard changed else {
            sheet.dismissQA()
            return false
        }
        let saveDeadline = ContinuousClock.now + .seconds(5)
        while window?.attachedSheet != nil && ContinuousClock.now < saveDeadline { try await Task.sleep(for: .milliseconds(20)) }
        while properties?.posixPermissions != mode && ContinuousClock.now < saveDeadline { try await Task.sleep(for: .milliseconds(20)) }
        return window?.attachedSheet == nil && properties?.posixPermissions == mode
    }
    func qaCanReachSignature() -> Bool {
        guard let window, let content = scroll.documentView else { return false }
        let previousSize = scroll.frame.size
        let clip = scroll.contentView
        defer {
            window.setContentSize(previousSize)
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
        }
        window.setContentSize(window.contentMinSize)
        scroll.layoutSubtreeIfNeeded()
        let buttonFrame = signatureButton.convert(signatureButton.bounds, to: content)
        guard !buttonFrame.isEmpty, !content.visibleRect.contains(buttonFrame) else { return false }
        _ = signatureButton.scrollToVisible(signatureButton.bounds)
        return content.visibleRect.contains(buttonFrame)
    }
    var qaHashing: Bool { hashTask != nil }
    var qaDigest: String? { digest.stringValue.isEmpty ? nil : digest.stringValue }
    func qaStartHash(_ algorithm: FileHashAlgorithm = .sha256, comparing url: URL? = nil) {
        hashAlgorithm.selectItem(withTitle: algorithm.rawValue)
        changeHashAlgorithm(nil)
        startHash(comparing: url)
    }
    func qaCompareHash(_ value: String) -> String {
        expectedHash.stringValue = value
        compareEnteredHash(nil)
        return hashStatus.stringValue
    }
    var qaHashStatus: String { hashStatus.stringValue }
    func qaSetTags(_ value: String) { tagField.stringValue = value; saveTags(nil) }
    var qaTagFieldFocused: Bool { tagField.currentEditor() != nil }
    var qaItemURLs: [URL] { items.map(\.url) }
    var qaTags: [String] { (try? FileTagService().snapshot(items[0].url).tags) ?? [] }
    func qaInspectSignature() { inspectSignature(nil) }
    var qaSignatureLoaded: Bool { signatureTask == nil && !signatureDetails.stringValue.isEmpty }
    func qaApplyFolderIcon(_ image: NSImage?) { applyFolderIcon(image) }
    var qaIconOperationSucceeded: Bool { iconStatus.stringValue.contains(L("저장했습니다", "saved")) || iconStatus.stringValue.contains(L("복원했습니다", "restored")) }
#endif
}

@MainActor
private final class FilePermissionsSheet: NSObject, NSTextViewDelegate {
    private let inspector = FilePropertiesInspector()
    private let url: URL
    private let onSave: () -> Void
    private let alert = NSAlert()
    private var initial: FilePermissionSnapshot?
    private var refreshAfterClose = false
    private var folderCancellation: CopyCancellation?
    private let stop = NSButton()
    private var checks: [NSButton] = []
    private let aclText = NSTextView()
    private let editACL = NSButton()
    private let addACLRule = NSButton()
    private let accountKind = NSPopUpButton(), ruleEffect = NSPopUpButton(), ruleAccess = NSPopUpButton()
    private let accountName = NSTextField(), accountList = NSPopUpButton()
    private let groupList = NSPopUpButton()
    private let ownerList = NSPopUpButton()
    private let includeDescendants = NSButton()
    private var accountListTask: Task<Void, Never>?
    private let ruleControls = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let save: NSButton

    init(url: URL, onSave: @escaping () -> Void) {
        self.url = url
        self.onSave = onSave
        alert.messageText = L("파일 권한", "File Permissions")
        alert.informativeText = url.lastPathComponent
        save = alert.addButton(withTitle: L("저장", "Save"))
        super.init()
        save.isEnabled = false
        alert.addButton(withTitle: L("닫기", "Close"))
        save.target = self
        save.action = #selector(savePermissions(_:))
        buildControls()
    }

    func present(on parent: NSWindow) {
        let sheet = alert.window
        alert.beginSheetModal(for: parent) { [self] _ in
            folderCancellation?.cancel()
            if refreshAfterClose { onSave() }
        }
        Task {
            do {
                let snapshot = try await inspector.permissions(url)
                guard sheet.sheetParent != nil else { return }
                display(snapshot)
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func buildControls() {
        let classes = [L("소유자", "Owner"), L("그룹", "Group"), L("기타", "Others")]
        let operations = [L("읽기", "Read"), L("쓰기", "Write"), L("실행/탐색", "Execute/Search")]
        var rows: [[NSView]] = [[NSTextField(labelWithString: "")] + operations.map(NSTextField.init(labelWithString:))]
        for accessClass in classes {
            let buttons = operations.map { operation in
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(permissionChanged(_:)))
                button.setAccessibilityLabel(accessClass + " " + operation)
                button.isEnabled = false
                return button
            }
            checks.append(contentsOf: buttons)
            rows.append([NSTextField(labelWithString: accessClass)] + buttons)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 10

        let aclLabel = NSTextField(labelWithString: L("확장 ACL", "Extended ACL"))
        editACL.title = L("ACL 편집", "Edit ACL")
        editACL.target = self; editACL.action = #selector(beginACLEdit(_:))
        editACL.isEnabled = false
        let aclHeader = NSStackView(views: [aclLabel, editACL])
        aclHeader.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        aclText.isEditable = false
        aclText.delegate = self
        aclText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        aclText.setAccessibilityLabel(aclLabel.stringValue)
        aclText.isVerticallyResizable = true
        aclText.autoresizingMask = [.width]
        scroll.documentView = aclText

        accountKind.addItems(withTitles: [L("사용자", "User"), L("그룹", "Group")])
        accountKind.setAccessibilityLabel(L("계정 유형", "Account type"))
        accountKind.target = self; accountKind.action = #selector(changeAccountKind(_:))
        accountName.placeholderString = L("계정 짧은 이름", "Account short name")
        accountName.setAccessibilityLabel(L("계정 짧은 이름", "Account short name"))
        accountList.setAccessibilityLabel(L("계정 목록", "Account list"))
        accountList.target = self; accountList.action = #selector(selectListedAccount(_:))
        accountList.widthAnchor.constraint(equalToConstant: 106).isActive = true
        ruleEffect.addItems(withTitles: [L("허용", "Allow"), L("거부", "Deny")])
        ruleEffect.setAccessibilityLabel(L("규칙 효과", "Rule effect"))
        ruleAccess.addItems(withTitles: [L("읽기", "Read"), L("쓰기", "Write"), L("실행/탐색", "Execute/Search")])
        ruleAccess.setAccessibilityLabel(L("규칙 권한", "Rule permission"))
        addACLRule.title = L("규칙 추가", "Add Rule")
        addACLRule.target = self; addACLRule.action = #selector(appendACLRule(_:))
        let accountRow = NSStackView(views: [accountKind, accountName, accountList])
        let ruleRow = NSStackView(views: [ruleEffect, ruleAccess, addACLRule])
        ruleControls.orientation = .vertical
        ruleControls.alignment = .leading
        ruleControls.addArrangedSubview(accountRow)
        ruleControls.addArrangedSubview(ruleRow)
        setRuleControlsEnabled(false)
        let groupRow = NSStackView(views: [NSTextField(labelWithString: L("그룹 소유권", "Group ownership")), groupList])
        groupList.setAccessibilityLabel(L("그룹 소유권", "Group ownership"))
        groupList.target = self; groupList.action = #selector(changeOwnership(_:))
        groupList.isEnabled = false
        groupList.widthAnchor.constraint(equalToConstant: 156).isActive = true
        let ownerLabel = L("사용자 소유권", "User ownership")
        ownerList.setAccessibilityLabel(ownerLabel)
        ownerList.target = self; ownerList.action = #selector(changeOwnership(_:))
        ownerList.isEnabled = false
        ownerList.widthAnchor.constraint(equalToConstant: 156).isActive = true
        let ownerRow = NSStackView(views: [NSTextField(labelWithString: ownerLabel), ownerList])
        let ownershipHelp = NSTextField(wrappingLabelWithString: L("사용자 소유권 변경에는 macOS 시스템 권한이 필요합니다.",
                                                                  "Changing the user owner requires macOS system privileges."))
        ownershipHelp.textColor = .secondaryLabelColor
        ownershipHelp.preferredMaxLayoutWidth = 350
        includeDescendants.setButtonType(.switch)
        includeDescendants.title = L("하위 파일과 폴더에도 적용", "Apply to enclosed files and folders")
        includeDescendants.target = self; includeDescendants.action = #selector(permissionChanged(_:))
        includeDescendants.isEnabled = false
        stop.title = L("중단", "Stop")
        stop.target = self; stop.action = #selector(stopFolderUpdate(_:))
        stop.isHidden = true
        let resultRow = NSStackView(views: [status, stop])
        let stack = NSStackView(views: [grid, includeDescendants, ownerRow, groupRow, ownershipHelp, aclHeader, ruleControls, scroll, resultRow])
        ownershipHelp.isHidden = FilePropertiesInspector.canChangeOwner
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
        status.preferredMaxLayoutWidth = 350
        status.stringValue = L("권한을 읽는 중…", "Reading permissions…")
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 410)
        alert.accessoryView = stack
    }

    private var selectedMode: Int {
        checks.enumerated().reduce(0) { mode, pair in
            pair.element.state == .on ? mode | (1 << (8 - pair.offset)) : mode
        }
    }

    private func display(_ snapshot: FilePermissionSnapshot) {
        initial = snapshot
        includeDescendants.isEnabled = snapshot.isDirectory
        for (index, button) in checks.enumerated() {
            button.state = snapshot.mode & (1 << (8 - index)) != 0 ? .on : .off
            button.isEnabled = true
        }
        aclText.string = snapshot.accessControlList ?? L("확장 ACL 항목이 없습니다.", "No extended ACL entries.")
        status.stringValue = String(format: "%04o", snapshot.mode)
        editACL.isEnabled = true
        ownerList.addItem(withTitle: L("현재 UID \(snapshot.ownerID)", "Current UID \(snapshot.ownerID)"))
        groupList.addItem(withTitle: L("현재 GID \(snapshot.groupID)", "Current GID \(snapshot.groupID)"))
        Task {
            let groups = await FileACLAccountKind.group.accountNames(memberGroupsOnly: true)
            guard alert.window.sheetParent != nil else { return }
            groupList.addItems(withTitles: groups)
            groupList.isEnabled = !groups.isEmpty && !aclText.isEditable && !save.isEnabled
        }
        if FilePropertiesInspector.canChangeOwner {
            Task {
                let users = await FileACLAccountKind.user.accountNames()
                guard alert.window.sheetParent != nil else { return }
                ownerList.addItems(withTitles: users)
                ownerList.isEnabled = !users.isEmpty && !aclText.isEditable && !save.isEnabled
            }
        }
    }

    @objc private func changeOwnership(_ sender: Any?) {
        let pickedOwner = ownerList.indexOfSelectedItem > 0
        let pickedGroup = groupList.indexOfSelectedItem > 0
        let pickedOwnership = pickedOwner || pickedGroup
        checks.forEach { $0.isEnabled = !pickedOwnership }
        includeDescendants.isEnabled = initial?.isDirectory == true
        editACL.isEnabled = !pickedOwnership
        save.isEnabled = pickedOwnership
        if pickedOwnership {
            ownerList.isEnabled = !pickedGroup && ownerList.numberOfItems > 1
            groupList.isEnabled = !pickedOwner && groupList.numberOfItems > 1
            status.stringValue = includeDescendants.state == .on
                ? L("하위 항목의 소유권도 변경합니다. macOS가 setuid 또는 setgid 비트를 해제할 수 있습니다.",
                    "Ownership also changes on enclosed items. macOS may clear setuid or setgid bits.")
                : L("소유권을 변경하면 macOS가 setuid 또는 setgid 비트를 해제할 수 있습니다.",
                    "macOS may clear setuid or setgid bits when ownership changes.")
        } else {
            permissionChanged(nil)
        }
    }

    @objc private func permissionChanged(_ sender: Any?) {
        guard let initial else { return }
        if aclText.isEditable {
            updateACLSaveState()
            return
        }
        if ownerList.indexOfSelectedItem > 0 || groupList.indexOfSelectedItem > 0 {
            changeOwnership(sender)
            return
        }
        let requested = (initial.mode & 0o7000) | selectedMode
        status.stringValue = String(format: "%04o → %04o", initial.mode, requested)
        save.isEnabled = requested != initial.mode || includeDescendants.state == .on
        if includeDescendants.state == .on {
            status.stringValue = L("하위 파일과 폴더에 같은 읽기·쓰기·실행 비트를 적용합니다.",
                                   "Enclosed files and folders receive the same read, write, and execute bits.")
        }
        editACL.isEnabled = !save.isEnabled
        groupList.isEnabled = !save.isEnabled && groupList.numberOfItems > 1
        ownerList.isEnabled = !save.isEnabled && ownerList.numberOfItems > 1
    }

    @objc private func beginACLEdit(_ sender: Any?) {
        guard let initial, editACL.isEnabled else { return }
        checks.forEach { $0.isEnabled = false }
        includeDescendants.isEnabled = initial.isDirectory
        editACL.isEnabled = false
        groupList.isEnabled = false
        ownerList.isEnabled = false
        aclText.string = initial.accessControlList ?? ""
        aclText.isEditable = true
        setRuleControlsEnabled(true)
        changeAccountKind(nil)
        aclText.isAutomaticQuoteSubstitutionEnabled = false
        aclText.isAutomaticDashSubstitutionEnabled = false
        status.stringValue = L("계정 이름으로 규칙을 추가하거나 ACL 항목을 직접 편집하세요.",
                               "Add a rule by account name or edit the ACL entries directly.")
        alert.window.makeFirstResponder(aclText)
    }

    private func setRuleControlsEnabled(_ enabled: Bool) {
        [accountKind, accountName, accountList, ruleEffect, ruleAccess, addACLRule].forEach { $0.isEnabled = enabled }
    }

    private var selectedAccountKind: FileACLAccountKind {
        accountKind.indexOfSelectedItem == 0 ? .user : .group
    }

    @objc private func changeAccountKind(_ sender: Any?) {
        accountListTask?.cancel()
        accountList.removeAllItems()
        accountList.addItem(withTitle: L("목록", "Accounts"))
        accountList.item(at: 0)?.isEnabled = false
        accountList.autoenablesItems = false
        accountList.isEnabled = false
        accountName.stringValue = ""
        let kind = selectedAccountKind
        accountListTask = Task { [weak self] in
            let names = await kind.accountNames()
            guard let self, !Task.isCancelled, self.aclText.isEditable,
                  self.alert.window.sheetParent != nil else { return }
            self.accountList.addItems(withTitles: names)
            self.accountList.isEnabled = !names.isEmpty
        }
    }

    @objc private func appendACLRule(_ sender: Any?) {
        guard aclText.isEditable, addACLRule.isEnabled else { return }
        let name = accountName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            status.stringValue = L("계정의 짧은 이름을 입력하세요.", "Enter the account’s short name.")
            return
        }
        let kind = selectedAccountKind
        let effect: FileACLEffect = ruleEffect.indexOfSelectedItem == 0 ? .allow : .deny
        let options: [FileACLAccess] = [.read, .write, .execute]
        guard options.indices.contains(ruleAccess.indexOfSelectedItem) else { return }
        let access = options[ruleAccess.indexOfSelectedItem]
        addACLRule.isEnabled = false
        Task {
            defer { addACLRule.isEnabled = aclText.isEditable }
            do {
                let rule = try await kind.rule(for: name, effect: effect, access: access)
                guard alert.window.sheetParent != nil, aclText.isEditable else { return }
                let entries = aclText.string.trimmingCharacters(in: .newlines)
                aclText.string = entries.isEmpty ? rule : entries + "\n" + rule
                updateACLSaveState()
                status.stringValue = L("규칙을 추가했습니다. 저장을 눌러 적용하세요.", "Rule added. Choose Save to apply it.")
            } catch {
                guard alert.window.sheetParent != nil, aclText.isEditable else { return }
                status.stringValue = L("계정을 찾을 수 없습니다.", "Account not found.")
            }
        }
    }

    @objc private func selectListedAccount(_ sender: Any?) {
        guard accountList.indexOfSelectedItem > 0, let name = accountList.titleOfSelectedItem else { return }
        accountName.stringValue = name
        accountList.selectItem(at: 0)
    }

    func textDidChange(_ notification: Notification) {
        updateACLSaveState()
    }

    private func updateACLSaveState() {
        guard aclText.isEditable, let initial else { return }
        let recursive = includeDescendants.state == .on
        save.isEnabled = recursive || aclText.string.trimmingCharacters(in: .whitespacesAndNewlines) != (initial.accessControlList ?? "")
        if recursive {
            status.stringValue = L("하위 항목의 기존 ACL을 이 ACL로 교체합니다.",
                                   "This ACL will replace existing ACLs on enclosed items.")
        }
    }

    @objc private func stopFolderUpdate(_ sender: Any?) {
        folderCancellation?.cancel()
        stop.isEnabled = false
        status.stringValue = L("현재 항목을 마치고 중단합니다…", "Stopping after the current item…")
    }

    @objc private func savePermissions(_ sender: Any?) {
        guard let initial, save.isEnabled else { return }
        let requested = selectedMode
        let aclEntries = aclText.isEditable ? aclText.string : nil
        let group = groupList.indexOfSelectedItem > 0 ? groupList.titleOfSelectedItem : nil
        let owner = ownerList.indexOfSelectedItem > 0 ? ownerList.titleOfSelectedItem : nil
        let cancellation = includeDescendants.state == .on ? CopyCancellation() : nil
        save.isEnabled = false
        editACL.isEnabled = false
        groupList.isEnabled = false
        ownerList.isEnabled = false
        includeDescendants.isEnabled = false
        aclText.isEditable = false
        setRuleControlsEnabled(false)
        alert.buttons[1].isEnabled = false
        checks.forEach { $0.isEnabled = false }
        folderCancellation = cancellation
        if cancellation != nil {
            stop.isHidden = false
            stop.isEnabled = true
            status.stringValue = L("하위 항목의 권한을 변경하는 중…", "Applying permissions to enclosed items…")
        }
        Task {
            defer {
                folderCancellation = nil
                stop.isHidden = true
                alert.buttons[1].isEnabled = true
            }
            do {
                if let cancellation {
                    let result: FolderPermissionResult
                    if let owner {
                        result = try await inspector.setFolderOwnership(owner, kind: .user, at: url, expected: initial, cancellation: cancellation)
                    } else if let group {
                        result = try await inspector.setFolderOwnership(group, kind: .group, at: url, expected: initial, cancellation: cancellation)
                    } else if let aclEntries {
                        result = try await inspector.setFolderAccessControlList(aclEntries, at: url, expected: initial, cancellation: cancellation)
                    } else {
                        result = try await inspector.setFolderPermissions(requested, at: url, expected: initial, cancellation: cancellation)
                    }
                    refreshAfterClose = true
                    let counts = L("적용 \(result.applied)개, 건너뜀 \(result.skipped)개, 실패 \(result.failed)개.",
                                           "Applied to \(result.applied), skipped \(result.skipped), failed \(result.failed).")
                    status.stringValue = result.cancelled ? L("중단됨. 변경한 항목은 유지됩니다. ", "Stopped. Changes already made are kept. ") + counts : counts
                    return
                } else if let owner {
                    _ = try await inspector.setOwner(owner, at: url, expected: initial)
                } else if let group {
                    _ = try await inspector.setGroup(group, at: url, expected: initial)
                } else if let aclEntries {
                    _ = try await inspector.setAccessControlList(aclEntries, at: url, expected: initial)
                } else {
                    _ = try await inspector.setPermissions(requested, at: url, expected: initial)
                }
                if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn) }
                onSave()
            } catch FilePermissionError.changedItem {
                status.stringValue = L("항목이 바뀌었습니다. 속성 창에서 권한을 다시 여세요.", "The item changed. Reopen File Permissions.")
            } catch FilePermissionError.changedPermissions {
                status.stringValue = L("권한이 외부에서 변경되었습니다. 권한을 다시 여세요.", "Permissions changed externally. Reopen File Permissions.")
            } catch FilePermissionError.invalidAccessControlList {
                status.stringValue = L("ACL 형식을 확인하세요.", "Check the ACL entry format.")
                aclText.isEditable = true
                includeDescendants.isEnabled = initial.isDirectory
                setRuleControlsEnabled(true)
                save.isEnabled = true
            } catch {
                status.stringValue = L("권한을 변경하지 못했습니다. ", "Unable to change permissions. ") + error.localizedDescription
            }
        }
    }
#if DEBUG
    var qaReady: Bool { initial != nil }
    var qaOwnerEnabled: Bool { ownerList.isEnabled }
    func qaApplyDescendants(acl: String?, group: String?, stopImmediately: Bool, watchFiles: [URL]) async throws -> Bool {
        guard includeDescendants.isEnabled else { return false }
        if let group {
            let deadline = ContinuousClock.now + .seconds(5)
            while !groupList.isEnabled && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let index = groupList.indexOfItem(withTitle: group)
            guard index > 0, groupList.isEnabled else { return false }
            groupList.selectItem(at: index)
            changeOwnership(nil)
        }
        if let acl {
            editACL.performClick(nil)
            guard aclText.isEditable else { return false }
            aclText.string = acl
        }
        includeDescendants.state = .on
        permissionChanged(nil)
        save.performClick(nil)
        if stopImmediately { stop.performClick(nil) }
        let deadline = ContinuousClock.now + .seconds(5)
        if !watchFiles.isEmpty {
            while stop.isEnabled && !stop.isHidden && ContinuousClock.now < deadline {
                let changed = watchFiles.contains {
                    (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int) == 0o750
                }
                if changed {
                    stop.performClick(nil)
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        while !refreshAfterClose && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard refreshAfterClose else { return false }
        if !watchFiles.isEmpty {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let changed = try files.filter {
                try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int == 0o750
            }.count
            let expected = L("중단됨. 변경한 항목은 유지됩니다. 적용 \(changed)개, 건너뜀 0개, 실패 0개.",
                             "Stopped. Changes already made are kept. Applied to \(changed), skipped 0, failed 0.")
            NSLog("Folder permissions QA: %d changed / %d files; %@", changed, files.count, status.stringValue)
            return changed > 0 && changed < files.count && status.stringValue == expected
        }
        return !stopImmediately || status.stringValue.hasPrefix(L("중단됨.", "Stopped."))
    }
    func dismissQA() {
        alert.window.sheetParent?.endSheet(alert.window)
    }
    func qaSetGroup(_ name: String) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !groupList.isEnabled && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let index = groupList.indexOfItem(withTitle: name)
        guard index > 0, groupList.isEnabled else { return false }
        groupList.selectItem(at: index)
        changeOwnership(nil)
        save.performClick(nil)
        return true
    }
    func qaAddEveryoneRule() async throws -> Bool {
        editACL.performClick(nil)
        guard aclText.isEditable else { return false }
        accountKind.selectItem(at: 1)
        changeAccountKind(nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while accountList.indexOfItem(withTitle: "everyone") < 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let groupIndex = accountList.indexOfItem(withTitle: "everyone")
        guard groupIndex >= 0 else { return false }
        accountList.selectItem(at: groupIndex)
        selectListedAccount(nil)
        ruleEffect.selectItem(at: 0)
        ruleAccess.selectItem(at: 1)
        addACLRule.performClick(nil)
        while !addACLRule.isEnabled && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard save.isEnabled, aclText.string.hasSuffix(":allow:write") else { return false }
        save.performClick(nil)
        return true
    }
    func qaSetACL(_ entries: String) -> Bool {
        editACL.performClick(nil)
        guard aclText.isEditable else { return false }
        aclText.string = entries
        textDidChange(Notification(name: NSText.didChangeNotification, object: aclText))
        guard save.isEnabled else { return false }
        save.performClick(nil)
        return true
    }
    func qaSetMode(_ mode: Int) -> Bool {
        guard qaReady, checks.allSatisfy({ $0.isEnabled && $0.accessibilityLabel()?.isEmpty == false }) else { return false }
        for (index, button) in checks.enumerated() {
            button.state = mode & (1 << (8 - index)) != 0 ? .on : .off
        }
        permissionChanged(nil)
        guard save.isEnabled else { return false }
        save.performClick(nil)
        return true
    }
#endif
}
