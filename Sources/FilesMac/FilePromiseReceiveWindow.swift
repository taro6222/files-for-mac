import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

/// Each receiver gets a separate durable directory, so independent providers cannot overwrite
/// each other's same-name exports. SDK coordinated reads are hashed before returning.
@MainActor
final class FilePromiseReceiveWindow: NSWindowController, NSWindowDelegate {
    typealias Prepare = ([URL], [PromisedFileIntake], @escaping (Bool) -> Void) -> Void
    private static var operations: [FilePromiseReceiveWindow] = []
    static var activities: [FileOperationActivity] { operations.filter { !$0.closed }.map(\.activity) }
    private let operationID = UUID()
    private let destination: URL
    private let receivers: [NSFilePromiseReceiver]
    private var intakes: [PromisedFileIntake] = []
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    private let cancellation = CopyCancellation()
    private var callbacks: [Int: Int] = [:]
    private var failures: [String] = []
    private var closed = false
    private var paused = false
    private var preparing = false
    private var submitted: Set<URL> = []
    private let prepare: Prepare
    private let label = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton(title: L("받은 파일 복사", "Copy Received Files"), target: nil, action: #selector(copyReceived))
    private let stop = NSButton(title: L("자동 복사 중지", "Stop Automatic Copy"), target: nil, action: #selector(pauseReceiving))
    private var finished: Bool {
        receivers.indices.allSatisfy { index in
            let count = receivers[index].fileNames.count
            return count > 0 && callbacks[index, default: 0] >= count
        }
    }

    @discardableResult
    static func start(receivers: [NSFilePromiseReceiver], destination: URL, prepare: @escaping Prepare) -> Bool {
        guard !receivers.isEmpty else { return false }
        let controller = FilePromiseReceiveWindow(receivers: receivers, destination: destination, prepare: prepare)
        operations.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.begin()
        return true
    }
    private init(receivers: [NSFilePromiseReceiver], destination: URL, prepare: @escaping Prepare) {
        self.receivers = receivers; self.destination = destination; self.prepare = prepare
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 270),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("다른 앱의 파일 받기", "Receive Files from Another App")
        window.delegate = self; window.center(); window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        let target = NSTextField(wrappingLabelWithString: L("대상: ", "Destination: ") + destination.path)
        target.isSelectable = true; details.isSelectable = true
        copy.target = self; stop.target = self
        let reveal = NSButton(title: L("보관된 파일 보기", "Show Retained Files"), target: self, action: #selector(revealFiles))
        let buttons = NSStackView(views: [copy, stop, reveal]); buttons.spacing = 8
        for view in [target, label, details, buttons] { stack.addArrangedSubview(view) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func begin() {
        let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac")
            .appendingPathComponent("received-files", isDirectory: true)
        let count = receivers.count
        Task { [self] in
            do {
                intakes = try await Task.detached { try (0..<count).map { _ in try PromisedFileIntake(storageDirectory: storage) } }.value
                for index in receivers.indices {
                    let intake = intakes[index], cancellation = cancellation
                    receivers[index].receivePromisedFiles(atDestination: intake.receivingDirectory, options: [:], operationQueue: queue) { [weak self] url, error in
                        let failure: String?
                        if let error { failure = error.localizedDescription }
                        else {
                            do { try intake.registerReceivedFile(url, cancellation: cancellation); failure = nil }
                            catch { failure = error.localizedDescription }
                        }
                        Task { @MainActor [weak self] in self?.received(index: index, failure: failure) }
                    }
                }
                update()
            } catch { failures.append(error.localizedDescription); paused = true; update() }
        }
    }
    private func received(index: Int, failure: String?) {
        callbacks[index, default: 0] += 1
        if let failure { failures.append(failure) }
        update()
        if closed, finished { Self.operations.removeAll { $0 === self }; FileOperationCenter.activityChanged(); return }
        if finished, failures.isEmpty, !paused, !preparing { copyReceived() }
    }
    @objc private func copyReceived() {
        guard !preparing, intakes.contains(where: { $0.itemCount > 0 }) else { return }
        preparing = true; update()
        let intakes = intakes, cancellation = CopyCancellation()
        Task { [self] in
            do {
                let all = try await Task.detached { try intakes.flatMap { try $0.verifiedSources(cancellation: cancellation) } }.value
                let sources = all.filter { !submitted.contains($0) }
                guard !sources.isEmpty else { preparing = false; update(); return }
                prepare(sources, intakes) { [weak self] accepted in
                    guard let self else { return }
                    if accepted { self.submitted.formUnion(sources) }
                    self.preparing = false; self.paused = true; self.update()
                }
            } catch { preparing = false; paused = true; failures.append(error.localizedDescription); update() }
        }
    }
    @objc private func pauseReceiving() { paused = true; cancellation.cancel(); update() }
    @objc private func revealFiles() {
        NSWorkspace.shared.activateFileViewerSelecting(intakes.map(\.receivingDirectory))
    }
    private func update() {
        let count = intakes.reduce(0) { $0 + $1.itemCount }
        let state = preparing ? L("복사 준비 중", "Preparing copy") : paused ? L("자동 복사 중지됨", "Automatic copy stopped") : finished ? L("수신 완료", "Reception complete") : L("수신 중", "Receiving")
        label.stringValue = state + " · " + L("검증된 수신 파일 \(count)개 · 오류 \(failures.count)개", "\(count) verified received files · \(failures.count) errors")
        details.stringValue = failures.last ?? L("수신 파일은 보관됩니다. 복사 취소·실패 후에도 보관된 파일에서 다시 시도할 수 있습니다.", "Received files are retained. After cancelling or failing a copy, retry from the retained files.")
        copy.isEnabled = count > submitted.count && !preparing
        stop.isEnabled = !paused && !finished
        FileOperationCenter.activityChanged()
    }
    private var activity: FileOperationActivity {
        FileOperationActivity(id: operationID, title: window?.title ?? "", destination: destination.path,
            status: label.stringValue, progress: !paused && !finished ? (callbacks.values.reduce(0, +), max(1, receivers.reduce(0) { $0 + $1.fileNames.count })) : nil,
            showDetails: { [weak self] in self?.showWindow(nil); self?.window?.makeKeyAndOrderFront(nil) },
            cancel: !paused && !finished ? { [weak self] in self?.pauseReceiving() } : nil)
    }
#if DEBUG
    /// Exercises the production handoff with real receipt files; does not simulate SDK delivery.
    static func verifyHandoff(intakes: [PromisedFileIntake], destination: URL) async -> [String: Bool] {
        var calls = 0
        var acceptedSources: [URL] = []
        var accept = false
        let controller = FilePromiseReceiveWindow(receivers: [], destination: destination) { sources, _, decision in
            calls += 1; acceptedSources = sources; decision(accept)
        }
        controller.intakes = intakes
        defer { controller.window?.close() }
        func settle() async {
            for _ in 0..<500 where controller.preparing { try? await Task.sleep(for: .milliseconds(10)) }
        }
        controller.copyReceived(); await settle()
        var checks = ["receivePolicyCancellationRetainsRetry": calls == 1 && controller.submitted.isEmpty && !controller.preparing]
        accept = true
        controller.copyReceived(); await settle()
        checks["receiveHandoffIncludesAllIntakes"] = calls == 2 && acceptedSources.count == intakes.reduce(0) { $0 + $1.itemCount }
        checks["receiveAcceptedBatchMarkedOnce"] = controller.submitted == Set(acceptedSources)
        controller.copyReceived(); await settle()
        checks["receiveDoesNotResubmitAcceptedBatch"] = calls == 2 && !controller.preparing
        controller.pauseReceiving()
        checks["receivePauseRetainsVerifiedFiles"] = intakes.allSatisfy { $0.itemCount > 0 } && controller.paused
        checks["receiveTypesIncludeURLAndPromises"] = FilePromiseDrop.types.contains(.fileURL)
            && NSFilePromiseReceiver.readableDraggedTypes.allSatisfy { FilePromiseDrop.types.contains(NSPasteboard.PasteboardType($0)) }
        return checks
    }
#endif
    func windowShouldClose(_ sender: NSWindow) -> Bool { paused || finished }
    func windowWillClose(_ notification: Notification) {
        FileOperationCenter.retainResult(activity)
        // SDK callbacks own the intake; closing never deletes delivered or unregistered bytes.
        closed = true
        if finished { Self.operations.removeAll { $0 === self } }
        FileOperationCenter.activityChanged()
    }
}
