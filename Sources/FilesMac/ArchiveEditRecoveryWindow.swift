import AppKit
import FilesCore

@MainActor
final class ArchiveEditRecoveryWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: ArchiveEditRecoveryWindow?, startupTask: Task<Void, Never>?
    private let directory: URL
    private let table = NSTableView(), status = NSTextField(wrappingLabelWithString: ""), detail = NSTextView()
    private let inspectButton = NSButton(title: L("파일 상태 확인", "Verify Files"), target: nil, action: nil)
    private let undoButton = NSButton(title: L("실행 취소…", "Undo…"), target: nil, action: nil)
    private let redoButton = NSButton(title: L("다시 실행…", "Redo…"), target: nil, action: nil)
    private let revealButton = NSButton(title: L("보존 위치 보기", "Reveal Retained Files"), target: nil, action: nil)
    private let refreshButton = NSButton(title: L("새로 고침", "Refresh"), target: nil, action: nil)
    private let stopButton = NSButton(title: L("중단", "Stop"), target: nil, action: nil)
    private var records: [ArchiveEditHistoryItem] = [], verifiedJournal: URL?, verifiedState: String?
    private var busy = false, pendingClose = false, task: Task<Void, Never>?, confirmation: NSAlert?
    private var selected: ArchiveEditHistoryItem? { records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil }
    static func present(journalDirectory: URL? = nil) {
        let directory = journalDirectory ?? ArchiveSplitRecoveryWindow.journalDirectory
        if let shared, shared.directory != directory, shared.busy { shared.showWindow(nil); shared.window?.makeKeyAndOrderFront(nil); return }
        if shared?.directory != directory { shared?.close(); shared = Self(directory: directory) }
        shared?.showWindow(nil); shared?.window?.makeKeyAndOrderFront(nil); shared?.refresh(nil)
    }
    static func checkForUnfinished() {
        startupTask?.cancel()
        startupTask = Task {
            guard let items = try? await SevenZipArchiveProvider.archiveEditHistory(journalDirectory: ArchiveSplitRecoveryWindow.journalDirectory), !Task.isCancelled else { return }
            let count = items.filter { !$0.readable || ["building", "prepared", "swapIntent", "undoIntent", "redoIntent"].contains($0.recordedState ?? "") }.count
            let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.identifier?.rawValue == "archive-edit-history" }
            item?.title = L("압축 편집 기록 및 복구…", "Archive Edit History and Recovery…") + (count > 0 ? L(" (\(count)개 확인 필요)", " (\(count) need review)") : "")
        }
    }
    private init(directory: URL) {
        self.directory = directory
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("압축 편집 기록 및 복구", "Archive Edit History and Recovery"); panel.isReleasedWhenClosed = false; panel.delegate = self; panel.minSize = NSSize(width: 800, height: 440); panel.center()
        let note = NSTextField(wrappingLabelWithString: L("목록은 기록에 적힌 상태입니다. 먼저 파일 상태를 확인한 뒤 복원을 선택하세요. 변경된 파일과 읽을 수 없는 기록은 보존합니다.", "The list shows recorded states. Verify the files before choosing a restore action. Changed files and unreadable records are preserved."))
        table.addTableColumn({ let c = NSTableColumn(identifier: .init("archive")); c.title = L("압축 파일", "Archive"); c.width = 460; return c }())
        table.addTableColumn({ let c = NSTableColumn(identifier: .init("state")); c.title = L("기록상 상태 · 미검증", "Recorded State · Unverified"); c.width = 310; return c }())
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel(L("압축 편집 기록", "Archive edit history"))
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        detail.isEditable = false; detail.isSelectable = true; detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular); detail.setAccessibilityLabel(L("선택한 기록과 보존 위치", "Selected record and retained locations"))
        detail.frame = NSRect(x: 0, y: 0, width: 844, height: 130)
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false; detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.containerSize = NSSize(width: 844, height: CGFloat.greatestFiniteMagnitude)
        let details = NSScrollView(); details.documentView = detail; details.hasVerticalScroller = true; details.borderType = .bezelBorder
        let actions = NSStackView(views: [refreshButton, inspectButton, undoButton, redoButton, revealButton, stopButton]); actions.orientation = .horizontal; actions.spacing = 8
        for (button, action) in [(refreshButton, #selector(refresh(_:))), (inspectButton, #selector(inspect(_:))), (undoButton, #selector(undo(_:))), (redoButton, #selector(redo(_:))), (revealButton, #selector(reveal(_:))), (stopButton, #selector(stop(_:)))] { button.target = self; button.action = action; button.bezelStyle = .rounded; button.setAccessibilityLabel(button.title) }
        let stack = NSStackView(views: [note, status, scroll, details, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160), details.heightAnchor.constraint(equalToConstant: 130)])
        for view in [note, status, scroll, details] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }; render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    private func stateText(_ value: String?) -> String {
        switch value {
        case "committed": return L("저장 완료 기록", "Recorded as saved")
        case "undone": return L("실행 취소 완료 기록", "Recorded as undone")
        case "prepared": return L("게시 전 기록", "Recorded before publication")
        case "swapIntent", "undoIntent", "redoIntent": return L("교체 의도 기록 · 확인 필요", "Exchange intent · needs verification")
        case "building": return L("미완료 기록 · 확인 필요", "Unfinished record · needs verification")
        default: return L("기록을 읽지 못함 · 보존", "Unreadable record · preserved")
        }
    }
    @objc private func refresh(_ sender: Any?) {
        guard !busy else { return }; let previous = selected?.journal
        busy = true; verifiedJournal = nil; verifiedState = nil; status.stringValue = L("기록을 읽는 중…", "Reading records…"); render()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                self.records = try await SevenZipArchiveProvider.archiveEditHistory(journalDirectory: self.directory); self.table.reloadData()
                if let row = self.records.firstIndex(where: { $0.journal == previous }) { self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                self.status.stringValue = L("기록 \(self.records.count)개 · 실제 파일 검증 전", "\(self.records.count) records · files not yet verified")
            } catch { self.status.stringValue = archiveEditErrorMessage(error) }
            self.finish()
        }
    }
    private func render() {
        let available = !busy && window?.attachedSheet == nil
        refreshButton.isEnabled = available; inspectButton.isEnabled = available && selected?.readable == true
        undoButton.isEnabled = available && verifiedJournal == selected?.journal && verifiedState == "committed"
        redoButton.isEnabled = available && verifiedJournal == selected?.journal && verifiedState == "undone"
        revealButton.isEnabled = available && selected != nil; stopButton.isEnabled = busy
        table.isEnabled = !busy
        if let item = selected { detail.string = stateText(item.recordedState) + "\n" + L("검증 결과: ", "Verification: ") + (verifiedJournal == item.journal ? verifiedText : L("미확인", "Not verified")) + "\n" + (item.archive?.path ?? "") + "\n" + (item.retainedFile?.path ?? "") + "\n" + item.journal.path }
        else { detail.string = "" }
    }
    private var verifiedText: String {
        switch verifiedState {
        case "committed": return L("저장본과 이전 원본 확인됨", "Saved archive and original verified")
        case "undone": return L("이전 원본 복원됨", "Previous original restored")
        case "unpublished": return L("원본 미교체", "Original not replaced")
        default: return L("미확인", "Not verified")
        }
    }
    private func finish() { busy = false; render(); NSAccessibility.post(element: status, notification: .valueChanged); if pendingClose { pendingClose = false; window?.close() } }
    @objc private func inspect(_ sender: Any?) { run(.inspect) }
    @objc private func undo(_ sender: Any?) { confirmAction(.undo) }
    @objc private func redo(_ sender: Any?) { confirmAction(.redo) }
    private func confirmAction(_ action: ArchiveEditRecoveryAction) {
        guard !busy, let item = selected, verifiedJournal == item.journal, let window,
              (action == .undo ? verifiedState == "committed" : verifiedState == "undone") else { return }
        let alert = NSAlert(); alert.messageText = action == .undo ? L("압축 편집을 실행 취소할까요?", "Undo this archive edit?") : L("압축 편집을 다시 실행할까요?", "Redo this archive edit?")
        alert.informativeText = (item.archive?.path ?? "") + "\n\n" + L("두 파일의 내용을 다시 확인하고 교체합니다. 현재 버전도 별도로 보존합니다.", "Both files are verified again before exchange. The current version is retained too.")
        alert.addButton(withTitle: action == .undo ? L("실행 취소", "Undo") : L("다시 실행", "Redo")); alert.addButton(withTitle: L("취소", "Cancel")); confirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in guard let self else { return }; alert.window.orderOut(nil); self.confirmation = nil; self.render(); if response == .alertFirstButtonReturn { self.run(action) } }; render()
    }
    private func run(_ action: ArchiveEditRecoveryAction) {
        guard !busy, selected?.readable == true, let item = selected else { return }
        busy = true; verifiedJournal = nil; verifiedState = nil; status.stringValue = L("실제 파일을 확인하는 중…", "Verifying the files…"); render()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: item.journal, journalDirectory: self.directory, action: action)
                self.verifiedJournal = item.journal
                switch result {
                case .unpublished: self.verifiedState = "unpublished"; self.status.stringValue = L("원본은 교체되지 않았습니다. 보존된 출력은 자동으로 삭제하지 않습니다.", "The original was not replaced. Retained output is not deleted automatically.")
                case .committed: self.verifiedState = "committed"; self.status.stringValue = action == .redo ? L("편집을 다시 적용했습니다.", "The edit was reapplied.") : L("저장본과 이전 원본을 확인했습니다.", "The saved archive and previous original were verified.")
                case .undone: self.verifiedState = "undone"; self.status.stringValue = L("이전 원본으로 복원된 상태입니다.", "The previous original is restored.")
                }
                do {
                    self.records = try await SevenZipArchiveProvider.archiveEditHistory(journalDirectory: self.directory); self.table.reloadData()
                    if let row = self.records.firstIndex(where: { $0.journal == item.journal }) { self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                } catch {
                    self.status.stringValue += L(" 기록 목록을 갱신하지 못했습니다. 새로 고침으로 다시 확인하세요.", " The record list could not be refreshed. Refresh to check it again.")
                }
            } catch is CancellationError { self.status.stringValue = L("확인을 중단했습니다. 파일은 보존했습니다.", "Verification stopped. Files were preserved.") }
            catch { self.status.stringValue = archiveEditErrorMessage(error) }
            self.finish()
        }
    }
    @objc private func reveal(_ sender: Any?) { guard let item = selected else { return }; NSWorkspace.shared.activateFileViewerSelecting([item.journal] + [item.archive, item.retainedFile].compactMap { $0 }) }
    @objc private func stop(_ sender: Any?) { task?.cancel(); status.stringValue = L("중단 요청을 처리하는 중…", "Finishing the stop request…") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if busy { pendingClose = true; stop(nil); return false }; return true }
    func tableViewSelectionDidChange(_ notification: Notification) { render() }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }; let item = records[row]
        let text = tableColumn?.identifier.rawValue == "state" ? stateText(item.recordedState) : item.archive?.lastPathComponent ?? item.journal.lastPathComponent
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = item.archive?.path ?? item.journal.path; return label
    }
#if DEBUG
    static var qaLatest: ArchiveEditRecoveryWindow? { shared }
    var qaBusy: Bool { busy }
    var qaRecords: [ArchiveEditHistoryItem] { records }
    var qaDetailsVisible: Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let item = selected, detail.string.contains(item.journal.path), let container = detail.textContainer, let layout = detail.layoutManager else { return false }
        layout.ensureLayout(for: container)
        return detail.bounds.width > 100 && detail.visibleRect.height > 0 && layout.glyphRange(forBoundingRect: detail.visibleRect, in: container).length > 0
    }
    var qaCanUndo: Bool { undoButton.isEnabled }
    var qaCanRedo: Bool { redoButton.isEnabled }
    func qaSelect(_ row: Int) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    func qaVerify() { inspect(nil) }
    func qaUndo() { undo(nil) }
    func qaRedo() { redo(nil) }
    func qaConfirm(_ yes: Bool) { confirmation?.buttons[yes ? 0 : 1].performClick(nil) }
#endif
}
