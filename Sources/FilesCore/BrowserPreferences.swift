import Foundation

public enum BrowserViewSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
}
public enum BrowserAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}
public enum BrowserSizeUnit: String, CaseIterable, Sendable { case binary, decimal }
public func formatByteCount(_ value: Int64, unit: BrowserSizeUnit) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: unit == .binary ? .binary : .file)
}
public func changesFileExtension(originalName: String, newName: String, isDirectory: Bool) -> Bool {
    guard !isDirectory else { return false }
    return (originalName as NSString).pathExtension.lowercased() != (newName as NSString).pathExtension.lowercased()
}
public struct FolderViewPreference: Codable, Equatable, Sendable {
    public var mode: BrowserViewMode
    public var size: BrowserViewSize
    public init(mode: BrowserViewMode, size: BrowserViewSize) { self.mode = mode; self.size = size }
}
public struct BrowserPreferencesArchive: Codable, Equatable, Sendable {
    public let version: Int
    public let sidebarOrder: [String]
    public let collapsedSidebar: [String]
    public let favorites: [String]
    public let recent: [String]
    public let showHidden: Bool
    public let showExtensions: Bool
    public let showToolbar: Bool
    public let showStatusBar: Bool
    public let showSidebar: Bool?
    public let showDateColumn: Bool?
    public let showTypeColumn: Bool?
    public let showSizeColumn: Bool?
    public let showGitStatusColumn: Bool?
    public let showCompressionOptions: Bool?
    public let showOpenTerminal: Bool?
    public let showCreateFolderWithSelection: Bool?
    public let showPinToSidebar: Bool?
    public let showHomeFavorites: Bool
    public let showHomeVolumes: Bool
    public let showHomeRecent: Bool
    public let viewSize: String
    public let appearance: String
    public let continueLastSession: Bool
    public let sizeUnit: String?
    public let openFoldersInNewTab: Bool?
    public let scrollToPreviousFolderOnUp: Bool?
    public let showFileExtensionWarning: Bool?
    public let startupLocationPath: String?
    public let developerApplicationPath: String?
    public let toolbarOrder: [String]
    public let hiddenToolbarItems: [String]
    public let folderViewPreferences: [String: FolderViewPreference]
}
public enum BrowserPreferencesArchiveError: Error, Equatable { case unsupportedVersion, invalidValue }
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
    public private(set) var showToolbar: Bool
    public private(set) var showStatusBar: Bool
    public private(set) var showSidebar: Bool
    public private(set) var showDateColumn: Bool
    public private(set) var showTypeColumn: Bool
    public private(set) var showSizeColumn: Bool
    public private(set) var showGitStatusColumn: Bool
    public private(set) var showCompressionOptions: Bool
    public private(set) var showOpenTerminal: Bool
    public private(set) var showCreateFolderWithSelection: Bool
    public private(set) var showPinToSidebar: Bool
    public private(set) var showHomeFavorites: Bool
    public private(set) var showHomeVolumes: Bool
    public private(set) var showHomeRecent: Bool
    public private(set) var viewSize: BrowserViewSize
    public private(set) var appearance: BrowserAppearance
    public private(set) var continueLastSession: Bool
    public private(set) var sizeUnit: BrowserSizeUnit
    public private(set) var openFoldersInNewTab: Bool
    public private(set) var scrollToPreviousFolderOnUp: Bool
    public private(set) var showFileExtensionWarning: Bool
    public private(set) var startupLocationPath: String?
    public private(set) var developerApplicationPath: String?
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
        showToolbar = defaults.object(forKey: "showToolbar") as? Bool ?? true
        showStatusBar = defaults.object(forKey: "showStatusBar") as? Bool ?? true
        showSidebar = defaults.object(forKey: "showSidebar") as? Bool ?? true
        showDateColumn = defaults.object(forKey: "showDateColumn") as? Bool ?? true
        showTypeColumn = defaults.object(forKey: "showTypeColumn") as? Bool ?? true
        showSizeColumn = defaults.object(forKey: "showSizeColumn") as? Bool ?? true
        showGitStatusColumn = defaults.object(forKey: "showGitStatusColumn") as? Bool ?? false
        showCompressionOptions = defaults.object(forKey: "showCompressionOptions") as? Bool ?? true
        showOpenTerminal = defaults.object(forKey: "showOpenTerminal") as? Bool ?? true
        showCreateFolderWithSelection = defaults.object(forKey: "showCreateFolderWithSelection") as? Bool ?? true
        showPinToSidebar = defaults.object(forKey: "showPinToSidebar") as? Bool ?? true
        showHomeFavorites = defaults.object(forKey: "showHomeFavorites") as? Bool ?? true
        showHomeVolumes = defaults.object(forKey: "showHomeVolumes") as? Bool ?? true
        showHomeRecent = defaults.object(forKey: "showHomeRecent") as? Bool ?? true
        viewSize = defaults.string(forKey: "viewSize").flatMap(BrowserViewSize.init(rawValue:)) ?? .medium
        appearance = defaults.string(forKey: "appearance").flatMap(BrowserAppearance.init(rawValue:)) ?? .system
        continueLastSession = defaults.object(forKey: "continueLastSession") as? Bool ?? true
        sizeUnit = defaults.string(forKey: "sizeUnit").flatMap(BrowserSizeUnit.init(rawValue:)) ?? .binary
        openFoldersInNewTab = defaults.bool(forKey: "openFoldersInNewTab")
        scrollToPreviousFolderOnUp = defaults.object(forKey: "scrollToPreviousFolderOnUp") as? Bool ?? true
        showFileExtensionWarning = defaults.object(forKey: "showFileExtensionWarning") as? Bool ?? true
        startupLocationPath = defaults.string(forKey: "startupLocationPath").flatMap { $0.hasPrefix("/") ? $0 : nil }
        developerApplicationPath = defaults.string(forKey: "developerApplicationPath")
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
    public func setShowToolbar(_ value: Bool) {
        guard showToolbar != value else { return }
        showToolbar = value; defaults.set(value, forKey: "showToolbar"); changed()
    }
    public func setShowStatusBar(_ value: Bool) {
        guard showStatusBar != value else { return }
        showStatusBar = value; defaults.set(value, forKey: "showStatusBar"); changed()
    }
    public func setShowSidebar(_ value: Bool) {
        guard showSidebar != value else { return }
        showSidebar = value; defaults.set(value, forKey: "showSidebar"); changed()
    }
    public func setShowDateColumn(_ value: Bool) { guard showDateColumn != value else { return }; showDateColumn = value; defaults.set(value, forKey: "showDateColumn"); changed() }
    public func setShowTypeColumn(_ value: Bool) { guard showTypeColumn != value else { return }; showTypeColumn = value; defaults.set(value, forKey: "showTypeColumn"); changed() }
    public func setShowSizeColumn(_ value: Bool) { guard showSizeColumn != value else { return }; showSizeColumn = value; defaults.set(value, forKey: "showSizeColumn"); changed() }
    public func setShowGitStatusColumn(_ value: Bool) { guard showGitStatusColumn != value else { return }; showGitStatusColumn = value; defaults.set(value, forKey: "showGitStatusColumn"); changed() }
    public func setShowCompressionOptions(_ value: Bool) { guard showCompressionOptions != value else { return }; showCompressionOptions = value; defaults.set(value, forKey: "showCompressionOptions"); changed() }
    public func setShowOpenTerminal(_ value: Bool) { guard showOpenTerminal != value else { return }; showOpenTerminal = value; defaults.set(value, forKey: "showOpenTerminal"); changed() }
    public func setShowCreateFolderWithSelection(_ value: Bool) { guard showCreateFolderWithSelection != value else { return }; showCreateFolderWithSelection = value; defaults.set(value, forKey: "showCreateFolderWithSelection"); changed() }
    public func setShowPinToSidebar(_ value: Bool) { guard showPinToSidebar != value else { return }; showPinToSidebar = value; defaults.set(value, forKey: "showPinToSidebar"); changed() }
    public func setViewSize(_ value: BrowserViewSize) {
        guard viewSize != value else { return }
        viewSize = value; defaults.set(value.rawValue, forKey: "viewSize"); changed()
    }
    public func setAppearance(_ value: BrowserAppearance) {
        guard appearance != value else { return }
        appearance = value; defaults.set(value.rawValue, forKey: "appearance"); changed()
    }
    public func setContinueLastSession(_ value: Bool) {
        guard continueLastSession != value else { return }
        continueLastSession = value; defaults.set(value, forKey: "continueLastSession"); changed()
    }
    public func setSizeUnit(_ value: BrowserSizeUnit) {
        guard sizeUnit != value else { return }
        sizeUnit = value; defaults.set(value.rawValue, forKey: "sizeUnit"); changed()
    }
    public func setOpenFoldersInNewTab(_ value: Bool) {
        guard openFoldersInNewTab != value else { return }
        openFoldersInNewTab = value; defaults.set(value, forKey: "openFoldersInNewTab"); changed()
    }
    public func setScrollToPreviousFolderOnUp(_ value: Bool) {
        guard scrollToPreviousFolderOnUp != value else { return }
        scrollToPreviousFolderOnUp = value; defaults.set(value, forKey: "scrollToPreviousFolderOnUp"); changed()
    }
    public func setShowFileExtensionWarning(_ value: Bool) {
        guard showFileExtensionWarning != value else { return }
        showFileExtensionWarning = value; defaults.set(value, forKey: "showFileExtensionWarning"); changed()
    }
    public func setStartupLocation(_ url: URL?) {
        let value = url?.standardizedFileURL.path
        guard startupLocationPath != value else { return }
        startupLocationPath = value
        if let value { defaults.set(value, forKey: "startupLocationPath") } else { defaults.removeObject(forKey: "startupLocationPath") }
        changed()
    }
    public func setDeveloperApplication(_ url: URL?) {
        let value = url?.standardizedFileURL.path
        guard developerApplicationPath != value else { return }
        developerApplicationPath = value
        if let value { defaults.set(value, forKey: "developerApplicationPath") }
        else { defaults.removeObject(forKey: "developerApplicationPath") }
        changed()
    }
    public func exportData() throws -> Data {
        let archive = BrowserPreferencesArchive(version: 1, sidebarOrder: sidebarOrder.map(\.rawValue),
            collapsedSidebar: collapsedSidebar.map(\.rawValue).sorted(), favorites: favorites.map(\.path), recent: recent.map(\.path),
            showHidden: showHidden, showExtensions: showExtensions, showToolbar: showToolbar, showStatusBar: showStatusBar, showSidebar: showSidebar,
            showDateColumn: showDateColumn, showTypeColumn: showTypeColumn, showSizeColumn: showSizeColumn, showGitStatusColumn: showGitStatusColumn,
            showCompressionOptions: showCompressionOptions, showOpenTerminal: showOpenTerminal, showCreateFolderWithSelection: showCreateFolderWithSelection,
            showPinToSidebar: showPinToSidebar,
            showHomeFavorites: showHomeFavorites, showHomeVolumes: showHomeVolumes, showHomeRecent: showHomeRecent,
            viewSize: viewSize.rawValue, appearance: appearance.rawValue, continueLastSession: continueLastSession, sizeUnit: sizeUnit.rawValue,
            openFoldersInNewTab: openFoldersInNewTab, scrollToPreviousFolderOnUp: scrollToPreviousFolderOnUp,
            showFileExtensionWarning: showFileExtensionWarning,
            startupLocationPath: startupLocationPath, developerApplicationPath: developerApplicationPath, toolbarOrder: toolbarOrder.map(\.rawValue),
            hiddenToolbarItems: hiddenToolbarItems.map(\.rawValue).sorted(), folderViewPreferences: folderViewPreferences)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }
    public func importData(_ data: Data) throws {
        let archive = try JSONDecoder().decode(BrowserPreferencesArchive.self, from: data)
        guard archive.version == 1 else { throw BrowserPreferencesArchiveError.unsupportedVersion }
        guard let size = BrowserViewSize(rawValue: archive.viewSize), let importedAppearance = BrowserAppearance(rawValue: archive.appearance) else { throw BrowserPreferencesArchiveError.invalidValue }
        let importedSizeUnit: BrowserSizeUnit
        if let raw = archive.sizeUnit {
            guard let value = BrowserSizeUnit(rawValue: raw) else { throw BrowserPreferencesArchiveError.invalidValue }
            importedSizeUnit = value
        } else { importedSizeUnit = .binary }
        let importedSidebar = archive.sidebarOrder.compactMap(SidebarSection.init(rawValue:))
        let importedToolbar = archive.toolbarOrder.compactMap(BrowserToolbarItem.init(rawValue:))
        guard importedSidebar.count == archive.sidebarOrder.count, Set(importedSidebar).count == SidebarSection.allCases.count,
              Set(importedSidebar) == Set(SidebarSection.allCases), importedToolbar.count == archive.toolbarOrder.count,
              Set(importedToolbar).count == BrowserToolbarItem.allCases.count, Set(importedToolbar) == Set(BrowserToolbarItem.allCases) else { throw BrowserPreferencesArchiveError.invalidValue }
        let importedCollapsed = archive.collapsedSidebar.compactMap(SidebarSection.init(rawValue:))
        let importedHiddenToolbar = archive.hiddenToolbarItems.compactMap(BrowserToolbarItem.init(rawValue:))
        guard importedCollapsed.count == archive.collapsedSidebar.count, importedHiddenToolbar.count == archive.hiddenToolbarItems.count,
              Set(importedCollapsed).count == importedCollapsed.count, Set(importedHiddenToolbar).count == importedHiddenToolbar.count,
              !importedHiddenToolbar.contains(where: { $0.isRequired }), archive.favorites.allSatisfy({ $0.hasPrefix("/") }),
              archive.recent.allSatisfy({ $0.hasPrefix("/") }), archive.folderViewPreferences.keys.allSatisfy({ $0.hasPrefix("/") }) else { throw BrowserPreferencesArchiveError.invalidValue }
        if let developerApplicationPath = archive.developerApplicationPath, !developerApplicationPath.hasPrefix("/") {
            throw BrowserPreferencesArchiveError.invalidValue
        }
        if let startupLocationPath = archive.startupLocationPath, !startupLocationPath.hasPrefix("/") {
            throw BrowserPreferencesArchiveError.invalidValue
        }
        sidebarOrder = importedSidebar; collapsedSidebar = Set(importedCollapsed)
        favorites = archive.favorites.map { URL(fileURLWithPath: $0) }; recent = archive.recent.map { URL(fileURLWithPath: $0) }
        showHidden = archive.showHidden; showExtensions = archive.showExtensions; showToolbar = archive.showToolbar; showStatusBar = archive.showStatusBar; showSidebar = archive.showSidebar ?? true
        showDateColumn = archive.showDateColumn ?? true; showTypeColumn = archive.showTypeColumn ?? true
        showSizeColumn = archive.showSizeColumn ?? true; showGitStatusColumn = archive.showGitStatusColumn ?? false
        showCompressionOptions = archive.showCompressionOptions ?? true; showOpenTerminal = archive.showOpenTerminal ?? true
        showCreateFolderWithSelection = archive.showCreateFolderWithSelection ?? true
        showPinToSidebar = archive.showPinToSidebar ?? true
        showHomeFavorites = archive.showHomeFavorites; showHomeVolumes = archive.showHomeVolumes; showHomeRecent = archive.showHomeRecent
        viewSize = size; appearance = importedAppearance; continueLastSession = archive.continueLastSession; sizeUnit = importedSizeUnit
        openFoldersInNewTab = archive.openFoldersInNewTab ?? false; scrollToPreviousFolderOnUp = archive.scrollToPreviousFolderOnUp ?? true
        showFileExtensionWarning = archive.showFileExtensionWarning ?? true; startupLocationPath = archive.startupLocationPath
        developerApplicationPath = archive.developerApplicationPath; toolbarOrder = importedToolbar; hiddenToolbarItems = Set(importedHiddenToolbar)
        folderViewPreferences = archive.folderViewPreferences
        defaults.set(sidebarOrder.map(\.rawValue), forKey: "sidebarOrder"); defaults.set(collapsedSidebar.map(\.rawValue).sorted(), forKey: "collapsedSidebar")
        defaults.set(favorites.map(\.path), forKey: "favorites"); defaults.set(recent.map(\.path), forKey: "recent")
        defaults.set(showHidden, forKey: "showHidden"); defaults.set(showExtensions, forKey: "showExtensions")
        defaults.set(showToolbar, forKey: "showToolbar"); defaults.set(showStatusBar, forKey: "showStatusBar"); defaults.set(showSidebar, forKey: "showSidebar")
        defaults.set(showDateColumn, forKey: "showDateColumn"); defaults.set(showTypeColumn, forKey: "showTypeColumn")
        defaults.set(showSizeColumn, forKey: "showSizeColumn"); defaults.set(showGitStatusColumn, forKey: "showGitStatusColumn")
        defaults.set(showCompressionOptions, forKey: "showCompressionOptions"); defaults.set(showOpenTerminal, forKey: "showOpenTerminal")
        defaults.set(showCreateFolderWithSelection, forKey: "showCreateFolderWithSelection")
        defaults.set(showPinToSidebar, forKey: "showPinToSidebar")
        defaults.set(showHomeFavorites, forKey: "showHomeFavorites"); defaults.set(showHomeVolumes, forKey: "showHomeVolumes"); defaults.set(showHomeRecent, forKey: "showHomeRecent")
        defaults.set(viewSize.rawValue, forKey: "viewSize"); defaults.set(appearance.rawValue, forKey: "appearance"); defaults.set(continueLastSession, forKey: "continueLastSession"); defaults.set(sizeUnit.rawValue, forKey: "sizeUnit")
        defaults.set(openFoldersInNewTab, forKey: "openFoldersInNewTab"); defaults.set(scrollToPreviousFolderOnUp, forKey: "scrollToPreviousFolderOnUp"); defaults.set(showFileExtensionWarning, forKey: "showFileExtensionWarning")
        if let startupLocationPath { defaults.set(startupLocationPath, forKey: "startupLocationPath") } else { defaults.removeObject(forKey: "startupLocationPath") }
        if let developerApplicationPath { defaults.set(developerApplicationPath, forKey: "developerApplicationPath") } else { defaults.removeObject(forKey: "developerApplicationPath") }
        defaults.set(toolbarOrder.map(\.rawValue), forKey: "toolbarOrder"); defaults.set(hiddenToolbarItems.map(\.rawValue).sorted(), forKey: "hiddenToolbarItems")
        saveFolderViewPreferences(); changed()
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
    public func setSection(_ section: HomeSection, visible: Bool) {
        let current: Bool
        switch section {
        case .favorites: current = showHomeFavorites
        case .volumes: current = showHomeVolumes
        case .recent: current = showHomeRecent
        }
        guard current != visible else { return }
        toggleSection(section)
    }
    public func toggleSection(_ section: HomeSection) {
        switch section {
        case .favorites: showHomeFavorites.toggle(); defaults.set(showHomeFavorites, forKey: "showHomeFavorites")
        case .volumes: showHomeVolumes.toggle(); defaults.set(showHomeVolumes, forKey: "showHomeVolumes")
        case .recent: showHomeRecent.toggle(); defaults.set(showHomeRecent, forKey: "showHomeRecent")
        }
        changed()
    }
}
