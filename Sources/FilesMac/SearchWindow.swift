import AppKit
import FilesCore

@MainActor
final class SearchWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private let model = SearchModel(searcher: SearchRouter(spotlight: SpotlightFileSearch()))
    private var onReveal: ((FileItem) -> Void)?
    private var onOpen: ((FileItem) -> Void)?
    private let reveal = NSButton()
    private let search = NSSearchField(), method = NSPopUpButton(), scope = NSPopUpButton(), kind = NSPopUpButton(), hidden = NSButton(checkboxWithTitle: L("숨김 포함", "Include Hidden"), target: nil, action: nil)
    private let tag = NSSearchField(), minimumSize = NSTextField(), maximumSize = NSTextField(), sizeUnit = NSPopUpButton()
    private let afterEnabled = NSButton(checkboxWithTitle: L("수정일 이후", "Modified after"), target: nil, action: nil)
    private let beforeEnabled = NSButton(checkboxWithTitle: L("수정일 이전", "Modified before"), target: nil, action: nil)
    private let afterDate = NSDatePicker(), beforeDate = NSDatePicker()
    private let table = SearchResultsTable(), status = NSTextField(labelWithString: ""), stop = NSButton()
    private var root: URL?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("검색", "Search"); panel.isReleasedWhenClosed = false; buildUI()
        model.onChange = { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        search.placeholderString = L("파일 이름 검색", "Search file names"); search.delegate = self; search.target = self; search.action = #selector(start(_:)); search.setAccessibilityLabel(L("파일 이름 검색", "Search file names")); controls.addArrangedSubview(search)
        method.addItems(withTitles: [L("파일 이름", "File Name"), L("Spotlight 콘텐츠", "Spotlight Content")]); method.setAccessibilityLabel(L("검색 방법", "Search method")); method.target = self; method.action = #selector(methodChanged(_:)); controls.addArrangedSubview(method)
        scope.addItems(withTitles: [L("하위 폴더 포함", "Include Subfolders"), L("현재 폴더", "Current Folder")]); scope.setAccessibilityLabel(L("검색 범위", "Search scope")); controls.addArrangedSubview(scope)
        kind.addItems(withTitles: [L("모든 항목", "All Items"), L("파일", "Files"), L("폴더", "Folders")]); kind.setAccessibilityLabel(L("항목 종류", "Item kind")); controls.addArrangedSubview(kind)
        hidden.target = self; hidden.action = #selector(start(_:)); controls.addArrangedSubview(hidden)
        let go = NSButton(title: L("검색", "Search"), target: self, action: #selector(start(_:))); controls.addArrangedSubview(go); stack.addArrangedSubview(controls)
        let metadata = NSStackView(); metadata.orientation = .vertical; metadata.spacing = 8
        let tagsAndSize = NSStackView(); tagsAndSize.orientation = .horizontal; tagsAndSize.spacing = 8
        tag.placeholderString = L("Finder 태그", "Finder tags"); tag.setAccessibilityLabel(L("Finder 태그 필터", "Finder tag filter")); tagsAndSize.addArrangedSubview(tag)
        minimumSize.placeholderString = L("최소 크기", "Min size"); minimumSize.setAccessibilityLabel(L("최소 파일 크기", "Minimum file size")); tagsAndSize.addArrangedSubview(minimumSize)
        maximumSize.placeholderString = L("최대 크기", "Max size"); maximumSize.setAccessibilityLabel(L("최대 파일 크기", "Maximum file size")); tagsAndSize.addArrangedSubview(maximumSize)
        sizeUnit.addItems(withTitles: SearchSizeUnit.allCases.map(\.rawValue)); sizeUnit.setAccessibilityLabel(L("파일 크기 단위", "File size unit")); tagsAndSize.addArrangedSubview(sizeUnit)
        metadata.addArrangedSubview(tagsAndSize)
        let dates = NSStackView(); dates.orientation = .horizontal; dates.spacing = 8
        for picker in [afterDate, beforeDate] { picker.datePickerElements = [.yearMonthDay]; picker.datePickerStyle = .textFieldAndStepper }
        afterDate.setAccessibilityLabel(L("수정일 시작 날짜", "Earliest modification date"))
        beforeDate.setAccessibilityLabel(L("수정일 종료 날짜", "Latest modification date"))
        dates.addArrangedSubview(afterEnabled); dates.addArrangedSubview(afterDate); dates.addArrangedSubview(beforeEnabled); dates.addArrangedSubview(beforeDate); dates.addArrangedSubview(NSView()); metadata.addArrangedSubview(dates); stack.addArrangedSubview(metadata)
        for (id, title, width) in [("name", L("이름", "Name"), 240.0), ("path", L("위치", "Location"), 360.0), ("kind", L("종류", "Kind"), 90.0)] { let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelection(_:)); table.allowsMultipleSelection = false
        table.setAccessibilityLabel(L("검색 결과", "Search results"))
        table.openSelected = { [weak self] in self?.openResult(at: self?.table.selectedRow ?? -1) }
        let resultMenu = NSMenu()
        let parent = resultMenu.addItem(withTitle: L("상위 폴더 열기", "Open Parent Folder"), action: #selector(openParentFolder(_:)), keyEquivalent: "")
        parent.target = self
        table.menu = resultMenu
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical); stack.addArrangedSubview(scroll)
        let footer = NSStackView(); footer.orientation = .horizontal; status.textColor = .secondaryLabelColor; footer.addArrangedSubview(status); footer.addArrangedSubview(NSView())
        reveal.title = L("상위 폴더 열기", "Open Parent Folder")
        reveal.target = self
        reveal.action = #selector(openParentFolder(_:))
        footer.addArrangedSubview(reveal)
        stop.title = L("중단", "Stop"); stop.target = self; stop.action = #selector(cancel(_:)); footer.addArrangedSubview(stop); stack.addArrangedSubview(footer)
    }
    func present(root: URL, showHidden: Bool, onReveal: @escaping (FileItem) -> Void, onOpen: ((FileItem) -> Void)? = nil) {
        if self.root != root { model.reset() }
        self.root = root
        self.onReveal = onReveal
        self.onOpen = onOpen
        hidden.state = showHidden ? .on : .off
        render()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }
    func presentTagSearch(tag value: String, root: URL, showHidden: Bool,
                          onReveal: @escaping (FileItem) -> Void, onOpen: @escaping (FileItem) -> Void) {
        present(root: root, showHidden: showHidden, onReveal: onReveal, onOpen: onOpen)
        method.selectItem(at: 0); methodChanged(nil); search.stringValue = ""; tag.stringValue = value
        scope.selectItem(at: 0); kind.selectItem(at: 0); minimumSize.stringValue = ""; maximumSize.stringValue = ""
        start(nil)
    }
    @objc private func methodChanged(_ sender: Any?) {
        let content = method.indexOfSelectedItem == 1
        if content && scope.numberOfItems == 2 {
            scope.addItem(withTitle: L("모든 인덱싱된 위치", "All Indexed Locations"))
        } else if !content && scope.numberOfItems == 3 {
            if scope.indexOfSelectedItem == 2 { scope.selectItem(at: 0) }
            scope.removeItem(at: 2)
        }
        search.placeholderString = content ? L("파일 콘텐츠 검색", "Search file contents") : L("파일 이름 검색", "Search file names")
        search.setAccessibilityLabel(search.placeholderString ?? "")
    }
    @objc private func start(_ sender: Any?) {
        guard let root else { return }
        let unit = SearchSizeUnit.allCases[sizeUnit.indexOfSelectedItem]
        guard let minimum = parseSize(minimumSize.stringValue, unit: unit), let maximum = parseSize(maximumSize.stringValue, unit: unit) else { status.stringValue = L("파일 크기는 선택한 단위의 0 이상 숫자로 입력하세요.", "File sizes must be non-negative numbers in the selected unit."); return }
        if let minimum, let maximum, minimum > maximum { status.stringValue = L("최소 크기는 최대 크기보다 클 수 없습니다.", "Minimum size cannot exceed maximum size."); return }
        let selectedScope: SearchScope = switch scope.indexOfSelectedItem {
        case 1: .currentFolder
        case 2: .indexedLocations
        default: .descendants
        }
        let selectedKind = SearchItemKind.allCases[kind.indexOfSelectedItem]
        model.search(in: root, query: FileSearchQuery(text: search.stringValue, scope: selectedScope, kind: selectedKind, showHidden: hidden.state == .on,
            tagText: tag.stringValue, minimumSize: minimum, maximumSize: maximum,
            modifiedAfter: afterEnabled.state == .on ? Calendar.current.startOfDay(for: afterDate.dateValue) : nil,
            modifiedBefore: beforeEnabled.state == .on ? Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: Calendar.current.startOfDay(for: beforeDate.dateValue)) : nil,
            method: method.indexOfSelectedItem == 1 ? .spotlightContent : .fileName))
    }
    private func parseSize(_ value: String, unit: SearchSizeUnit) -> Int64?? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .some(nil) }
        let formatter = NumberFormatter(); formatter.locale = .current; formatter.numberStyle = .decimal
        guard let number = formatter.number(from: value), let parsed = unit.byteCount(number.doubleValue) else { return nil }
        return .some(parsed)
    }
    @objc private func cancel(_ sender: Any?) { model.cancel() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText(),
              selector == #selector(NSResponder.moveDown(_:)), !model.results.isEmpty,
              window?.makeFirstResponder(table) == true else { return false }
        let row = max(0, table.selectedRow)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return true
    }
    private func result(at row: Int) -> FileItem? {
        model.results.indices.contains(row) ? model.results[row] : nil
    }
    @objc private func openSelection(_ sender: Any?) {
        openResult(at: table.clickedRow)
    }
    private func openResult(at row: Int) {
        guard let item = result(at: row) else { return }
        model.cancel()
        close()
        (onOpen ?? onReveal)?(item)
    }
    @objc private func openParentFolder(_ sender: Any?) {
        let row = sender is NSMenuItem ? table.clickedRow : table.selectedRow
        guard let item = result(at: row) else { return }
        model.cancel()
        close()
        onReveal?(item)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { result(at: table.clickedRow) != nil }
    func tableViewSelectionDidChange(_ notification: Notification) { reveal.isEnabled = result(at: table.selectedRow) != nil }
    private func render() {
        table.reloadData(); stop.isEnabled = model.isSearching
        reveal.isEnabled = result(at: table.selectedRow) != nil
        let usesSpotlight = model.query?.method == .spotlightContent
        if model.isSearching { status.stringValue = usesSpotlight ? L("Spotlight 인덱스 검색 중… \(model.results.count)개", "Searching Spotlight index… \(model.results.count)") : L("직접 열거로 검색 중… \(model.results.count)개", "Searching by direct enumeration… \(model.results.count)") }
        else if model.wasCancelled { status.stringValue = L("검색 중단 · 부분 결과 \(model.results.count)개", "Search stopped · \(model.results.count) partial results") }
        else if let error = model.error { status.stringValue = L("검색 실패: ", "Search failed: ") + error }
        else if usesSpotlight && model.results.isEmpty { status.stringValue = L("Spotlight 결과 0개 · 이 위치의 인덱스 범위를 확인하세요.", "0 Spotlight results · Check whether this location is indexed.") }
        else { status.stringValue = usesSpotlight ? L("Spotlight 결과 \(model.results.count)개", "\(model.results.count) Spotlight results") : L("직접 열거 결과 \(model.results.count)개", "\(model.results.count) results from direct enumeration") }
        if model.skippedLocations > 0 { status.stringValue += L(" · 접근 불가 \(model.skippedLocations)곳", " · \(model.skippedLocations) locations skipped") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.results.indices.contains(row), let id = tableColumn?.identifier else { return nil }; let item = model.results[row]
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? { let c = NSTableCellView(); c.identifier = id; let t = NSTextField(labelWithString: ""); t.lineBreakMode = .byTruncatingMiddle; t.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(t); c.textField = t; NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)]); return c }()
        switch id.rawValue { case "name": cell.textField?.stringValue = item.name; case "path": cell.textField?.stringValue = item.url.deletingLastPathComponent().path; default: cell.textField?.stringValue = item.kind }
        return cell
    }
#if DEBUG
    func qaSearch(_ text: String, scope value: SearchScope) { search.stringValue = text; scope.selectItem(at: value == .currentFolder ? 1 : 0); start(nil) }
    func qaSearchAdvanced(_ text: String, tag tagValue: String, minimum: String, maximum: String, unit: SearchSizeUnit = .bytes) { search.stringValue = text; tag.stringValue = tagValue; minimumSize.stringValue = minimum; maximumSize.stringValue = maximum; sizeUnit.selectItem(at: SearchSizeUnit.allCases.firstIndex(of: unit)!); scope.selectItem(at: 1); start(nil) }
    func qaSearchSpotlight(_ text: String, scope value: SearchScope = .currentFolder) {
        method.selectItem(at: 1); methodChanged(nil); search.stringValue = text
        tag.stringValue = ""; minimumSize.stringValue = ""; maximumSize.stringValue = ""
        switch value {
        case .descendants: scope.selectItem(at: 0)
        case .currentFolder: scope.selectItem(at: 1)
        case .indexedLocations: scope.selectItem(at: 2)
        }
        start(nil)
    }
    func qaReturnToFileNameSearch() -> Bool {
        method.selectItem(at: 0); methodChanged(nil)
        return scope.numberOfItems == 2 && scope.indexOfSelectedItem == 0
    }
    func qaContainsResult(at url: URL) -> Bool {
        model.results.contains { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    func qaInvalidSize() { minimumSize.stringValue = "invalid"; start(nil) }
    var qaValidationError: Bool { status.stringValue.contains(L("파일 크기", "File sizes")) }
    var qaIsSearching: Bool { model.isSearching }
    var qaResultCount: Int { model.results.count }
    var qaTagFilter: String { tag.stringValue }
    var qaShowsDirectEnumeration: Bool { status.stringValue.contains(L("직접 열거", "direct enumeration")) }
    var qaShowsSpotlight: Bool { status.stringValue.contains("Spotlight") }
    func qaContainsResult(named name: String) -> Bool { model.results.contains { $0.name == name } }
    func qaOpenResultWithKeyboard() -> (focusedResult: Bool, closed: Bool) {
        guard let window, window.makeFirstResponder(search) else { return (false, false) }
        func sendKey(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            window.sendEvent(event)
        }
        sendKey(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.function, .numericPad])
        guard window.firstResponder === table, table.selectedRow == 0 else { return (false, false) }
        sendKey(36, "\r")
        return (true, !window.isVisible)
    }
    func qaRevealResult(named name: String) -> Bool {
        guard let row = model.results.firstIndex(where: { $0.name == name }) else { return false }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard reveal.isEnabled else { return false }
        reveal.performClick(nil)
        return true
    }
#endif
}

@MainActor
private final class SearchResultsTable: NSTableView {
    var openSelected: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), selectedRow >= 0,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            openSelected?()
            return
        }
        super.keyDown(with: event)
    }
}
