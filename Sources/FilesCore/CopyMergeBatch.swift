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
    public var selectionTransfer: SelectionTransferProgress? = nil
}

public struct CopyMergeBatchProgress: Sendable {
    public let index: Int
    public let total: Int
    public let source: URL
    public let state: String
    /// Int.max marks the final source result, after every nested action callback.
    public var actionIndex: Int = 0
    public var actionTotal: Int = 1
    public var relativePath: String? = nil
    public var liveTransfer: LiveTransferProgress? = nil
    public var selectionTransfer: SelectionTransferProgress? = nil
}

/// Coordinates a mixed multi-selection as one user operation. Missing top-level items use the
/// normal copy engine, folder/folder conflicts use recursive merge, and all created results share
/// one undo record.
public enum CopyMergeBatch {
    public static func run(sources: [URL], destination: URL, journalDirectory: URL,
                           cancellation: CopyCancellation,
                           sourceIntakes: [PromisedFileIntake] = [],
                           progress: @escaping @Sendable (CopyMergeBatchProgress) -> Void = { _ in }) async -> CopyMergeBatchReport {
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
        guard let destinationEntry = ShelfEntry(destination.resolvingSymlinksInPath()),
              (try? kind(destinationEntry.url)) == .directory else {
            report.state = "failed"; report.journalError = "Merge destination unavailable."; try? save(); return report
        }
        var prepared = [PreparedSource?](repeating: nil, count: sources.count)
        var sizes = [Int64?](repeating: nil, count: sources.count)
        for index in sources.indices {
            if cancellation.isCancelled { break }
            let source = sources[index]
            progress(CopyMergeBatchProgress(index: 0, total: sources.count, source: source, state: "sizing"))
            let value = await prepareSource(source: source, target: report.items[index].target,
                destination: destination, cancellation: cancellation, sourceIntakes: sourceIntakes) { action in
                progress(CopyMergeBatchProgress(index: 0, total: sources.count, source: source,
                    state: "sizing", relativePath: action.relativePath))
            }
            prepared[index] = value
            sizes[index] = value.totalBytes
        }
        let selection = SelectionTransferTracker(plans: sizes)
        var remainingNames = Dictionary(sources.map { (nameKey($0), 1) }, uniquingKeysWith: +)
        var anchors: [DirectoryAnchor] = []
        var undoItems: [CopyUndoItem] = []
        for index in sources.indices {
            let original = prepared[index]; prepared[index] = nil
            let key = nameKey(sources[index])
            remainingNames[key, default: 1] -= 1
            let hasFuturePeer = remainingNames[key, default: 0] > 0
            defer { if !hasFuturePeer { anchors.removeAll { $0.key == key } } }
            if cancellation.isCancelled {
                report.items[index].state = "cancelled"
                continue
            }
            let source = sources[index]
            let target = report.items[index].target
            progress(CopyMergeBatchProgress(index: index, total: sources.count, source: source, state: "planning", selectionTransfer: selection.snapshot()))
            do {
                guard destinationEntry.isCurrent else { throw BatchFailure(text: "Merge destination changed after preparation.") }
                if case .failed(let error) = original { throw error }
                if !sourceIntakes.isEmpty {
                    let snapshot = try await Task.detached { try CopyEngine.makeSnapshot(source, cancellation: cancellation) }.value
                    try PromisedFileIntake.validate(source, snapshot: snapshot, in: sourceIntakes)
                }
                let sourceKind = try kind(source)
                let targetKind = try optionalKind(target)
                if targetKind == nil {
                    guard case .copy(let snapshot) = original else {
                        throw BatchFailure(text: "Merge destination topology changed after preparation.")
                    }
                    let child = await CopyEngine.runPrepared(source: source, snapshot: snapshot, destination: destination,
                        journalDirectory: journalDirectory, cancellation: cancellation,
                        expectedDestination: destinationEntry, sourceIntakes: sourceIntakes) { update in
                            progress(CopyMergeBatchProgress(index: index, total: sources.count, source: source,
                                state: update.phase, liveTransfer: update.liveTransfer,
                                selectionTransfer: aggregate(update.selectionTransfer, index: index, in: selection)))
                        }
                    _ = aggregate(child.selectionTransfer, index: index, in: selection)
                    guard let item = child.items.first else { throw BatchFailure(text: "Copy returned no result.") }
                    report.items[index].state = item.state
                    report.items[index].addedCount = item.state == "completed" ? 1 : 0
                    report.items[index].message = item.message
                    if item.state == "completed", let identity = item.targetIdentity, let snapshot = item.targetSnapshot {
                        undoItems.append(CopyUndoItem(target: item.target, targetIdentity: identity, targetSnapshot: snapshot,
                                                      targetMetadata: item.targetMetadata))
                        if sourceKind == .directory, hasFuturePeer,
                           let anchor = try? DirectoryAnchor(target: target, expected: identity, key: key) { anchors.append(anchor) }
                    }
                } else if sourceKind == .directory && targetKind == .directory {
                    let followsEarlierRoot = anchors.contains { $0.matches(target) }
                    let plan: CopyMergePlan
                    let preparedPlan: CopyMergeExecutor.Prepared
                    switch original {
                    case .merge(let initialPlan, let initialPreparation):
                        guard try CopyEngine.entryIdentity(target) == initialPlan.targetIdentity else {
                            throw BatchFailure(text: "Merge destination changed after preparation.")
                        }
                        if followsEarlierRoot {
                            let refreshed = try await Task.detached {
                                try CopyMergeExecutor.revalidate(plan: initialPlan, prepared: initialPreparation, cancellation: cancellation)
                                let plan = try CopyMergePlanner.plan(source: source, target: target, cancellation: cancellation)
                                return (plan, CopyMergeExecutor.prepare(plan: plan, cancellation: cancellation))
                            }.value
                            plan = refreshed.0; preparedPlan = refreshed.1
                        } else { plan = initialPlan; preparedPlan = initialPreparation }
                    case .copy(let snapshot) where followsEarlierRoot:
                        let refreshed = try await Task.detached {
                            guard try CopyEngine.makeSnapshot(source, cancellation: cancellation).matchesOriginal(snapshot) else {
                                throw BatchFailure(text: "Source changed after preparation.")
                            }
                            let plan = try CopyMergePlanner.plan(source: source, target: target, cancellation: cancellation)
                            return (plan, CopyMergeExecutor.prepare(plan: plan, cancellation: cancellation))
                        }.value
                        plan = refreshed.0; preparedPlan = refreshed.1
                    default: throw BatchFailure(text: "Merge destination topology changed after preparation.")
                    }
                    if !followsEarlierRoot, hasFuturePeer,
                       let anchor = try? DirectoryAnchor(target: target, expected: plan.targetIdentity, key: key) { anchors.append(anchor) }
                    if !sourceIntakes.isEmpty {
                        let snapshot = try await Task.detached { try CopyEngine.makeSnapshot(source, cancellation: cancellation) }.value
                        try PromisedFileIntake.validate(source, snapshot: snapshot, in: sourceIntakes)
                    }
                    let child = await CopyMergeExecutor.runPrepared(plan: plan, prepared: preparedPlan, journalDirectory: journalDirectory,
                                                            cancellation: cancellation, expectedDestination: destinationEntry) { update in
                        progress(CopyMergeBatchProgress(index: index, total: sources.count, source: source,
                            state: update.phase, actionIndex: update.index, actionTotal: update.total,
                            relativePath: update.relativePath, liveTransfer: update.liveTransfer,
                            selectionTransfer: aggregate(update.selectionTransfer, index: index, in: selection)))
                    }
                    _ = aggregate(child.selectionTransfer, index: index, in: selection)
                    report.items[index].addedCount = child.items.filter { $0.state == "completed" }.count
                    report.items[index].conflictCount = child.items.filter { $0.state == "conflict" }.count
                    switch child.state {
                    case "completed": report.items[index].state = "merged"
                    case "cancelled": report.items[index].state = "cancelled"
                    default: report.items[index].state = "failed"
                    }
                    report.items[index].message = child.journalError ?? child.items.first(where: { $0.state == "failed" })?.message
                    undoItems += child.items.compactMap { item in
                        guard item.state == "completed", let identity = item.targetIdentity,
                              let snapshot = item.targetSnapshot else { return nil }
                        return CopyUndoItem(target: item.target, targetIdentity: identity, targetSnapshot: snapshot,
                                            targetMetadata: item.targetMetadata)
                    }
                } else {
                    selection.excludeUnstaged(index)
                    report.items[index].state = "conflict"
                    report.items[index].conflictCount = 1
                    report.items[index].message = "Existing file or folder type conflict was preserved."
                }
            } catch {
                report.items[index].state = cancellation.isCancelled ? "cancelled" : "failed"
                report.items[index].message = error.localizedDescription
            }
            do { try save() } catch { report.journalError = error.localizedDescription }
            progress(CopyMergeBatchProgress(index: index, total: sources.count,
                                            source: source, state: report.items[index].state, actionIndex: Int.max, selectionTransfer: selection.snapshot()))
            if report.journalError != nil { break }
        }
        report.selectionTransfer = selection.snapshot()
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

    private static func nameKey(_ source: URL) -> String {
        source.lastPathComponent.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    private final class DirectoryAnchor {
        let key: String
        private let descriptor: Int32
        init(target: URL, expected: String, key: String) throws {
            let fd = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do {
                guard try CopyEngine.matchesRecordedIdentity(at: target, expected: expected, identity: CopyEngine.entryIdentity),
                      CopyEngine.matchesPublicationHandle(target, descriptor: fd) else {
                    throw BatchFailure(text: "Merge destination identity changed.")
                }
            } catch { close(fd); throw error }
            descriptor = fd; self.key = key
        }
        func matches(_ target: URL) -> Bool { CopyEngine.matchesPublicationHandle(target, descriptor: descriptor) }
        deinit { close(descriptor) }
    }

    private enum PreparedSource: Sendable {
        case copy(CopyEngine.VerificationSnapshot)
        case merge(CopyMergePlan, CopyMergeExecutor.Prepared)
        case conflict
        case failed(any Error)
        var totalBytes: Int64? {
            switch self {
            case .copy(let snapshot): return snapshot.logicalDataBytes
            case .merge(_, let prepared): return prepared.totalBytes
            case .conflict: return 0
            case .failed: return nil
            }
        }
    }
    private static func prepareSource(source: URL, target: URL, destination: URL,
                                      cancellation: CopyCancellation, sourceIntakes: [PromisedFileIntake],
                                      progress: @escaping @Sendable (CopyMergeAction) -> Void) async -> PreparedSource {
        await Task.detached(priority: .userInitiated) {
            do {
                try cancellation.check()
                if !sourceIntakes.isEmpty {
                    let snapshot = try CopyEngine.makeSnapshot(source, cancellation: cancellation)
                    try PromisedFileIntake.validate(source, snapshot: snapshot, in: sourceIntakes)
                }
                let sourceKind = try kind(source), targetKind = try optionalKind(target)
                if targetKind == nil {
                    if sourceKind == .directory {
                        let root = source.resolvingSymlinksInPath().path
                        let path = destination.resolvingSymlinksInPath().path
                        guard path != root, !path.hasPrefix(root == "/" ? "/" : root + "/") else {
                            throw BatchFailure(text: "Cannot copy a folder into itself or a descendant.")
                        }
                    }
                    return .copy(try CopyEngine.makeSnapshot(source, cancellation: cancellation))
                }
                if sourceKind == .directory && targetKind == .directory {
                    let plan = try CopyMergePlanner.plan(source: source, target: target, cancellation: cancellation)
                    return .merge(plan, CopyMergeExecutor.prepare(plan: plan, cancellation: cancellation, progress: progress))
                }
                return .conflict
            } catch { return .failed(error) }
        }.value
    }
    private static func aggregate(_ value: SelectionTransferProgress?, index: Int,
                                  in tracker: SelectionTransferTracker) -> SelectionTransferProgress {
        guard let value else { return tracker.snapshot() }
        return tracker.record(index, live: LiveTransferProgress(bytes: value.bytes,
            totalBytes: value.totalBytes, seconds: value.seconds))
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
