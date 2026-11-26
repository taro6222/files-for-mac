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

    private enum CodingKeys: String, CodingKey { case panes, axis, ratio, activePaneID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let panes = try values.decode([PaneSnapshot].self, forKey: .panes)
        guard (1...2).contains(panes.count), Set(panes.map(\.id)).count == panes.count else {
            throw DecodingError.dataCorruptedError(forKey: .panes, in: values,
                debugDescription: "Expected one or two panes with distinct identifiers")
        }
        self.init(primary: panes[0], secondary: panes.dropFirst().first,
            axis: try values.decode(SplitAxis.self, forKey: .axis),
            ratio: try values.decode(Double.self, forKey: .ratio),
            activePaneID: try values.decode(UUID.self, forKey: .activePaneID))
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

/// Ordered browser windows, each containing ordered tabs and its selected tab.
public struct WorkspaceWindowSession: Equatable, Sendable {
    public let tabs: [SplitTabState]
    public let selectedIndex: Int
    public init(tabs: [SplitTabState], selectedIndex: Int = 0) {
        self.tabs = tabs
        self.selectedIndex = tabs.indices.contains(selectedIndex) ? selectedIndex : 0
    }
}

public struct WorkspaceDesktopSession: Equatable, Sendable {
    public let windows: [WorkspaceWindowSession]
    public let focusedWindowIndex: Int
    public init(windows: [WorkspaceWindowSession], focusedWindowIndex: Int = 0) {
        let retained = windows.enumerated().filter { !$0.element.tabs.isEmpty }
        self.windows = retained.map(\.element)
        self.focusedWindowIndex = retained.firstIndex { $0.offset == focusedWindowIndex } ?? 0
    }
}

public final class WorkspaceSessionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "workspaceSessionV2") {
        self.defaults = defaults; self.key = key
    }

    /// An explicitly saved empty desktop must not revive an obsolete legacy session.
    public var hasSavedSession: Bool { defaults.object(forKey: key) != nil }

    public func save(_ workspaces: [SplitTabState]) throws {
        defaults.set(try JSONEncoder().encode(workspaces), forKey: key)
    }

    public func load() -> [SplitTabState] {
        loadEntries().map(\.workspace)
    }

    public func loadEntries() -> [(index: Int, workspace: SplitTabState)] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let entries = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else { return [] }
        return entries.enumerated().compactMap { index, entry in
            entry.workspace.map { (index, $0) }
        }
    }

    /// Keep the v2 flat array readable by earlier builds; group metadata is additive.
    public func saveDesktop(_ session: WorkspaceDesktopSession) throws {
        let entries = session.windows.enumerated().flatMap { windowIndex, window in
            let group = UUID()
            return window.tabs.enumerated().map { tabIndex, workspace in
                EncodedWorkspace(workspace: workspace, windowGroupID: group,
                    selectedInWindow: tabIndex == window.selectedIndex,
                    focusedTab: windowIndex == session.focusedWindowIndex && tabIndex == window.selectedIndex)
            }
        }
        defaults.set(try JSONEncoder().encode(entries), forKey: key)
    }

    public func loadDesktop(selectedFlatIndex: Int = -1) -> WorkspaceDesktopSession {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else {
            return WorkspaceDesktopSession(windows: [])
        }
        // Legacy entries share one group. Keep original indices while skipping damaged tabs.
        let legacyGroup = UUID()
        var groupIDs: [UUID] = []
        var groups: [[(index: Int, entry: SavedWorkspace)]] = []
        for (index, entry) in entries.enumerated() where entry.workspace != nil {
            let id = entry.windowGroupID ?? legacyGroup
            if let group = groupIDs.firstIndex(of: id) { groups[group].append((index, entry)) }
            else { groupIDs.append(id); groups.append([(index, entry)]) }
        }
        let explicitFocus = groups.firstIndex { $0.contains { $0.entry.focusedTab } }
        let legacyFocus = groups.firstIndex { $0.contains { $0.index == selectedFlatIndex } }
        let windows = groups.map { group in
            let selected = group.firstIndex { $0.entry.selectedInWindow }
                ?? group.firstIndex { $0.entry.focusedTab }
                ?? group.firstIndex { $0.index == selectedFlatIndex } ?? 0
            return WorkspaceWindowSession(tabs: group.compactMap { $0.entry.workspace }, selectedIndex: selected)
        }
        return WorkspaceDesktopSession(windows: windows, focusedWindowIndex: explicitFocus ?? legacyFocus ?? 0)
    }

    private struct EncodedWorkspace: Encodable {
        let workspace: SplitTabState
        let windowGroupID: UUID
        let selectedInWindow: Bool
        let focusedTab: Bool
        enum CodingKeys: String, CodingKey { case windowGroupID, selectedInWindow, focusedTab }
        func encode(to encoder: any Encoder) throws {
            try workspace.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(windowGroupID, forKey: .windowGroupID)
            try values.encode(selectedInWindow, forKey: .selectedInWindow)
            try values.encode(focusedTab, forKey: .focusedTab)
        }
    }

    private struct SavedWorkspace: Decodable {
        let workspace: SplitTabState?
        let windowGroupID: UUID?
        let selectedInWindow: Bool
        let focusedTab: Bool
        enum CodingKeys: String, CodingKey { case windowGroupID, selectedInWindow, focusedTab }
        init(from decoder: any Decoder) {
            workspace = try? SplitTabState(from: decoder)
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            windowGroupID = try? values?.decode(UUID.self, forKey: .windowGroupID)
            selectedInWindow = (try? values?.decode(Bool.self, forKey: .selectedInWindow)) ?? false
            focusedTab = (try? values?.decode(Bool.self, forKey: .focusedTab)) ?? false
        }
    }
}
