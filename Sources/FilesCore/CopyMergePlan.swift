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
    public static func plan(source: URL, target: URL) throws -> CopyMergePlan {
        let source = source.standardizedFileURL
        let target = target.standardizedFileURL
        guard try entryKind(source) == .directory, try entryKind(target) == .directory else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var actions: [CopyMergeAction] = []
        try appendDirectory(source: source, target: target, relativeParent: "", actions: &actions)
        return CopyMergePlan(source: source, target: target, actions: actions,
                             targetIdentity: try identity(target))
    }

    private enum EntryKind { case directory, other }

    private static func appendDirectory(source: URL, target: URL, relativeParent: String,
                                        actions: inout [CopyMergeAction]) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for child in children {
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
                                    relativeParent: relative, actions: &actions)
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
}

public struct CopyMergeExecutionReport: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public var state: String
    public var items: [CopyMergeExecutionItem]
    public var journalError: String?
}

public enum CopyMergeExecutor {
    public static func run(plan: CopyMergePlan, journalDirectory: URL,
                           cancellation: CopyCancellation, recordUndo: Bool = true) async -> CopyMergeExecutionReport {
        await Task.detached(priority: .userInitiated) {
            execute(plan: plan, journalDirectory: journalDirectory,
                    cancellation: cancellation, recordUndo: recordUndo)
        }.value
    }

    private static func execute(plan: CopyMergePlan, journalDirectory: URL,
                                cancellation: CopyCancellation, recordUndo: Bool) -> CopyMergeExecutionReport {
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
        var undoItems: [CopyUndoItem] = []
        for index in plan.actions.indices {
            let action = plan.actions[index]
            if cancellation.isCancelled { report.items[index].state = "cancelled"; continue }
            do {
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
                    let before = try CopyEngine.verifiedSnapshot(action.source, cancellation: cancellation)
                    let contentBefore = try CopyEngine.verifiedContentSnapshot(action.source, cancellation: cancellation)
                    let temporary = parent.appendingPathComponent(".files-merge-\(report.id.uuidString)-\(index)")
                    try fm.copyItem(at: action.source, to: temporary)
                    defer { try? fm.removeItem(at: temporary) }
                    try cancellation.check()
                    guard try CopyEngine.verifiedContentSnapshot(temporary, cancellation: cancellation) == contentBefore,
                          try CopyEngine.verifiedSnapshot(action.source, cancellation: cancellation) == before else {
                        throw MergeFailure(text: "Source changed or copied contents did not match.")
                    }
                    guard try identity(parent) == action.expectedParentIdentity else {
                        throw MergeFailure(text: "Destination parent changed before publication.")
                    }
                    let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard parentFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    defer { close(parentFD) }
                    do {
                        try CopyEngine.publishNoReplace(payload: temporary, target: action.target,
                            sourceDirectoryFD: parentFD, sourceName: temporary.lastPathComponent,
                            destinationDirectoryFD: parentFD, destinationName: action.target.lastPathComponent)
                    } catch CopyPublicationError.conflict { throw MergeConflict() }
                    let targetIdentity = try identity(action.target)
                    report.items[index].state = "completed"
                    report.items[index].targetIdentity = targetIdentity
                    let targetSnapshot = try CopyEngine.verifiedSnapshot(action.target, cancellation: cancellation)
                    report.items[index].targetSnapshot = targetSnapshot
                    undoItems.append(CopyUndoItem(target: action.target, targetIdentity: targetIdentity,
                                                  targetSnapshot: targetSnapshot))
                }
            } catch is MergeConflict {
                report.items[index].state = "conflict"
                report.items[index].message = "Destination appeared after planning; preserved."
            } catch {
                report.items[index].state = cancellation.isCancelled ? "cancelled" : "failed"
                report.items[index].message = error.localizedDescription
            }
            do { try save() } catch { report.journalError = error.localizedDescription; break }
        }
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
