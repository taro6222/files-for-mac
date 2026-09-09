import Foundation

public struct FileItem: Identifiable, Sendable, Equatable {
    // Directory entries, rather than inodes: two hard links in one folder must stay distinct.
    public var id: String { url.path }
    public let identity: String?
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let kind: String

    public init(url: URL, name: String, isDirectory: Bool, identity: String? = nil, isPackage: Bool = false,
                isSymbolicLink: Bool = false, isHidden: Bool = false,
                size: Int64? = nil, modified: Date? = nil, kind: String = "") {
        self.identity = identity
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.isPackage = isPackage; self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden; self.size = size; self.modified = modified; self.kind = kind
    }
    public func displayName(showExtensions: Bool) -> String {
        guard !showExtensions, !isDirectory, !name.hasPrefix("."), !url.pathExtension.isEmpty else { return name }
        return (name as NSString).deletingPathExtension
    }
    public var isBrowsable: Bool { isDirectory && !isPackage }
}

public enum SortField: String, CaseIterable, Sendable { case name, modified, kind, size }
public struct SortOrder: Sendable {
    public var field: SortField
    public var ascending: Bool
    public var foldersFirst: Bool
    public init(field: SortField = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.field = field; self.ascending = ascending; self.foldersFirst = foldersFirst
    }
    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if foldersFirst && a.isBrowsable != b.isBrowsable { return a.isBrowsable }
            let comparison: ComparisonResult
            switch field {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .kind: comparison = a.kind.localizedStandardCompare(b.kind)
            case .size:
                comparison = compare(a.size, b.size)
            case .modified:
                comparison = compare(a.modified, b.modified)
            }
            if comparison == .orderedSame { return a.id < b.id }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    private func compare<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (a?, b?): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
    }
}

public enum SelectionRestoration {
    /// Preserve a directory entry first; follow a renamed identity only when it is
    /// unambiguous on both sides (hard links must not acquire each other's selection).
    public static func restore(_ selected: Set<String>, from old: [FileItem], to new: [FileItem]) -> Set<String> {
        let oldByPath = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        let oldByIdentity = Dictionary(grouping: old.filter { $0.identity != nil }, by: { $0.identity! })
        let newByIdentity = Dictionary(grouping: new.filter { $0.identity != nil }, by: { $0.identity! })
        var result = Set<String>()
        for id in selected {
            guard let previous = oldByPath[id] else {
                if newByPath[id] != nil { result.insert(id) }; continue
            }
            if let current = newByPath[id], previous.identity == current.identity {
                result.insert(id); continue
            }
            if let identity = previous.identity, oldByIdentity[identity]?.count == 1,
               let candidates = newByIdentity[identity], candidates.count == 1 {
                result.insert(candidates[0].id)
            }
        }
        return result
    }
}
