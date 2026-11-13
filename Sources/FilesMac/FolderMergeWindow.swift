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

    static func start(source: URL, target: URL, completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        let controller = FolderMergeWindow(source: source, target: target)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try CopyMergePlanner.plan(source: source, target: target)
                }.value
                controller.showPlan(plan)
                let report = await CopyMergeExecutor.run(plan: plan, journalDirectory: journals,
                                                         cancellation: controller.cancellation)
                controller.finish(report)
            } catch { controller.finish(error) }
            completion()
        }
    }

    private init(source: URL, target: URL) {
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
        let paths = NSTextField(wrappingLabelWithString: L("원본: ", "Source: ") + source.path + "\n" + L("대상: ", "Target: ") + target.path)
        paths.isSelectable = true; stack.addArrangedSubview(paths); stack.addArrangedSubview(label)
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil); stack.addArrangedSubview(progress)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12)
        scroll.documentView = details; stack.addArrangedSubview(scroll)
        cancel.target = self; stack.addArrangedSubview(cancel)
        for view in [paths, label, progress, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func showPlan(_ plan: CopyMergePlan) {
        let copies = plan.actions.filter { $0.kind == .copyMissing }.count
        label.stringValue = L("계획 완료 · 추가 \(copies) · 충돌 \(plan.conflicts.count)",
                              "Plan ready · Add \(copies) · Conflicts \(plan.conflicts.count)")
        details.string = plan.actions.map { "[\($0.kind.rawValue)] \($0.relativePath)" }.joined(separator: "\n")
    }
    private func finish(_ report: CopyMergeExecutionReport) {
        running = false; progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 1
        let completed = report.items.filter { $0.state == "completed" }.count
        let conflicts = report.items.filter { $0.state == "conflict" }.count
        label.stringValue = L("병합 종료 · 추가 \(completed) · 보존한 충돌 \(conflicts)",
                              "Merge finished · Added \(completed) · Preserved conflicts \(conflicts)")
        details.string = report.items.map { "[\($0.state)] \($0.relativePath)" + ($0.message.map { "\n  " + $0 } ?? "") }.joined(separator: "\n\n")
        if let error = report.journalError { details.string += "\n\n" + L("저널 오류: ", "Journal error: ") + error }
        cancel.title = L("닫기", "Close"); cancel.isEnabled = true
    }
    private func finish(_ error: Error) {
        running = false; progress.stopAnimation(nil); label.stringValue = L("병합 계획 실패", "Merge planning failed")
        details.string = error.localizedDescription; cancel.title = L("닫기", "Close"); cancel.isEnabled = true
    }
    @objc private func cancelMerge(_ sender: Any?) {
        if !running { close(); return }
        cancellation.cancel(); cancel.isEnabled = false; label.stringValue = L("안전 지점에서 취소 중…", "Cancelling at a safe point…")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { NSSound.beep(); return false }; return true }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
}
