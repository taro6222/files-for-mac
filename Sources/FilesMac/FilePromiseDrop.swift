import AppKit

/// Inspect types during hover; instantiate receivers only after the drop is accepted.
@MainActor
enum FilePromiseDrop {
    static var types: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }
    static func isExternalPromise(_ info: any NSDraggingInfo) -> Bool {
        info.draggingSource == nil && info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }
    static func receivers(_ info: any NSDraggingInfo) -> [NSFilePromiseReceiver] {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }
}
