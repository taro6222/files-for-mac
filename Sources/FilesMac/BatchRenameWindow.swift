import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class BatchRenameWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [BatchRenameWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private var running = true
    private let label = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextView()
    private let closeButton = NSButton(title: L("닫기", "Close"), target: nil, action: #selector(closeWindow(_:)))

    static func start(requests: [BatchRenameRequest], completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        let controller = BatchRenameWindow(requests: requests)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
        Task {
            do { controller.finish(try await EntryOperations.batchRename(requests, journalDirectory: journals)) }
            catch { controller.fail(error) }
            completion()
        }
    }

    private init(requests: [BatchRenameRequest]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = L("일괄 이름 변경", "Batch Rename")
        window.delegate = self; window.center(); window.minSize = NSSize(width: 560, height: 300)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        label.stringValue = L("이름 변경 계획을 검사하는 중…", "Checking rename plan…"); stack.addArrangedSubview(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.string = requests.map { $0.source.lastPathComponent + " → " + $0.name }.joined(separator: "\n")
        scroll.documentView = details; stack.addArrangedSubview(scroll)
        closeButton.target = self; closeButton.isEnabled = false; stack.addArrangedSubview(closeButton)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func finish(_ report: BatchRenameResult) {
        running = false
        let completed = report.items.filter { $0.state == "completed" || $0.state == "unchanged" }.count
        switch report.state {
        case "completed":
            label.stringValue = L("일괄 이름 변경 완료", "Batch rename complete") + " · \(completed)/\(report.items.count)"
        case "failed":
            label.stringValue = L("일괄 이름 변경 중단", "Batch rename stopped") + " · \(completed)/\(report.items.count)"
        default:
            label.stringValue = L("이름 변경 계획을 적용하지 않았습니다", "Rename plan was not applied")
        }
        details.string = report.items.map { item in
            let state: String
            switch item.state {
            case "completed": state = L("완료", "Done")
            case "unchanged": state = L("변경 없음", "Unchanged")
            case "conflict": state = L("충돌", "Conflict")
            case "invalid": state = L("잘못된 이름", "Invalid")
            case "notFound": state = L("원본 없음", "Missing")
            default: state = L("실패", "Failed")
            }
            return "[\(state)] \(item.source.lastPathComponent) → \(item.target.lastPathComponent)" +
                (item.message.map { "\n  " + $0 } ?? "")
        }.joined(separator: "\n\n")
        if let error = report.journalError { details.string += "\n\n" + L("저널 저장 오류: ", "Journal error: ") + error }
        closeButton.isEnabled = true
    }
    private func fail(_ error: Error) { running = false; label.stringValue = L("일괄 이름 변경 실패", "Batch rename failed"); details.string = error.localizedDescription; closeButton.isEnabled = true }
    @objc private func closeWindow(_ sender: Any?) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !running }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
}
