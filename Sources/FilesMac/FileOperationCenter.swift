import AppKit

@MainActor
struct FileOperationActivity {
    let id: UUID
    let title: String
    let destination: String
    let status: String
    let progress: (processed: Int, total: Int)?
    let showDetails: (() -> Void)?
    let cancel: (() -> Void)?
}

extension NSWindowController {
    func fileOperationActivity(id: UUID, destination: String, status: String, progress: NSProgressIndicator, running: Bool,
                               cancel: (() -> Void)?) -> FileOperationActivity {
        FileOperationActivity(
            id: id, title: window?.title ?? "", destination: destination, status: status,
            progress: running ? (Int(progress.doubleValue), Int(progress.maxValue)) : nil,
            showDetails: { [weak self] in
                self?.showWindow(nil)
                self?.window?.makeKeyAndOrderFront(nil)
            }, cancel: cancel
        )
    }
}

@MainActor
final class FileOperationCenter: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var center: FileOperationCenter?
    private static var recentResults: [FileOperationActivity] = []
    private static var dismissedOpenResults: Set<UUID> = []
    private static let resultLimit = 50
    private var activities: [FileOperationActivity] = []
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let details = NSButton()
    private let cancel = NSButton()
    private let clear = NSButton()

    @discardableResult
    static func present() -> FileOperationCenter {
        let controller = center ?? FileOperationCenter()
        center = controller
        controller.refresh()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    static func activityChanged() {
        if let center, center.window?.isVisible == true { center.refresh() }
    }

    static func retainResult(_ activity: FileOperationActivity) {
        guard activity.progress == nil, dismissedOpenResults.remove(activity.id) == nil else { return }
        let result = FileOperationActivity(id: activity.id, title: activity.title, destination: activity.destination,
                                           status: activity.status, progress: nil, showDetails: nil, cancel: nil)
        recentResults.insert(result, at: 0)
        if recentResults.count > resultLimit { recentResults.removeLast() }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 330),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("파일 작업", "File Operations")
        window.minSize = NSSize(width: 580, height: 240)
        window.isReleasedWhenClosed = false
        window.center()

        for (id, title, width) in [
            ("operation", L("작업", "Operation"), 125.0),
            ("status", L("상태", "Status"), 280.0),
            ("destination", L("대상", "Destination"), 195.0),
            ("progress", L("처리 항목", "Items Processed"), 120.0)
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openDetails(_:))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(L("파일 작업 목록", "File operations list"))
        window.initialFirstResponder = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        details.title = L("세부 정보 열기", "Open Details")
        details.target = self
        details.action = #selector(openDetails(_:))
        window.defaultButtonCell = details.cell as? NSButtonCell
        cancel.title = L("작업 취소", "Cancel Operation")
        cancel.target = self
        cancel.action = #selector(cancelSelectedOperation(_:))
        cancel.keyEquivalent = "."
        cancel.keyEquivalentModifierMask = .command
        clear.title = L("완료 기록 지우기", "Clear Completed")
        clear.target = self
        clear.action = #selector(clearCompletedOperations(_:))

        let actions = NSStackView(views: [details, cancel, clear])
        let stack = NSStackView(views: [summary, scroll, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var selected: FileOperationActivity? {
        activities.indices.contains(table.selectedRow) ? activities[table.selectedRow] : nil
    }

    private func refresh() {
        let selectedID = selected?.id
        let openActivities = CopyWindow.activities + MoveWindow.activities + FolderMergeWindow.activities
        activities = openActivities.filter { !Self.dismissedOpenResults.contains($0.id) } + Self.recentResults
        let running = activities.filter { $0.progress != nil }.count
        clear.isEnabled = running != activities.count
        summary.stringValue = activities.isEmpty
            ? L("파일 작업이 없습니다.", "No file operations.")
            : L("진행 중 \(running)개 · 결과 \(activities.count - running)개",
                "\(running) in progress · \(activities.count - running) with results")
        table.reloadData()
        if let row = activities.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !activities.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    private func updateButtons() {
        details.isEnabled = selected?.showDetails != nil
        cancel.isEnabled = selected?.cancel != nil
    }

    @objc private func openDetails(_ sender: Any?) {
        let row = sender is NSTableView ? table.clickedRow : table.selectedRow
        if activities.indices.contains(row) { activities[row].showDetails?() }
    }

    @objc private func cancelSelectedOperation(_ sender: Any?) { selected?.cancel?() }

    @objc private func clearCompletedOperations(_ sender: Any?) {
        Self.dismissedOpenResults.formUnion(activities.lazy.filter { $0.progress == nil && $0.showDetails != nil }.map(\.id))
        Self.recentResults.removeAll()
        refresh()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func numberOfRows(in tableView: NSTableView) -> Int { activities.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, activities.indices.contains(row) else { return nil }
        let activity = activities[row]
        let text: String
        switch column.identifier.rawValue {
        case "operation": text = activity.title
        case "status": text = activity.status
        case "destination": text = activity.destination
        default:
            guard let progress = activity.progress, progress.total > 0 else { return nil }
            let count = NSTextField(labelWithString: "\(progress.processed)/\(progress.total)")
            count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            count.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            count.setAccessibilityElement(false)

            let indicator = NSProgressIndicator()
            indicator.style = .bar
            indicator.controlSize = .small
            indicator.isIndeterminate = false
            indicator.minValue = 0
            indicator.maxValue = Double(progress.total)
            indicator.doubleValue = Double(progress.processed)
            indicator.setAccessibilityLabel(L("처리 항목", "Items Processed"))
            indicator.setAccessibilityValueDescription(
                L("\(progress.total)개 중 \(progress.processed)개", "\(progress.processed) of \(progress.total)"))

            let cell = NSStackView(views: [indicator, count])
            cell.alignment = .centerY
            cell.spacing = 6
            cell.edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
            indicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
            return cell
        }
        let field = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = column.identifier
        field.stringValue = text
        field.toolTip = text
        return field
    }

#if DEBUG
    func qaStatus(for id: UUID) -> FileOperationActivity? {
        activities.first { $0.id == id }
    }

    private func qaProgressIndicator(for id: UUID) -> NSProgressIndicator? {
        guard let row = activities.firstIndex(where: { $0.id == id }) else { return nil }
        let column = table.column(withIdentifier: .init("progress"))
        let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSStackView
        window?.contentView?.layoutSubtreeIfNeeded()
        return cell?.arrangedSubviews.first as? NSProgressIndicator
    }

    func qaShowsInitialCopyProgress(_ id: UUID) -> Bool {
        guard let indicator = qaProgressIndicator(for: id) else { return false }
        return !indicator.isHidden && indicator.bounds.width >= 18 && !indicator.isIndeterminate
            && indicator.maxValue == 1 && indicator.doubleValue == 0
            && indicator.accessibilityLabel() == L("처리 항목", "Items Processed")
            && indicator.accessibilityValueDescription() == L("1개 중 0개", "0 of 1")
    }

    func qaHidesProgress(_ id: UUID) -> Bool { qaProgressIndicator(for: id) == nil }

    var qaCanClearCompleted: Bool { clear.isEnabled }
    func qaClearCompleted() { clear.performClick(nil) }

    func qaPressShortcut(for id: UUID, characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        guard let window, window.initialFirstResponder === table,
              let row = activities.firstIndex(where: { $0.id == id }),
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return window.performKeyEquivalent(with: event)
    }

    func qaCancel(_ id: UUID) -> Bool {
        guard let row = activities.firstIndex(where: { $0.id == id }) else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard cancel.isEnabled else { return false }
        cancel.performClick(nil)
        return true
    }
#endif
}
