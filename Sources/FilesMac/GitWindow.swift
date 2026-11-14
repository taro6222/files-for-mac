import AppKit
import FilesCore

@MainActor
final class GitWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let provider: GitProvider
    private var location: URL?
    private var snapshot: GitRepositorySnapshot?
    private var branches: [GitBranch] = []
    private var remotes: [GitRemote] = []
    private var task: Task<Void, Never>?
    private let repositoryLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let supportLabel = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let refreshButton = NSButton(), fetchButton = NSButton(), pullButton = NSButton(), pushButton = NSButton(), stopButton = NSButton()

    init(provider: GitProvider = .init()) {
        self.provider = provider
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("Git 상태", "Git Status"); panel.isReleasedWhenClosed = false; panel.delegate = self
        buildUI(); updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root); NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        repositoryLabel.lineBreakMode = .byTruncatingMiddle; repositoryLabel.setAccessibilityLabel(L("Git 저장소 경로", "Git repository path")); root.addArrangedSubview(repositoryLabel)
        branchLabel.setAccessibilityLabel(L("Git 브랜치 상태", "Git branch status")); root.addArrangedSubview(branchLabel)
        stateLabel.textColor = .secondaryLabelColor; stateLabel.setAccessibilityLabel(L("Git 작업 상태", "Git operation status")); root.addArrangedSubview(stateLabel)
        supportLabel.stringValue = L(
            "지원 범위: 상태·Fetch·FF 전용 Pull·비강제 Push. 인증은 시스템 Git 설정을 사용하며 stage/commit, submodule, LFS, hook 실행은 지원하지 않습니다.",
            "Supported: status, fetch, fast-forward-only pull, and non-force push. Authentication uses system Git configuration; stage/commit, submodules, LFS, and hook execution are not supported."
        )
        supportLabel.textColor = .secondaryLabelColor; supportLabel.font = .systemFont(ofSize: 11)
        supportLabel.setAccessibilityLabel(L("Git 지원 범위", "Git support boundary")); root.addArrangedSubview(supportLabel)
        let statusColumn = NSTableColumn(identifier: .init("status")); statusColumn.title = L("상태", "Status"); statusColumn.width = 90
        let pathColumn = NSTableColumn(identifier: .init("path")); pathColumn.title = L("경로", "Path"); pathColumn.width = 560
        table.addTableColumn(statusColumn); table.addTableColumn(pathColumn); table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(L("Git 변경 파일", "Git changed files"))
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; root.addArrangedSubview(scroll)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        refreshButton.title = L("새로 고침", "Refresh"); refreshButton.target = self; refreshButton.action = #selector(refresh(_:)); controls.addArrangedSubview(refreshButton)
        fetchButton.title = "Fetch"; fetchButton.target = self; fetchButton.action = #selector(fetch(_:)); controls.addArrangedSubview(fetchButton)
        pullButton.title = L("Pull (FF 전용)", "Pull (FF Only)"); pullButton.target = self; pullButton.action = #selector(pull(_:)); controls.addArrangedSubview(pullButton)
        pushButton.title = "Push"; pushButton.target = self; pushButton.action = #selector(push(_:)); controls.addArrangedSubview(pushButton)
        controls.addArrangedSubview(NSView()); stopButton.title = L("중단", "Stop"); stopButton.target = self; stopButton.action = #selector(stop(_:)); controls.addArrangedSubview(stopButton)
        root.addArrangedSubview(controls)
    }

    func present(location: URL) {
        self.location = location.standardizedFileURL; window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); load()
    }
    func windowWillClose(_ notification: Notification) { task?.cancel(); task = nil; updateControls() }
    @objc private func refresh(_ sender: Any?) { load() }
    @objc private func fetch(_ sender: Any?) { runOperation(L("원격 변경을 가져오는 중…", "Fetching remote changes…")) { try await self.provider.fetch(at: $0) } }
    @objc private func pull(_ sender: Any?) { runOperation(L("fast-forward pull 중…", "Pulling fast-forward only…")) { try await self.provider.pullFastForwardOnly(at: $0) } }
    @objc private func push(_ sender: Any?) { runOperation(L("변경을 push하는 중…", "Pushing changes…")) { repository in try await self.provider.push(at: repository, branch: self.snapshot?.branch) } }
    @objc private func stop(_ sender: Any?) { task?.cancel() }

    private func load() {
        guard let location, task == nil else { return }
        stateLabel.stringValue = L("Git 상태를 읽는 중…", "Reading Git status…"); updateControls()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                async let snapshot = provider.snapshot(at: location)
                let loaded = try await snapshot
                async let branches = provider.branches(at: loaded.root)
                async let remotes = provider.remotes(at: loaded.root)
                self.snapshot = loaded; self.branches = try await branches; self.remotes = try await remotes
                let conflictCount = loaded.entries.count(where: { $0.kind == .unmerged })
                if conflictCount > 0 {
                    stateLabel.stringValue = L("변경 \(loaded.entries.count)개 · 병합 충돌 \(conflictCount)개",
                                               "\(loaded.entries.count) changes · \(conflictCount) unmerged")
                } else {
                    stateLabel.stringValue = loaded.entries.isEmpty ? L("변경 없음", "Working tree clean") : L("변경 \(loaded.entries.count)개", "\(loaded.entries.count) changes")
                }
            } catch is CancellationError { stateLabel.stringValue = L("작업이 중단되었습니다.", "Operation cancelled.") }
            catch { snapshot = nil; branches = []; remotes = []; stateLabel.stringValue = errorText(error) }
            task = nil; render(); updateControls()
        }
        updateControls()
    }
    private func runOperation(_ message: String, operation: @escaping (URL) async throws -> Void) {
        guard let repository = snapshot?.root, task == nil else { return }
        stateLabel.stringValue = message
        task = Task { [weak self] in
            guard let self else { return }
            do { try await operation(repository); task = nil; load(); return }
            catch is CancellationError { stateLabel.stringValue = L("작업이 중단되었습니다.", "Operation cancelled.") }
            catch { stateLabel.stringValue = errorText(error) }
            task = nil; updateControls()
        }
        updateControls()
    }
    private func render() {
        repositoryLabel.stringValue = snapshot?.root.path ?? location?.path ?? ""
        if let snapshot {
            let branch = snapshot.branch ?? L("분리된 HEAD", "Detached HEAD")
            let tracking = snapshot.upstream.map { "  \($0)  ↑\(snapshot.ahead) ↓\(snapshot.behind)" } ?? ""
            branchLabel.stringValue = branch + tracking
        } else { branchLabel.stringValue = "" }
        table.reloadData()
    }
    private func updateControls() {
        let running = task != nil, hasRemote = !remotes.isEmpty, hasBranch = snapshot?.branch != nil
        refreshButton.isEnabled = !running && location != nil; fetchButton.isEnabled = !running && hasRemote
        pullButton.isEnabled = !running && hasRemote && snapshot?.upstream != nil; pushButton.isEnabled = !running && hasRemote && hasBranch; stopButton.isEnabled = running
    }
    private func errorText(_ error: Error) -> String {
        if let backend = error as? GitBackendError {
            switch backend {
            case .notRepository: return L("현재 위치는 Git 저장소가 아닙니다.", "The current location is not a Git repository.")
            case .commandFailed: return L("Git 명령이 실패했습니다. 충돌 또는 인증 상태를 확인하세요. 작업 트리는 자동 변경하지 않았습니다.", "The Git command failed. Check conflicts or authentication. The working tree was not automatically changed.")
            default: break
            }
        }
        return String(describing: error)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { snapshot?.entries.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = snapshot?.entries[row], let identifier = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? { let value = NSTableCellView(); value.identifier = identifier; let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; value.addSubview(text); value.textField = text; NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: value.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: value.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: value.centerYAnchor)]); return value }()
        if identifier.rawValue == "status" {
            cell.textField?.stringValue = entry.statusCode
        } else {
            cell.textField?.stringValue = entry.path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\r\n", with: "\\r\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
        }
        cell.textField?.setAccessibilityLabel(identifier.rawValue == "status" && entry.kind == .unmerged
            ? L("병합 충돌: \(entry.statusCode)", "Unmerged: \(entry.statusCode)") : nil)
        return cell
    }
#if DEBUG
    var qaLoaded: Bool { task == nil && snapshot != nil }
    var qaRowCount: Int { snapshot?.entries.count ?? 0 }
    var qaBranch: String? { snapshot?.branch }
    func qaShowsConflict(code: String) -> Bool {
        guard let row = snapshot?.entries.firstIndex(where: { $0.kind == .unmerged }),
              let cell = tableView(table, viewFor: table.tableColumns[0], row: row) as? NSTableCellView else { return false }
        return stateLabel.stringValue.contains(L("병합 충돌 1개", "1 unmerged"))
            && cell.textField?.stringValue == code
            && cell.textField?.accessibilityLabel() == L("병합 충돌: \(code)", "Unmerged: \(code)")
    }
    var qaSupportBoundaryVisible: Bool { !supportLabel.stringValue.isEmpty && supportLabel.superview != nil }
    var qaAccessibilityReady: Bool { table.accessibilityLabel() != nil && repositoryLabel.accessibilityLabel() != nil && supportLabel.accessibilityLabel() != nil }
#endif
}
