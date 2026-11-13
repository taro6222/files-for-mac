import Foundation

public enum SplitAxis: String, Codable, CaseIterable, Sendable {
    case vertical
    case horizontal
}

public struct PaneSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var tab: TabSnapshot

    public init(id: UUID = UUID(), tab: TabSnapshot) {
        self.id = id
        self.tab = tab
    }
}

public struct SplitTabState: Codable, Equatable, Sendable {
    public private(set) var panes: [PaneSnapshot]
    public private(set) var axis: SplitAxis
    public private(set) var ratio: Double
    public private(set) var activePaneID: UUID

    public init(primary: PaneSnapshot, secondary: PaneSnapshot? = nil,
                axis: SplitAxis = .vertical, ratio: Double = 0.5, activePaneID: UUID? = nil) {
        let initialPanes = secondary.map { [primary, $0] } ?? [primary]
        self.panes = initialPanes
        self.axis = axis
        self.ratio = Self.clamped(ratio)
        let requested = activePaneID.flatMap { id in initialPanes.contains { $0.id == id } ? id : nil }
        self.activePaneID = requested ?? primary.id
    }

    public var activePane: PaneSnapshot {
        panes.first { $0.id == activePaneID } ?? panes[0]
    }

    public var isSplit: Bool { panes.count == 2 }

    @discardableResult
    public mutating func split(axis: SplitAxis, snapshot: TabSnapshot) -> UUID {
        self.axis = axis
        if panes.count == 2 {
            panes[1].tab = snapshot
            activePaneID = panes[1].id
            return panes[1].id
        }
        let pane = PaneSnapshot(tab: snapshot)
        panes.append(pane)
        activePaneID = pane.id
        return pane.id
    }

    public mutating func activate(_ id: UUID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        activePaneID = id
    }

    public mutating func setRatio(_ value: Double) {
        ratio = Self.clamped(value)
    }

    public mutating func updateActive(_ snapshot: TabSnapshot) {
        guard let index = panes.firstIndex(where: { $0.id == activePaneID }) else { return }
        panes[index].tab = snapshot
    }

    @discardableResult
    public mutating func close(_ id: UUID) -> Bool {
        guard panes.count == 2, let index = panes.firstIndex(where: { $0.id == id }) else { return false }
        panes.remove(at: index)
        activePaneID = panes[0].id
        ratio = 0.5
        return true
    }

    private static func clamped(_ ratio: Double) -> Double {
        min(0.8, max(0.2, ratio.isFinite ? ratio : 0.5))
    }
}

public final class WorkspaceSessionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "workspaceSessionV2") {
        self.defaults = defaults; self.key = key
    }

    public func save(_ workspaces: [SplitTabState]) throws {
        defaults.set(try JSONEncoder().encode(workspaces), forKey: key)
    }

    public func load() -> [SplitTabState] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SplitTabState].self, from: data)) ?? []
    }
}
