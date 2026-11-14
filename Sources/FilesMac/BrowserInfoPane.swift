import AppKit
import FilesCore
@preconcurrency import QuickLookUI

@MainActor
final class BrowserInfoPane: NSView {
    private let tabs = NSSegmentedControl(labels: [L("상세", "Details"), L("미리보기", "Preview")],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let title = NSTextField(wrappingLabelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let previewHost = NSView()
    private var preview: QLPreviewView?
    private var task: Task<Void, Never>?
    private var items: [FileItem] = []
    private var tab: InfoPaneTab?
    private var sizeUnit: BrowserSizeUnit?
    var onTabChange: ((InfoPaneTab) -> Void)?

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
        tabs.setAccessibilityLabel(L("정보 보기", "Information View"))
        title.font = .boldSystemFont(ofSize: 13)
        text.isSelectable = true
        text.textColor = .secondaryLabelColor
        for view in [tabs, title, text, previewHost] { stack.addArrangedSubview(view) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.heightAnchor.constraint(equalToConstant: 260)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selectTab() { onTabChange?(tabs.selectedSegment == 1 ? .preview : .details) }

    func update(items: [FileItem], tab: InfoPaneTab, sizeUnit: BrowserSizeUnit) {
        guard items != self.items || tab != self.tab || sizeUnit != self.sizeUnit else { return }
        clear()
        self.items = items
        self.tab = tab
        self.sizeUnit = sizeUnit
        tabs.selectedSegment = tab == .details ? 0 : 1
        previewHost.isHidden = true
        guard let item = items.first else {
            title.stringValue = L("선택한 항목 없음", "No Selection")
            text.stringValue = ""
            return
        }
        guard items.count == 1 else {
            title.stringValue = L("\(items.count)개 항목 선택", "\(items.count) items selected")
            text.stringValue = tab == .preview ? L("미리 볼 항목 하나를 선택하세요.", "Select one item to preview.") : ""
            return
        }
        title.stringValue = item.name
        if tab == .preview {
            guard !item.isDirectory, let view = QLPreviewView(frame: .zero, style: .normal) else {
                text.stringValue = L("미리보기를 표시할 수 없습니다.", "Preview unavailable.")
                return
            }
            text.stringValue = ""
            previewHost.isHidden = false
            view.translatesAutoresizingMaskIntoConstraints = false
            previewHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: previewHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor)
            ])
            preview = view
            view.autostarts = true
            view.previewItem = item.url as NSURL
            return
        }
        text.stringValue = L("정보 읽는 중…", "Loading information…")
        task = Task { [weak self] in
            let properties = try? await FilePropertiesInspector().inspect(item.url)
            guard !Task.isCancelled, let self else { return }
            guard let properties else {
                self.text.stringValue = L("정보를 읽을 수 없습니다.", "Unable to read information.")
                return
            }
            let size = properties.isDirectory ? item.size : properties.logicalSize
            let date = properties.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            self.text.stringValue = [
                properties.typeIdentifier ?? item.kind,
                size.map { formatByteCount($0, unit: sizeUnit) } ?? "—",
                L("수정일: ", "Modified: ") + date,
                L("소유자: ", "Owner: ") + (properties.owner ?? "—"),
                L("태그: ", "Tags: ") + (properties.tags.isEmpty ? "—" : properties.tags.joined(separator: ", ")),
                item.url.path
            ].joined(separator: "\n")
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        items = []
        tab = nil
        title.stringValue = ""
        text.stringValue = ""
    }

#if DEBUG
    var qaTitle: String { title.stringValue }
    var qaDetails: String { text.stringValue }
    var qaPreviewURL: URL? { (preview?.previewItem as? NSURL).map { $0 as URL } }
#endif
}
