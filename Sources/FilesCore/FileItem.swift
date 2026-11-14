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
    public let created: Date?
    public let modified: Date?
    public let kind: String
    public let tags: [String]

    public init(url: URL, name: String, isDirectory: Bool, identity: String? = nil, isPackage: Bool = false,
                isSymbolicLink: Bool = false, isHidden: Bool = false,
                size: Int64? = nil, created: Date? = nil, modified: Date? = nil, kind: String = "", tags: [String] = []) {
        self.identity = identity
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.isPackage = isPackage; self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden; self.size = size; self.created = created; self.modified = modified; self.kind = kind; self.tags = tags
    }
    public func displayName(showExtensions: Bool) -> String {
        guard !showExtensions, !isDirectory, !name.hasPrefix("."), !url.pathExtension.isEmpty else { return name }
        return (name as NSString).deletingPathExtension
    }
    public var isBrowsable: Bool { isDirectory && !isPackage }
}

public enum SortField: String, CaseIterable, Codable, Sendable { case name, created, modified, kind, size, tag, path }
public enum SortDirectoryPlacement: String, CaseIterable, Codable, Sendable { case foldersFirst, filesFirst, mixed }
public struct SortOrder: Codable, Equatable, Sendable {
    public var field: SortField
    public var ascending: Bool
    public var directoryPlacement: SortDirectoryPlacement
    public var foldersFirst: Bool {
        get { directoryPlacement == .foldersFirst }
        set { directoryPlacement = newValue ? .foldersFirst : .mixed }
    }
    public init(field: SortField = .name, ascending: Bool = true, foldersFirst: Bool = true,
                directoryPlacement: SortDirectoryPlacement? = nil) {
        self.field = field; self.ascending = ascending
        self.directoryPlacement = directoryPlacement ?? (foldersFirst ? .foldersFirst : .mixed)
    }
    private enum CodingKeys: String, CodingKey { case field, ascending, directoryPlacement, foldersFirst }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        field = try values.decodeIfPresent(SortField.self, forKey: .field) ?? .name
        ascending = try values.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        if let placement = try values.decodeIfPresent(SortDirectoryPlacement.self, forKey: .directoryPlacement) {
            directoryPlacement = placement
        } else {
            directoryPlacement = (try values.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? true) ? .foldersFirst : .mixed
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(field, forKey: .field); try values.encode(ascending, forKey: .ascending)
        try values.encode(directoryPlacement, forKey: .directoryPlacement)
    }
    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if directoryPlacement != .mixed && a.isBrowsable != b.isBrowsable {
                return directoryPlacement == .foldersFirst ? a.isBrowsable : !a.isBrowsable
            }
            let comparison: ComparisonResult
            switch field {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .created: comparison = compare(a.created, b.created)
            case .kind: comparison = a.kind.localizedStandardCompare(b.kind)
            case .tag: comparison = a.tags.joined(separator: "\u{0}").localizedStandardCompare(b.tags.joined(separator: "\u{0}"))
            case .path: comparison = a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
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
