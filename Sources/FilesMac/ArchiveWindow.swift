import AppKit
import FilesCore

@MainActor
final class ArchiveWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let provider = ZipArchiveProvider()
    private let table = NSTableView(), status = NSTextField(labelWithString: ""), progress = NSProgressIndicator()
    private let extractButton = NSButton(), cancelButton = NSButton()
    private var archiveURL: URL?, entries: [ArchiveEntryDescriptor] = [], task: Task<Void, Never>?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.isReleasedWhenClosed = false; buildUI()
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
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; footer.addArrangedSubview(progress)
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

    func present(archiveURL: URL) {
        task?.cancel(); self.archiveURL = archiveURL; entries = []; table.reloadData()
        window?.title = L("압축 파일: ", "Archive: ") + archiveURL.lastPathComponent
        status.stringValue = L("목록을 읽는 중…", "Reading archive…"); setRunning(true)
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        task = Task { [weak self, provider] in
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try provider.entries(at: archiveURL) }.value
                guard let self, !Task.isCancelled else { return }
                self.entries = loaded; self.status.stringValue = L("\(loaded.count)개 항목", "\(loaded.count) items"); self.setRunning(false); self.table.reloadData()
            } catch is CancellationError { }
            catch { guard let self else { return }; self.status.stringValue = L("목록 실패: ", "Could not read archive: ") + error.localizedDescription; self.setRunning(false) }
        }
    }

    @objc private func chooseDestination(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.prompt = L("여기에 추출", "Extract Here")
        panel.beginSheetModal(for: window) { [weak self] response in guard response == .OK, let destination = panel.url else { return }; self?.extract(to: destination) }
    }
    private func extract(to destination: URL) {
        guard let archiveURL else { return }; task?.cancel(); status.stringValue = L("안전하게 추출하는 중…", "Extracting safely…"); setRunning(true)
        task = Task { [weak self, provider] in
            do {
                let report = try await provider.extract(archiveURL, to: destination)
                guard let self, !Task.isCancelled else { return }
                self.status.stringValue = L("\(report.entries)개 항목을 추출했습니다.", "Extracted \(report.entries) items."); self.setRunning(false)
            } catch is CancellationError { guard let self else { return }; self.status.stringValue = L("추출을 중단했습니다.", "Extraction stopped."); self.setRunning(false) }
            catch { guard let self else { return }; self.status.stringValue = L("추출 실패: ", "Extraction failed: ") + error.localizedDescription; self.setRunning(false) }
        }
    }
    @objc private func cancel(_ sender: Any?) { task?.cancel() }
    private func setRunning(_ running: Bool) { running ? progress.startAnimation(nil) : progress.stopAnimation(nil); cancelButton.isEnabled = running; extractButton.isEnabled = !running && !entries.isEmpty }
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
#endif
}
