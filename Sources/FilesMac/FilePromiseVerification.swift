#if DEBUG
import AppKit
import FilesCore
import UniformTypeIdentifiers

// AppKit explicitly invokes this delegate method on its operation queue. The request
// holds the provider and delegate unchanged until their completion handler returns.
private final class PromiseWriteRequest: @unchecked Sendable {
    let provider: NSFilePromiseProvider
    let writer: any NSFilePromiseProviderDelegate
    let target: URL
    let completion: @Sendable (String?, Int?) -> Void
    init(provider: NSFilePromiseProvider, writer: any NSFilePromiseProviderDelegate, target: URL,
         completion: @escaping @Sendable (String?, Int?) -> Void) {
        self.provider = provider; self.writer = writer; self.target = target; self.completion = completion
    }
    func execute() {
        writer.filePromiseProvider(provider, writePromiseTo: target) { error in
            let cocoa = error.map { $0 as NSError }
            self.completion(cocoa?.localizedDescription, cocoa?.code)
        }
    }
}

@MainActor
private final class PromiseSourceView: NSView, NSDraggingSource {
    var provider: FileDragPromise?
    private(set) var started = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        ("Drag promised file" as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: [.foregroundColor: NSColor.labelColor])
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard !started, let provider else { return }
        started = true
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

@MainActor
private final class PromiseDestinationView: NSView {
    var onPromise: ((NSFilePromiseReceiver) -> Void)?
    private(set) var accepted = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill(); bounds.fill()
        ("Receive file promise" as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: [.foregroundColor: NSColor.selectedTextColor])
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let receiver = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)?.first as? NSFilePromiseReceiver else { return false }
        accepted = true
        onPromise?(receiver)
        return true
    }
}

@MainActor
enum FilePromiseVerification {
    static func run(output: String) async {
        if let theme = ProcessInfo.processInfo.environment["FILES_PROMISE_QA_THEME"] {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: output, isDirectory: true)
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("source", isDirectory: true)
            let target = root.appendingPathComponent("target", isDirectory: true)
            for directory in [source, target] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            let file = source.appendingPathComponent("한글 promised file.txt")
            let bytes = Data("promised file contents".utf8)
            try bytes.write(to: file)
            try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            guard let item = try await LocalFileSystem().contents(of: source, showHidden: true).first(where: { $0.url == file }) else {
                throw CocoaError(.fileReadUnknown)
            }
            guard let provider = FileDragPromise(item: item) else { throw CocoaError(.fileReadUnknown) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            checks["writesPasteboard"] = pasteboard.writeObjects([provider])
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            checks["preservesFileURLRepresentation"] = urls == [file]
            checks["promiseIsLazy"] = try fm.contentsOfDirectory(atPath: target.path).isEmpty
            checks["offersPromiseTypes"] = provider.writableTypes(for: pasteboard).contains {
                NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue)
            }
            let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
            checks["readsOnePromiseReceiver"] = receivers.count == 1
            let contractOnly = ProcessInfo.processInfo.environment["FILES_PROMISE_QA_MODE"] == "contract"
            if contractOnly {
                guard let writer = provider.delegate else { throw CocoaError(.coderInvalidValue) }
                checks["delegateNamesOriginalFile"] = writer.filePromiseProvider(provider, fileNameForType: provider.fileType) == file.lastPathComponent
                let queue = writer.operationQueue?(for: provider) ?? .main
                checks["usesBackgroundPromiseQueue"] = queue !== OperationQueue.main
                let unknown = FileDragPromise(item: FileItem(url: file, name: file.lastPathComponent, isDirectory: false))
                checks["unknownIdentityKeepsOnlyFileURL"] = unknown?.writableTypes(for: pasteboard) == [.fileURL]
                func deliver(_ provider: FileDragPromise, to destination: URL) async -> (String?, Int?) {
                    guard let writer = provider.delegate else { return ("No delegate", nil) }
                    let queue = writer.operationQueue?(for: provider) ?? .main
                    return await withCheckedContinuation { continuation in
                        let request = PromiseWriteRequest(provider: provider, writer: writer, target: destination) {
                            continuation.resume(returning: ($0, $1))
                        }
                        queue.addOperation { request.execute() }
                    }
                }
                let received = target.appendingPathComponent("Receiver chosen.txt")
                let first = await deliver(provider, to: received)
                checks["delegateCompletesWithoutError"] = first.0 == nil
                checks["delegateUsesReceiversName"] = (try? Data(contentsOf: received)) == bytes
                checks["delegatePreservesMode"] = (try? fm.attributesOfItem(atPath: received.path)[.posixPermissions] as? Int) == 0o640
                let existing = Data("existing destination".utf8)
                try existing.write(to: received)
                let collision = await deliver(provider, to: received)
                checks["delegateReportsCollision"] = collision.1 == CocoaError.Code.fileWriteFileExists.rawValue
                checks["delegateProtectsExistingDestination"] = try Data(contentsOf: received) == existing
                let retained = source.appendingPathComponent("retained-original.txt")
                try fm.moveItem(at: file, to: retained)
                try Data("replacement source".utf8).write(to: file)
                let staleTarget = target.appendingPathComponent("stale.txt")
                let stale = await deliver(provider, to: staleTarget)
                checks["delegateRejectsChangedSource"] = stale.0 != nil && !fm.fileExists(atPath: staleTarget.path)
                checks["delegatePreservesBothSourceVersions"] = try Data(contentsOf: retained) == bytes
                    && Data(contentsOf: file) == Data("replacement source".utf8)
                let folder = source.appendingPathComponent("folder", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try bytes.write(to: folder.appendingPathComponent("nested.txt"))
                try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "nested.txt")
                guard let directoryItem = try await LocalFileSystem().contents(of: source, showHidden: true).first(where: { $0.url == folder }),
                      let directoryProvider = FileDragPromise(item: directoryItem) else { throw CocoaError(.fileReadUnknown) }
                checks["offersDirectoryType"] = UTType(directoryProvider.fileType)?.conforms(to: .directory) == true
                let directoryTarget = target.appendingPathComponent("Receiver Folder", isDirectory: true)
                let directory = await deliver(directoryProvider, to: directoryTarget)
                checks["delegateExportsDirectory"] = directory.0 == nil
                    && (try? Data(contentsOf: directoryTarget.appendingPathComponent("nested.txt"))) == bytes
                checks["delegatePreservesSymbolicLink"] = (try? fm.destinationOfSymbolicLink(atPath: directoryTarget.appendingPathComponent("link").path)) == "nested.txt"
                let intake = try await Task.detached { () throws -> PromisedFileIntake in
                    let intake = try PromisedFileIntake(storageDirectory: root.appendingPathComponent("intake-contract"))
                    let url = intake.receivingDirectory.appendingPathComponent("received.txt")
                    try bytes.write(to: url)
                    try intake.registerReceivedFile(url)
                    return intake
                }.value
                checks.merge(await FilePromiseReceiveWindow.verifyHandoff(intakes: [intake], destination: target)) { _, new in new }
                let recoveryStorage = intake.directoryURL.deletingLastPathComponent()
                try await Task.detached {
                    try FileManager.default.createDirectory(at: recoveryStorage.appendingPathComponent("promise-damaged"), withIntermediateDirectories: false)
                }.value
                checks.merge(await ReceivedFilesWindow.verifyRecovery(storage: recoveryStorage, destination: target, pendingReceiver: receivers.first)) { _, new in new }
                diagnostics["collisionError"] = collision.0 ?? ""
                diagnostics["staleSourceError"] = stale.0 ?? ""
            }
            if !contractOnly, !receivers.isEmpty {
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 300),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Files file promise verification"
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let sourceView = PromiseSourceView(frame: NSRect(x: 24, y: 60, width: 250, height: 180))
                let destinationView = PromiseDestinationView(frame: NSRect(x: 346, y: 60, width: 270, height: 180))
                sourceView.provider = FileDragPromise(item: item)
                window.contentView?.addSubview(sourceView)
                window.contentView?.addSubview(destinationView)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                func eventPoint(_ view: NSView) -> CGPoint {
                    let point = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
                    return CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
                }
                let start = eventPoint(sourceView), end = eventPoint(destinationView)
                try JSONSerialization.data(withJSONObject: ["state": "receiving", "checks": checks,
                    "processID": ProcessInfo.processInfo.processIdentifier,
                    "source": ["x": Double(start.x), "y": Double(start.y)],
                    "destination": ["x": Double(end.x), "y": Double(end.y)]], options: [.prettyPrinted])
                    .write(to: root.appendingPathComponent("progress.json"), options: .atomic)
                let queue = OperationQueue()
                let received: (URL, String?) = await withCheckedContinuation { continuation in
                    destinationView.onPromise = { receiver in
                        receiver.receivePromisedFiles(atDestination: target, options: [:], operationQueue: queue) { url, error in
                            continuation.resume(returning: (url, error?.localizedDescription))
                        }
                    }
                }
                withExtendedLifetime(provider) {}
                diagnostics["appActive"] = NSApp.isActive
                diagnostics["keyWindow"] = window.isKeyWindow
                checks["realDraggingSession"] = sourceView.started && destinationView.accepted
                diagnostics["receivedURL"] = received.0.path
                diagnostics["receiveError"] = received.1 ?? ""
                checks["receiverCompletesWithoutError"] = received.1 == nil
                checks["receiverWritesExpectedName"] = received.0 == target.appendingPathComponent(file.lastPathComponent)
                checks["receiverWritesExpectedBytes"] = (try? Data(contentsOf: received.0)) == bytes
                checks["receiverPreservesMode"] = (try? fm.attributesOfItem(atPath: received.0.path)[.posixPermissions] as? Int) == 0o640
            }
            if !contractOnly { checks["sourceRemainsUnchanged"] = try Data(contentsOf: file) == bytes }
            let report: [String: Any] = ["checks": checks, "diagnostics": diagnostics,
                                       "mode": contractOnly ? "delegate-contract" : "actual-drag",
                                       "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "language": Locale.preferredLanguages.first ?? "unknown",
            "theme": NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("report.json"), options: .atomic)
            DispatchQueue.main.async { exit(checks.values.allSatisfy { $0 } ? 0 : 1) }
        } catch {
            fputs("File promise verification failed: \(error)\n", stderr)
            let report: [String: Any] = ["checks": checks, "diagnostics": diagnostics, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("report.json"), options: .atomic)
            DispatchQueue.main.async { exit(1) }
        }
    }
}
#endif
