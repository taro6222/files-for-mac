import Foundation
import Darwin

public enum CopyMergeActionKind: String, Codable, Sendable {
    case copyMissing
    case mergeDirectory
    case fileConflict
    case typeConflict
}

public struct CopyMergeAction: Codable, Sendable, Equatable {
    public let source: URL
    public let target: URL
    public let relativePath: String
    public let kind: CopyMergeActionKind
    public let expectedParentIdentity: String
    public let expectedTargetIdentity: String?
}

public struct CopyMergePlan: Codable, Sendable {
    public let source: URL
    public let target: URL
    public let actions: [CopyMergeAction]
    public let targetIdentity: String

    public var conflicts: [CopyMergeAction] {
        actions.filter { $0.kind == .fileConflict || $0.kind == .typeConflict }
    }
}

public enum CopyMergePlanner {
    /// Builds a read-only recursive plan. Execution must revalidate every target because the
    /// directory can change between planning and publication.
    public static func plan(source: URL, target: URL, cancellation: CopyCancellation? = nil) throws -> CopyMergePlan {
        let source = source.standardizedFileURL
        let target = target.standardizedFileURL
        guard try entryKind(source) == .directory, try entryKind(target) == .directory else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let root = source.resolvingSymlinksInPath().path
        let destination = target.resolvingSymlinksInPath().path
        guard destination != root, !destination.hasPrefix(root == "/" ? "/" : root + "/") else {
            throw MergeFailure(text: "Cannot merge a folder into itself or a descendant.")
        }
        var actions: [CopyMergeAction] = []
        try appendDirectory(source: source, target: target, relativeParent: "", cancellation: cancellation, actions: &actions)
        return CopyMergePlan(source: source, target: target, actions: actions,
                             targetIdentity: try identity(target))
    }

    private enum EntryKind { case directory, other }

    private static func appendDirectory(source: URL, target: URL, relativeParent: String,
                                        cancellation: CopyCancellation?, actions: inout [CopyMergeAction]) throws {
        try cancellation?.check()
        let children = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for child in children {
            try cancellation?.check()
            let relative = relativeParent.isEmpty ? child.lastPathComponent : relativeParent + "/" + child.lastPathComponent
            let destination = target.appendingPathComponent(child.lastPathComponent)
            let sourceKind = try entryKind(child)
            guard let targetKind = try optionalEntryKind(destination) else {
                actions.append(CopyMergeAction(source: child, target: destination,
                                               relativePath: relative, kind: .copyMissing,
                                               expectedParentIdentity: try identity(target), expectedTargetIdentity: nil))
                continue
            }
            if sourceKind == .directory, targetKind == .directory {
                actions.append(CopyMergeAction(source: child, target: destination,
                                               relativePath: relative, kind: .mergeDirectory,
                                               expectedParentIdentity: try identity(target),
                                               expectedTargetIdentity: try identity(destination)))
                try appendDirectory(source: child, target: destination,
                                    relativeParent: relative, cancellation: cancellation, actions: &actions)
            } else {
                actions.append(CopyMergeAction(source: child, target: destination,
                                               relativePath: relative,
                                               kind: sourceKind == targetKind ? .fileConflict : .typeConflict,
                                               expectedParentIdentity: try identity(target),
                                               expectedTargetIdentity: try identity(destination)))
            }
        }
    }

    private static func optionalEntryKind(_ url: URL) throws -> EntryKind? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .other }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func entryKind(_ url: URL) throws -> EntryKind {
        guard let kind = try optionalEntryKind(url) else { throw CocoaError(.fileNoSuchFile) }
        return kind
    }

    private static func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)"
    }
}

public struct CopyMergeExecutionItem: Codable, Sendable {
    public let relativePath: String
    public let target: URL
    public var state: String
    public var message: String?
    public var targetIdentity: String?
    public var targetSnapshot: [String: String]?
    var targetMetadata: CopyTransferMetadata? = nil
}

public struct CopyMergeExecutionReport: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public var state: String
    public var items: [CopyMergeExecutionItem]
    public var journalError: String?
    public var selectionTransfer: SelectionTransferProgress? = nil
    var directoryMutations: [String: MergeDirectoryMutation]? = nil
}

/// Progress of the current missing entry; bytes describe staging before verification/publication.
public struct CopyMergeProgress: Sendable {
    public let index: Int
    public let total: Int
    public let relativePath: String
    public let phase: String
    public var liveTransfer: LiveTransferProgress? = nil
    public var selectionTransfer: SelectionTransferProgress? = nil
}

public enum CopyMergeExecutor {
    public static func run(plan: CopyMergePlan, journalDirectory: URL,
                           cancellation: CopyCancellation, recordUndo: Bool = true,
                           progress: @escaping @Sendable (CopyMergeProgress) -> Void = { _ in }) async -> CopyMergeExecutionReport {
        await Task.detached(priority: .userInitiated) {
            execute(plan: plan, prepared: nil, journalDirectory: journalDirectory,
                    cancellation: cancellation, recordUndo: recordUndo, progress: progress)
        }.value
    }

    final class Prepared: @unchecked Sendable {
        private let lock = NSLock()
        private var originals: [Result<CopyEngine.VerificationSnapshot, any Error>?]
        let sizes: [Int64?]
        init(originals: [Result<CopyEngine.VerificationSnapshot, any Error>?], sizes: [Int64?]) {
            self.originals = originals; self.sizes = sizes
        }
        func take(_ index: Int) -> Result<CopyEngine.VerificationSnapshot, any Error>? {
            lock.withLock { let value = originals[index]; originals[index] = nil; return value }
        }
        var totalBytes: Int64? { SelectionTransferTracker(plans: sizes).snapshot().totalBytes }
    }
    static func prepare(plan: CopyMergePlan, cancellation: CopyCancellation,
                        progress: (CopyMergeAction) -> Void = { _ in }) -> Prepared {
        var originals = [Result<CopyEngine.VerificationSnapshot, any Error>?](repeating: nil, count: plan.actions.count)
        var sizes = [Int64?](repeating: 0, count: plan.actions.count)
        var lastFeedback: ContinuousClock.Instant?
        for index in plan.actions.indices where plan.actions[index].kind == .copyMissing {
            let action = plan.actions[index]
            if cancellation.isCancelled {
                for remaining in index..<plan.actions.count where plan.actions[remaining].kind == .copyMissing { sizes[remaining] = nil }
                break
            }
            let now = ContinuousClock.now
            if lastFeedback.map({ $0.duration(to: now) >= .milliseconds(100) }) != false {
                progress(action); lastFeedback = now
            }
            let result = Result { () throws -> CopyEngine.VerificationSnapshot in
                try cancellation.check()
                guard try identity(plan.target) == plan.targetIdentity,
                      try identity(action.target.deletingLastPathComponent()) == action.expectedParentIdentity else {
                    throw MergeFailure(text: "Merge destination changed before preparation.")
                }
                return try CopyEngine.makeSnapshot(action.source, cancellation: cancellation)
            }
            originals[index] = result
            if case .success(let snapshot) = result { sizes[index] = snapshot.logicalDataBytes }
            else { sizes[index] = nil }
        }
        return Prepared(originals: originals, sizes: sizes)
    }
    static func revalidate(plan: CopyMergePlan, prepared: Prepared, cancellation: CopyCancellation) throws {
        for index in plan.actions.indices where plan.actions[index].kind == .copyMissing {
            try cancellation.check()
            guard let original = prepared.take(index) else { continue }
            let snapshot = try original.get()
            guard try CopyEngine.makeSnapshot(plan.actions[index].source, cancellation: cancellation).matchesOriginal(snapshot) else {
                throw MergeFailure(text: "Source changed after merge preparation.")
            }
        }
    }
    static func runPrepared(plan: CopyMergePlan, prepared: Prepared, journalDirectory: URL,
                            cancellation: CopyCancellation, expectedDestination: ShelfEntry?,
                            progress: @escaping @Sendable (CopyMergeProgress) -> Void) async -> CopyMergeExecutionReport {
        await Task.detached(priority: .userInitiated) {
            execute(plan: plan, prepared: prepared, journalDirectory: journalDirectory,
                    cancellation: cancellation, recordUndo: false, expectedDestination: expectedDestination, progress: progress)
        }.value
    }

    private static func execute(plan: CopyMergePlan, prepared: Prepared?, journalDirectory: URL,
                                cancellation: CopyCancellation, recordUndo: Bool, expectedDestination: ShelfEntry? = nil,
                                progress: @escaping @Sendable (CopyMergeProgress) -> Void) -> CopyMergeExecutionReport {
        let fm = FileManager.default
        var report = CopyMergeExecutionReport(version: 1, id: UUID(), state: "running",
            items: plan.actions.map { CopyMergeExecutionItem(relativePath: $0.relativePath,
                                                               target: $0.target, state: "queued",
                                                               targetIdentity: nil, targetSnapshot: nil) })
        let journal = journalDirectory.appendingPathComponent("merge-\(report.id.uuidString).json")
        func save() throws {
            try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: journal, options: .atomic)
        }
        do { try save() } catch {
            report.state = "failed"; report.journalError = error.localizedDescription; return report
        }
        guard (try? identity(plan.target)) == plan.targetIdentity else {
            report.state = "failed"; report.journalError = "Merge destination changed after planning."; try? save(); return report
        }
        let preparation = prepared ?? prepare(plan: plan, cancellation: cancellation) { action in
            progress(CopyMergeProgress(index: 0, total: plan.actions.count, relativePath: action.relativePath, phase: "sizing"))
        }
        var undoItems: [CopyUndoItem] = []
        let selection = SelectionTransferTracker(plans: preparation.sizes)
        for index in plan.actions.indices {
            let original = preparation.take(index)
            let action = plan.actions[index]
            var mutationFD: Int32 = -1
            var mutatedParent = false
            defer { if mutationFD >= 0 { close(mutationFD) } }
            func emit(_ phase: String) {
                progress(CopyMergeProgress(index: index, total: plan.actions.count,
                    relativePath: action.relativePath, phase: phase, selectionTransfer: selection.snapshot()))
            }
            if cancellation.isCancelled { report.items[index].state = "cancelled"; continue }
            emit("planning")
            do {
                guard expectedDestination?.isCurrent != false else {
                    throw MergeFailure(text: "Merge destination changed after preparation.")
                }
                let parent = action.target.deletingLastPathComponent()
                guard try identity(parent) == action.expectedParentIdentity else {
                    throw MergeFailure(text: "Destination parent changed after planning.")
                }
                switch action.kind {
                case .fileConflict, .typeConflict:
                    guard try identity(action.target) == action.expectedTargetIdentity else {
                        throw MergeFailure(text: "Conflicting destination changed after planning.")
                    }
                    report.items[index].state = "conflict"
                case .mergeDirectory:
                    guard try identity(action.target) == action.expectedTargetIdentity else {
                        throw MergeFailure(text: "Merge directory changed after planning.")
                    }
                    report.items[index].state = "verified"
                case .copyMissing:
                    report.items[index].state = "copying"; try save(); try cancellation.check()
                    let before: CopyEngine.VerificationSnapshot
                    if let original { before = try original.get() }
                    else { before = try CopyEngine.makeSnapshot(action.source, cancellation: cancellation) }
                    mutationFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard mutationFD >= 0, CopyEngine.matchesPublicationHandle(parent, descriptor: mutationFD) else {
                        throw MergeFailure(text: "Merge parent changed before staging.")
                    }
                    let staging = parent.appendingPathComponent(".files-merge-\(report.id.uuidString)-\(index)")
                    guard mkdir(staging.path, 0o700) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    mutatedParent = true
                    defer { try? fm.removeItem(at: staging) }
                    let stageFD = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard stageFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    defer { close(stageFD) }
                    let temporary = staging.appendingPathComponent("payload")
                    try NativeFileCopy.run(from: action.source, to: temporary,
                                           totalBytes: before.logicalDataBytes, cancellation: cancellation) { live in
                        progress(CopyMergeProgress(index: index, total: plan.actions.count,
                            relativePath: action.relativePath, phase: "copying", liveTransfer: live,
                            selectionTransfer: selection.record(index, live: live)))
                    }
                    try before.restoreCreationTimes(in: temporary, cancellation: cancellation)
                    try before.restoreDirectoryModificationTimes(in: temporary, cancellation: cancellation)
                    try cancellation.check()
                    emit("verifying")
                    let copied = try CopyEngine.makeSnapshot(temporary, cancellation: cancellation)
                    guard try CopyEngine.makeSnapshot(action.source, cancellation: cancellation).matchesOriginal(before) else {
                        throw MergeFailure(text: "Source changed during copying.")
                    }
                    try copied.verifyTransferredContents(of: before)
                    try before.restoreAccessTimes(in: temporary, verifiedCopy: copied, cancellation: cancellation)
                    let targetIdentity = try identity(temporary)
                    let publicationHandle = try CopyEngine.openPublicationHandle(temporary, on: stageFD)
                    defer { if let publicationHandle { close(publicationHandle) } }
                    emit("committing"); try cancellation.check()
                    guard try identity(parent) == action.expectedParentIdentity else {
                        throw MergeFailure(text: "Destination parent changed before publication.")
                    }
                    let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard parentFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    defer { close(parentFD) }
                    guard expectedDestination?.isCurrent != false,
                          try identity(parent) == action.expectedParentIdentity,
                          CopyEngine.matches(parent, descriptor: parentFD),
                          CopyEngine.matches(staging, descriptor: stageFD) else {
                        throw MergeFailure(text: "Destination or staging directory changed before publication.")
                    }
                    do {
                        try CopyEngine.publishNoReplace(payload: temporary, target: action.target,
                            sourceDirectoryFD: stageFD, sourceName: temporary.lastPathComponent,
                            destinationDirectoryFD: parentFD, destinationName: action.target.lastPathComponent)
                    } catch CopyPublicationError.conflict { throw MergeConflict() }
                    let publishedIdentity = try CopyEngine.identityAfterPublication(of: action.target,
                        handle: publicationHandle, original: targetIdentity, identity: CopyEngine.entryIdentity)
                    report.items[index].state = "completed"
                    report.items[index].targetIdentity = publishedIdentity
                    report.items[index].targetSnapshot = copied.withPermissions
                    report.items[index].targetMetadata = copied.metadata
                    undoItems.append(CopyUndoItem(target: action.target, targetIdentity: publishedIdentity,
                                                  targetSnapshot: copied.withPermissions, targetMetadata: copied.metadata))
                }
            } catch is MergeConflict {
                report.items[index].state = "conflict"
                report.items[index].message = "Destination appeared after planning; preserved."
            } catch {
                report.items[index].state = cancellation.isCancelled ? "cancelled" : "failed"
                report.items[index].message = error.localizedDescription
            }
            if mutatedParent, let (path,mutation) = MergeDirectoryMutation.capture(mutationFD) {
                if report.directoryMutations == nil { report.directoryMutations = [:] }
                report.directoryMutations?[path] = mutation
            }
            emit(report.items[index].state)
            do { try save() } catch { report.journalError = error.localizedDescription; break }
        }
        report.selectionTransfer = selection.snapshot()
        let failed = report.items.filter { $0.state == "failed" }.count
        report.state = cancellation.isCancelled ? "cancelled" : (failed == 0 ? "completed" : "partiallyCompleted")
        if recordUndo && !undoItems.isEmpty {
            do {
                let undo = CopyUndoRecord(operationId: report.id, items: undoItems, createdAt: Date())
                try JSONEncoder().encode(undo).write(
                    to: journalDirectory.appendingPathComponent("undo-copy-\(report.id.uuidString).json"), options: .atomic)
            } catch { report.journalError = error.localizedDescription }
        }
        try? save()
        return report
    }

    private static func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)"
    }
}

private struct MergeFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
private struct MergeConflict: Error {}
