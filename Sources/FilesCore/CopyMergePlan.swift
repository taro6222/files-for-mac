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
}

public struct CopyMergePlan: Codable, Sendable {
    public let source: URL
    public let target: URL
    public let actions: [CopyMergeAction]

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
        return CopyMergePlan(source: source, target: target, actions: actions)
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
                                               relativePath: relative, kind: .copyMissing))
                continue
            }
            if sourceKind == .directory, targetKind == .directory {
                actions.append(CopyMergeAction(source: child, target: destination,
                                               relativePath: relative, kind: .mergeDirectory))
                try appendDirectory(source: child, target: destination,
                                    relativeParent: relative, actions: &actions)
            } else {
                actions.append(CopyMergeAction(source: child, target: destination,
                                               relativePath: relative,
                                               kind: sourceKind == targetKind ? .fileConflict : .typeConflict))
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
}
