import AppKit
import FilesCore

@MainActor
final class ArchiveCreationWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [ArchiveCreationWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let details = NSTextView()
    private let cancelButton = NSButton()
    private var task: Task<Void, Never>?
    private var running = true
    private var succeeded = false

    static func start(sources: [URL], destination: URL, completion: @escaping @MainActor () -> Void) {
        guard !sources.isEmpty, !isRunning else { return }
        let controller = ArchiveCreationWindow(sources: sources, destination: destination)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.task = Task { [weak controller] in
            do {
                _ = try await ZipArchiveProvider().create(from: sources, at: destination) { [weak controller] update in
                    Task { @MainActor [weak controller] in controller?.update(update) }
                }
                guard let controller, !Task.isCancelled else { return }
                controller.finish(success: true, message: L("ZIP 생성을 완료했습니다.", "ZIP archive created.")); completion()
            } catch is CancellationError {
                controller?.finish(success: false, message: L("생성을 중단했습니다.", "Creation stopped."))
            } catch {
                controller?.finish(success: false, message: archiveErrorMessage(error))
            }
        }
    }

    private init(sources: [URL], destination: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("ZIP 생성", "Create ZIP Archive"); panel.delegate = self; panel.center(); panel.minSize = NSSize(width: 500, height: 300)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)])
        let target = NSTextField(wrappingLabelWithString: L("대상: ", "Destination: ") + destination.path); target.isSelectable = true; stack.addArrangedSubview(target)
        label.stringValue = L("원본을 검증하고 ZIP을 생성하는 중…", "Validating sources and creating ZIP…"); stack.addArrangedSubview(label)
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil); stack.addArrangedSubview(progress)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12); details.string = sources.map(\.path).joined(separator: "\n"); scroll.documentView = details; stack.addArrangedSubview(scroll)
        cancelButton.title = L("중단", "Stop"); cancelButton.bezelStyle = .rounded; cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); stack.addArrangedSubview(cancelButton)
        for view in [target, label, progress, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }

    @objc private func cancel(_ sender: Any?) {
        if !running { close(); return }
        task?.cancel(); cancelButton.isEnabled = false; label.stringValue = L("중단 요청됨 — 안전한 지점에서 임시 파일을 정리합니다.", "Stop requested — temporary output will be cleaned at a safe point.")
    }
    private func update(_ update: ArchiveProgress) {
        guard running else { return }
        progress.isIndeterminate = update.totalBytes == 0 && update.totalEntries == 0
        let byteFraction = update.totalBytes > 0 ? Double(update.completedBytes) / Double(update.totalBytes) : 0
        let entryFraction = update.totalEntries > 0 ? Double(update.completedEntries) / Double(update.totalEntries) : 0
        progress.doubleValue = max(byteFraction, entryFraction)
        let phase = update.phase == .publishing ? L("결과 확정", "Publishing") : L("ZIP 생성", "Creating ZIP")
        label.stringValue = "\(phase) · \(update.completedEntries)/\(update.totalEntries) · \(ByteCountFormatter.string(fromByteCount: update.completedBytes, countStyle: .file))" + (update.currentPath.map { " · \($0)" } ?? "")
    }
    private func finish(success: Bool, message: String) {
        running = false; succeeded = success; progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = success ? 1 : 0; label.stringValue = message; cancelButton.title = L("닫기", "Close"); cancelButton.isEnabled = true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { NSSound.beep(); return false }; return true }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
#if DEBUG
    static var qaLatest: ArchiveCreationWindow? { operations.last }
    var qaRunning: Bool { running }
    var qaSucceeded: Bool { succeeded }
#endif
}
