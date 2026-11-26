import AppKit
import FilesCore
import Darwin

@MainActor
final class ArchiveExtractionWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [ArchiveExtractionWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator(), details = NSTextView(), cancelButton = NSButton()
    private var task: Task<Void, Never>?, running = true, succeeded = false
    private var encryptedArchive = false

    static func start(archives: [URL], parent: URL, placement: ArchiveExtractionPlacement,
                      completion: @escaping @MainActor () -> Void) {
        let archives = SevenZipVolumes.uniqueArchives(archives)
        guard !archives.isEmpty, !isRunning else { return }
        let controller = ArchiveExtractionWindow(archives: archives, parent: parent)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.task = Task { [weak controller] in
            guard let controller else { return }
            var completed = 0
            do {
                for (index, archive) in archives.enumerated() {
                    try Task<Never, Never>.checkCancellation()
                    controller.encryptedArchive = false
                    let backend = try await ArchiveReadBackend.resolve(for: archive)
                    guard let window = controller.window else { throw CancellationError() }
                    let loaded = try await backend.readWithPassword(archive, window: window)
                    let entries = loaded.entries
                    controller.encryptedArchive = entries.contains(where: \.isEncrypted)
                    var password = loaded.password
                    if password == nil, entries.contains(where: \.isEncrypted) {
                        guard backend.supportsPassword(for: archive) else { throw ZipArchiveError.unsupportedEncryption }
                        guard let entered = await ArchivePasswordPrompt.request(for: window, archiveName: archive.lastPathComponent) else { throw CancellationError() }
                        password = entered
                    }
                    try Task<Never, Never>.checkCancellation()
                    let needsChild = try archiveNeedsChildFolder(entries, placement: placement)
                    let child = needsChild ? try controller.createUniqueChild(in: parent, base: archiveChildFolderBaseName(archive)) : nil
                    let destination = child?.url ?? parent
                    do {
                        _ = try await backend.extract(archive, to: destination, password: password) { [weak controller] update in
                            Task { @MainActor [weak controller] in controller?.update(update, archive: archive, index: index, total: archives.count) }
                        }
                    } catch {
                        if let child { controller.removeEmptyChild(child) }
                        throw error
                    }
                    completed += 1
                }
                controller.finish(success: true, message: L("\(completed)개 압축 파일을 추출했습니다.", "Extracted \(completed) archives.")); completion()
            } catch is CancellationError { controller.finish(success: false, message: L("추출을 중단했습니다.", "Extraction stopped.")) }
            catch { controller.finish(success: false, message: archiveExtractionErrorMessage(error, encrypted: controller.encryptedArchive)) }
        }
    }

    private init(archives: [URL], parent: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("압축 파일 추출", "Extract Archives"); panel.delegate = self; panel.center(); panel.minSize = NSSize(width: 500, height: 300)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)])
        let target = NSTextField(wrappingLabelWithString: L("기준 폴더: ", "Base folder: ") + parent.path); target.isSelectable = true; stack.addArrangedSubview(target)
        label.stringValue = L("압축 파일을 검증하고 추출하는 중…", "Validating and extracting archives…"); stack.addArrangedSubview(label)
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1; progress.isIndeterminate = true; progress.startAnimation(nil); stack.addArrangedSubview(progress)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12); details.string = archives.map(\.path).joined(separator: "\n"); scroll.documentView = details; stack.addArrangedSubview(scroll)
        cancelButton.title = L("중단", "Stop"); cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); stack.addArrangedSubview(cancelButton)
        for view in [target, label, progress, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }

    private struct Child { let url: URL, device: dev_t, inode: ino_t }
    private func createUniqueChild(in parent: URL, base: String) throws -> Child {
        for index in 0..<10_000 {
            let name = index == 0 ? base : "\(base) \(index + 1)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            if mkdir(candidate.path, 0o700) == 0 {
                var info = stat()
                guard lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw CocoaError(.fileWriteUnknown) }
                return Child(url: candidate, device: info.st_dev, inode: info.st_ino)
            }
            if errno == EEXIST { continue }
            throw CocoaError(.fileWriteUnknown)
        }
        throw CocoaError(.fileWriteFileExists)
    }
    private func removeEmptyChild(_ child: Child) {
        var info = stat()
        guard lstat(child.url.path, &info) == 0, info.st_dev == child.device, info.st_ino == child.inode, (info.st_mode & S_IFMT) == S_IFDIR else { return }
        _ = rmdir(child.url.path)
    }
    @objc private func cancel(_ sender: Any?) {
        if !running { close(); return }
        task?.cancel(); cancelButton.isEnabled = false; label.stringValue = L("중단 요청됨 — 안전한 지점에서 임시 파일을 정리합니다.", "Stop requested — temporary output will be cleaned at a safe point.")
    }
    private func update(_ update: ArchiveProgress, archive: URL, index: Int, total: Int) {
        guard running else { return }; progress.isIndeterminate = update.totalBytes == 0 && update.totalEntries == 0
        let byteFraction = update.totalBytes > 0 ? Double(update.completedBytes) / Double(update.totalBytes) : 0
        let entryFraction = update.totalEntries > 0 ? Double(update.completedEntries) / Double(update.totalEntries) : 0
        progress.doubleValue = max(byteFraction, entryFraction)
        label.stringValue = "\(index + 1)/\(total) · \(archive.lastPathComponent) · \(update.completedEntries)/\(update.totalEntries)"
    }
    private func finish(success: Bool, message: String) { running = false; succeeded = success; progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = success ? 1 : 0; label.stringValue = message; cancelButton.title = L("닫기", "Close"); cancelButton.isEnabled = true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { NSSound.beep(); return false }; return true }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
#if DEBUG
    static var qaLatest: ArchiveExtractionWindow? { operations.last }
    var qaRunning: Bool { running }
    var qaSucceeded: Bool { succeeded }
    var qaMessage: String { label.stringValue }
#endif
}
