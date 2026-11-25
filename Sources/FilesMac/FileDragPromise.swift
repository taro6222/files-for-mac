import AppKit
import FilesCore
import UniformTypeIdentifiers

/// A file URL for ordinary Finder/pane drops, plus deferred delivery for promise-aware clients.
final class FileDragPromise: NSFilePromiseProvider {
    private let writer: FileDragPromiseWriter

    init?(item: FileItem) {
        guard item.url.isFileURL else { return nil }
        writer = FileDragPromiseWriter(source: item)
        super.init()
        let fallback = item.isDirectory ? UTType.directory : UTType.data
        if let inferred = UTType(filenameExtension: item.url.pathExtension), inferred.conforms(to: fallback) {
            fileType = inferred.identifier
        } else {
            fileType = fallback.identifier
        }
        delegate = writer // NSFilePromiseProvider holds its delegate weakly.
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        guard writer.source.identity != nil else { return [.fileURL] }
        let types = super.writableTypes(for: pasteboard)
        return types.contains(.fileURL) ? types : [.fileURL] + types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .fileURL ? writer.source.url.absoluteString : super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .fileURL ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

private final class FileDragPromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    let source: FileItem
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FilesMac.FilePromiseExport"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(source: FileItem) { self.source = source }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        source.url.lastPathComponent
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("files-promise-\(UUID())", isDirectory: true)
        var preserveJournal = false
        var writeError: (any Error)?
        do {
            let report = try CopyEngine.exportPromisedItem(source, to: url, journalDirectory: journal)
            preserveJournal = report.journalError != nil || report.items.contains { $0.temporary != nil }
            guard report.state == "completed", report.items.first?.state == "completed", report.journalError == nil else {
                let item = report.items.first
                let code: CocoaError.Code = item?.state == "conflict" ? .fileWriteFileExists : .fileWriteUnknown
                throw NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: [
                    NSLocalizedDescriptionKey: [item?.message ?? item?.state ?? report.state, report.journalError,
                                               item?.temporary?.path, preserveJournal ? journal.path : nil]
                        .compactMap { $0 }.joined(separator: "\n"),
                    NSFilePathErrorKey: url.path
                ])
            }
        } catch {
            writeError = error
        }
        if !preserveJournal { try? FileManager.default.removeItem(at: journal) }
        completionHandler(writeError)
    }
}

func fileDragURL(from writer: (any NSPasteboardWriting)?) -> URL? {
    guard let value = writer?.pasteboardPropertyList(forType: .fileURL) as? String,
          let url = URL(string: value), url.isFileURL else { return nil }
    return url
}
