import Foundation

public enum BrowserViewSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
}
public enum BrowserAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}
public struct FolderViewPreference: Codable, Equatable, Sendable {
    public var mode: BrowserViewMode
    public var size: BrowserViewSize
    public init(mode: BrowserViewMode, size: BrowserViewSize) { self.mode = mode; self.size = size }
}
public enum BrowserToolbarItem: String, CaseIterable, Sendable {
    case back, forward, up, refresh, path, hidden, viewMode, favorite, options
    public var isRequired: Bool { self == .path }
}

/// A single main-actor store shared by all windows. Mutations notify synchronously,
/// so an older window cannot overwrite a newer window's favorites or history.
@MainActor
public final class BrowserPreferences {
    public static let shared = BrowserPreferences()
    private let defaults: UserDefaults
    private var observers: [UUID: () -> Void] = [:]
    public enum SidebarSection: String, CaseIterable, Sendable { case favorites, locations }
    public private(set) var sidebarOrder: [SidebarSection]
    public private(set) var collapsedSidebar: Set<SidebarSection>
    public private(set) var favorites: [URL]
    public private(set) var recent: [URL]
    public private(set) var showHidden: Bool
    public private(set) var showExtensions: Bool
    public private(set) var showHomeFavorites: Bool
    public private(set) var showHomeVolumes: Bool
    public private(set) var showHomeRecent: Bool
    public private(set) var viewSize: BrowserViewSize
    public private(set) var appearance: BrowserAppearance
    public private(set) var toolbarOrder: [BrowserToolbarItem]
    public private(set) var hiddenToolbarItems: Set<BrowserToolbarItem>
    public private(set) var folderViewPreferences: [String: FolderViewPreference]

    public init(defaults: UserDefaults = .standard, initialFavorites: [URL]? = nil) {
        self.defaults = defaults
        var order: [SidebarSection] = []
        for raw in defaults.stringArray(forKey: "sidebarOrder") ?? [] {
            if let section = SidebarSection(rawValue: raw), !order.contains(section) { order.append(section) }
        }
        sidebarOrder = order + SidebarSection.allCases.filter { !order.contains($0) }
        collapsedSidebar = Set((defaults.stringArray(forKey: "collapsedSidebar") ?? []).compactMap(SidebarSection.init(rawValue:)))
        let home = FileManager.default.homeDirectoryForCurrentUser
        favorites = (defaults.stringArray(forKey: "favorites")?.map { URL(fileURLWithPath: $0) }
            ?? initialFavorites ?? ["Downloads", "Documents", "Desktop"].map { home.appendingPathComponent($0) })
        recent = (defaults.stringArray(forKey: "recent") ?? []).map { URL(fileURLWithPath: $0) }
        showHidden = defaults.bool(forKey: "showHidden")
        showExtensions = defaults.object(forKey: "showExtensions") as? Bool ?? true
        showHomeFavorites = defaults.object(forKey: "showHomeFavorites") as? Bool ?? true
        showHomeVolumes = defaults.object(forKey: "showHomeVolumes") as? Bool ?? true
        showHomeRecent = defaults.object(forKey: "showHomeRecent") as? Bool ?? true
        viewSize = defaults.string(forKey: "viewSize").flatMap(BrowserViewSize.init(rawValue:)) ?? .medium
        appearance = defaults.string(forKey: "appearance").flatMap(BrowserAppearance.init(rawValue:)) ?? .system
        var toolbar: [BrowserToolbarItem] = []
        for raw in defaults.stringArray(forKey: "toolbarOrder") ?? [] {
            if let item = BrowserToolbarItem(rawValue: raw), !toolbar.contains(item) { toolbar.append(item) }
        }
        toolbarOrder = toolbar + BrowserToolbarItem.allCases.filter { !toolbar.contains($0) }
        hiddenToolbarItems = Set((defaults.stringArray(forKey: "hiddenToolbarItems") ?? []).compactMap(BrowserToolbarItem.init(rawValue:)).filter { !$0.isRequired })
        folderViewPreferences = (defaults.data(forKey: "folderViewPreferences").flatMap { try? JSONDecoder().decode([String: FolderViewPreference].self, from: $0) }) ?? [:]
    }
    @discardableResult public func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func changed() { for callback in Array(observers.values) { callback() } }
    public func toggleSidebar(_ section: SidebarSection) {
        if collapsedSidebar.contains(section) { collapsedSidebar.remove(section) }
        else { collapsedSidebar.insert(section) }
        defaults.set(collapsedSidebar.map(\.rawValue).sorted(), forKey: "collapsedSidebar"); changed()
    }
    public func moveSidebar(_ section: SidebarSection, by offset: Int) {
        guard let index = sidebarOrder.firstIndex(of: section), sidebarOrder.indices.contains(index + offset) else { return }
        sidebarOrder.swapAt(index, index + offset)
        defaults.set(sidebarOrder.map(\.rawValue), forKey: "sidebarOrder"); changed()
    }
    public func toggleFavorite(_ url: URL) {
        let url = url.standardizedFileURL
        if favorites.contains(url) { favorites.removeAll { $0 == url } }
        else { favorites.append(url) }
        defaults.set(favorites.map(\.path), forKey: "favorites"); changed()
    }
    public func moveFavorite(_ url: URL, by offset: Int) {
        guard let index = favorites.firstIndex(of: url), favorites.indices.contains(index + offset) else { return }
        favorites.swapAt(index, index + offset)
        defaults.set(favorites.map(\.path), forKey: "favorites"); changed()
    }
    public func recordVisit(_ url: URL) {
        let url = url.standardizedFileURL
        guard recent.first != url else { return }
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(10))
        defaults.set(recent.map(\.path), forKey: "recent"); changed()
    }
    public func clearRecent() {
        recent = []; defaults.set([], forKey: "recent"); changed()
    }
    public func setShowHidden(_ value: Bool) {
        showHidden = value; defaults.set(value, forKey: "showHidden"); changed()
    }
    public func setShowExtensions(_ value: Bool) {
        showExtensions = value; defaults.set(value, forKey: "showExtensions"); changed()
    }
    public func setViewSize(_ value: BrowserViewSize) {
        guard viewSize != value else { return }
        viewSize = value; defaults.set(value.rawValue, forKey: "viewSize"); changed()
    }
    public func setAppearance(_ value: BrowserAppearance) {
        guard appearance != value else { return }
        appearance = value; defaults.set(value.rawValue, forKey: "appearance"); changed()
    }
    public func folderViewPreference(for url: URL) -> FolderViewPreference? {
        folderViewPreferences[url.standardizedFileURL.path]
    }
    public func setFolderViewPreference(_ preference: FolderViewPreference, for url: URL) {
        folderViewPreferences[url.standardizedFileURL.path] = preference; saveFolderViewPreferences(); changed()
    }
    public func removeFolderViewPreference(for url: URL) {
        guard folderViewPreferences.removeValue(forKey: url.standardizedFileURL.path) != nil else { return }
        saveFolderViewPreferences(); changed()
    }
    public func resetFolderViewPreferences() {
        guard !folderViewPreferences.isEmpty else { return }
        folderViewPreferences = [:]; defaults.removeObject(forKey: "folderViewPreferences"); changed()
    }
    private func saveFolderViewPreferences() {
        if let data = try? JSONEncoder().encode(folderViewPreferences) { defaults.set(data, forKey: "folderViewPreferences") }
    }
    public func toggleToolbarItem(_ item: BrowserToolbarItem) {
        guard !item.isRequired else { return }
        if hiddenToolbarItems.contains(item) { hiddenToolbarItems.remove(item) } else { hiddenToolbarItems.insert(item) }
        defaults.set(hiddenToolbarItems.map(\.rawValue).sorted(), forKey: "hiddenToolbarItems"); changed()
    }
    public func moveToolbarItem(_ item: BrowserToolbarItem, by offset: Int) {
        guard let index = toolbarOrder.firstIndex(of: item), toolbarOrder.indices.contains(index + offset) else { return }
        toolbarOrder.swapAt(index, index + offset); defaults.set(toolbarOrder.map(\.rawValue), forKey: "toolbarOrder"); changed()
    }
    public func resetToolbar() {
        toolbarOrder = BrowserToolbarItem.allCases; hiddenToolbarItems = []
        defaults.removeObject(forKey: "toolbarOrder"); defaults.removeObject(forKey: "hiddenToolbarItems"); changed()
    }
    public enum HomeSection { case favorites, volumes, recent }
    public func toggleSection(_ section: HomeSection) {
        switch section {
        case .favorites: showHomeFavorites.toggle(); defaults.set(showHomeFavorites, forKey: "showHomeFavorites")
        case .volumes: showHomeVolumes.toggle(); defaults.set(showHomeVolumes, forKey: "showHomeVolumes")
        case .recent: showHomeRecent.toggle(); defaults.set(showHomeRecent, forKey: "showHomeRecent")
        }
        changed()
    }
}
