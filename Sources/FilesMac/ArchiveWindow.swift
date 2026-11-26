import AppKit
import FilesCore

enum ArchiveReadBackend: Sendable {
    case system, sevenZip(SevenZipArchiveProvider)
    static func resolve(for archive: URL) async throws -> Self {
        guard ArchiveFormat.detect(archive) == .sevenZip else { return .system }
#if DEBUG
        if let path = ProcessInfo.processInfo.environment["FILES_UI_QA_SEVENZIP_BUNDLE"] {
            return .sevenZip(try await .bundled(in: URL(fileURLWithPath: path)))
        }
#endif
        guard Bundle.main.object(forInfoDictionaryKey: "FilesArchiveSDKVersion") != nil else { return .system }
        return .sevenZip(try await .bundled())
    }
    func supportsPassword(for archive: URL) -> Bool {
        if case .sevenZip = self { return true }
        return ArchiveFormat.detect(archive) == .zip
    }
    func entries(at archive: URL, password: String? = nil) async throws -> [ArchiveEntryDescriptor] {
        switch self {
        case .sevenZip(let provider): return try await provider.entries(at: archive, password: password)
        case .system:
            let worker = Task.detached(priority: .userInitiated) { try ZipArchiveProvider().entries(at: archive, password: password) }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
    }
    func extract(_ archive: URL, to destination: URL, password: String?, progress: ArchiveProgressHandler?) async throws -> ArchiveExtractionReport {
        switch self {
        case .sevenZip(let provider): return try await provider.extract(archive, to: destination, password: password, progress: progress)
        case .system: return try await ZipArchiveProvider().extract(archive, to: destination, password: password, progress: progress)
        }
    }
    @MainActor func readWithPassword(_ archive: URL, window: NSWindow) async throws -> (entries: [ArchiveEntryDescriptor], password: String?) {
        do { return (try await entries(at: archive), nil) }
        catch SevenZipWorkerError.worker("password-required") {
            guard let password = await ArchivePasswordPrompt.request(for: window, archiveName: archive.lastPathComponent, reading: true) else { throw CancellationError() }
            return (try await entries(at: archive, password: password), password)
        }
    }
}

@MainActor
final class ArchivePasswordView: NSStackView {
    let secureField = NSSecureTextField(), visibleField = NSTextField()
    let revealButton = NSButton(checkboxWithTitle: L("암호 표시", "Show password"), target: nil, action: nil)
    var onChange: (() -> Void)?
    var value: String {
        get { revealButton.state == .on ? visibleField.stringValue : secureField.stringValue }
        set { clear(); secureField.stringValue = newValue; onChange?() }
    }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        orientation = .vertical; alignment = .leading; spacing = 8
        for field in [secureField, visibleField] {
            field.placeholderString = L("암호", "Password"); field.setAccessibilityLabel(L("암호", "Password"))
            field.delegate = self; field.widthAnchor.constraint(equalToConstant: 360).isActive = true; addArrangedSubview(field)
        }
        visibleField.isHidden = true
        revealButton.target = self; revealButton.action = #selector(toggleReveal(_:)); addArrangedSubview(revealButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func clear() {
        secureField.stringValue = ""; visibleField.stringValue = ""
        revealButton.state = .off; visibleField.isHidden = true; secureField.isHidden = false
    }
    @objc private func toggleReveal(_ sender: NSButton) {
        if sender.state == .on {
            visibleField.stringValue = secureField.stringValue; secureField.stringValue = ""
            secureField.isHidden = true; visibleField.isHidden = false; window?.makeFirstResponder(visibleField)
        } else {
            secureField.stringValue = visibleField.stringValue; visibleField.stringValue = ""
            visibleField.isHidden = true; secureField.isHidden = false; window?.makeFirstResponder(secureField)
        }
    }
}
extension ArchivePasswordView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { onChange?() }
}

@MainActor
final class ArchivePasswordPrompt {
    let input = ArchivePasswordView()
    private let alert = NSAlert()
    private init(name: String, reading: Bool) {
        alert.messageText = L("압축 파일 암호", "Archive Password")
        alert.informativeText = reading ? L("‘\(name)’의 목록을 열 암호를 입력하세요.", "Enter the password to open ‘\(name)’.") : L("‘\(name)’의 내용을 추출할 암호를 입력하세요.", "Enter the password to extract ‘\(name)’.")
        alert.addButton(withTitle: reading ? L("열기", "Open") : L("추출", "Extract")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.accessoryView = input; alert.buttons[0].isEnabled = false
        input.onChange = { [weak self] in
            guard let self else { return }
            self.alert.buttons[0].isEnabled = !self.input.value.isEmpty && !self.input.value.utf8.contains(0)
        }
    }
    static func request(for window: NSWindow, archiveName: String, reading: Bool = false) async -> String? {
        let prompt = ArchivePasswordPrompt(name: archiveName, reading: reading)
#if DEBUG
        qaLatest = prompt
#endif
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prompt.alert.beginSheetModal(for: window) { response in
                    let password = response == .alertFirstButtonReturn ? prompt.input.value : nil
                    prompt.alert.window.orderOut(nil); prompt.input.clear(); continuation.resume(returning: password)
                }
                prompt.alert.window.makeFirstResponder(prompt.input.secureField)
                if Task.isCancelled { prompt.cancel() }
            }
        } onCancel: { Task { @MainActor in prompt.cancel() } }
    }
    private func cancel() {
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    }
#if DEBUG
    private(set) static weak var qaLatest: ArchivePasswordPrompt?
    var qaRejectsEmpty: Bool { !alert.buttons[0].isEnabled }
    func qaSubmit(_ password: String?) {
        guard let password else { cancel(); return }
        input.value = password
        if alert.buttons[0].isEnabled { alert.buttons[0].performClick(nil) }
    }
    static func qaWait(for window: NSWindow) async -> ArchivePasswordPrompt? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(5) {
            if let prompt = qaLatest, prompt.alert.window.sheetParent === window { return prompt }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
#endif
}

@MainActor
final class ArchiveWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var backend: ArchiveReadBackend = .system
    private var operationID = UUID()
    private var pendingClose = false
    private let table = NSTableView(), status = NSTextField(labelWithString: ""), progress = NSProgressIndicator()
    private let extractButton = NSButton(), cancelButton = NSButton()
    private var archiveURL: URL?, entries: [ArchiveEntryDescriptor] = [], task: Task<Void, Never>?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.isReleasedWhenClosed = false; panel.delegate = self; buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        for (id, title, width) in [("path", L("경로", "Path"), 430.0), ("kind", L("종류", "Kind"), 100.0), ("size", L("크기", "Size"), 110.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; stack.addArrangedSubview(scroll)
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle; footer.addArrangedSubview(status)
        progress.style = .bar; progress.controlSize = .small; progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 1; progress.isDisplayedWhenStopped = false; progress.widthAnchor.constraint(equalToConstant: 130).isActive = true; footer.addArrangedSubview(progress)
        cancelButton.title = L("중단", "Stop"); configureFooterButton(cancelButton); cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); footer.addArrangedSubview(cancelButton)
        extractButton.title = L("추출…", "Extract…"); configureFooterButton(extractButton); extractButton.target = self; extractButton.action = #selector(chooseDestination(_:)); footer.addArrangedSubview(extractButton)
        stack.addArrangedSubview(footer); render()
    }

    private func configureFooterButton(_ button: NSButton) {
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
    }

    func present(archiveURL: URL, onRead: (() -> Void)? = nil) {
        task?.cancel(); pendingClose = false; operationID = UUID(); let currentID = operationID
        self.archiveURL = archiveURL; entries = []; table.reloadData()
        window?.title = L("압축 파일: ", "Archive: ") + archiveURL.lastPathComponent
        status.stringValue = L("목록을 읽는 중…", "Reading archive…"); setRunning(true)
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        task = Task { [weak self] in
            do {
                let backend = try await ArchiveReadBackend.resolve(for: archiveURL)
                guard let self, self.operationID == currentID, let window = self.window else { return }
                let loaded = try await backend.readWithPassword(archiveURL, window: window).entries
                guard self.operationID == currentID else { return }
                try Task<Never, Never>.checkCancellation()
                self.backend = backend; self.entries = loaded; self.status.stringValue = L("\(loaded.count)개 항목", "\(loaded.count) items"); self.setRunning(false); self.table.reloadData()
                onRead?()
            } catch is CancellationError { guard let self, self.operationID == currentID else { return }; self.status.stringValue = L("읽기를 중단했습니다.", "Reading stopped."); self.setRunning(false) }
            catch { guard let self, self.operationID == currentID else { return }; self.status.stringValue = archiveErrorMessage(error); self.setRunning(false) }
        }
    }

    @objc private func chooseDestination(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = L("여기에 추출", "Extract Here")
        panel.beginSheetModal(for: window) { [weak self] response in guard response == .OK, let destination = panel.url else { return }; self?.extract(to: destination) }
    }
    private func extract(to destination: URL) {
        guard let archiveURL else { return }; task?.cancel(); operationID = UUID(); let currentID = operationID
        status.stringValue = L("안전하게 추출하는 중…", "Extracting safely…"); setRunning(true)
        task = Task { [weak self, backend] in
            do {
                var password: String?
                if let self, self.entries.contains(where: \.isEncrypted), let window = self.window {
                    guard backend.supportsPassword(for: archiveURL) else { throw ZipArchiveError.unsupportedEncryption }
                    guard let entered = await ArchivePasswordPrompt.request(for: window, archiveName: archiveURL.lastPathComponent) else { throw CancellationError() }
                    password = entered
                }
                try Task<Never, Never>.checkCancellation()
                let report = try await backend.extract(archiveURL, to: destination, password: password) { [weak self] update in
                    Task { @MainActor [weak self] in guard let self, self.operationID == currentID else { return }; self.updateProgress(update) }
                }
                guard let self, self.operationID == currentID else { return }
                self.status.stringValue = L("\(report.entries)개 항목을 추출했습니다.", "Extracted \(report.entries) items."); self.setRunning(false)
            } catch is CancellationError { guard let self, self.operationID == currentID else { return }; self.status.stringValue = L("추출을 중단했습니다.", "Extraction stopped."); self.setRunning(false) }
            catch { guard let self, self.operationID == currentID else { return }; self.status.stringValue = archiveExtractionErrorMessage(error, encrypted: self.entries.contains(where: \.isEncrypted)); self.setRunning(false) }
        }
    }
    @objc private func cancel(_ sender: Any?) { task?.cancel() }
    private func updateProgress(_ update: ArchiveProgress) {
        guard cancelButton.isEnabled else { return }
        progress.isIndeterminate = update.totalBytes == 0 && update.totalEntries == 0
        let byteFraction = update.totalBytes > 0 ? Double(update.completedBytes) / Double(update.totalBytes) : 0
        let entryFraction = update.totalEntries > 0 ? Double(update.completedEntries) / Double(update.totalEntries) : 0
        progress.doubleValue = max(byteFraction, entryFraction)
        let phase = update.phase == .publishing ? L("결과 확정", "Publishing") : L("추출", "Extracting")
        status.stringValue = "\(phase) · \(update.completedEntries)/\(update.totalEntries) · \(ByteCountFormatter.string(fromByteCount: update.completedBytes, countStyle: .file))" + (update.currentPath.map { " · \($0)" } ?? "")
    }
    private func setRunning(_ running: Bool) { if running { progress.isIndeterminate = true; progress.startAnimation(nil) } else { progress.stopAnimation(nil) }; cancelButton.isEnabled = running; extractButton.isEnabled = !running && !entries.isEmpty; if !running && pendingClose { pendingClose = false; window?.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if cancelButton.isEnabled { pendingClose = true; task?.cancel(); return false }; return true }
    private func render() { setRunning(false); status.stringValue = L("압축 파일을 여세요.", "Open an archive.") }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier else { return nil }; let entry = entries[row]
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let text = NSTextField(labelWithString: ""); text.lineBreakMode = .byTruncatingMiddle; text.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(text); c.textField = text; NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        switch id.rawValue { case "path": cell.textField?.stringValue = entry.path; case "kind": cell.textField?.stringValue = entry.kind == .directory ? L("폴더", "Folder") : L("파일", "File"); default: cell.textField?.stringValue = entry.kind == .directory ? "—" : ByteCountFormatter.string(fromByteCount: entry.uncompressedSize, countStyle: .file) }
        return cell
    }
#if DEBUG
    var qaLoaded: Bool { task == nil || (!cancelButton.isEnabled && !entries.isEmpty) }
    var qaEntryCount: Int { entries.count }
    func qaExtract(to destination: URL) { extract(to: destination) }
    var qaIsRunning: Bool { cancelButton.isEnabled }
    var qaSucceeded: Bool { status.stringValue.contains(L("추출했습니다", "Extracted")) }
    var qaMessage: String { status.stringValue }
    func qaCancel() { cancel(nil) }
#endif
}
