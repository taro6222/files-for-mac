import Foundation

public enum FileGroupField: String, Codable, CaseIterable, Sendable {
    case none, name, created, modified, size, kind, tag, path, syncStatus
}

public enum FileGroupDateUnit: String, Codable, CaseIterable, Sendable {
    case year, month, day
}

public struct FileGroupOptions: Codable, Equatable, Sendable {
    public var field: FileGroupField
    public var ascending: Bool
    public var dateUnit: FileGroupDateUnit

    public init(field: FileGroupField = .none, ascending: Bool = true, dateUnit: FileGroupDateUnit = .year) {
        self.field = field; self.ascending = ascending; self.dateUnit = dateUnit
    }
}

public struct FileItemGroup: Equatable, Sendable {
    public let key: String
    public let items: [FileItem]
}

public enum FileGrouping {
    public static func groups(_ items: [FileItem], options: FileGroupOptions,
                              calendar: Calendar = Calendar(identifier: .gregorian)) -> [FileItemGroup] {
        guard options.field != .none else { return items.isEmpty ? [] : [FileItemGroup(key: "all", items: items)] }
        var buckets: [String: [FileItem]] = [:]
        for item in items { buckets[key(for: item, options: options, calendar: calendar), default: []].append(item) }
        return buckets.keys.sorted(by: options.ascending ? (<) : (>)).map { FileItemGroup(key: $0, items: buckets[$0] ?? []) }
    }

    private static func key(for item: FileItem, options: FileGroupOptions, calendar: Calendar) -> String {
        switch options.field {
        case .none: return "all"
        case .name:
            let scalar = item.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .unicodeScalars.first
            guard let scalar, CharacterSet.alphanumerics.contains(scalar) else { return "2:#" }
            return "1:" + String(scalar).uppercased()
        case .created, .modified:
            let date = options.field == .created ? item.created : item.modified
            guard let date else { return "0:unknown" }
            let components: DateComponents
            switch options.dateUnit {
            case .year: components = calendar.dateComponents([.year], from: date)
            case .month: components = calendar.dateComponents([.year, .month], from: date)
            case .day: components = calendar.dateComponents([.year, .month, .day], from: date)
            }
            return String(format: "1:%04d-%02d-%02d", components.year ?? 0,
                          options.dateUnit == .year ? 0 : components.month ?? 0,
                          options.dateUnit == .day ? components.day ?? 0 : 0)
        case .size:
            if item.isDirectory { return "0:folder" }
            guard let size = item.size else { return "1:unknown" }
            if size == 0 { return "2:empty" }
            if size < 1_000_000 { return "3:small" }
            if size < 1_000_000_000 { return "4:medium" }
            return "5:large"
        case .kind:
            let value = item.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "0:unknown" : "1:" + value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        case .tag:
            guard let value = item.tags.first?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "0:untagged" }
            return "1:" + value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        case .syncStatus: return item.cloudState.map { "1:" + $0.rawValue } ?? "0:unreported"
        case .path: return "1:" + item.url.deletingLastPathComponent().standardizedFileURL.path
        }
    }
}
