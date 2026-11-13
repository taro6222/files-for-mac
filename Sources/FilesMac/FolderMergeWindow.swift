import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class FolderMergeWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [FolderMergeWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private var running = true
    private let cancellation = CopyCancellation()
    private let label = NSTextField(wrappingLabelWithString: L("병합 계획 준비 중…", "Preparing merge plan…"))
    private let progress = NSProgressIndicator()
    private let details = NSTextView()
    private let cancel = NSButton(title: L("취소", "Cancel"), target: nil, action: #selector(cancelMerge(_:)))

    static func start(sources: [URL], destination: URL, completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        let controller = FolderMergeWindow(sources: sources, destination: destination)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
        Task { [controller] in
            let report = await CopyMergeBatch.run(sources: sources, destination: destination,
                                                  journalDirectory: journals,
                                                  cancellation: controller.cancellation) { [weak controller] update in
                Task { @MainActor in controller?.update(update) }
            }
            controller.finish(report)
            completion()
        }
    }

    private init(sources: [URL], destination: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("폴더 병합", "Merge Folders"); window.delegate = self; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let paths = NSTextField(wrappingLabelWithString:
            L("대상: ", "Destination: ") + destination.path + "\n" +
            L("항목: ", "Items: ") + "\(sources.count)")
        paths.isSelectable = true; stack.addArrangedSubview(paths); stack.addArrangedSubview(label)
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0
        progress.maxValue = Double(sources.count); stack.addArrangedSubview(progress)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12)
        scroll.documentView = details; stack.addArrangedSubview(scroll)
        cancel.target = self; stack.addArrangedSubview(cancel)
        for view in [paths, label, progress, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update(_ update: CopyMergeBatchProgress) {
        guard running else { return }
        progress.doubleValue = Double(update.index + 1)
        label.stringValue = "\(update.index + 1)/\(update.total) · \(update.state) · \(update.source.lastPathComponent)"
    }

    private func finish(_ report: CopyMergeBatchReport) {
        running = false; progress.doubleValue = progress.maxValue
        let added = report.items.reduce(0) { $0 + $1.addedCount }
        let conflicts = report.items.reduce(0) { $0 + $1.conflictCount }
        label.stringValue = L("병합 종료 · 추가 \(added) · 보존한 충돌 \(conflicts)",
                              "Merge finished · Added \(added) · Preserved conflicts \(conflicts)")
        details.string = report.items.map {
            "[\($0.state)] \($0.source.path) → \($0.target.path)" +
            "\n  " + L("추가 ", "Added ") + "\($0.addedCount)" +
            L(" · 충돌 ", " · Conflicts ") + "\($0.conflictCount)" +
            ($0.message.map { "\n  " + $0 } ?? "")
        }.joined(separator: "\n\n")
        if let error = report.journalError { details.string += "\n\n" + L("저널 오류: ", "Journal error: ") + error }
        cancel.title = L("닫기", "Close"); cancel.isEnabled = true
    }
    @objc private func cancelMerge(_ sender: Any?) {
        if !running { close(); return }
        cancellation.cancel(); cancel.isEnabled = false; label.stringValue = L("안전 지점에서 취소 중…", "Cancelling at a safe point…")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { NSSound.beep(); return false }; return true }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
}
