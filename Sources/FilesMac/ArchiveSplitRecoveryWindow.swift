import AppKit
import FilesCore

@MainActor
final class ArchiveSplitRecoveryWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static var journalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
    }
    private static var shared: ArchiveSplitRecoveryWindow?
    private static var startupTask: Task<Void, Never>?
    private let directory: URL
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextView()
    private let recoverButton = NSButton(title: L("부분 생성 되돌리기…", "Roll Back Partial Creation…"), target: nil, action: nil)
    private let revealButton = NSButton(title: L("기록 위치 보기", "Reveal Journal"), target: nil, action: nil)
    private let outputButton = NSButton(title: L("출력 위치 보기", "Reveal Output"), target: nil, action: nil)
    private let refreshButton = NSButton(title: L("새로 고침", "Refresh"), target: nil, action: nil)
    private var records: [SevenZipSplitJournalSummary] = []
    private var task: Task<Void, Never>?
    private var busy = false
    private var recovering = false
    private var selected: SevenZipSplitJournalSummary? { records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil }

    static func present(journalDirectory: URL? = nil) {
        let directory = journalDirectory ?? Self.journalDirectory
        if shared?.directory != directory { shared = ArchiveSplitRecoveryWindow(directory: directory) }
        shared?.showWindow(nil); shared?.window?.makeKeyAndOrderFront(nil); shared?.refresh(nil)
    }
    static func checkForUnfinished() {
        startupTask?.cancel()
        startupTask = Task {
            do {
                let records = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: journalDirectory)
                if !Task.isCancelled && records.contains(where: \.isUnfinished) { present() }
            } catch is CancellationError {} catch { /* The menu also exposes read failures without blocking startup. */ }
        }
    }
    private init(directory: URL) {
        self.directory = directory
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("분할 압축 생성 복구", "Split Archive Creation Recovery"); panel.isReleasedWhenClosed = false; panel.delegate = self; panel.minSize = NSSize(width: 640, height: 420); panel.center()
        let note = NSTextField(wrappingLabelWithString: L("중단된 분할 생성을 확인하세요. 되돌리기는 변경되지 않은 이 작업의 출력만 정리합니다. 원본과 외부 변경 파일은 보존합니다.", "Review interrupted split creation. Rollback removes only unchanged output owned by the operation. Sources and externally changed files are preserved."))
        for (id, title, width) in [("destination", L("출력", "Output"), 470.0), ("state", L("상태", "Status"), 240.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.setAccessibilityLabel(L("분할 생성 기록", "Split creation history")); table.identifier = NSUserInterfaceItemIdentifier("archive-split-history")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        detail.isEditable = false; detail.isSelectable = true; detail.font = .systemFont(ofSize: 12)
        detail.setAccessibilityLabel(L("선택한 복구 기록 상세", "Selected recovery record details"))
        let details = NSScrollView(); details.documentView = detail; details.hasVerticalScroller = true; details.borderType = .bezelBorder
        let actions = NSStackView(views: [refreshButton, revealButton, outputButton, recoverButton]); actions.orientation = .horizontal; actions.spacing = 8
        for (button, action) in [(refreshButton, #selector(refresh(_:))), (revealButton, #selector(reveal(_:))), (outputButton, #selector(revealOutput(_:))), (recoverButton, #selector(recover(_:)))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        let stack = NSStackView(views: [note, status, scroll, details, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160), details.heightAnchor.constraint(equalToConstant: 100)])
        for view in [note, status, scroll, details] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        selectionChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    private func stateText(_ item: SevenZipSplitJournalSummary) -> String {
        if item.ambiguousIntent && item.phase != "unreadable" { return L("게시 상태 확인 필요 · 파일 보존", "Publication needs review · preserved") }
        switch item.phase {
        case "committed": return item.staging == nil ? L("완료", "Completed") : L("완료 · 임시 폴더 확인 필요", "Completed · inspect staging")
        case "rolledBack": return L("되돌림 완료", "Rolled back")
        case "prepared": return L("게시 전 중단", "Stopped before publication")
        case "publishing": return L("부분 게시 · 확인 후 되돌리기", "Partial publication · rollback available")
        case "discarding": return L("임시 파일 정리 중단", "Private cleanup interrupted")
        case "building": return L("생성 중 또는 중단됨 · 확인 필요", "Creating or interrupted · inspect files")
        default: return L("기록을 읽지 못함 · 보존", "Unreadable record · preserved")
        }
    }
    @objc private func refresh(_ sender: Any?) {
        guard !busy else { return }
        let previous = selected?.journal
        busy = true; status.stringValue = L("기록 확인 중…", "Reading history…"); selectionChanged()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                records = try await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: directory)
                table.reloadData()
                if let index = records.firstIndex(where: { $0.journal == previous }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                status.stringValue = records.isEmpty ? L("분할 생성 기록이 없습니다.", "No split creation records.") : L("기록 \(records.count)개 · 확인이 필요한 작업 \(records.filter(\.isUnfinished).count)개", "\(records.count) records · \(records.filter(\.isUnfinished).count) need review")
            } catch { status.stringValue = archiveErrorMessage(error) }
            busy = false; selectionChanged()
        }
    }
    private func selectionChanged() {
        refreshButton.isEnabled = !busy
        recoverButton.isEnabled = !busy && !ArchiveCreationWindow.isRunning && selected?.canAttemptRecovery == true
        revealButton.isEnabled = !busy && selected != nil; outputButton.isEnabled = !busy && selected?.destination != nil
        guard let selected else { detail.string = ""; return }
        detail.string = [selected.destination?.path, stateText(selected), selected.updatedAt == .distantPast ? nil : selected.updatedAt.formatted(), selected.staging.map { L("보존 위치: ", "Preserved staging: ") + $0.path }, L("기록: ", "Journal: ") + selected.journal.path].compactMap { $0 }.joined(separator: "\n")
    }
    @objc private func reveal(_ sender: Any?) { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected.journal]) } }
    @objc private func revealOutput(_ sender: Any?) { if let destination = selected?.destination { NSWorkspace.shared.open(destination.deletingLastPathComponent()) } }
    @objc private func recover(_ sender: Any?) {
        guard !busy, !ArchiveCreationWindow.isRunning, let item = selected, item.canAttemptRecovery, let window else { return }
        let alert = NSAlert(); alert.messageText = L("이 분할 생성을 되돌릴까요?", "Roll back this split creation?")
        alert.informativeText = (item.destination?.path ?? item.journal.lastPathComponent) + "\n\n" + L("이 작업이 만든 변경되지 않은 출력만 제거합니다. 파일 상태가 다르면 보존하고 중단합니다.", "Only unchanged output created by this operation is removed. If file state differs, it is preserved and rollback stops.")
        alert.addButton(withTitle: L("되돌리기", "Roll Back")); alert.addButton(withTitle: L("취소", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.busy else { return }
            self.busy = true; self.recovering = true; self.status.stringValue = L("출력을 확인하고 되돌리는 중…", "Verifying and rolling back output…"); self.selectionChanged()
            self.task = Task { [weak self] in
                guard let self else { return }
                do {
                    let outcome = try await SevenZipArchiveProvider.recoverSplitCreation(journal: item.journal, journalDirectory: self.directory)
                    switch outcome {
                    case .rolledBack: self.status.stringValue = L("부분 생성을 되돌렸습니다. 새로 고침으로 기록을 확인하세요.", "Partial creation rolled back. Refresh to review history.")
                    case .committed: self.status.stringValue = L("이미 완료된 생성입니다. 출력은 변경하지 않았습니다.", "Creation already completed. Output was left unchanged.")
                    }
                } catch { self.status.stringValue = archiveErrorMessage(error) }
                if let refreshed = try? await SevenZipArchiveProvider.splitCreationHistory(journalDirectory: self.directory) {
                    self.records = refreshed; self.table.reloadData()
                    if let row = refreshed.firstIndex(where: { $0.journal == item.journal }) { self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                }
                self.busy = false; self.recovering = false; self.selectionChanged()
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }; let item = records[row]
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "state" ? stateText(item) : item.destination?.lastPathComponent ?? item.journal.lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = item.destination?.path ?? item.journal.path; return label
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !recovering else { return false }; task?.cancel(); return true
    }
#if DEBUG
    static var qaLatest: ArchiveSplitRecoveryWindow? { shared }
    var qaRecords: [SevenZipSplitJournalSummary] { records }
    var qaBusy: Bool { busy }
    var qaRecoveryEnabled: Bool { recoverButton.isEnabled }
    func qaSelect(_ row: Int) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
#endif
}
