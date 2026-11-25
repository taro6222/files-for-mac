import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class ReceivedFilesWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    typealias Prepare = ([URL], [PromisedFileIntake], URL, @escaping (Bool) -> Void) -> Void
    private static var shared: ReceivedFilesWindow?
    private let prepare: Prepare
    private let storage: URL
    private var rows: [PromisedFileRecovery] = []
    private var busy = false
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton(title: L("복사 재개…", "Resume Copy…"), target: nil, action: #selector(resumeCopy))
    private let reveal = NSButton(title: L("보관된 파일 보기", "Show Retained Files"), target: nil, action: #selector(revealFiles))
    private let refresh = NSButton(title: L("새로 고침", "Refresh"), target: nil, action: #selector(reload))

    static func present(prepare: @escaping Prepare) {
        let controller = shared ?? ReceivedFilesWindow(storage: FilePromiseReceiveWindow.storageDirectory, prepare: prepare)
        shared = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.reload()
    }
    private init(storage: URL, prepare: @escaping Prepare) {
        self.storage = storage; self.prepare = prepare
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("보관된 수신 파일", "Retained Received Files"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300); window.center()
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        table.setAccessibilityLabel(L("보관된 수신 작업", "Retained receive jobs"))
        for (id, title, width) in [("date", L("수신 시각", "Received"), 160.0), ("files", L("파일", "Files"), 340.0), ("state", L("상태", "Status"), 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        let intro = NSTextField(wrappingLabelWithString: L("다른 앱에서 받은 파일은 앱을 종료해도 보관됩니다. 복사를 재개하면 파일을 다시 검증하고 이름 충돌 처리 방법을 묻습니다.", "Files received from other apps remain available after quitting. Resuming a copy verifies the files again and asks how to handle name conflicts."))
        let buttons = NSStackView(views: [copy, reveal, refresh]); buttons.spacing = 10
        for button in [copy, reveal, refresh] { button.target = self }
        let stack = NSStackView(views: [intro, scroll, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var selected: [PromisedFileRecovery] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    @objc private func reload() {
        guard !busy else { return }; busy = true; updateButtons()
        status.stringValue = L("보관된 파일 확인 중…", "Checking retained files…")
        let storage = storage
        Task { [self] in
            do {
                rows = try await Task.detached { try PromisedFileRecovery.discover(in: storage) }.value
                status.stringValue = rows.isEmpty ? L("보관된 수신 파일이 없습니다.", "No retained received files.")
                    : L("수신 작업 \(rows.count)개 · 복구가 필요한 작업은 파일 보기에서 직접 확인하세요.", "\(rows.count) receive jobs · inspect jobs needing recovery with Show Retained Files.")
            } catch { rows = []; status.stringValue = error.localizedDescription }
            table.reloadData(); busy = false; updateButtons()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let record = rows[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = record.createdAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        case "files": text = record.names.isEmpty ? L("등록된 파일 없음", "No registered files") : record.names.prefix(3).joined(separator: ", ") + (record.names.count > 3 ? "…" : "")
        default: text = record.problem != nil ? L("기록 복구 필요", "Receipt needs recovery") : L("\(record.names.count)개 · 복사 전 재검증", "\(record.names.count) · verify before copy")
        }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = record.problem ?? record.names.joined(separator: "\n")
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        let chosen = selected
        copy.isEnabled = !busy && !chosen.isEmpty && chosen.allSatisfy { $0.intake != nil && !$0.names.isEmpty }
        reveal.isEnabled = !chosen.isEmpty
        refresh.isEnabled = !busy
    }
    @objc private func revealFiles() { NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.directoryURL)) }
    @objc private func resumeCopy() {
        guard copy.isEnabled, let window else { return }
        let intakes = selected.compactMap(\.intake)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("여기로 복사", "Copy Here")
        busy = true; updateButtons()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.busy = false; self.updateButtons(); return }
            self.resume(intakes: intakes, destination: destination)
        }
    }
#if DEBUG
    static func verifyRecovery(storage: URL, destination: URL) async -> [String: Bool] {
        let controller = ReceivedFilesWindow(storage: storage) { _, _, _, decision in decision(false) }
        defer { controller.window?.close() }
        controller.reload()
        for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        var checks = ["recoveryListsPersistedJobs": !controller.busy && controller.rows.count == 2 && controller.table.numberOfRows == 2]
        if let healthy = controller.rows.firstIndex(where: { $0.intake != nil }) {
            controller.table.selectRowIndexes(IndexSet(integer: healthy), byExtendingSelection: false)
            controller.updateButtons()
            checks["recoveryEnablesVerifiedCopyRequest"] = controller.copy.isEnabled && controller.reveal.isEnabled
        }
        if let damaged = controller.rows.firstIndex(where: { $0.intake == nil }) {
            controller.table.selectRowIndexes(IndexSet(integer: damaged), byExtendingSelection: false)
            controller.updateButtons()
            checks["recoveryDamagedReceiptAllowsRevealOnly"] = !controller.copy.isEnabled && controller.reveal.isEnabled
        }
        controller.table.selectAll(nil); controller.updateButtons()
        checks["recoveryMixedSelectionProtectsDamagedData"] = !controller.copy.isEnabled && controller.reveal.isEnabled
        return checks
    }
#endif
    private func resume(intakes: [PromisedFileIntake], destination: URL) {
        guard let destinationIdentity = ShelfEntry(destination.resolvingSymlinksInPath()) else {
            busy = false; status.stringValue = L("대상 폴더를 확인할 수 없습니다. 다시 선택하세요.", "Could not identify the destination folder. Select it again."); updateButtons(); return
        }
        status.stringValue = L("받은 파일 재검증 중…", "Verifying received files again…")
        Task { [self] in
            do {
                let sources = try await Task.detached { try intakes.flatMap { try $0.verifiedSources() } }.value
                guard destinationIdentity.isCurrent else { throw EntryOperationError.sourceChanged }
                prepare(sources, intakes, destination) { [weak self] accepted in
                    guard let self else { return }
                    self.busy = false
                    self.status.stringValue = accepted ? L("복사 작업으로 전달했습니다. 보관된 원본은 유지됩니다.", "Handed off to the copy job. Retained originals are preserved.") : L("복사 요청이 취소되었거나 다른 작업이 진행 중입니다. 다시 시도할 수 있습니다.", "The copy request was cancelled or another job is running. You can retry.")
                    self.updateButtons()
                }
            } catch { busy = false; status.stringValue = L("수신 파일을 재검증하지 못했습니다. 보관된 파일을 확인하세요. ", "Could not verify received files. Inspect the retained files. ") + error.localizedDescription; updateButtons() }
        }
    }
}
