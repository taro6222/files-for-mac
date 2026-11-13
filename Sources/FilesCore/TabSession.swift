import Foundation

public struct TabSnapshot: Codable, Equatable, Sendable {
    public var history: NavigationHistory
    public var sortOrder: SortOrder
    public var showHidden: Bool

    public var location: URL? { history.current.url }

    public init(location: URL?, sortOrder: SortOrder = SortOrder(), showHidden: Bool = false) {
        self.history = NavigationHistory(current: NavigationEntry(url: location))
        self.sortOrder = sortOrder
        self.showHidden = showHidden
    }

    public init(history: NavigationHistory, sortOrder: SortOrder = SortOrder(), showHidden: Bool = false) {
        self.history = history
        self.sortOrder = sortOrder
        self.showHidden = showHidden
    }
}

public final class TabSessionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "tabSession") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ snapshots: [TabSnapshot]) throws {
        defaults.set(try encoder.encode(snapshots), forKey: key)
    }

    public func load() -> [TabSnapshot] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? decoder.decode([TabSnapshot].self, from: data)) ?? []
    }
}

public struct ClosedTabHistory: Sendable {
    public let capacity: Int
    public private(set) var snapshots: [TabSnapshot] = []

    public init(capacity: Int = 20) {
        self.capacity = max(0, capacity)
    }

    public var canRestore: Bool { !snapshots.isEmpty }

    public mutating func record(_ snapshot: TabSnapshot) {
        guard capacity > 0 else { return }
        snapshots.append(snapshot)
        if snapshots.count > capacity {
            snapshots.removeFirst(snapshots.count - capacity)
        }
    }

    public mutating func restoreLast() -> TabSnapshot? {
        snapshots.popLast()
    }
}
