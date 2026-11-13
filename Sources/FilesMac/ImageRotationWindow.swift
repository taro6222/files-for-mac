import AppKit
import FilesCore

@MainActor
final class ImageRotationWindow: NSWindowController, NSWindowDelegate {
    private static var operations: [ImageRotationWindow] = []
    static var isRunning: Bool { operations.contains { $0.running } }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator(), details = NSTextView(), button = NSButton()
    private var task: Task<Void, Never>?, running = true, succeeded = false

    static func start(urls: [URL], direction: ImageRotationDirection, completion: @escaping @MainActor () -> Void) {
        guard !urls.isEmpty, !isRunning else { return }
        let controller = ImageRotationWindow(urls: urls); operations.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.task = Task { [weak controller] in
            guard let controller else { return }
            var completed = 0
            do {
                for (index, url) in urls.enumerated() {
                    try Task<Never, Never>.checkCancellation()
                    controller.update(index: index, total: urls.count, name: url.lastPathComponent)
                    try await Task.detached(priority: .userInitiated) { try ImageRotationEngine().rotate(url, direction: direction) }.value
                    completed += 1
                }
                guard !Task.isCancelled else { return }
                controller.finish(success: true, message: L("\(completed)개 이미지를 회전했습니다.", "Rotated \(completed) images.")); completion()
            } catch is CancellationError { controller.finish(success: false, message: L("회전을 중단했습니다. 완료된 파일은 유지됩니다.", "Rotation stopped. Completed files are preserved.")); completion() }
            catch { controller.finish(success: false, message: L("이미지를 안전하게 회전하지 못했습니다: \(error)", "The image could not be rotated safely: \(error)")); completion() }
        }
    }

    private init(urls: [URL]) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 330), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = L("이미지 회전", "Rotate Images"); panel.delegate = self; panel.center(); panel.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)])
        label.stringValue = L("이미지 메타데이터를 보존하며 회전하는 중…", "Rotating while preserving image metadata…"); stack.addArrangedSubview(label)
        progress.style = .bar; progress.minValue = 0; progress.maxValue = Double(urls.count); stack.addArrangedSubview(progress)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 12); details.string = urls.map(\.path).joined(separator: "\n"); scroll.documentView = details; stack.addArrangedSubview(scroll)
        button.title = L("중단", "Stop"); button.target = self; button.action = #selector(cancel(_:)); stack.addArrangedSubview(button)
        for view in [label, progress, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    private func update(index: Int, total: Int, name: String) { progress.doubleValue = Double(index); label.stringValue = "\(index + 1)/\(total) · \(name)" }
    private func finish(success: Bool, message: String) { running = false; succeeded = success; progress.doubleValue = success ? progress.maxValue : progress.doubleValue; label.stringValue = message; button.title = L("닫기", "Close"); button.isEnabled = true }
    @objc private func cancel(_ sender: Any?) { if running { task?.cancel(); button.isEnabled = false; label.stringValue = L("중단 요청됨 — 현재 파일의 원자 교체가 끝난 뒤 멈춥니다.", "Stop requested — rotation will stop after the current atomic replacement.") } else { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { NSSound.beep(); return false }; return true }
    func windowWillClose(_ notification: Notification) { Self.operations.removeAll { $0 === self } }
#if DEBUG
    static var qaLatest: ImageRotationWindow? { operations.last }
    var qaRunning: Bool { running }
    var qaSucceeded: Bool { succeeded }
#endif
}
