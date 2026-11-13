import AppKit
import FilesCore

@MainActor
final class RemoteBrowserWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: RemoteBrowserModel
    private let onDownload: (RemoteDirectoryEntry, NSWindow?) -> Void
    private let path = NSTextField(labelWithString: "/"), status = NSTextField(labelWithString: "")
    private let table = NSTableView(), back = NSButton(), forward = NSButton(), up = NSButton(), refresh = NSButton(), stop = NSButton(), download = NSButton()

    init(title: String, model: RemoteBrowserModel, onDownload: @escaping (RemoteDirectoryEntry, NSWindow?) -> Void) {
        self.model = model; self.onDownload = onDownload
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = title; panel.isReleasedWhenClosed = false
        buildUI(); model.onChange = { [weak self] in self?.render() }; render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() { window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); model.start() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 8; root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12); root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root); NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 6
        configure(back, L("뒤로", "Back"), #selector(goBack(_:))); configure(forward, L("앞으로", "Forward"), #selector(goForward(_:)))
        configure(up, L("상위", "Up"), #selector(goUp(_:))); configure(refresh, L("새로고침", "Refresh"), #selector(reload(_:))); configure(stop, L("중단", "Stop"), #selector(stopLoading(_:)))
        for button in [back, forward, up, refresh, stop] { controls.addArrangedSubview(button) }
        path.lineBreakMode = .byTruncatingMiddle; controls.addArrangedSubview(path); root.addArrangedSubview(controls)
        let name = NSTableColumn(identifier: .init("name")); name.title = L("이름", "Name"); name.width = 480
        let kind = NSTableColumn(identifier: .init("kind")); kind.title = L("종류", "Kind"); kind.width = 120
        table.addTableColumn(name); table.addTableColumn(kind); table.delegate = self; table.dataSource = self; table.doubleAction = #selector(openSelection(_:)); table.target = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; root.addArrangedSubview(scroll)
        let footer = NSStackView(); footer.orientation = .horizontal; footer.addArrangedSubview(status); footer.addArrangedSubview(NSView())
        configure(download, L("선택 파일 다운로드…", "Download Selected File…"), #selector(downloadSelection(_:))); footer.addArrangedSubview(download); root.addArrangedSubview(footer)
    }
    private func configure(_ button: NSButton, _ title: String, _ action: Selector) { button.title = title; button.target = self; button.action = action }
    private func render() {
        path.stringValue = model.path; table.reloadData()
        back.isEnabled = model.canGoBack && !model.isLoading; forward.isEnabled = model.canGoForward && !model.isLoading
        up.isEnabled = model.canGoUp && !model.isLoading; refresh.isEnabled = !model.isLoading; stop.isEnabled = model.isLoading
        if model.isLoading { status.stringValue = L("불러오는 중…", "Loading…") }
        else if model.wasCancelled { status.stringValue = L("불러오기가 중단되었습니다.", "Loading was stopped.") }
        else if let error = model.error { status.stringValue = error }
        else { status.stringValue = L("항목 \(model.entries.count)개", "\(model.entries.count) items") }
        updateSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.entries.indices.contains(row), let tableColumn else { return nil }; let entry = model.entries[row]
        let id = NSUserInterfaceItemIdentifier(tableColumn.identifier.rawValue + "Cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(text); c.textField = text; NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6), text.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        cell.textField?.stringValue = tableColumn.identifier.rawValue == "kind" ? (entry.isDirectory ? L("폴더", "Folder") : L("파일", "File")) : entry.name
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() { download.isEnabled = selected?.isDirectory == false && !model.isLoading }
    private var selected: RemoteDirectoryEntry? { model.entries.indices.contains(table.selectedRow) ? model.entries[table.selectedRow] : nil }
    @objc private func openSelection(_ sender: Any?) { guard let selected, selected.isDirectory else { return }; try? model.open(selected) }
    @objc private func downloadSelection(_ sender: Any?) { guard let selected, !selected.isDirectory else { return }; onDownload(selected, window) }
    @objc private func goBack(_ sender: Any?) { model.goBack() }
    @objc private func goForward(_ sender: Any?) { model.goForward() }
    @objc private func goUp(_ sender: Any?) { model.goUp() }
    @objc private func reload(_ sender: Any?) { model.reload() }
    @objc private func stopLoading(_ sender: Any?) { model.cancel() }
}
