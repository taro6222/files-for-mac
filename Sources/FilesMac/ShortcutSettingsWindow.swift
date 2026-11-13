import AppKit
import FilesCore

@MainActor
enum ShortcutBridge {
    static func commandID(_ item: NSMenuItem) -> String? { item.action.map(NSStringFromSelector) }
    static func shortcut(_ item: NSMenuItem) -> KeyboardShortcut? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        return KeyboardShortcut(key: keyName(item.keyEquivalent), modifiers: modifiers(item.keyEquivalentModifierMask))
    }
    static func apply(_ preferences: ShortcutPreferences, to menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if let submenu = item.submenu { apply(preferences, to: submenu) }
            guard let id = commandID(item) else { continue }
            if let shortcut = preferences.shortcut(for: id) {
                item.keyEquivalent = keyEquivalent(shortcut.key); item.keyEquivalentModifierMask = eventModifiers(shortcut.modifiers)
            } else { item.keyEquivalent = ""; item.keyEquivalentModifierMask = [] }
        }
    }
    static func label(_ shortcut: KeyboardShortcut?) -> String {
        guard let shortcut else { return "—" }; let m = shortcut.modifiers
        let key = switch shortcut.key { case "down": "↓"; case "up": "↑"; case "left": "←"; case "right": "→"; case "delete": "⌫"; case "escape": "Esc"; case "space": "Space"; case "tab": "Tab"; default: shortcut.key.uppercased() }
        return (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
            + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + key
    }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var value: ShortcutModifiers = []
        if flags.contains(.command) { value.insert(.command) }; if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }; if flags.contains(.shift) { value.insert(.shift) }; return value
    }
    static func eventModifiers(_ value: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if value.contains(.command) { flags.insert(.command) }; if value.contains(.option) { flags.insert(.option) }
        if value.contains(.control) { flags.insert(.control) }; if value.contains(.shift) { flags.insert(.shift) }; return flags
    }
    private static func keyName(_ value: String) -> String {
        switch value { case " ": "space"; case "\t": "tab"; case "\u{1b}": "escape"; case "\u{f700}": "up"; case "\u{f701}": "down"; case "\u{f702}": "left"; case "\u{f703}": "right"; case "\u{8}": "delete"; default: value }
    }
    private static func keyEquivalent(_ value: String) -> String {
        switch value { case "space": " "; case "tab": "\t"; case "escape": "\u{1b}"; case "up": "\u{f700}"; case "down": "\u{f701}"; case "left": "\u{f702}"; case "right": "\u{f703}"; case "delete": "\u{8}"; default: value }
    }
}

@MainActor
private final class ShortcutRecorder: NSTextField {
    var onRecord: ((KeyboardShortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let key: String
        switch event.keyCode {
        case 48: key = "tab"; case 49: key = "space"; case 53: key = "escape"
        default: key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        let shortcut = KeyboardShortcut(key: key, modifiers: ShortcutBridge.modifiers(event.modifierFlags))
        stringValue = ShortcutBridge.label(shortcut); onRecord?(shortcut)
    }
}

@MainActor
final class ShortcutSettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row { let id: String; let category: String; let title: String }
    private let preferences: ShortcutPreferences
    private let onChange: () -> Void
    private let table = NSTableView()
    private let recorder = ShortcutRecorder()
    private var rows: [Row] = []

    init(preferences: ShortcutPreferences, entries: [CommandPaletteEntry], onChange: @escaping () -> Void) {
        self.preferences = preferences; self.onChange = onChange
        var seen: Set<String> = []
        rows = entries.compactMap { entry in
            guard let id = ShortcutBridge.commandID(entry.item), seen.insert(id).inserted else { return nil }
            return Row(id: id, category: entry.category, title: entry.title)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("키보드 단축키", "Keyboard Shortcuts"); panel.isReleasedWhenClosed = false; buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildUI() {
        guard let content = window?.contentView else { return }; let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let info = NSTextField(wrappingLabelWithString: L("명령을 선택하고 아래 필드에서 새 조합을 누르세요. 충돌과 macOS 예약 조합은 저장되지 않습니다.", "Select a command, then press the new combination below. Conflicts and macOS-reserved combinations are rejected.")); stack.addArrangedSubview(info)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut")); column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 30; table.delegate = self; table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical); stack.addArrangedSubview(scroll)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        controls.setContentCompressionResistancePriority(.required, for: .vertical)
        recorder.placeholderString = L("새 단축키 누르기", "Press new shortcut"); recorder.isEditable = false; recorder.isSelectable = false
        recorder.isBordered = false; recorder.drawsBackground = false; recorder.wantsLayer = true; recorder.layer?.borderWidth = 1; recorder.layer?.borderColor = NSColor.separatorColor.cgColor; recorder.layer?.cornerRadius = 5
        recorder.setAccessibilityLabel(L("단축키 기록", "Shortcut recorder")); controls.addArrangedSubview(recorder); recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let reset = NSButton(title: L("기본값 복원", "Restore Defaults"), target: self, action: #selector(resetAll(_:))); reset.isBordered = false; reset.contentTintColor = .labelColor; controls.addArrangedSubview(reset); stack.addArrangedSubview(controls)
        controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        recorder.onRecord = { [weak self] shortcut in self?.record(shortcut) }
        if let first = rows.first { table.selectRowIndexes([0], byExtendingSelection: false); recorder.stringValue = ShortcutBridge.label(preferences.shortcut(for: first.id)) }
    }
    func present() { table.reloadData(); window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let value = rows[row], id = NSUserInterfaceItemIdentifier("ShortcutCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let t = NSTextField(labelWithString: ""); t.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(t); c.textField = t; NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        cell.textField?.stringValue = "\(value.category)  ›  \(value.title)    \(ShortcutBridge.label(preferences.shortcut(for: value.id)))"; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { window?.makeFirstResponder(recorder); if rows.indices.contains(table.selectedRow) { recorder.stringValue = ShortcutBridge.label(preferences.shortcut(for: rows[table.selectedRow].id)) } }
    private func record(_ shortcut: KeyboardShortcut) {
        guard rows.indices.contains(table.selectedRow) else { return }
        do { try preferences.set(shortcut, for: rows[table.selectedRow].id); onChange(); table.reloadData() }
        catch { let alert = NSAlert(); alert.messageText = L("단축키를 저장할 수 없습니다", "Unable to Save Shortcut"); alert.informativeText = message(error); alert.beginSheetModal(for: window!) }
    }
    private func message(_ error: Error) -> String {
        switch error as? ShortcutValidationError {
        case .emptyKey: return L("키를 누르세요.", "Press a key.")
        case .modifierRequired: return L("Command, Option, Control 또는 Shift가 필요합니다.", "Command, Option, Control, or Shift is required.")
        case .systemReserved: return L("macOS가 예약한 조합입니다.", "This combination is reserved by macOS.")
        case .conflict: return L("다른 명령에서 이미 사용 중입니다.", "This combination is already used by another command.")
        case nil: return error.localizedDescription
        }
    }
    @objc private func resetAll(_ sender: Any?) { preferences.resetAll(); onChange(); table.reloadData() }
#if DEBUG
    var qaRowCount: Int { rows.count }
#endif
}
