import AppKit
import FilesCore
import UniformTypeIdentifiers

@MainActor
final class ArchiveSaveOptionsView: NSStackView, NSOpenSavePanelDelegate {
    let formatButton = NSPopUpButton()
    let levelButton = NSPopUpButton()
    let encryptionButton = NSButton(checkboxWithTitle: L("암호화", "Encrypt"), target: nil, action: nil)
    let passwordInput = ArchivePasswordView()
    let headerEncryptionButton = NSButton(checkboxWithTitle: L("파일 이름 암호화 (7z)", "Encrypt file names (7z)"), target: nil, action: nil)
    var encryptHeader: Bool { selectedFormat == .sevenZip && encryptionButton.state == .on && headerEncryptionButton.state == .on }
    private var supportsSevenZipEncryption: Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["FILES_UI_QA_SEVENZIP_BUNDLE"] != nil { return true }
#endif
        return Bundle.main.object(forInfoDictionaryKey: "FilesArchiveSDKVersion") != nil
    }
    private let passwordNote = NSTextField(wrappingLabelWithString: L("파일 이름은 암호화되지 않습니다.", "File names are not encrypted."))
    var compressionLevel: ArchiveCompressionLevel { ArchiveCompressionLevel.allCases[levelButton.indexOfSelectedItem] }
    private weak var panel: NSSavePanel?
    private let preferences: BrowserPreferences?
    private let formats: [ArchiveFormat] = [.zip, .sevenZip]
    private var selectedFormat: ArchiveFormat = .zip

    init(panel: NSSavePanel, preferences: BrowserPreferences? = nil) {
        self.panel = panel
        self.preferences = preferences
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 210))
        orientation = .vertical; alignment = .leading; spacing = 12
        formatButton.addItems(withTitles: ["ZIP (.zip)", "7z (.7z)"])
        formatButton.setAccessibilityLabel(L("압축 형식", "Archive format"))
        formatButton.identifier = NSUserInterfaceItemIdentifier("archive-format")
        formatButton.target = self; formatButton.action = #selector(changeFormat(_:))
        formatButton.autoenablesItems = false
        levelButton.addItems(withTitles: [L("최고", "Ultra"), L("높음", "High"), L("보통", "Normal"),
                                         L("낮음", "Low"), L("빠르게", "Fast"), L("압축 안 함", "No compression")])
        levelButton.selectItem(at: ArchiveCompressionLevel.allCases.firstIndex(of: preferences?.archiveCompressionLevel ?? .normal)!)
        levelButton.setAccessibilityLabel(L("압축 수준", "Compression level"))
        levelButton.identifier = NSUserInterfaceItemIdentifier("archive-compression-level")
        levelButton.target = self; levelButton.action = #selector(changeLevel(_:))
        for (title, button) in [(L("압축 형식:", "Archive format:"), formatButton),
                                (L("압축 수준:", "Compression level:"), levelButton)] {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 145).isActive = true
            button.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let row = NSStackView(views: [label, button]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            addArrangedSubview(row)
        }
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        encryptionButton.target = self; encryptionButton.action = #selector(changeEncryption(_:))
        addArrangedSubview(encryptionButton); addArrangedSubview(passwordInput); addArrangedSubview(headerEncryptionButton); addArrangedSubview(passwordNote)
        headerEncryptionButton.state = .on; headerEncryptionButton.isHidden = true
        passwordInput.isHidden = true; passwordNote.isHidden = true
        passwordNote.textColor = .secondaryLabelColor; passwordNote.font = .systemFont(ofSize: 11)
        panel.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func panel(_ sender: Any, validate url: URL) throws {
        if encryptionButton.state == .on {
            guard selectedFormat == .zip || supportsSevenZipEncryption else { throw ZipArchiveError.unsupportedEncryption }
            guard !passwordInput.value.isEmpty && !passwordInput.value.utf8.contains(0) else {
                throw NSError(domain: "FilesMac.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: L("암호를 입력하세요.", "Enter a password.")])
            }
        }
    }
    func takePassword() -> String? {
        let value = encryptionButton.state == .on ? passwordInput.value : nil
        clearPassword(); return value
    }
    func clearPassword() {
        passwordInput.clear(); encryptionButton.state = .off
        passwordInput.isHidden = true; passwordNote.isHidden = true; headerEncryptionButton.isHidden = true
        formatButton.item(at: 1)?.isEnabled = true
    }
    @objc private func changeEncryption(_ sender: NSButton) {
        guard selectedFormat == .zip || supportsSevenZipEncryption else { sender.state = .off; clearPassword(); return }
        let encrypted = sender.state == .on
        if !encrypted { passwordInput.clear() }
        passwordInput.isHidden = !encrypted; passwordNote.isHidden = !encrypted
        headerEncryptionButton.isHidden = !encrypted || selectedFormat != .sevenZip
        formatButton.item(at: 1)?.isEnabled = !encrypted || supportsSevenZipEncryption
    }

    @objc private func changeLevel(_ sender: NSPopUpButton) {
        guard ArchiveCompressionLevel.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences?.setArchiveCompressionLevel(compressionLevel)
    }

    @objc private func changeFormat(_ sender: NSPopUpButton) {
        guard formats.indices.contains(sender.indexOfSelectedItem), let panel else { return }
        let format = formats[sender.indexOfSelectedItem]
        if encryptionButton.state == .on && format != .zip && !supportsSevenZipEncryption {
            sender.selectItem(at: formats.firstIndex(of: selectedFormat)!); return
        }
        guard format != selectedFormat, let type = UTType(filenameExtension: format.rawValue) else { return }
        var name = panel.nameFieldStringValue
        if let existing = formats.first(where: { name.lowercased().hasSuffix("." + $0.rawValue) }) {
            name.removeLast(existing.rawValue.count + 1)
        }
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name.isEmpty ? "" : name + "." + format.rawValue
        selectedFormat = format
        encryptionButton.isEnabled = format == .zip || supportsSevenZipEncryption
        headerEncryptionButton.isHidden = encryptionButton.state != .on || format != .sevenZip
        passwordNote.stringValue = format == .sevenZip
            ? L("파일 이름 암호화를 끄면 암호 없이 목록을 볼 수 있습니다.", "When file name encryption is off, the file list is visible without a password.")
            : L("파일 이름은 암호화되지 않습니다.", "File names are not encrypted.")
    }
}

@MainActor
final class ArchiveCreationWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [ArchiveCreationWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let details = NSTextView()
    private let cancelButton = NSButton()
    private var task: Task<Void, Never>?
    private var running = true
    private var succeeded = false
    private var pendingClose = false

    static func start(sources: [URL], destination: URL, compressionLevel: ArchiveCompressionLevel? = nil, password: String? = nil, encryptHeader: Bool = true, completion: @escaping @MainActor () -> Void) {
        guard !sources.isEmpty, !isRunning else { return }
        let controller = ArchiveCreationWindow(sources: sources, destination: destination)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.task = Task { [weak controller] in
            do {
                let backend = try await ArchiveReadBackend.resolve(for: destination)
                let update: ArchiveProgressHandler = { [weak controller] update in
                    Task { @MainActor [weak controller] in controller?.update(update) }
                }
                switch backend {
                case .sevenZip(let provider):
                    _ = try await provider.create(from: sources, at: destination, compressionLevel: compressionLevel ?? .normal,
                                                  password: password, encryptHeader: encryptHeader, progress: update)
                case .system:
                    _ = try await ZipArchiveProvider().create(from: sources, at: destination, compressionLevel: compressionLevel, password: password, progress: update)
                }
                guard let controller else { return }
                controller.finish(success: true, message: L("압축 파일 생성을 완료했습니다.", "Archive created.")); completion()
            } catch is CancellationError {
                controller?.finish(success: false, message: L("생성을 중단했습니다.", "Creation stopped."))
            } catch {
                controller?.finish(success: false, message: archiveErrorMessage(error))
            }
        }
    }

    private init(sources: [URL], destination: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("압축 파일 생성", "Create Archive"); panel.delegate = self; panel.center(); panel.minSize = NSSize(width: 500, height: 300)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)])
        let target = NSTextField(wrappingLabelWithString: L("대상: ", "Destination: ") + destination.path); target.isSelectable = true; stack.addArrangedSubview(target)
        label.stringValue = L("원본을 검증하고 압축 파일을 생성하는 중…", "Validating sources and creating archive…"); stack.addArrangedSubview(label)
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil); stack.addArrangedSubview(progress)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12); details.string = sources.map(\.path).joined(separator: "\n"); scroll.documentView = details; stack.addArrangedSubview(scroll)
        cancelButton.title = L("중단", "Stop"); cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); stack.addArrangedSubview(cancelButton)
        for view in [target, label, progress, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }

    @objc private func cancel(_ sender: Any?) {
        if !running { close(); return }
        task?.cancel(); cancelButton.isEnabled = false; label.stringValue = L("중단 요청됨 — 안전한 지점에서 임시 파일을 정리합니다.", "Stop requested — temporary output will be cleaned at a safe point.")
    }
    private func update(_ update: ArchiveProgress) {
        guard running else { return }
        progress.isIndeterminate = update.totalBytes == 0 && update.totalEntries == 0
        let byteFraction = update.totalBytes > 0 ? Double(update.completedBytes) / Double(update.totalBytes) : 0
        let entryFraction = update.totalEntries > 0 ? Double(update.completedEntries) / Double(update.totalEntries) : 0
        progress.doubleValue = max(byteFraction, entryFraction)
        let phase = update.phase == .publishing ? L("결과 확정", "Publishing") : L("압축 생성", "Creating archive")
        label.stringValue = "\(phase) · \(update.completedEntries)/\(update.totalEntries) · \(ByteCountFormatter.string(fromByteCount: update.completedBytes, countStyle: .file))" + (update.currentPath.map { " · \($0)" } ?? "")
    }
    private func finish(success: Bool, message: String) {
        running = false; succeeded = success; progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = success ? 1 : 0; label.stringValue = message; cancelButton.title = L("닫기", "Close"); cancelButton.isEnabled = true
        if pendingClose { close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { pendingClose = true; cancel(nil); return false }; return true }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
#if DEBUG
    static var qaLatest: ArchiveCreationWindow? { operations.last }
    var qaRunning: Bool { running }
    var qaSucceeded: Bool { succeeded }
    func qaCancel() { cancel(nil) }
#endif
}
