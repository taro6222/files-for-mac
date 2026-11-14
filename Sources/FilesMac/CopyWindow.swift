import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

@MainActor
final class CopyWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [CopyWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private var running = true
    private let cancellation = CopyCancellation()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let details = NSTextView()
    private let cancel = NSButton(title: L("취소", "Cancel"), target: nil, action: #selector(cancelCopy(_:)))
    private let retry = NSButton(title: L("실패 항목 다시 시도", "Retry Failed Items"), target: nil,
                                 action: #selector(retryFailedItems(_:)))
    private var retryAction: (() -> Void)?

    static func start(sources: [URL], destination: URL, conflictPolicy: CopyConflictPolicy = .skip,
                      expectedDestination: ShelfEntry? = nil,
                      journalDirectory: URL, completion: @escaping @MainActor () -> Void) {
        guard !isRunning, !MoveWindow.isRunning, !FolderMergeWindow.isRunning,
              !BrowserWindow.entryOperationRunning else { return }
        let destinationIdentity = expectedDestination ?? ShelfEntry(destination.resolvingSymlinksInPath())
        let controller = CopyWindow(sources: sources, destination: destination, conflictPolicy: conflictPolicy)
        operations.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        Task { [controller] in
            let report = await CopyEngine.run(sources: sources, destination: destination, journalDirectory: journalDirectory,
                                              cancellation: controller.cancellation, conflictPolicy: conflictPolicy,
                                              expectedDestination: destinationIdentity) { [weak controller] update in
                Task { @MainActor in controller?.update(update) }
            }
            controller.finish(report)
            let retrySources = report.items.filter { $0.state == "failed" && $0.temporary == nil }.map(\.source)
            if report.journalError == nil, let destinationIdentity, !retrySources.isEmpty {
                controller.retryAction = {
                    start(sources: retrySources, destination: destinationIdentity.url,
                          expectedDestination: destinationIdentity, journalDirectory: journalDirectory, completion: completion)
                }
                controller.retry.isHidden = false
            }
            completion()
        }
    }

    private init(sources: [URL], destination: URL, conflictPolicy: CopyConflictPolicy) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("파일 복사", "Copy Files")
        window.delegate = self; window.center(); window.minSize = NSSize(width: 540, height: 320)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let target = NSTextField(wrappingLabelWithString: L("대상: ", "Destination: ") + destination.path)
        target.isSelectable = true; stack.addArrangedSubview(target)
        label.stringValue = L("복사 준비 중…", "Preparing copy…"); stack.addArrangedSubview(label)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = Double(sources.count)
        progress.style = .bar; stack.addArrangedSubview(progress)
        progress.setAccessibilityLabel(L("복사 진행률", "Copy progress"))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12)
        details.setAccessibilityLabel(L("복사 상세 결과", "Copy details"))
        details.autoresizingMask = [.width]; details.textContainer?.widthTracksTextView = true
        details.string = (conflictPolicy == .keepBoth ? L("같은 이름은 번호를 붙여 양쪽을 유지합니다.\n", "Conflicting names receive a number; both items are kept.\n") : "") + L("완료된 복사는 취소해도 유지됩니다.\n\n", "Completed copies remain when cancelled.\n\n") + sources.map(\.path).joined(separator: "\n")
        scroll.documentView = details; stack.addArrangedSubview(scroll)
        cancel.target = self; cancel.keyEquivalent = "\u{1b}"; stack.addArrangedSubview(cancel)
        retry.target = self; retry.isHidden = true; stack.addArrangedSubview(retry)
        for view in [target, label, progress, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update(_ update: CopyProgress) {
        guard running, !cancellation.isCancelled else { return }
        let phase: String
        switch update.phase {
        case "planning": phase = L("원본 확인", "Checking source")
        case "copying": phase = L("복사", "Copying")
        case "verifying": phase = L("내용 검증", "Verifying contents")
        default: phase = L("결과 확정", "Committing")
        }
        label.stringValue = "\(update.index + 1)/\(update.total) · \(phase) · \(update.name)"
        progress.doubleValue = Double(update.index)
    }
    @objc private func cancelCopy(_ sender: Any?) {
        if !running { close(); return }
        cancellation.cancel(); cancel.isEnabled = false
        label.stringValue = L("취소 요청됨 — 현재 파일의 복사 호출이 끝나면 임시 출력을 정리합니다.", "Cancellation requested — cleaning up after the current file copy returns.")
        announceStatus()
    }
    @objc private func retryFailedItems(_ sender: Any?) {
        guard let retryAction, !Self.isRunning, !MoveWindow.isRunning, !FolderMergeWindow.isRunning,
              !BrowserWindow.entryOperationRunning else { NSSound.beep(); return }
        self.retryAction = nil
        retry.isHidden = true
        retryAction()
    }
    private func finish(_ report: CopyReport) {
        running = false
        let count = report.items.filter { $0.state == "completed" }.count
        let conflicts = report.items.filter { $0.state == "conflict" }.count
        let failed = report.items.filter { $0.state == "failed" }.count
        let pending = report.items.filter { $0.state == "queued" }.count
        label.stringValue = (report.state == "cancelled" ? L("취소됨", "Cancelled") : L("작업 종료", "Finished")) +
            L(" · 완료 \(count)/\(report.items.count) · 충돌 \(conflicts)", " · Copied \(count)/\(report.items.count) · Conflicts \(conflicts)")
        if failed > 0 { label.stringValue += L(" · 실패 \(failed)", " · Failed \(failed)") }
        if pending > 0 { label.stringValue += L(" · 실행 안 됨 \(pending)", " · Not attempted \(pending)") }
        progress.isHidden = true
        details.string = report.items.map { item in
            let state: String
            switch item.state {
            case "completed": state = L("완료", "Copied")
            case "conflict": state = L("충돌: 건너뜀", "Conflict: skipped")
            case "cancelled": state = L("취소됨", "Cancelled")
            case "queued": state = L("실행 안 됨", "Not attempted")
            default: state = L("실패", "Failed")
            }
            return "[\(state)] \(item.source.path) → \(item.target.path)" +
                (item.message.map { "\n  " + $0 } ?? "") +
                (item.temporary.map { "\n  " + L("남은 임시 경로: ", "Remaining temporary path: ") + $0.path } ?? "")
        }.joined(separator: "\n\n")
        if let error = report.journalError { details.string += "\n\n" + L("저널 저장 오류: ", "Journal error: ") + error }
        cancel.title = L("닫기", "Close"); cancel.isEnabled = true
        window?.defaultButtonCell = cancel.cell as? NSButtonCell
        announceStatus()
    }
    private func announceStatus() {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: label.stringValue,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
#if DEBUG
    @MainActor
    private final class CancellationSample {
        var clickTime: ContinuousClock.Instant?
        var feedbackTime: Duration?
    }

    static func qaCancellationDuringVerification(source: URL, destination: URL,
                                                 journals: URL) async throws -> [String: [Double]] {
        let fm = FileManager.default
        let output = destination.appendingPathComponent(source.lastPathComponent)
        let original = try Data(contentsOf: source)
        let initialNames = try Set(fm.contentsOfDirectory(atPath: destination.path))
        var feedback: [Double] = []
        var settlement: [Double] = []
        for _ in 0..<10 {
            let controller = CopyWindow(sources: [source], destination: destination, conflictPolicy: .skip)
            controller.showWindow(nil)
            defer { controller.close() }
            let gate = DispatchSemaphore(value: 0)
            let clock = ContinuousClock()
            let sample = CancellationSample()
            let report = await CopyEngine.run(sources: [source], destination: destination,
                journalDirectory: journals, cancellation: controller.cancellation) { update in
                guard update.phase == "verifying" else { return }
                // Place the click after staging, before the engine can publish the output.
                Task { @MainActor in
                    defer { gate.signal() }
                    controller.update(update)
                    let started = clock.now
                    controller.cancel.performClick(nil)
                    sample.clickTime = started
                    if controller.cancellation.isCancelled && !controller.cancel.isEnabled
                        && controller.label.stringValue.hasPrefix(L("취소 요청됨", "Cancellation requested")) {
                        sample.feedbackTime = started.duration(to: clock.now)
                    }
                }
                _ = gate.wait(timeout: .now() + 5)
            }
            let finished = clock.now
            controller.finish(report)
            guard let clickTime = sample.clickTime, let feedbackTime = sample.feedbackTime, report.state == "cancelled",
                  report.items.map(\.state) == ["cancelled"], report.journalError == nil,
                  !fm.fileExists(atPath: output.path), try Data(contentsOf: source) == original,
                  try Set(fm.contentsOfDirectory(atPath: destination.path)) == initialNames else {
                throw CocoaError(.fileWriteUnknown)
            }
            func seconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            }
            feedback.append(seconds(feedbackTime))
            settlement.append(seconds(clickTime.duration(to: finished)))
        }
        return ["feedbackSeconds": feedback, "settlementSeconds": settlement]
    }

    static func qaCancellationFeedback(sources: [URL], destination: URL) -> [Double]? {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<20 {
            let controller = CopyWindow(sources: sources, destination: destination, conflictPolicy: .skip)
            guard let window = controller.window else { return nil }
            controller.showWindow(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let start = clock.now
            controller.cancel.performClick(nil)
            let elapsed = start.duration(to: clock.now).components
            guard controller.cancellation.isCancelled, !controller.cancel.isEnabled,
                  controller.label.stringValue.hasPrefix(L("취소 요청됨", "Cancellation requested")) else {
                controller.close()
                return nil
            }
            samples.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            controller.close()
        }
        return samples
    }

    var qaAccessibleResult: Bool {
        !running && progress.accessibilityLabel() == L("복사 진행률", "Copy progress")
            && details.accessibilityLabel() == L("복사 상세 결과", "Copy details")
            && label.stringValue.contains(L("충돌 1", "Conflicts 1"))
            && window?.defaultButtonCell === cancel.cell
    }
    var qaMixedResult: Bool {
        !running && progress.isHidden
            && label.stringValue.contains(L("완료 1/2", "Copied 1/2"))
            && label.stringValue.contains(L("실패 1", "Failed 1"))
    }
    var qaCanRetry: Bool { !retry.isHidden }
    func qaRetry() { retry.performClick(nil) }
#endif
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if running { NSSound.beep(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
}
