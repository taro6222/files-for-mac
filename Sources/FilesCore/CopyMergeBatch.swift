import Foundation
import Darwin

public struct CopyMergeBatchItem: Codable, Sendable {
    public let source: URL
    public let target: URL
    public var state: String
    public var addedCount: Int
    public var conflictCount: Int
    public var message: String?
}

public struct CopyMergeBatchReport: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public var state: String
    public var items: [CopyMergeBatchItem]
    public var journalError: String?
}

/// Coordinates a mixed multi-selection as one user operation. Missing top-level items use the
/// normal copy engine, folder/folder conflicts use recursive merge, and all created results share
/// one undo record.
public enum CopyMergeBatch {
    public static func run(sources: [URL], destination: URL, journalDirectory: URL,
                           cancellation: CopyCancellation) async -> CopyMergeBatchReport {
        let id = UUID()
        var report = CopyMergeBatchReport(version: 1, id: id, state: "running", items: sources.map {
            CopyMergeBatchItem(source: $0, target: destination.appendingPathComponent($0.lastPathComponent),
                               state: "queued", addedCount: 0, conflictCount: 0, message: nil)
        })
        let journal = journalDirectory.appendingPathComponent("merge-batch-\(id.uuidString).json")
        func save() throws {
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: journal, options: .atomic)
        }
        do { try save() } catch {
            report.state = "failed"; report.journalError = error.localizedDescription; return report
        }
        var undoItems: [CopyUndoItem] = []
        for index in sources.indices {
            if cancellation.isCancelled { report.items[index].state = "cancelled"; continue }
            let source = sources[index]
            let target = report.items[index].target
            do {
                let sourceKind = try kind(source)
                let targetKind = try optionalKind(target)
                if targetKind == nil {
                    let child = await CopyEngine.run(sources: [source], destination: destination,
                        journalDirectory: journalDirectory, cancellation: cancellation,
                        conflictPolicy: .skip, recordUndo: false)
                    guard let item = child.items.first else { throw BatchFailure(text: "Copy returned no result.") }
                    report.items[index].state = item.state
                    report.items[index].addedCount = item.state == "completed" ? 1 : 0
                    report.items[index].message = item.message
                    if item.state == "completed", let identity = item.targetIdentity, let snapshot = item.targetSnapshot {
                        undoItems.append(CopyUndoItem(target: item.target, targetIdentity: identity, targetSnapshot: snapshot))
                    }
                } else if sourceKind == .directory && targetKind == .directory {
                    let plan = try CopyMergePlanner.plan(source: source, target: target)
                    let child = await CopyMergeExecutor.run(plan: plan, journalDirectory: journalDirectory,
                                                            cancellation: cancellation, recordUndo: false)
                    report.items[index].addedCount = child.items.filter { $0.state == "completed" }.count
                    report.items[index].conflictCount = child.items.filter { $0.state == "conflict" }.count
                    report.items[index].state = child.state == "failed" ? "failed" : "merged"
                    report.items[index].message = child.journalError
                    undoItems += child.items.compactMap { item in
                        guard item.state == "completed", let identity = item.targetIdentity,
                              let snapshot = item.targetSnapshot else { return nil }
                        return CopyUndoItem(target: item.target, targetIdentity: identity, targetSnapshot: snapshot)
                    }
                } else {
                    report.items[index].state = "conflict"
                    report.items[index].conflictCount = 1
                    report.items[index].message = "Existing file or folder type conflict was preserved."
                }
            } catch {
                report.items[index].state = cancellation.isCancelled ? "cancelled" : "failed"
                report.items[index].message = error.localizedDescription
            }
            do { try save() } catch { report.journalError = error.localizedDescription; break }
        }
        let failures = report.items.filter { $0.state == "failed" }.count
        report.state = cancellation.isCancelled ? "cancelled" : (failures == 0 ? "completed" : "partiallyCompleted")
        if !undoItems.isEmpty {
            do {
                let undo = CopyUndoRecord(operationId: id, items: undoItems, createdAt: Date())
                try JSONEncoder().encode(undo).write(
                    to: journalDirectory.appendingPathComponent("undo-copy-\(id.uuidString).json"), options: .atomic)
            } catch { report.journalError = error.localizedDescription }
        }
        try? save()
        return report
    }

    private enum EntryKind: Equatable { case directory, other }
    private static func optionalKind(_ url: URL) throws -> EntryKind? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .other }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    private static func kind(_ url: URL) throws -> EntryKind {
        guard let value = try optionalKind(url) else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
}

private struct BatchFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
