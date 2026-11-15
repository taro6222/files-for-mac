import AppKit
import FilesCore
@preconcurrency import QuickLookUI

@MainActor
final class BrowserInfoPane: NSView {
    private let tabs = NSSegmentedControl(labels: [L("상세", "Details"), L("미리보기", "Preview")],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let git = NSTextField(wrappingLabelWithString: "")
    private let previewHost = NSView()
    private let previous = NSButton()
    private let next = NSButton()
    private let position = NSTextField(labelWithString: "")
    private let navigation = NSStackView()
    private let propertiesButton = NSButton()
    private let tagsButton = NSButton()
    private var preview: QLPreviewView?
    private var previewIndex = 0
    private var task: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?
    private var items: [FileItem] = []
    private var tab: InfoPaneTab?
    private var sizeUnit: BrowserSizeUnit?
    var onTabChange: ((InfoPaneTab) -> Void)?
    var onOpenProperties: (() -> Void)?
    var onEditTags: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setAccessibilityLabel(L("정보 보기", "Information View"))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.setAccessibilityLabel(L("항목 정보", "Item information"))
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        title.font = .boldSystemFont(ofSize: 13)
        text.isSelectable = true
        text.textColor = .secondaryLabelColor
        git.textColor = .secondaryLabelColor
        git.isHidden = true
        previous.title = L("이전", "Previous")
        previous.target = self
        previous.action = #selector(previousPreview)
        next.title = L("다음", "Next")
        next.target = self
        next.action = #selector(nextPreview)
        navigation.orientation = .horizontal
        navigation.isHidden = true
        previewHost.isHidden = true
        propertiesButton.title = L("속성…", "Properties…")
        propertiesButton.target = self
        propertiesButton.action = #selector(openProperties)
        tagsButton.title = L("Finder 태그 편집…", "Edit Finder Tags…")
        tagsButton.target = self
        tagsButton.action = #selector(editTags)
        propertiesButton.isHidden = true
        tagsButton.isHidden = true
        for view in [previous, position, next] { navigation.addArrangedSubview(view) }
        for view in [title, text, git, tagsButton, propertiesButton, navigation, previewHost] { stack.addArrangedSubview(view) }
        addSubview(tabs)
        addSubview(scroll)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            git.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.heightAnchor.constraint(equalToConstant: 260)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selectTab() { onTabChange?(tabs.selectedSegment == 1 ? .preview : .details) }
    @objc private func previousPreview() { showPreview(at: previewIndex - 1) }
    @objc private func nextPreview() { showPreview(at: previewIndex + 1) }
    @objc private func openProperties() { onOpenProperties?() }
    @objc private func editTags() { onEditTags?() }

    func update(items: [FileItem], tab: InfoPaneTab, sizeUnit: BrowserSizeUnit) {
        guard items != self.items || tab != self.tab || sizeUnit != self.sizeUnit else { return }
        clear()
        self.items = items
        self.tab = tab
        self.sizeUnit = sizeUnit
        tabs.selectedSegment = tab == .details ? 0 : 1
        guard let item = items.first else {
            title.stringValue = L("선택한 항목 없음", "No Selection")
            text.stringValue = ""
            return
        }
        if tab == .preview {
            showPreview(at: 0)
            return
        }
        propertiesButton.isHidden = false
        tagsButton.isHidden = items.count != 1
        guard items.count == 1 else {
            title.stringValue = L("\(items.count)개 항목 선택", "\(items.count) items selected")
            let folders = items.count(where: \.isDirectory)
            let files = items.count - folders
            text.stringValue = L("파일 \(files)개 · 폴더 \(folders)개", "\(files) files · \(folders) folders")
            return
        }
        title.stringValue = item.name
        text.stringValue = L("정보 읽는 중…", "Loading information…")
        refreshGitStatus()
        task = Task { [weak self] in
            let properties = try? await FilePropertiesInspector().inspect(item.url)
            guard !Task.isCancelled, let self else { return }
            guard let properties else {
                self.text.stringValue = L("정보를 읽을 수 없습니다.", "Unable to read information.")
                return
            }
            let size = properties.isDirectory ? item.size : properties.logicalSize
            let sizeLabel = size.map { formatByteCount($0, unit: sizeUnit) } ?? "—"
            let created = properties.created?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            let modified = properties.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            let tags = properties.tags.isEmpty ? "—" : properties.tags.joined(separator: ", ")
            let lines: [String] = [
                properties.typeIdentifier ?? item.kind,
                sizeLabel,
                L("생성일: ", "Created: ") + created,
                L("수정일: ", "Modified: ") + modified,
                L("소유자: ", "Owner: ") + (properties.owner ?? "—"),
                L("태그: ", "Tags: ") + tags,
                item.url.path
            ]
            self.text.stringValue = lines.joined(separator: "\n")
        }
    }

    func refreshGitStatus() {
        guard tab == .details, items.count == 1, let item = items.first else { return }
        gitTask?.cancel()
        gitTask = Task { [weak self] in
            let state = try? await GitProvider().status(for: item)
            guard let self, !Task.isCancelled else { return }
            guard let state else {
                self.git.isHidden = true
                self.git.stringValue = ""
                return
            }
            let value: String
            switch state {
            case .clean: value = L("변경 없음", "No changes")
            case .changed(let entry):
                switch entry.kind {
                case .untracked: value = L("추적되지 않음", "Untracked")
                case .unmerged: value = L("병합 충돌 (\(entry.statusCode))", "Merge conflict (\(entry.statusCode))")
                default: value = entry.statusCode
                }
            case .directoryChanges(let count): value = L("항목 \(count)개 변경", "\(count) changed entries")
            }
            self.git.stringValue = L("Git 상태: ", "Git status: ") + value
            self.git.isHidden = false
        }
    }

    private func showPreview(at index: Int) {
        guard items.indices.contains(index) else { return }
        resetScroll()
        previewIndex = index
        let item = items[index]
        title.stringValue = item.name
        navigation.isHidden = items.count < 2
        previous.isEnabled = index > 0
        next.isEnabled = index + 1 < items.count
        position.stringValue = L("\(index + 1) / \(items.count)", "\(index + 1) of \(items.count)")
        if preview == nil && !item.isDirectory {
            preview = QLPreviewView(frame: .zero, style: .normal)
        }
        guard !item.isDirectory, let view = preview else {
            preview?.previewItem = nil
            previewHost.isHidden = true
            text.stringValue = L("미리보기를 표시할 수 없습니다.", "Preview unavailable.")
            return
        }
        text.stringValue = ""
        previewHost.isHidden = false
        if view.superview == nil {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: previewHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor)
            ])
            view.autostarts = true
        }
        view.previewItem = item.url as NSURL
    }

    func clear() {
        task?.cancel()
        task = nil
        gitTask?.cancel()
        gitTask = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        previewHost.isHidden = true
        navigation.isHidden = true
        propertiesButton.isHidden = true
        tagsButton.isHidden = true
        items = []
        tab = nil
        title.stringValue = ""
        text.stringValue = ""
        git.isHidden = true
        git.stringValue = ""
        resetScroll()
    }

    private func resetScroll() {
        let clip = scroll.contentView
        guard clip.bounds.origin != .zero else { return }
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
    }

#if DEBUG
    var qaTitle: String { title.stringValue }
    var qaDetails: String { text.stringValue }
    var qaGitStatus: String? { git.isHidden ? nil : git.stringValue }
    var qaPreviewURL: URL? { (preview?.previewItem as? NSURL).map { $0 as URL } }
    var qaPreviewNavigation: (previous: Bool, next: Bool)? {
        navigation.isHidden ? nil : (previous.isEnabled, next.isEnabled)
    }
    func qaNextPreview() { next.performClick(nil) }
    func qaPreviousPreview() { previous.performClick(nil) }
    func qaOpenProperties() -> Bool {
        guard !propertiesButton.isHiddenOrHasHiddenAncestor else { return false }
        propertiesButton.performClick(nil)
        return true
    }
    func qaEditTags() -> Bool {
        guard !tagsButton.isHiddenOrHasHiddenAncestor else { return false }
        tagsButton.performClick(nil)
        return true
    }
    func qaCanScrollToDetailEnd() -> Bool {
        layoutSubtreeIfNeeded()
        guard let document = scroll.documentView else { return false }
        let frame = text.convert(text.bounds, to: document)
        guard frame.maxY > scroll.documentVisibleRect.maxY else { return false }
        document.scrollToVisible(NSRect(x: frame.minX, y: frame.maxY - 1, width: 1, height: 1))
        return scroll.documentVisibleRect.maxY >= frame.maxY - 1
    }
    var qaScrollStartsAtTop: Bool { scroll.contentView.bounds.minY == 0 }
#endif
}
