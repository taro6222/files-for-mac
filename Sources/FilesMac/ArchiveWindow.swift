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
        guard Bundle.main.object(forInfoDictionaryKey: "FilesArchiveSDKVersion") != nil else {
            if SevenZipVolumes.index(of: archive) != nil { throw SevenZipVolumeError.sdkRequired }
            return .system
        }
        return .sevenZip(try await .bundled())
    }
    static func editingProvider() async throws -> SevenZipArchiveProvider {
#if DEBUG
        if let path = ProcessInfo.processInfo.environment["FILES_UI_QA_SEVENZIP_BUNDLE"] { return try await .bundled(in: URL(fileURLWithPath: path)) }
#endif
        return try await .bundled()
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
    private init(name: String, reading: Bool, editing: Bool) {
        alert.messageText = L("압축 파일 암호", "Archive Password")
        alert.informativeText = reading ? L("‘\(name)’의 목록을 열 암호를 입력하세요.", "Enter the password to open ‘\(name)’.") : L("‘\(name)’의 내용을 추출할 암호를 입력하세요.", "Enter the password to extract ‘\(name)’.")
        alert.addButton(withTitle: reading ? L("열기", "Open") : L("추출", "Extract")); alert.addButton(withTitle: L("취소", "Cancel"))
        if editing {
            alert.informativeText = L("‘\(name)’을 편집할 현재 암호를 입력하세요.", "Enter the current password to edit ‘\(name)’.")
            alert.buttons[0].title = L("계속", "Continue")
        }
        alert.accessoryView = input; alert.buttons[0].isEnabled = false
        input.onChange = { [weak self] in
            guard let self else { return }
            self.alert.buttons[0].isEnabled = !self.input.value.isEmpty && !self.input.value.utf8.contains(0)
        }
    }
    static func request(for window: NSWindow, archiveName: String, reading: Bool = false, editing: Bool = false) async -> String? {
        let prompt = ArchivePasswordPrompt(name: archiveName, reading: reading, editing: editing)
#if DEBUG
        qaLatest = prompt
        prompt.qaWindowID = ObjectIdentifier(window)
        qaActive[ObjectIdentifier(window)] = WeakPrompt(prompt)
#endif
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prompt.alert.beginSheetModal(for: window) { response in
#if DEBUG
                    prompt.qaRetire()
#endif
                    let password = response == .alertFirstButtonReturn ? prompt.input.value : nil
                    prompt.alert.window.orderOut(nil); prompt.input.clear(); continuation.resume(returning: password)
                }
                prompt.alert.window.makeFirstResponder(prompt.input.secureField)
                if Task.isCancelled { prompt.cancel() }
            }
        } onCancel: { Task { @MainActor in prompt.cancel() } }
    }
    private func cancel() {
#if DEBUG
        qaRetire()
#endif
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    }
#if DEBUG
    private(set) static weak var qaLatest: ArchivePasswordPrompt?
    private final class WeakPrompt {
        weak var value: ArchivePasswordPrompt?
        init(_ value: ArchivePasswordPrompt) { self.value = value }
    }
    private static var qaActive: [ObjectIdentifier: WeakPrompt] = [:]
    private var qaWindowID: ObjectIdentifier?
    private func qaRetire() {
        if let key = qaWindowID, Self.qaActive[key]?.value === self { Self.qaActive.removeValue(forKey: key) }
    }
    var qaRejectsEmpty: Bool { !alert.buttons[0].isEnabled }
    func qaSubmit(_ password: String?) {
        guard let password else { cancel(); return }
        input.value = password
        if alert.buttons[0].isEnabled { qaRetire(); alert.buttons[0].performClick(nil) }
    }
    static func qaWait(for window: NSWindow) async -> ArchivePasswordPrompt? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(5) {
            if let prompt = qaActive[ObjectIdentifier(window)]?.value, prompt.alert.window.sheetParent === window { return prompt }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
#endif
}

@MainActor
private final class ArchiveNameInput: NSStackView, NSTextFieldDelegate {
    let field = NSTextField(), errorLabel = NSTextField(wrappingLabelWithString: "")
    let validation: (String) -> String?
    var onValidity: ((Bool) -> Void)?
    init(initial: String, validate: @escaping (String) -> String?) {
        validation = validate; super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 70))
        orientation = .vertical; alignment = .leading; spacing = 6
        field.stringValue = initial; field.delegate = self; field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        field.setAccessibilityLabel(L("이름", "Name")); errorLabel.textColor = .systemRed
        addArrangedSubview(field); addArrangedSubview(errorLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func validate() { let message = validation(field.stringValue); errorLabel.stringValue = message ?? ""; onValidity?(message == nil) }
    func controlTextDidChange(_ obj: Notification) { validate() }
}
@MainActor
private final class ArchiveEditingTable: NSTableView {
    var onRename: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { onRename?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if isEnabled {
            if row < 0 { deselectAll(nil) }
            else if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        return super.menu(for: event)
    }
}

@MainActor
final class ArchiveAdditionOptionsView: NSStackView {
    let encryption = NSButton(checkboxWithTitle: L("추가 파일 암호화", "Encrypt added files"), target: nil, action: nil)
    var encryptNewData: Bool { encryption.state == .on }
    init(required: Bool, emptyZIP: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 76))
        orientation = .vertical; alignment = .leading; spacing = 8
        encryption.state = required || emptyZIP ? .on : .off; encryption.isEnabled = !required
        encryption.setAccessibilityLabel(encryption.title)
        let message = required
            ? L("기존 암호화 파일이 있으므로 추가 파일도 같은 암호로 보호합니다.", "Added files use the same password as the existing encrypted files.")
            : emptyZIP
                ? L("파일이 없는 ZIP입니다. 추가 파일의 암호를 새로 지정하거나 암호화를 해제하세요.", "This ZIP has no files. Set a password for added files, or turn encryption off.")
                : L("새 파일에 암호를 지정할 수 있습니다. 기존 항목의 암호화 상태는 유지합니다.", "You can set a password for added files. Existing items retain their encryption.")
        let note = NSTextField(wrappingLabelWithString: message)
        addArrangedSubview(encryption); addArrangedSubview(note)
        note.widthAnchor.constraint(equalToConstant: 440).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class ArchiveWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var backend: ArchiveReadBackend = .system
    private var operationID = UUID()
    private var pendingClose = false
    private let table = ArchiveEditingTable(), status = NSTextField(labelWithString: ""), progress = NSProgressIndicator()
    private let extractButton = NSButton(), cancelButton = NSButton()
    private let addButton = NSButton(), folderButton = NSButton(), renameButton = NSButton(), deleteButton = NSButton(), undoButton = NSButton(), redoButton = NSButton(), recoveryButton = NSButton()
    private var editor: SevenZipArchiveProvider?, sourceVersion: ArchiveEditSourceVersion?
    private var isRunning = false, hasLoaded = false, cancelRequested = false, editingOperation = false, headerEncrypted = false
    private var undoReports: [ArchiveEditReport] = [], redoReports: [ArchiveEditReport] = [], recoveryLocations: [URL] = []
    private var nameAlert: NSAlert?, nameInput: ArchiveNameInput?
    private var storedConfirmation: NSAlert?
    #if DEBUG
    var qaJournalDirectory: URL?
    #endif
    private var pendingPresentation: (URL, (() -> Void)?)?
    private var archiveURL: URL?, entries: [ArchiveEntryDescriptor] = [], task: Task<Void, Never>?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.minSize = NSSize(width: 760, height: 360); panel.isReleasedWhenClosed = false; panel.delegate = self; buildUI()
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
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        table.onRename = { [weak self] in self?.renameSelection(nil) }
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 6
        for (button, title, action) in [(addButton, L("파일 추가…", "Add Files…"), #selector(addFiles(_:))),
            (folderButton, L("새 폴더…", "New Folder…"), #selector(createFolder(_:))), (renameButton, L("이름 변경…", "Rename…"), #selector(renameSelection(_:))),
            (deleteButton, L("압축에서 삭제…", "Delete from Archive…"), #selector(deleteSelection(_:))), (undoButton, L("실행 취소…", "Undo…"), #selector(undoLastFileTransfer(_:))), (redoButton, L("다시 실행…", "Redo…"), #selector(redoLastMove(_:)))] {
            button.title = title; button.target = self; button.action = action; configureFooterButton(button); button.setAccessibilityLabel(title); actions.addArrangedSubview(button)
        }
        let menu = NSMenu()
        for button in [addButton, folderButton, renameButton, deleteButton, undoButton, redoButton] { let item = NSMenuItem(title: button.title, action: button.action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        table.menu = menu; stack.addArrangedSubview(actions)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; stack.addArrangedSubview(scroll)
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle; footer.addArrangedSubview(status)
        progress.style = .bar; progress.controlSize = .small; progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 1; progress.isDisplayedWhenStopped = false; progress.widthAnchor.constraint(equalToConstant: 130).isActive = true; footer.addArrangedSubview(progress)
        cancelButton.title = L("중단", "Stop"); configureFooterButton(cancelButton); cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); footer.addArrangedSubview(cancelButton)
        extractButton.title = L("추출…", "Extract…"); configureFooterButton(extractButton); extractButton.target = self; extractButton.action = #selector(chooseDestination(_:)); footer.addArrangedSubview(extractButton)
        stack.addArrangedSubview(footer)
        recoveryButton.title = L("편집 기록 및 보존 파일…", "Edit History and Retained Files…"); recoveryButton.target = self; recoveryButton.action = #selector(showRecovery(_:)); recoveryButton.isHidden = true; stack.addArrangedSubview(recoveryButton)
        render()
    }

    private func configureFooterButton(_ button: NSButton) {
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
    }

    func present(archiveURL: URL, onRead: (() -> Void)? = nil) {
        if isRunning { pendingPresentation = (archiveURL, onRead); task?.cancel(); return }
        if let sheet = window?.attachedSheet { pendingPresentation = (archiveURL, onRead); window?.endSheet(sheet, returnCode: sheet is NSOpenPanel ? .cancel : .alertSecondButtonReturn); return }
        if self.archiveURL?.standardizedFileURL != archiveURL.standardizedFileURL { undoReports = []; redoReports = [] }
        task?.cancel(); pendingClose = false; operationID = UUID(); let currentID = operationID
        sourceVersion = nil; hasLoaded = false; headerEncrypted = false; editor = nil; recoveryLocations = []; recoveryButton.isHidden = true
        self.archiveURL = archiveURL; entries = []; table.reloadData()
        window?.title = L("압축 파일: ", "Archive: ") + archiveURL.lastPathComponent
        status.stringValue = L("목록을 읽는 중…", "Reading archive…"); setRunning(true)
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        task = Task { [weak self] in
            do {
                let backend = try await ArchiveReadBackend.resolve(for: archiveURL)
                guard let self, self.operationID == currentID, let window = self.window else { return }
                let version = try? await Task.detached { try ArchiveEditSourceVersion(at: archiveURL) }.value
                let read = try await backend.readWithPassword(archiveURL, window: window)
                let loaded = read.entries
                let editor = try? await ArchiveReadBackend.editingProvider()
                if let version { guard try await Task.detached(operation: { try ArchiveEditSourceVersion(at: archiveURL) }).value == version else { throw SevenZipWorkerError.worker("source-changed") } }
                guard self.operationID == currentID else { return }
                try Task<Never, Never>.checkCancellation()
                self.backend = backend; self.editor = editor; self.headerEncrypted = ArchiveFormat.detect(archiveURL) == .sevenZip && read.password != nil; self.sourceVersion = version; self.hasLoaded = true; self.entries = loaded; self.status.stringValue = L("\(loaded.count)개 항목", "\(loaded.count) items"); self.setRunning(false); self.table.reloadData()
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
    @objc private func cancel(_ sender: Any?) { cancelRequested = true; cancelButton.isEnabled = false; status.stringValue = L("중단 요청을 처리하는 중…", "Finishing the stop request…"); task?.cancel() }
    private func updateProgress(_ update: ArchiveProgress) {
        guard isRunning, !cancelRequested else { return }
        progress.isIndeterminate = update.totalBytes == 0 && update.totalEntries == 0
        let byteFraction = update.totalBytes > 0 ? Double(update.completedBytes) / Double(update.totalBytes) : 0
        let entryFraction = update.totalEntries > 0 ? Double(update.completedEntries) / Double(update.totalEntries) : 0
        progress.doubleValue = max(byteFraction, entryFraction)
        let phase = update.phase == .publishing ? L("결과 확정", "Publishing") : (editingOperation ? L("편집", "Editing") : L("추출", "Extracting"))
        status.stringValue = "\(phase) · \(update.completedEntries)/\(update.totalEntries) · \(ByteCountFormatter.string(fromByteCount: update.completedBytes, countStyle: .file))" + (update.currentPath.map { " · \($0)" } ?? "")
    }
    private func setRunning(_ running: Bool) {
        isRunning = running
        if running { cancelRequested = false; progress.isIndeterminate = true; progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        cancelButton.isEnabled = running; extractButton.isEnabled = !running && !entries.isEmpty; table.isEnabled = !running; renderEditActions()
        if !running && pendingClose { pendingClose = false; pendingPresentation = nil; window?.close() }
        else if !running, let next = pendingPresentation { pendingPresentation = nil; present(archiveURL: next.0, onRead: next.1) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if isRunning { pendingClose = true; cancel(nil); return false }; return true }
    private var selectedEntries: [ArchiveEntryDescriptor] { table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil } }
    private func cleanPath(_ path: String) -> String { path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private var targetDirectory: String {
        guard selectedEntries.count == 1, let entry = selectedEntries.first else { return "" }
        return entry.kind == .directory ? cleanPath(entry.path) : cleanPath(entry.path).split(separator: "/").dropLast().joined(separator: "/")
    }
    private var canEdit: Bool { hasLoaded && !isRunning && window?.attachedSheet == nil && editor != nil && sourceVersion != nil && archiveURL.map { [.zip, .sevenZip].contains(ArchiveFormat.detect($0)) && SevenZipVolumes.index(of: $0) == nil } == true }
    private func renderEditActions() {
        for button in [addButton, folderButton] { button.isEnabled = canEdit }
        renameButton.isEnabled = canEdit && selectedEntries.count == 1
        deleteButton.isEnabled = canEdit && !selectedEntries.isEmpty
        undoButton.isEnabled = canEdit && !undoReports.isEmpty
        redoButton.isEnabled = canEdit && !redoReports.isEmpty
    }
    func tableViewSelectionDidChange(_ notification: Notification) { renderEditActions() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(addFiles(_:)), #selector(createFolder(_:)): return canEdit
        case #selector(renameSelection(_:)): return canEdit && selectedEntries.count == 1
        case #selector(deleteSelection(_:)): item.title = L("압축에서 삭제…", "Delete from Archive…"); return canEdit && !selectedEntries.isEmpty
        case #selector(redoLastMove(_:)): item.title = L("마지막 압축 편집 다시 실행…", "Redo Last Archive Edit…"); return canEdit && !redoReports.isEmpty
        case #selector(undoLastFileTransfer(_:)): item.title = L("마지막 압축 편집 실행 취소…", "Undo Last Archive Edit…"); return canEdit && !undoReports.isEmpty
        default: return false
        }
    }
    private func additionOptions() -> ArchiveAdditionOptionsView {
        ArchiveAdditionOptionsView(required: headerEncrypted || entries.contains(where: \.isEncrypted),
                                   emptyZIP: archiveURL.map { ArchiveFormat.detect($0) == .zip } == true && !entries.contains(where: { $0.kind == .regularFile }))
    }
    @objc private func addFiles(_ sender: Any?) {
        guard canEdit, let window else { return }; let directory = targetDirectory
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = L("추가", "Add"); panel.message = L("추가 위치: /", "Add to: /") + directory
        let options = additionOptions(); panel.accessoryView = options
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.renderEditActions()
            if response == .OK { self.performEdit([.add(sources: panel.urls, directory: directory)], selecting: panel.urls.map { (directory.isEmpty ? "" : directory + "/") + $0.lastPathComponent }, encryptNewData: options.encryptNewData) }
            else { self.setRunning(false) }
        }; renderEditActions()
    }
    @objc func createFolder(_ sender: Any?) {
        guard canEdit else { return }; let directory = targetDirectory
        askName(title: L("압축 안에 새 폴더", "New Folder in Archive"), initial: L("새 폴더", "New Folder"), directory: directory, renaming: nil) { [weak self] name in
            let path = (directory.isEmpty ? "" : directory + "/") + name
            self?.performEdit([.createDirectory(path: path)], selecting: [path])
        }
    }
    @objc func renameSelection(_ sender: Any?) {
        guard canEdit, selectedEntries.count == 1, let entry = selectedEntries.first else { return }
        let path = cleanPath(entry.path), directory = path.split(separator: "/").dropLast().joined(separator: "/")
        askName(title: L("압축 항목 이름 변경", "Rename Archive Item"), initial: path.split(separator: "/").last.map(String.init) ?? path, directory: directory, renaming: entry) { [weak self] name in
            self?.performEdit([.rename(path: path, newName: name)], selecting: [(directory.isEmpty ? "" : directory + "/") + name])
        }
    }
    private func askName(title: String, initial: String, directory: String, renaming: ArchiveEntryDescriptor?, submit: @escaping @MainActor (String) -> Void) {
        guard canEdit, let window else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = L("위치: /", "Location: /") + directory
        alert.addButton(withTitle: L("저장", "Save")); alert.addButton(withTitle: L("취소", "Cancel"))
        let input = ArchiveNameInput(initial: initial) { [weak self] name in
            guard let self else { return L("창이 닫혔습니다.", "The window closed.") }
            do {
                guard !name.contains("/") else { throw ArchiveValidationError.invalidPath(name) }
                _ = try ArchiveExtractionValidator.validate([.init(path: name, kind: .regularFile)])
                if let renaming, name == initial { return L("다른 이름을 입력하세요.", "Enter a different name.") }
                let desired = (directory.isEmpty ? "" : directory + "/") + name
                let old = renaming.map { self.cleanPath($0.path) }
                var result = Set<String>()
                for entry in self.entries {
                    let path = self.cleanPath(entry.path)
                    let changed = old.map { path == $0 || (renaming?.kind == .directory && path.hasPrefix($0 + "/")) } ?? false
                    let next = changed ? desired + String(path.dropFirst(old!.count)) : path
                    if !result.insert(next.precomposedStringWithCanonicalMapping).inserted { return L("같은 이름의 항목이 있습니다.", "An item with this name already exists.") }
                }
                if old == nil && result.contains(desired.precomposedStringWithCanonicalMapping) { return L("같은 이름의 항목이 있습니다.", "An item with this name already exists.") }
                return nil
            } catch { return L("비어 있지 않은 올바른 이름을 입력하세요.", "Enter a valid, nonempty name.") }
        }
        alert.accessoryView = input; input.onValidity = { [weak alert] valid in alert?.buttons.first?.isEnabled = valid }; input.validate()
        nameAlert = alert; nameInput = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; alert.window.orderOut(nil); self.nameAlert = nil; self.nameInput = nil; self.renderEditActions()
            if response == .alertFirstButtonReturn { submit(input.field.stringValue) } else { self.setRunning(false) }
        }; alert.window.makeFirstResponder(input.field); renderEditActions()
    }
    @objc func deleteSelection(_ sender: Any?) {
        guard canEdit, !selectedEntries.isEmpty else { return }; let selected = selectedEntries
        let paths = selected.map { cleanPath($0.path) }
        let count = entries.filter { entry in selected.contains { selection in let path = cleanPath(selection.path); return cleanPath(entry.path) == path || (selection.kind == .directory && entry.path.hasPrefix(path + "/")) } }.count
        var message = L("하위 항목을 포함하여 \(count)개 항목을 삭제합니다. 이전 원본은 실행 취소를 위해 보관합니다.", "Delete \(count) items, including descendants. The previous archive is retained for Undo.")
        let encrypted = entries.filter(\.isEncrypted)
        let removesLastEncryptedZIP = archiveURL.map { ArchiveFormat.detect($0) == .zip } == true && !encrypted.isEmpty && encrypted.allSatisfy { entry in
            selected.contains { selection in let path = cleanPath(selection.path); return cleanPath(entry.path) == path || (selection.kind == .directory && entry.path.hasPrefix(path + "/")) }
        }
        if removesLastEncryptedZIP { message += L("\n\n암호화된 파일이 모두 삭제됩니다. 이후 파일 추가 시 암호화를 다시 선택하세요. 파일이 없는 ZIP에는 기존 암호를 재사용할 정보가 남지 않습니다.", "\n\nAll encrypted files will be removed. Choose encryption again when adding files later. A ZIP with no files cannot supply the previous password.") }
        confirm(title: L("압축에서 삭제", "Delete from Archive"), message: message, button: L("삭제", "Delete")) { [weak self] in self?.performEdit([.delete(paths: paths)], selecting: []) }
    }
    private func confirm(title: String, message: String, button: String, action: @escaping @MainActor () -> Void) {
        guard let window else { return }; let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: button); alert.addButton(withTitle: L("취소", "Cancel")); storedConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; alert.window.orderOut(nil); self.storedConfirmation = nil; self.renderEditActions()
            if response == .alertFirstButtonReturn { action() } else { self.setRunning(false) }
        }; renderEditActions()
    }
    private func performEdit(_ operations: [ArchiveEditOperation], selecting paths: [String], encryptNewData: Bool? = nil) {
        guard canEdit, let editor, let archiveURL, let sourceVersion else { return }
        operationID = UUID(); let currentID = operationID; editingOperation = true
        status.stringValue = L("압축 파일을 편집하는 중…", "Editing archive…"); setRunning(true)
        task = Task { [weak self] in
            guard let self else { return }; var password: String?, saved = false
            do {
                var report: ArchiveEditReport?
                while report == nil {
                    do {
                        report = try await editor.edit(archiveURL, operations: operations, password: password, encryptNewData: password != nil || (encryptNewData ?? self.entries.contains(where: \.isEncrypted)), journalDirectory: self.editJournalDirectory, expectedSource: sourceVersion) { [weak self] update in
                            Task { @MainActor [weak self] in guard let self, self.operationID == currentID else { return }; self.updateProgress(update) }
                        }
                    } catch SevenZipWorkerError.worker(let code) where code == "password-required" || code == "password-or-corrupt" {
                        try Task.checkCancellation(); guard self.operationID == currentID, let window = self.window else { throw CancellationError() }
                        self.status.stringValue = L("암호를 확인하세요.", "Check the archive password.")
                        guard let entered = await ArchivePasswordPrompt.request(for: window, archiveName: archiveURL.lastPathComponent, editing: true) else { throw CancellationError() }
                        password = entered
                    }
                }
                guard let report else { throw SevenZipWorkerError.invalidResponse }
                saved = true; self.undoReports.append(report); self.redoReports = []; self.archiveURL = report.archive; self.sourceVersion = nil
                try await self.reloadAfterEdit(password: password, selecting: paths)
                guard self.operationID == currentID else { return }
                self.status.stringValue = L("저장했습니다 · \(self.entries.count)개 항목", "Saved · \(self.entries.count) items")
            } catch is CancellationError { self.status.stringValue = saved ? L("저장했습니다. 목록을 다시 열어 확인하세요.", "Saved. Reopen the archive to refresh its listing.") : L("편집을 중단했습니다. 파일은 보존했습니다.", "Editing stopped. Files were preserved.") }
            catch {
                self.status.stringValue = saved ? L("저장했지만 목록을 새로 읽지 못했습니다. 다시 여세요.", "Saved, but the listing could not be refreshed. Reopen the archive.") : archiveEditErrorMessage(error)
                if case SevenZipWorkerError.worker("source-changed") = error { self.sourceVersion = nil }
                if case let ArchiveEditError.recoveryRequired(journal, _, retained) = error { self.recoveryLocations = [retained, journal]; self.recoveryButton.isHidden = false }
            }
            guard self.operationID == currentID else { return }; self.editingOperation = false; self.setRunning(false)
            NSAccessibility.post(element: self.status, notification: .valueChanged)
        }
    }
    private var editJournalDirectory: URL {
#if DEBUG
        if let qaJournalDirectory { return qaJournalDirectory }
#endif
        return ArchiveSplitRecoveryWindow.journalDirectory
    }
    private func reloadAfterEdit(password: String?, selecting paths: [String]) async throws {
        guard let archiveURL else { throw SevenZipWorkerError.invalidConfiguration }; let backend = self.backend
        let refresh = Task.detached { () -> ([ArchiveEntryDescriptor], ArchiveEditSourceVersion) in
            let version = try ArchiveEditSourceVersion(at: archiveURL)
            let entries = try await backend.entries(at: archiveURL, password: password)
            guard try ArchiveEditSourceVersion(at: archiveURL) == version else { throw SevenZipWorkerError.worker("source-changed") }
            return (entries, version)
        }
        let loaded = try await withTaskCancellationHandler(operation: { try await refresh.value }, onCancel: { refresh.cancel() })
        entries = loaded.0; sourceVersion = loaded.1; hasLoaded = true; table.reloadData()
        let desired = Set(paths.map(cleanPath)), selected = IndexSet(entries.indices.filter { desired.contains(cleanPath(entries[$0].path)) })
        table.selectRowIndexes(selected, byExtendingSelection: false)
        if let first = selected.first { table.scrollRowToVisible(first) }; window?.makeFirstResponder(table)
    }
    @objc func undoLastFileTransfer(_ sender: Any?) {
        guard canEdit, let report = undoReports.last else { return }
        confirm(title: L("마지막 압축 편집 실행 취소", "Undo Last Archive Edit"), message: L("이전 원본을 복원합니다. 수정본도 별도로 보존합니다.", "Restore the previous archive and retain the edited version."), button: L("실행 취소", "Undo")) { [weak self] in self?.performRestore(report, redo: false) }
    }
    @objc func redoLastMove(_ sender: Any?) {
        guard canEdit, let report = redoReports.last else { return }
        confirm(title: L("마지막 압축 편집 다시 실행", "Redo Last Archive Edit"), message: L("보존한 수정본을 다시 적용합니다. 현재 원본도 보존합니다.", "Reapply the retained edited version and preserve the current original."), button: L("다시 실행", "Redo")) { [weak self] in self?.performRestore(report, redo: true) }
    }
    private func performRestore(_ report: ArchiveEditReport, redo: Bool) {
        guard canEdit else { return }; operationID = UUID(); let currentID = operationID; editingOperation = true
        status.stringValue = redo ? L("압축 편집을 다시 적용하는 중…", "Reapplying the archive edit…") : L("이전 원본을 복원하는 중…", "Restoring the previous archive…"); setRunning(true)
        task = Task { [weak self] in
            guard let self else { return }; var restored = false
            do {
                let result = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: report.journal, journalDirectory: self.editJournalDirectory, action: redo ? .redo : .undo)
                if redo { guard case .committed = result else { throw ArchiveEditError.invalidState }; _ = self.redoReports.popLast(); self.undoReports.append(report) }
                else { guard case .undone = result else { throw ArchiveEditError.invalidState }; _ = self.undoReports.popLast(); self.redoReports.append(report) }
                restored = true; self.sourceVersion = nil
                // Reopening an encrypted-header listing may require a password again.
                let loaded = Task { @MainActor in
                    guard let window = self.window else { throw CancellationError() }
                    let result = try await self.backend.readWithPassword(report.archive, window: window)
                    try await self.reloadAfterEdit(password: result.password, selecting: [])
                }
                try await withTaskCancellationHandler(operation: { try await loaded.value }, onCancel: { loaded.cancel() }); self.status.stringValue = redo ? L("압축 편집을 다시 실행했습니다.", "Archive edit reapplied.") : L("압축 편집을 실행 취소했습니다.", "Archive edit undone.")
            } catch { self.status.stringValue = restored ? L("복원했습니다. 목록을 다시 열어 확인하세요.", "Restored. Reopen the archive to refresh its listing.") : archiveEditErrorMessage(error) }
            guard self.operationID == currentID else { return }; self.editingOperation = false; self.setRunning(false)
            NSAccessibility.post(element: self.status, notification: .valueChanged)
        }
    }
    @objc private func showRecovery(_ sender: Any?) { ArchiveEditRecoveryWindow.present(journalDirectory: editJournalDirectory) }
    private func render() { setRunning(false); status.stringValue = L("압축 파일을 여세요.", "Open an archive.") }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier else { return nil }; let entry = entries[row]
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let text = NSTextField(labelWithString: ""); text.lineBreakMode = .byTruncatingMiddle; text.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(text); c.textField = text; NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        switch id.rawValue { case "path": cell.textField?.stringValue = entry.path; case "kind": cell.textField?.stringValue = entry.kind == .directory ? L("폴더", "Folder") : L("파일", "File"); default: cell.textField?.stringValue = entry.kind == .directory ? "—" : ByteCountFormatter.string(fromByteCount: entry.uncompressedSize, countStyle: .file) }
        return cell
    }
#if DEBUG
    var qaEditReady: Bool { canEdit }
    var qaEntryPaths: [String] { entries.map { cleanPath($0.path) } }
    var qaCanUndoEdit: Bool { undoButton.isEnabled }
    var qaCanRedoEdit: Bool { redoButton.isEnabled }
    var qaRedoJournal: URL? { redoReports.last?.journal }
    var qaArchiveURL: URL? { archiveURL }
    func qaRedoEdit() { redoLastMove(nil) }
    func qaSelectPaths(_ paths: [String]) { let selected = Set(paths); table.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(cleanPath(entries[$0].path)) }), byExtendingSelection: false) }
    func qaCreateFolder() { createFolder(nil) }
    func qaRename() { renameSelection(nil) }
    func qaDelete() { deleteSelection(nil) }
    func qaUndoEdit() { undoLastFileTransfer(nil) }
    func qaSubmitName(_ name: String?) { guard let alert = nameAlert else { return }; if let name { nameInput?.field.stringValue = name; nameInput?.validate(); if alert.buttons[0].isEnabled { alert.buttons[0].performClick(nil) } } else { window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) } }
    var qaNameRejected: Bool { nameAlert?.buttons.first?.isEnabled == false }
    func qaConfirm(_ accepted: Bool) { storedConfirmation?.buttons[accepted ? 0 : 1].performClick(nil) }
    func qaAdditionOptions() -> ArchiveAdditionOptionsView { additionOptions() }
    var qaDeleteNotice: String? { storedConfirmation?.informativeText }
    func qaAdd(_ sources: [URL], directory: String, encryptNewData: Bool? = nil) { performEdit([.add(sources: sources, directory: directory)], selecting: sources.map { (directory.isEmpty ? "" : directory + "/") + $0.lastPathComponent }, encryptNewData: encryptNewData) }
    var qaLoaded: Bool { !isRunning && hasLoaded }
    var qaEntryCount: Int { entries.count }
    func qaExtract(to destination: URL) { extract(to: destination) }
    var qaIsRunning: Bool { isRunning }
    var qaSucceeded: Bool { status.stringValue.contains(L("추출했습니다", "Extracted")) }
    var qaMessage: String { status.stringValue }
    func qaCancel() { cancel(nil) }
#endif
}
