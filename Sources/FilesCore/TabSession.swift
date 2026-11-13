import Foundation

public struct TabSnapshot: Equatable, Sendable {
    public let location: URL?

    public init(location: URL?) {
        self.location = location
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
