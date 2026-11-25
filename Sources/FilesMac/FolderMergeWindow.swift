import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class FolderMergeWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [FolderMergeWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    static var activities: [FileOperationActivity] { operations.map(\.activity) }
    let operationID = UUID()
    private var latestIndex = -1
    private var latestAction = -1
    private var latestPhase = -1
    private var latestBytes: Int64?
    private let destinationPath: String
    private var running = true
    private let cancellation = CopyCancellation()
    private let label = NSTextField(wrappingLabelWithString: L("병합 계획 준비 중…", "Preparing merge plan…"))
    private let progress = NSProgressIndicator()
    private let details = NSTextView()
    private let cancel = NSButton(title: L("취소", "Cancel"), target: nil, action: #selector(cancelMerge(_:)))

    static func start(sources: [URL], destination: URL, sourceIntakes: [PromisedFileIntake] = [],
                      completion: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        let controller = FolderMergeWindow(sources: sources, destination: destination)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        FileOperationCenter.activityChanged()
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("operations")
        Task { [controller] in
            let report = await CopyMergeBatch.run(sources: sources, destination: destination,
                                                  journalDirectory: journals,
                                                  cancellation: controller.cancellation, sourceIntakes: sourceIntakes) { [weak controller] update in
                Task { @MainActor in controller?.update(update) }
            }
            controller.finish(report)
            completion()
        }
    }

    private init(sources: [URL], destination: URL) {
        destinationPath = destination.path
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
        guard running, !cancellation.isCancelled else { return }
        let rank = ["sizing": -1, "planning": 0, "copying": 1, "verifying": 2, "committing": 3][update.state] ?? 4
        guard update.index >= latestIndex else { return }
        if update.index == latestIndex {
            guard update.actionIndex >= latestAction else { return }
            if update.actionIndex == latestAction {
                guard rank >= latestPhase else { return }
                if rank == 1, let latestBytes {
                    guard let live = update.liveTransfer, live.bytes >= latestBytes else { return }
                }
            } else { latestBytes = nil }
        } else { latestBytes = nil }
        latestIndex = update.index; latestAction = update.actionIndex; latestPhase = rank
        if let live = update.liveTransfer { latestBytes = live.bytes }
        progress.doubleValue = Double(update.index) + (rank == 4 && update.actionIndex == Int.max ? 1 : 0)
        progress.showCurrentFileActivity(rank == -1 || rank == 1 || rank == 2)
        let phase: String
        switch update.state {
        case "sizing": phase = L("전체 데이터 확인", "Checking selected data")
        case "planning": phase = L("원본 확인", "Checking source")
        case "copying": phase = L("복사", "Copying")
        case "verifying": phase = L("내용 검증", "Verifying contents")
        case "committing": phase = L("결과 확정", "Committing")
        case "completed", "merged", "verified": phase = L("완료", "Completed")
        case "conflict": phase = L("충돌 보존", "Conflict preserved")
        case "cancelled": phase = L("취소됨", "Cancelled")
        default: phase = L("실패", "Failed")
        }
        label.stringValue = "\(update.index + 1)/\(update.total) · \(phase) · \(update.source.lastPathComponent)"
        if let path = update.relativePath { label.stringValue += " · \(path)" }
        if let live = update.liveTransfer { label.stringValue += liveTransferDescription(live) }
        FileOperationCenter.activityChanged()
    }

    private func finish(_ report: CopyMergeBatchReport) {
        running = false; progress.showCurrentFileActivity(false); progress.doubleValue = progress.maxValue
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
        FileOperationCenter.activityChanged()
    }
    @objc private func cancelMerge(_ sender: Any?) {
        if !running { close(); return }
        cancellation.cancel(); cancel.isEnabled = false; label.stringValue = L("안전 지점에서 취소 중…", "Cancelling at a safe point…")
        FileOperationCenter.activityChanged()
    }
    private var activity: FileOperationActivity {
        fileOperationActivity(id: operationID, destination: destinationPath, status: label.stringValue,
                              progress: progress, running: running,
                              cancel: running && cancel.isEnabled ? { [weak self] in self?.cancelMerge(nil) } : nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { NSSound.beep(); return false }; return true }
    func windowWillClose(_ notification: Notification) {
        Self.operations.removeAll { $0 === self }
        FileOperationCenter.retainResult(activity)
        FileOperationCenter.activityChanged()
    }
#if DEBUG
    /// Replays real engine callbacks through the actual view, independently of MainActor scheduling.
    static func qaVerifyProgress(_ events: [CopyMergeBatchProgress], sources: [URL], destination: URL,
                                 captures: URL) -> Bool {
        let controller = FolderMergeWindow(sources: sources, destination: destination)
        controller.showWindow(nil)
        defer { controller.close() }
        guard let liveEvent = events.first(where: { $0.relativePath != nil && ($0.liveTransfer?.bytes ?? 0) > 0 }),
              let live = liveEvent.liveTransfer,
              let verifying = events.first(where: { $0.index == liveEvent.index && $0.actionIndex == liveEvent.actionIndex && $0.state == "verifying" }),
              let earlier = events.first(where: { $0.index == liveEvent.index && $0.actionIndex == liveEvent.actionIndex && $0.liveTransfer?.bytes == 0 }),
              let later = events.last else { return false }
        controller.update(liveEvent)
        guard controller.label.stringValue.contains(liveTransferDescription(live)), controller.progress.isIndeterminate else { return false }
        let text = controller.label.stringValue
        controller.update(earlier)
        guard controller.label.stringValue == text else { return false }
        if let content = controller.window?.contentView {
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                    context.setBlendMode(.destinationOver)
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]),
                  (try? png.write(to: captures.appendingPathComponent("merge-live-data.png"))) != nil else { return false }
        } else { return false }
        controller.update(verifying)
        let verificationText = controller.label.stringValue
        controller.update(liveEvent)
        guard controller.label.stringValue == verificationText, controller.progress.isIndeterminate else { return false }
        controller.update(later)
        let terminalText = controller.label.stringValue
        controller.update(liveEvent)
        guard controller.label.stringValue == terminalText, !controller.progress.isIndeterminate else { return false }
        controller.cancelMerge(nil)
        controller.update(liveEvent)
        return controller.label.stringValue.contains(L("취소", "Cancelling")) && !controller.cancel.isEnabled
    }
#endif

}

#if DEBUG
final class MergeProgressQARecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CopyMergeBatchProgress] = []
    func append(_ event: CopyMergeBatchProgress) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    var values: [CopyMergeBatchProgress] { lock.lock(); defer { lock.unlock() }; return events }
}
#endif
