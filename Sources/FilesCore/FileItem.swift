import Foundation

public struct FileItem: Identifiable, Sendable, Equatable {
    // Directory entries, rather than inodes: two hard links in one folder must stay distinct.
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let kind: String

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool = false,
                isSymbolicLink: Bool = false, isHidden: Bool = false,
                size: Int64? = nil, modified: Date? = nil, kind: String = "") {
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.isPackage = isPackage; self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden; self.size = size; self.modified = modified; self.kind = kind
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
