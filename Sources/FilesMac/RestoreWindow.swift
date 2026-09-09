import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class RestoreWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [RestoreWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private var running = true
    private let label = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextView()
    private let close = NSButton(title: L("닫기", "Close"), target: nil, action: #selector(closeWindow(_:)))

    static func start(sources: [URL], destination: URL, completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        let controller = RestoreWindow(sources: sources, destination: destination)
        operations.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
        Task {
            do {
                let report = try await EntryOperations.restoreFromTrash(sources, to: destination, journalDirectory: journals)
                await MainActor.run { controller.finish(report) }
            } catch {
                await MainActor.run { controller.fail(error) }
            }
            completion()
        }
    }

    private init(sources: [URL], destination: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("휴지통에서 복원", "Restore from Trash")
        window.delegate = self
        window.center()
        window.minSize = NSSize(width: 560, height: 280)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let target = NSTextField(wrappingLabelWithString: L("대상: ", "Destination: ") + destination.path)
        target.isSelectable = true
        stack.addArrangedSubview(target)
        label.stringValue = L("휴지통에서 복원 중…", "Restoring from trash…")
        stack.addArrangedSubview(label)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        details.isEditable = false
        details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.string = sources.map(\.path).joined(separator: "\n")
        scroll.documentView = details
        stack.addArrangedSubview(scroll)
        close.target = self
        close.isEnabled = false
        close.bezelStyle = .rounded
        stack.addArrangedSubview(close)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        for view in [target, label, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func finish(_ report: RestoreOperationResult) {
        running = false
        let completed = report.items.filter { $0.state == "completed" }.count
        let failed = report.items.filter { $0.state == "failed" || $0.state == "conflict" || $0.state == "notFound" }.count
        label.stringValue = L("작업 완료", "Finished") + " · " +
            L("복원 완료 ", "Restored ") + "\(completed)/\(report.items.count)" +
            L("개 항목", " items")
        if failed > 0 {
            label.stringValue += L(" · 실패 ", " · Failed ") + "\(failed)/\(report.items.count)"
        }
        details.string = report.items.map { item in
            let status: String
            switch item.state {
            case "completed":
                status = L("완료", "Done")
            case "conflict":
                status = L("충돌", "Conflict")
            case "failed":
                status = L("실패", "Failed")
            default:
                status = L("미처리", "Not attempted")
            }
            return "[\(status)] " + item.source.path + " → " + item.target.path +
                (item.message.map { "\n  " + $0 } ?? "")
        }.joined(separator: "\n\n")
        if let error = report.journalError { details.string += "\n\n" + L("저널 저장 오류: ", "Journal error: ") + error }
        close.title = L("닫기", "Close")
        close.isEnabled = true
    }

    private func fail(_ error: Error) {
        running = false
        label.stringValue = L("휴지통 복원 실패", "Restore from trash failed")
        details.string = error.localizedDescription
        close.title = L("닫기", "Close")
        close.isEnabled = true
    }

    @objc private func closeWindow(_ sender: Any?) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !running }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
}
