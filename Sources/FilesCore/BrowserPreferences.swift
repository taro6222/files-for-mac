import Foundation

public enum BrowserViewSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
}
public enum BrowserAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}
public enum BrowserSizeUnit: String, CaseIterable, Sendable { case binary, decimal }
public enum AppBackgroundFit: String, CaseIterable, Codable, Sendable { case fill, fit, stretch }
public enum AppBackgroundHorizontalAlignment: String, CaseIterable, Codable, Sendable { case leading, center, trailing }
public enum AppBackgroundVerticalAlignment: String, CaseIterable, Codable, Sendable { case bottom, center, top }
public func formatByteCount(_ value: Int64, unit: BrowserSizeUnit) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: unit == .binary ? .binary : .file)
}
public func changesFileExtension(originalName: String, newName: String, isDirectory: Bool) -> Bool {
    guard !isDirectory else { return false }
    return (originalName as NSString).pathExtension.lowercased() != (newName as NSString).pathExtension.lowercased()
}
public func formatCopiedPaths(_ urls: [URL], quoted: Bool) -> String {
    urls.map { url in
        let path = url.standardizedFileURL.path
        guard quoted else { return path }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }.joined(separator: "\n")
}
public struct FolderViewPreference: Codable, Equatable, Sendable {
    public var mode: BrowserViewMode
    public var size: BrowserViewSize
    public init(mode: BrowserViewMode, size: BrowserViewSize) { self.mode = mode; self.size = size }
}
public struct SharedFolderLayout: Codable, Equatable, Sendable {
    public var mode: BrowserViewMode
    public var size: BrowserViewSize
    public var sort: SortOrder
    public var grouping: FileGroupOptions

    public init(mode: BrowserViewMode, size: BrowserViewSize, sort: SortOrder, grouping: FileGroupOptions) {
        self.mode = mode
        self.size = size
        self.sort = sort
        self.grouping = grouping
    }
}
public enum InfoPaneTab: String, Codable, Sendable { case details, preview }

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
    public let showCreatedColumn: Bool?
    public let showDateColumn: Bool?
    public let showTypeColumn: Bool?
    public let showSizeColumn: Bool?
    public let showGitStatusColumn: Bool?
    public let showGitCommitDateColumn: Bool?
    public let showGitCommitMessageColumn: Bool?
    public let showGitCommitAuthorColumn: Bool?
    public let showGitCommitSHAColumn: Bool?
    public let showSyncStatusColumn: Bool?
    public let showFileTagColumn: Bool?
    public let showPathColumn: Bool?
    public let showCompressionOptions: Bool?
    public let showFlattenOptions: Bool?
    public let showOpenTerminal: Bool?
    public let showCreateFolderWithSelection: Bool?
    public let showPinToSidebar: Bool?
    public let showSendToMenu: Bool?
    public let showCopyPath: Bool?
    public let showOpenInNewTab: Bool?
    public let showOpenInNewWindow: Bool?
    public let showOpenInNewPane: Bool?
    public let showEditTagsMenu: Bool?
    public let showCreateShortcut: Bool?
    public let showHomeFavorites: Bool
    public let showHomeVolumes: Bool
    public let showHomeRecent: Bool
    public let homeFavoritesExpanded: Bool?
    public let homeVolumesExpanded: Bool?
    public let homeRecentExpanded: Bool?
    public let viewSize: String
    public let syncFolderLayouts: Bool?
    public let showInfoPane: Bool?
    public let infoPaneTab: String?
    public let sharedFolderLayout: SharedFolderLayout?
    public let appearance: String
    public let continueLastSession: Bool
    public let sizeUnit: String?
    public let openFoldersInNewTab: Bool?
    public let scrollToPreviousFolderOnUp: Bool?
    public let showFileExtensionWarning: Bool?
    public let defaultSortDirectoryPlacement: String?
    public let autoSizeColumnsInDetailsLayout: Bool?
    public let openNewTabOnStartup: Bool?
    public let lastSessionSelectedTabIndex: Int?
    public let alwaysOpenDualPaneInNewTab: Bool?
    public let alwaysSwitchToNewlyOpenedTab: Bool?
    public let calculateFolderSizes: Bool?
    public let enableThumbnailCache: Bool?
    public let thumbnailCacheLimitMiB: Int?
    public let showThumbnails: Bool?
    public let doubleClickToGoUp: Bool?
    public let reverseTabScrollDirection: Bool?
    public let showFilterHeader: Bool?
    public let showShelfPane: Bool?
    public let showShelfToggle: Bool?
    public let startupLocationPath: String?
    public let developerApplicationPath: String?
    public let appBackgroundPath: String?
    public let appBackgroundFit: String?
    public let appBackgroundOpacity: Double?
    public let appBackgroundHorizontalAlignment: String?
    public let appBackgroundVerticalAlignment: String?
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
    private var observers: [UUID: (includesRecentLocations: Bool, callback: () -> Void)] = [:]
    private var recentLocationObservers: [UUID: () -> Void] = [:]
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
    public private(set) var showCreatedColumn: Bool
    public private(set) var showDateColumn: Bool
    public private(set) var showTypeColumn: Bool
    public private(set) var showSizeColumn: Bool
    public private(set) var showGitStatusColumn: Bool
    public private(set) var showGitCommitDateColumn: Bool
    public private(set) var showGitCommitMessageColumn: Bool
    public private(set) var showGitCommitAuthorColumn: Bool
    public private(set) var showGitCommitSHAColumn: Bool
    public private(set) var showSyncStatusColumn: Bool
    public private(set) var showFileTagColumn: Bool
    public private(set) var showPathColumn: Bool
    public private(set) var showCompressionOptions: Bool
    public private(set) var showFlattenOptions: Bool
    public private(set) var showOpenTerminal: Bool
    public private(set) var showCreateFolderWithSelection: Bool
    public private(set) var showPinToSidebar: Bool
    public private(set) var showSendToMenu: Bool
    public private(set) var showCopyPath: Bool
    public private(set) var showOpenInNewTab: Bool
    public private(set) var showOpenInNewWindow: Bool
    public private(set) var showOpenInNewPane: Bool
    public private(set) var showEditTagsMenu: Bool
    public private(set) var showCreateShortcut: Bool
    public private(set) var showHomeFavorites: Bool
    public private(set) var showHomeVolumes: Bool
    public private(set) var showHomeRecent: Bool
    public private(set) var homeFavoritesExpanded: Bool
    public private(set) var homeVolumesExpanded: Bool
    public private(set) var homeRecentExpanded: Bool
    public private(set) var viewSize: BrowserViewSize
    public private(set) var syncFolderLayouts: Bool
    public private(set) var showInfoPane: Bool
    public private(set) var infoPaneTab: InfoPaneTab
    public private(set) var sharedFolderLayout: SharedFolderLayout?
    public private(set) var appearance: BrowserAppearance
    public private(set) var continueLastSession: Bool
    public private(set) var sizeUnit: BrowserSizeUnit
    public private(set) var openFoldersInNewTab: Bool
    public private(set) var scrollToPreviousFolderOnUp: Bool
    public private(set) var showFileExtensionWarning: Bool
    public private(set) var defaultSortDirectoryPlacement: SortDirectoryPlacement
    public private(set) var autoSizeColumnsInDetailsLayout: Bool
    public private(set) var openNewTabOnStartup: Bool
    public private(set) var lastSessionSelectedTabIndex: Int
    public private(set) var alwaysOpenDualPaneInNewTab: Bool
    public private(set) var alwaysSwitchToNewlyOpenedTab: Bool
    public private(set) var calculateFolderSizes: Bool
    public static let thumbnailCacheLimits = [8, 16, 32, 64, 128, 256, 512]
    public static let defaultThumbnailCacheLimitMiB = 32
    public private(set) var enableThumbnailCache: Bool
    public private(set) var thumbnailCacheLimitMiB: Int
    public private(set) var showThumbnails: Bool
    public private(set) var doubleClickToGoUp: Bool
    public private(set) var reverseTabScrollDirection: Bool
    public private(set) var showFilterHeader: Bool
    public private(set) var showShelfPane: Bool
    public private(set) var showShelfToggle: Bool
    public private(set) var shelfEntries: [ShelfEntry] = []
    public private(set) var startupLocationPath: String?
    public private(set) var developerApplicationPath: String?
    public private(set) var appBackgroundPath: String?
    public private(set) var appBackgroundFit: AppBackgroundFit
    public private(set) var appBackgroundOpacity: Double
    public private(set) var appBackgroundHorizontalAlignment: AppBackgroundHorizontalAlignment
    public private(set) var appBackgroundVerticalAlignment: AppBackgroundVerticalAlignment
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
        showCreatedColumn = defaults.object(forKey: "showCreatedColumn") as? Bool ?? false
        showDateColumn = defaults.object(forKey: "showDateColumn") as? Bool ?? true
        showTypeColumn = defaults.object(forKey: "showTypeColumn") as? Bool ?? true
        showSizeColumn = defaults.object(forKey: "showSizeColumn") as? Bool ?? true
        showGitStatusColumn = defaults.object(forKey: "showGitStatusColumn") as? Bool ?? false
        showGitCommitDateColumn = defaults.bool(forKey: "showGitCommitDateColumn")
        showGitCommitMessageColumn = defaults.bool(forKey: "showGitCommitMessageColumn")
        showGitCommitAuthorColumn = defaults.bool(forKey: "showGitCommitAuthorColumn")
        showGitCommitSHAColumn = defaults.bool(forKey: "showGitCommitSHAColumn")
        showSyncStatusColumn = defaults.bool(forKey: "showSyncStatusColumn")
        showFileTagColumn = defaults.object(forKey: "showFileTagColumn") as? Bool ?? false
        showPathColumn = defaults.object(forKey: "showPathColumn") as? Bool ?? false
        showCompressionOptions = defaults.object(forKey: "showCompressionOptions") as? Bool ?? true
        showFlattenOptions = defaults.bool(forKey: "showFlattenOptions")
        showOpenTerminal = defaults.object(forKey: "showOpenTerminal") as? Bool ?? true
        showCreateFolderWithSelection = defaults.object(forKey: "showCreateFolderWithSelection") as? Bool ?? true
        showPinToSidebar = defaults.object(forKey: "showPinToSidebar") as? Bool ?? true
        showSendToMenu = defaults.object(forKey: "showSendToMenu") as? Bool ?? true
        showCopyPath = defaults.object(forKey: "showCopyPath") as? Bool ?? true
        showOpenInNewTab = defaults.object(forKey: "showOpenInNewTab") as? Bool ?? true
        showOpenInNewWindow = defaults.object(forKey: "showOpenInNewWindow") as? Bool ?? true
        showOpenInNewPane = defaults.object(forKey: "showOpenInNewPane") as? Bool ?? true
        showEditTagsMenu = defaults.object(forKey: "showEditTagsMenu") as? Bool ?? true
        showCreateShortcut = defaults.object(forKey: "showCreateShortcut") as? Bool ?? true
        showHomeFavorites = defaults.object(forKey: "showHomeFavorites") as? Bool ?? true
        showHomeVolumes = defaults.object(forKey: "showHomeVolumes") as? Bool ?? true
        showHomeRecent = defaults.object(forKey: "showHomeRecent") as? Bool ?? true
        homeFavoritesExpanded = defaults.object(forKey: "homeFavoritesExpanded") as? Bool ?? true
        homeVolumesExpanded = defaults.object(forKey: "homeVolumesExpanded") as? Bool ?? true
        homeRecentExpanded = defaults.object(forKey: "homeRecentExpanded") as? Bool ?? true
        viewSize = defaults.string(forKey: "viewSize").flatMap(BrowserViewSize.init(rawValue:)) ?? .medium
        sharedFolderLayout = defaults.data(forKey: "sharedFolderLayout").flatMap {
            try? JSONDecoder().decode(SharedFolderLayout.self, from: $0)
        }
        syncFolderLayouts = defaults.bool(forKey: "syncFolderLayouts") && sharedFolderLayout != nil
        showInfoPane = defaults.bool(forKey: "showInfoPane")
        infoPaneTab = defaults.string(forKey: "infoPaneTab").flatMap(InfoPaneTab.init(rawValue:)) ?? .details
        appearance = defaults.string(forKey: "appearance").flatMap(BrowserAppearance.init(rawValue:)) ?? .system
        continueLastSession = defaults.object(forKey: "continueLastSession") as? Bool ?? true
        sizeUnit = defaults.string(forKey: "sizeUnit").flatMap(BrowserSizeUnit.init(rawValue:)) ?? .binary
        openFoldersInNewTab = defaults.bool(forKey: "openFoldersInNewTab")
        scrollToPreviousFolderOnUp = defaults.object(forKey: "scrollToPreviousFolderOnUp") as? Bool ?? true
        showFileExtensionWarning = defaults.object(forKey: "showFileExtensionWarning") as? Bool ?? true
        defaultSortDirectoryPlacement = defaults.string(forKey: "defaultSortDirectoryPlacement").flatMap(SortDirectoryPlacement.init(rawValue:)) ?? .foldersFirst
        autoSizeColumnsInDetailsLayout = defaults.object(forKey: "autoSizeColumnsInDetailsLayout") as? Bool ?? false
        openNewTabOnStartup = defaults.object(forKey: "openNewTabOnStartup") as? Bool ?? false
        lastSessionSelectedTabIndex = max(-1, defaults.object(forKey: "lastSessionSelectedTabIndex") as? Int ?? -1)
        alwaysOpenDualPaneInNewTab = defaults.object(forKey: "alwaysOpenDualPaneInNewTab") as? Bool ?? false
        alwaysSwitchToNewlyOpenedTab = defaults.object(forKey: "alwaysSwitchToNewlyOpenedTab") as? Bool ?? false
        calculateFolderSizes = defaults.object(forKey: "calculateFolderSizes") as? Bool ?? false
        enableThumbnailCache = defaults.object(forKey: "enableThumbnailCache") as? Bool ?? true
        let cacheLimit = defaults.integer(forKey: "thumbnailCacheLimitMiB")
        thumbnailCacheLimitMiB = Self.thumbnailCacheLimits.contains(cacheLimit) ? cacheLimit : Self.defaultThumbnailCacheLimitMiB
        showThumbnails = defaults.object(forKey: "showThumbnails") as? Bool ?? true
        doubleClickToGoUp = defaults.object(forKey: "doubleClickToGoUp") as? Bool ?? true
        reverseTabScrollDirection = defaults.object(forKey: "reverseTabScrollDirection") as? Bool ?? false
        showFilterHeader = defaults.object(forKey: "showFilterHeader") as? Bool ?? false
        showShelfPane = defaults.bool(forKey: "showShelfPane")
        showShelfToggle = defaults.bool(forKey: "showShelfToggle")
        startupLocationPath = defaults.string(forKey: "startupLocationPath").flatMap { $0.hasPrefix("/") ? $0 : nil }
        developerApplicationPath = defaults.string(forKey: "developerApplicationPath")
        appBackgroundPath = defaults.string(forKey: "appBackgroundPath").flatMap { $0.hasPrefix("/") ? $0 : nil }
        appBackgroundFit = defaults.string(forKey: "appBackgroundFit").flatMap(AppBackgroundFit.init(rawValue:)) ?? .fill
        appBackgroundOpacity = min(1, max(0, defaults.object(forKey: "appBackgroundOpacity") as? Double ?? 1))
        appBackgroundHorizontalAlignment = defaults.string(forKey: "appBackgroundHorizontalAlignment").flatMap(AppBackgroundHorizontalAlignment.init(rawValue:)) ?? .center
        appBackgroundVerticalAlignment = defaults.string(forKey: "appBackgroundVerticalAlignment").flatMap(AppBackgroundVerticalAlignment.init(rawValue:)) ?? .center
        var toolbar: [BrowserToolbarItem] = []
        for raw in defaults.stringArray(forKey: "toolbarOrder") ?? [] {
            if let item = BrowserToolbarItem(rawValue: raw), !toolbar.contains(item) { toolbar.append(item) }
        }
        toolbarOrder = toolbar + BrowserToolbarItem.allCases.filter { !toolbar.contains($0) }
        hiddenToolbarItems = Set((defaults.stringArray(forKey: "hiddenToolbarItems") ?? []).compactMap(BrowserToolbarItem.init(rawValue:)).filter { !$0.isRequired })
        folderViewPreferences = (defaults.data(forKey: "folderViewPreferences").flatMap { try? JSONDecoder().decode([String: FolderViewPreference].self, from: $0) }) ?? [:]
    }
    @discardableResult public func observe(_ callback: @escaping () -> Void) -> UUID {
        observe(includesRecentLocations: true, callback)
    }
    @discardableResult public func observe(includesRecentLocations: Bool, _ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = (includesRecentLocations, callback)
        return id
    }
    @discardableResult public func observeRecentLocations(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        recentLocationObservers[id] = callback
        return id
    }
    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        recentLocationObservers.removeValue(forKey: id)
    }
    private func changed() {
        for observer in Array(observers.values) { observer.callback() }
    }
    private func recentLocationsChanged() {
        for observer in Array(observers.values) where observer.includesRecentLocations { observer.callback() }
        for callback in Array(recentLocationObservers.values) { callback() }
    }
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
        defaults.set(recent.map(\.path), forKey: "recent"); recentLocationsChanged()
    }
    public func clearRecent() {
        recent = []; defaults.set([], forKey: "recent"); recentLocationsChanged()
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
    public func setShowCreatedColumn(_ value: Bool) { guard showCreatedColumn != value else { return }; showCreatedColumn = value; defaults.set(value, forKey: "showCreatedColumn"); changed() }
    public func setShowDateColumn(_ value: Bool) { guard showDateColumn != value else { return }; showDateColumn = value; defaults.set(value, forKey: "showDateColumn"); changed() }
    public func setShowTypeColumn(_ value: Bool) { guard showTypeColumn != value else { return }; showTypeColumn = value; defaults.set(value, forKey: "showTypeColumn"); changed() }
    public func setShowSizeColumn(_ value: Bool) { guard showSizeColumn != value else { return }; showSizeColumn = value; defaults.set(value, forKey: "showSizeColumn"); changed() }
    public func setShowGitStatusColumn(_ value: Bool) { guard showGitStatusColumn != value else { return }; showGitStatusColumn = value; defaults.set(value, forKey: "showGitStatusColumn"); changed() }
    public func setShowGitCommitDateColumn(_ value: Bool) {
        guard showGitCommitDateColumn != value else { return }
        showGitCommitDateColumn = value
        defaults.set(value, forKey: "showGitCommitDateColumn")
        changed()
    }
    public func setShowGitCommitMessageColumn(_ value: Bool) {
        guard showGitCommitMessageColumn != value else { return }
        showGitCommitMessageColumn = value
        defaults.set(value, forKey: "showGitCommitMessageColumn")
        changed()
    }
    public func setShowGitCommitAuthorColumn(_ value: Bool) {
        guard showGitCommitAuthorColumn != value else { return }
        showGitCommitAuthorColumn = value
        defaults.set(value, forKey: "showGitCommitAuthorColumn")
        changed()
    }
    public func setShowGitCommitSHAColumn(_ value: Bool) {
        guard showGitCommitSHAColumn != value else { return }
        showGitCommitSHAColumn = value
        defaults.set(value, forKey: "showGitCommitSHAColumn")
        changed()
    }
    public func setShowSyncStatusColumn(_ value: Bool) {
        guard showSyncStatusColumn != value else { return }
        showSyncStatusColumn = value
        defaults.set(value, forKey: "showSyncStatusColumn")
        changed()
    }
    public func setShowFileTagColumn(_ value: Bool) { guard showFileTagColumn != value else { return }; showFileTagColumn = value; defaults.set(value, forKey: "showFileTagColumn"); changed() }
    public func setShowPathColumn(_ value: Bool) { guard showPathColumn != value else { return }; showPathColumn = value; defaults.set(value, forKey: "showPathColumn"); changed() }
    public func setShowCompressionOptions(_ value: Bool) { guard showCompressionOptions != value else { return }; showCompressionOptions = value; defaults.set(value, forKey: "showCompressionOptions"); changed() }
    public func setShowFlattenOptions(_ value: Bool) {
        guard showFlattenOptions != value else { return }
        showFlattenOptions = value
        defaults.set(value, forKey: "showFlattenOptions")
        changed()
    }
    public func setShowOpenTerminal(_ value: Bool) { guard showOpenTerminal != value else { return }; showOpenTerminal = value; defaults.set(value, forKey: "showOpenTerminal"); changed() }
    public func setShowCreateFolderWithSelection(_ value: Bool) { guard showCreateFolderWithSelection != value else { return }; showCreateFolderWithSelection = value; defaults.set(value, forKey: "showCreateFolderWithSelection"); changed() }
    public func setShowPinToSidebar(_ value: Bool) { guard showPinToSidebar != value else { return }; showPinToSidebar = value; defaults.set(value, forKey: "showPinToSidebar"); changed() }
    public func setShowSendToMenu(_ value: Bool) { guard showSendToMenu != value else { return }; showSendToMenu = value; defaults.set(value, forKey: "showSendToMenu"); changed() }
    public func setShowCopyPath(_ value: Bool) { guard showCopyPath != value else { return }; showCopyPath = value; defaults.set(value, forKey: "showCopyPath"); changed() }
    public func setShowOpenInNewTab(_ value: Bool) { guard showOpenInNewTab != value else { return }; showOpenInNewTab = value; defaults.set(value, forKey: "showOpenInNewTab"); changed() }
    public func setShowOpenInNewWindow(_ value: Bool) { guard showOpenInNewWindow != value else { return }; showOpenInNewWindow = value; defaults.set(value, forKey: "showOpenInNewWindow"); changed() }
    public func setShowOpenInNewPane(_ value: Bool) { guard showOpenInNewPane != value else { return }; showOpenInNewPane = value; defaults.set(value, forKey: "showOpenInNewPane"); changed() }
    public func setShowEditTagsMenu(_ value: Bool) { guard showEditTagsMenu != value else { return }; showEditTagsMenu = value; defaults.set(value, forKey: "showEditTagsMenu"); changed() }
    public func setShowCreateShortcut(_ value: Bool) { guard showCreateShortcut != value else { return }; showCreateShortcut = value; defaults.set(value, forKey: "showCreateShortcut"); changed() }
    public func setViewSize(_ value: BrowserViewSize) {
        guard viewSize != value else { return }
        viewSize = value; defaults.set(value.rawValue, forKey: "viewSize"); changed()
    }
    public var synchronizedFolderLayout: SharedFolderLayout? {
        syncFolderLayouts ? sharedFolderLayout : nil
    }
    public func setShowInfoPane(_ value: Bool) {
        guard showInfoPane != value else { return }
        showInfoPane = value
        defaults.set(value, forKey: "showInfoPane")
        changed()
    }
    public func setInfoPaneTab(_ tab: InfoPaneTab) {
        guard infoPaneTab != tab else { return }
        infoPaneTab = tab
        defaults.set(tab.rawValue, forKey: "infoPaneTab")
        changed()
    }
    public func setFolderLayoutSynchronization(_ enabled: Bool, initial: SharedFolderLayout) {
        guard syncFolderLayouts != enabled else { return }
        syncFolderLayouts = enabled
        if enabled { sharedFolderLayout = initial }
        persistSharedFolderLayout()
        changed()
    }
    public func updateSharedFolderLayout(_ update: (inout SharedFolderLayout) -> Void) {
        guard var layout = synchronizedFolderLayout else { return }
        update(&layout)
        guard layout != sharedFolderLayout else { return }
        sharedFolderLayout = layout
        persistSharedFolderLayout()
        changed()
    }
    private func persistSharedFolderLayout() {
        defaults.set(syncFolderLayouts, forKey: "syncFolderLayouts")
        defaults.set(sharedFolderLayout.flatMap { try? JSONEncoder().encode($0) }, forKey: "sharedFolderLayout")
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
    public func setDefaultSortDirectoryPlacement(_ value: SortDirectoryPlacement) {
        guard defaultSortDirectoryPlacement != value else { return }
        defaultSortDirectoryPlacement = value; defaults.set(value.rawValue, forKey: "defaultSortDirectoryPlacement"); changed()
    }
    public func setAutoSizeColumnsInDetailsLayout(_ value: Bool) {
        guard autoSizeColumnsInDetailsLayout != value else { return }
        autoSizeColumnsInDetailsLayout = value; defaults.set(value, forKey: "autoSizeColumnsInDetailsLayout"); changed()
    }
    public func setOpenNewTabOnStartup(_ value: Bool) {
        guard openNewTabOnStartup != value else { return }
        openNewTabOnStartup = value; defaults.set(value, forKey: "openNewTabOnStartup"); changed()
    }
    public func setLastSessionSelectedTabIndex(_ value: Int) {
        let value = max(-1, value)
        guard lastSessionSelectedTabIndex != value else { return }
        lastSessionSelectedTabIndex = value; defaults.set(value, forKey: "lastSessionSelectedTabIndex"); changed()
    }
    public func setAlwaysOpenDualPaneInNewTab(_ value: Bool) {
        guard alwaysOpenDualPaneInNewTab != value else { return }
        alwaysOpenDualPaneInNewTab = value; defaults.set(value, forKey: "alwaysOpenDualPaneInNewTab"); changed()
    }
    public func setAlwaysSwitchToNewlyOpenedTab(_ value: Bool) {
        guard alwaysSwitchToNewlyOpenedTab != value else { return }
        alwaysSwitchToNewlyOpenedTab = value; defaults.set(value, forKey: "alwaysSwitchToNewlyOpenedTab"); changed()
    }
    public func setCalculateFolderSizes(_ value: Bool) {
        guard calculateFolderSizes != value else { return }
        calculateFolderSizes = value; defaults.set(value, forKey: "calculateFolderSizes"); changed()
    }
    public func setEnableThumbnailCache(_ value: Bool) {
        guard enableThumbnailCache != value else { return }
        enableThumbnailCache = value
        defaults.set(value, forKey: "enableThumbnailCache")
        changed()
    }
    public func setThumbnailCacheLimitMiB(_ value: Int) {
        guard Self.thumbnailCacheLimits.contains(value), thumbnailCacheLimitMiB != value else { return }
        thumbnailCacheLimitMiB = value
        defaults.set(value, forKey: "thumbnailCacheLimitMiB")
        changed()
    }
    public func setShowThumbnails(_ value: Bool) {
        guard showThumbnails != value else { return }
        showThumbnails = value; defaults.set(value, forKey: "showThumbnails"); changed()
    }
    public func setDoubleClickToGoUp(_ value: Bool) {
        guard doubleClickToGoUp != value else { return }
        doubleClickToGoUp = value; defaults.set(value, forKey: "doubleClickToGoUp"); changed()
    }
    public func setShowFilterHeader(_ value: Bool) {
        guard showFilterHeader != value else { return }
        showFilterHeader = value
        defaults.set(value, forKey: "showFilterHeader")
        changed()
    }
    public func setShowShelfPane(_ value: Bool) {
        guard showShelfPane != value else { return }
        showShelfPane = value
        defaults.set(value, forKey: "showShelfPane")
        changed()
    }
    public func setShowShelfToggle(_ value: Bool) {
        guard showShelfToggle != value else { return }
        showShelfToggle = value
        defaults.set(value, forKey: "showShelfToggle")
        changed()
    }
    public func addToShelf(_ urls: [URL]) {
        var entries = shelfEntries
        var known = Set(entries.map(\.url))
        for url in urls {
            if let entry = ShelfEntry(url), known.insert(entry.url).inserted { entries.append(entry) }
        }
        guard entries != shelfEntries else { return }
        shelfEntries = entries
        changed()
    }
    public func removeFromShelf(_ entries: [ShelfEntry]) {
        let remaining = shelfEntries.filter { !entries.contains($0) }
        guard remaining != shelfEntries else { return }
        shelfEntries = remaining
        changed()
    }
    public func setReverseTabScrollDirection(_ value: Bool) {
        guard reverseTabScrollDirection != value else { return }
        reverseTabScrollDirection = value; defaults.set(value, forKey: "reverseTabScrollDirection"); changed()
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
    public func setAppBackground(_ url: URL?) {
        let value = url?.standardizedFileURL.path
        guard appBackgroundPath != value else { return }
        appBackgroundPath = value
        if let value { defaults.set(value, forKey: "appBackgroundPath") }
        else { defaults.removeObject(forKey: "appBackgroundPath") }
        changed()
    }
    public func setAppBackgroundPresentation(fit: AppBackgroundFit? = nil, opacity: Double? = nil,
                                             horizontal: AppBackgroundHorizontalAlignment? = nil,
                                             vertical: AppBackgroundVerticalAlignment? = nil) {
        let nextFit = fit ?? appBackgroundFit
        let nextOpacity = min(1, max(0, opacity ?? appBackgroundOpacity))
        let nextHorizontal = horizontal ?? appBackgroundHorizontalAlignment
        let nextVertical = vertical ?? appBackgroundVerticalAlignment
        guard nextFit != appBackgroundFit || nextOpacity != appBackgroundOpacity ||
              nextHorizontal != appBackgroundHorizontalAlignment || nextVertical != appBackgroundVerticalAlignment else { return }
        appBackgroundFit = nextFit; appBackgroundOpacity = nextOpacity
        appBackgroundHorizontalAlignment = nextHorizontal; appBackgroundVerticalAlignment = nextVertical
        defaults.set(nextFit.rawValue, forKey: "appBackgroundFit"); defaults.set(nextOpacity, forKey: "appBackgroundOpacity")
        defaults.set(nextHorizontal.rawValue, forKey: "appBackgroundHorizontalAlignment"); defaults.set(nextVertical.rawValue, forKey: "appBackgroundVerticalAlignment")
        changed()
    }
    public func exportData() throws -> Data {
        let archive = BrowserPreferencesArchive(version: 1, sidebarOrder: sidebarOrder.map(\.rawValue),
            collapsedSidebar: collapsedSidebar.map(\.rawValue).sorted(), favorites: favorites.map(\.path), recent: recent.map(\.path),
            showHidden: showHidden, showExtensions: showExtensions, showToolbar: showToolbar, showStatusBar: showStatusBar, showSidebar: showSidebar,
            showCreatedColumn: showCreatedColumn, showDateColumn: showDateColumn, showTypeColumn: showTypeColumn, showSizeColumn: showSizeColumn, showGitStatusColumn: showGitStatusColumn,
            showGitCommitDateColumn: showGitCommitDateColumn,
            showGitCommitMessageColumn: showGitCommitMessageColumn,
            showGitCommitAuthorColumn: showGitCommitAuthorColumn,
            showGitCommitSHAColumn: showGitCommitSHAColumn,
            showSyncStatusColumn: showSyncStatusColumn,
            showFileTagColumn: showFileTagColumn, showPathColumn: showPathColumn,
            showCompressionOptions: showCompressionOptions, showFlattenOptions: showFlattenOptions,
            showOpenTerminal: showOpenTerminal, showCreateFolderWithSelection: showCreateFolderWithSelection,
            showPinToSidebar: showPinToSidebar,
            showSendToMenu: showSendToMenu,
            showCopyPath: showCopyPath,
            showOpenInNewTab: showOpenInNewTab, showOpenInNewWindow: showOpenInNewWindow, showOpenInNewPane: showOpenInNewPane,
            showEditTagsMenu: showEditTagsMenu,
            showCreateShortcut: showCreateShortcut,
            showHomeFavorites: showHomeFavorites, showHomeVolumes: showHomeVolumes, showHomeRecent: showHomeRecent,
            homeFavoritesExpanded: homeFavoritesExpanded, homeVolumesExpanded: homeVolumesExpanded, homeRecentExpanded: homeRecentExpanded,
            viewSize: viewSize.rawValue, syncFolderLayouts: syncFolderLayouts, showInfoPane: showInfoPane,
            infoPaneTab: infoPaneTab.rawValue, sharedFolderLayout: sharedFolderLayout,
            appearance: appearance.rawValue, continueLastSession: continueLastSession, sizeUnit: sizeUnit.rawValue,
            openFoldersInNewTab: openFoldersInNewTab, scrollToPreviousFolderOnUp: scrollToPreviousFolderOnUp,
            showFileExtensionWarning: showFileExtensionWarning,
            defaultSortDirectoryPlacement: defaultSortDirectoryPlacement.rawValue,
            autoSizeColumnsInDetailsLayout: autoSizeColumnsInDetailsLayout,
            openNewTabOnStartup: openNewTabOnStartup,
            lastSessionSelectedTabIndex: lastSessionSelectedTabIndex,
            alwaysOpenDualPaneInNewTab: alwaysOpenDualPaneInNewTab,
            alwaysSwitchToNewlyOpenedTab: alwaysSwitchToNewlyOpenedTab,
            calculateFolderSizes: calculateFolderSizes,
            enableThumbnailCache: enableThumbnailCache, thumbnailCacheLimitMiB: thumbnailCacheLimitMiB,
            showThumbnails: showThumbnails,
            doubleClickToGoUp: doubleClickToGoUp,
            reverseTabScrollDirection: reverseTabScrollDirection,
            showFilterHeader: showFilterHeader,
            showShelfPane: showShelfPane,
            showShelfToggle: showShelfToggle,
            startupLocationPath: startupLocationPath, developerApplicationPath: developerApplicationPath, appBackgroundPath: appBackgroundPath,
            appBackgroundFit: appBackgroundFit.rawValue, appBackgroundOpacity: appBackgroundOpacity,
            appBackgroundHorizontalAlignment: appBackgroundHorizontalAlignment.rawValue, appBackgroundVerticalAlignment: appBackgroundVerticalAlignment.rawValue,
            toolbarOrder: toolbarOrder.map(\.rawValue),
            hiddenToolbarItems: hiddenToolbarItems.map(\.rawValue).sorted(), folderViewPreferences: folderViewPreferences)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }
    public func importData(_ data: Data) throws {
        struct ArchiveHeader: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard try decoder.decode(ArchiveHeader.self, from: data).version == 1 else {
            throw BrowserPreferencesArchiveError.unsupportedVersion
        }
        let archive = try decoder.decode(BrowserPreferencesArchive.self, from: data)
        guard let size = BrowserViewSize(rawValue: archive.viewSize), let importedAppearance = BrowserAppearance(rawValue: archive.appearance) else { throw BrowserPreferencesArchiveError.invalidValue }
        let importedSizeUnit: BrowserSizeUnit
        if let raw = archive.sizeUnit {
            guard let value = BrowserSizeUnit(rawValue: raw) else { throw BrowserPreferencesArchiveError.invalidValue }
            importedSizeUnit = value
        } else { importedSizeUnit = .binary }
        let importedDefaultSortDirectoryPlacement: SortDirectoryPlacement
        if let raw = archive.defaultSortDirectoryPlacement {
            guard let value = SortDirectoryPlacement(rawValue: raw) else { throw BrowserPreferencesArchiveError.invalidValue }
            importedDefaultSortDirectoryPlacement = value
        } else { importedDefaultSortDirectoryPlacement = .foldersFirst }
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
        if let appBackgroundPath = archive.appBackgroundPath, !appBackgroundPath.hasPrefix("/") {
            throw BrowserPreferencesArchiveError.invalidValue
        }
        guard let importedBackgroundFit = archive.appBackgroundFit.flatMap(AppBackgroundFit.init(rawValue:)) ?? (archive.appBackgroundFit == nil ? .fill : nil),
              let importedHorizontal = archive.appBackgroundHorizontalAlignment.flatMap(AppBackgroundHorizontalAlignment.init(rawValue:)) ?? (archive.appBackgroundHorizontalAlignment == nil ? .center : nil),
              let importedVertical = archive.appBackgroundVerticalAlignment.flatMap(AppBackgroundVerticalAlignment.init(rawValue:)) ?? (archive.appBackgroundVerticalAlignment == nil ? .center : nil) else { throw BrowserPreferencesArchiveError.invalidValue }
        let importedOpacity = archive.appBackgroundOpacity ?? 1
        guard (0...1).contains(importedOpacity) else { throw BrowserPreferencesArchiveError.invalidValue }
        sidebarOrder = importedSidebar; collapsedSidebar = Set(importedCollapsed)
        favorites = archive.favorites.map { URL(fileURLWithPath: $0) }; recent = archive.recent.map { URL(fileURLWithPath: $0) }
        showHidden = archive.showHidden; showExtensions = archive.showExtensions; showToolbar = archive.showToolbar; showStatusBar = archive.showStatusBar; showSidebar = archive.showSidebar ?? true
        showCreatedColumn = archive.showCreatedColumn ?? false; showDateColumn = archive.showDateColumn ?? true; showTypeColumn = archive.showTypeColumn ?? true
        showSizeColumn = archive.showSizeColumn ?? true; showGitStatusColumn = archive.showGitStatusColumn ?? false
        showGitCommitDateColumn = archive.showGitCommitDateColumn ?? false
        showGitCommitMessageColumn = archive.showGitCommitMessageColumn ?? false
        showGitCommitAuthorColumn = archive.showGitCommitAuthorColumn ?? false
        showGitCommitSHAColumn = archive.showGitCommitSHAColumn ?? false
        showSyncStatusColumn = archive.showSyncStatusColumn ?? false
        showFileTagColumn = archive.showFileTagColumn ?? false; showPathColumn = archive.showPathColumn ?? false
        showCompressionOptions = archive.showCompressionOptions ?? true; showOpenTerminal = archive.showOpenTerminal ?? true
        showFlattenOptions = archive.showFlattenOptions ?? false
        showCreateFolderWithSelection = archive.showCreateFolderWithSelection ?? true
        showPinToSidebar = archive.showPinToSidebar ?? true
        showSendToMenu = archive.showSendToMenu ?? true
        showCopyPath = archive.showCopyPath ?? true
        showOpenInNewTab = archive.showOpenInNewTab ?? true; showOpenInNewWindow = archive.showOpenInNewWindow ?? true; showOpenInNewPane = archive.showOpenInNewPane ?? true
        showEditTagsMenu = archive.showEditTagsMenu ?? true
        showCreateShortcut = archive.showCreateShortcut ?? true
        showHomeFavorites = archive.showHomeFavorites; showHomeVolumes = archive.showHomeVolumes; showHomeRecent = archive.showHomeRecent
        homeFavoritesExpanded = archive.homeFavoritesExpanded ?? true; homeVolumesExpanded = archive.homeVolumesExpanded ?? true; homeRecentExpanded = archive.homeRecentExpanded ?? true
        viewSize = size; appearance = importedAppearance; continueLastSession = archive.continueLastSession; sizeUnit = importedSizeUnit
        sharedFolderLayout = archive.sharedFolderLayout
        syncFolderLayouts = archive.syncFolderLayouts == true && sharedFolderLayout != nil
        showInfoPane = archive.showInfoPane ?? false
        infoPaneTab = archive.infoPaneTab.flatMap(InfoPaneTab.init(rawValue:)) ?? .details
        defaults.set(showInfoPane, forKey: "showInfoPane")
        defaults.set(infoPaneTab.rawValue, forKey: "infoPaneTab")
        persistSharedFolderLayout()
        openFoldersInNewTab = archive.openFoldersInNewTab ?? false; scrollToPreviousFolderOnUp = archive.scrollToPreviousFolderOnUp ?? true
        showFileExtensionWarning = archive.showFileExtensionWarning ?? true; startupLocationPath = archive.startupLocationPath
        defaultSortDirectoryPlacement = importedDefaultSortDirectoryPlacement
        autoSizeColumnsInDetailsLayout = archive.autoSizeColumnsInDetailsLayout ?? false
        openNewTabOnStartup = archive.openNewTabOnStartup ?? false
        lastSessionSelectedTabIndex = max(-1, archive.lastSessionSelectedTabIndex ?? -1)
        alwaysOpenDualPaneInNewTab = archive.alwaysOpenDualPaneInNewTab ?? false
        alwaysSwitchToNewlyOpenedTab = archive.alwaysSwitchToNewlyOpenedTab ?? false
        calculateFolderSizes = archive.calculateFolderSizes ?? false
        enableThumbnailCache = archive.enableThumbnailCache ?? true
        let cacheLimit = archive.thumbnailCacheLimitMiB ?? Self.defaultThumbnailCacheLimitMiB
        thumbnailCacheLimitMiB = Self.thumbnailCacheLimits.contains(cacheLimit) ? cacheLimit : Self.defaultThumbnailCacheLimitMiB
        showThumbnails = archive.showThumbnails ?? true
        doubleClickToGoUp = archive.doubleClickToGoUp ?? true
        reverseTabScrollDirection = archive.reverseTabScrollDirection ?? false
        showFilterHeader = archive.showFilterHeader ?? false
        showShelfPane = archive.showShelfPane ?? false
        showShelfToggle = archive.showShelfToggle ?? false
        developerApplicationPath = archive.developerApplicationPath; appBackgroundPath = archive.appBackgroundPath; toolbarOrder = importedToolbar; hiddenToolbarItems = Set(importedHiddenToolbar)
        appBackgroundFit = importedBackgroundFit; appBackgroundOpacity = importedOpacity
        appBackgroundHorizontalAlignment = importedHorizontal; appBackgroundVerticalAlignment = importedVertical
        folderViewPreferences = archive.folderViewPreferences
        defaults.set(sidebarOrder.map(\.rawValue), forKey: "sidebarOrder"); defaults.set(collapsedSidebar.map(\.rawValue).sorted(), forKey: "collapsedSidebar")
        defaults.set(favorites.map(\.path), forKey: "favorites"); defaults.set(recent.map(\.path), forKey: "recent")
        defaults.set(showHidden, forKey: "showHidden"); defaults.set(showExtensions, forKey: "showExtensions")
        defaults.set(showToolbar, forKey: "showToolbar"); defaults.set(showStatusBar, forKey: "showStatusBar"); defaults.set(showSidebar, forKey: "showSidebar")
        defaults.set(showCreatedColumn, forKey: "showCreatedColumn"); defaults.set(showDateColumn, forKey: "showDateColumn"); defaults.set(showTypeColumn, forKey: "showTypeColumn")
        defaults.set(showSizeColumn, forKey: "showSizeColumn"); defaults.set(showGitStatusColumn, forKey: "showGitStatusColumn")
        defaults.set(showGitCommitDateColumn, forKey: "showGitCommitDateColumn")
        defaults.set(showGitCommitMessageColumn, forKey: "showGitCommitMessageColumn")
        defaults.set(showGitCommitAuthorColumn, forKey: "showGitCommitAuthorColumn")
        defaults.set(showGitCommitSHAColumn, forKey: "showGitCommitSHAColumn")
        defaults.set(showSyncStatusColumn, forKey: "showSyncStatusColumn")
        defaults.set(showFileTagColumn, forKey: "showFileTagColumn"); defaults.set(showPathColumn, forKey: "showPathColumn")
        defaults.set(showCompressionOptions, forKey: "showCompressionOptions"); defaults.set(showOpenTerminal, forKey: "showOpenTerminal")
        defaults.set(showFlattenOptions, forKey: "showFlattenOptions")
        defaults.set(showCreateFolderWithSelection, forKey: "showCreateFolderWithSelection")
        defaults.set(showPinToSidebar, forKey: "showPinToSidebar")
        defaults.set(showSendToMenu, forKey: "showSendToMenu")
        defaults.set(showCopyPath, forKey: "showCopyPath")
        defaults.set(showOpenInNewTab, forKey: "showOpenInNewTab"); defaults.set(showOpenInNewWindow, forKey: "showOpenInNewWindow"); defaults.set(showOpenInNewPane, forKey: "showOpenInNewPane")
        defaults.set(showEditTagsMenu, forKey: "showEditTagsMenu")
        defaults.set(showCreateShortcut, forKey: "showCreateShortcut")
        defaults.set(showHomeFavorites, forKey: "showHomeFavorites"); defaults.set(showHomeVolumes, forKey: "showHomeVolumes"); defaults.set(showHomeRecent, forKey: "showHomeRecent")
        defaults.set(homeFavoritesExpanded, forKey: "homeFavoritesExpanded"); defaults.set(homeVolumesExpanded, forKey: "homeVolumesExpanded"); defaults.set(homeRecentExpanded, forKey: "homeRecentExpanded")
        defaults.set(viewSize.rawValue, forKey: "viewSize"); defaults.set(appearance.rawValue, forKey: "appearance"); defaults.set(continueLastSession, forKey: "continueLastSession"); defaults.set(sizeUnit.rawValue, forKey: "sizeUnit")
        defaults.set(openFoldersInNewTab, forKey: "openFoldersInNewTab"); defaults.set(scrollToPreviousFolderOnUp, forKey: "scrollToPreviousFolderOnUp"); defaults.set(showFileExtensionWarning, forKey: "showFileExtensionWarning")
        defaults.set(defaultSortDirectoryPlacement.rawValue, forKey: "defaultSortDirectoryPlacement")
        defaults.set(autoSizeColumnsInDetailsLayout, forKey: "autoSizeColumnsInDetailsLayout")
        defaults.set(openNewTabOnStartup, forKey: "openNewTabOnStartup")
        defaults.set(lastSessionSelectedTabIndex, forKey: "lastSessionSelectedTabIndex")
        defaults.set(alwaysOpenDualPaneInNewTab, forKey: "alwaysOpenDualPaneInNewTab")
        defaults.set(alwaysSwitchToNewlyOpenedTab, forKey: "alwaysSwitchToNewlyOpenedTab")
        defaults.set(calculateFolderSizes, forKey: "calculateFolderSizes")
        defaults.set(enableThumbnailCache, forKey: "enableThumbnailCache")
        defaults.set(thumbnailCacheLimitMiB, forKey: "thumbnailCacheLimitMiB")
        defaults.set(showThumbnails, forKey: "showThumbnails")
        defaults.set(doubleClickToGoUp, forKey: "doubleClickToGoUp")
        defaults.set(reverseTabScrollDirection, forKey: "reverseTabScrollDirection")
        defaults.set(showFilterHeader, forKey: "showFilterHeader")
        defaults.set(showShelfPane, forKey: "showShelfPane")
        defaults.set(showShelfToggle, forKey: "showShelfToggle")
        if let startupLocationPath { defaults.set(startupLocationPath, forKey: "startupLocationPath") } else { defaults.removeObject(forKey: "startupLocationPath") }
        if let developerApplicationPath { defaults.set(developerApplicationPath, forKey: "developerApplicationPath") } else { defaults.removeObject(forKey: "developerApplicationPath") }
        if let appBackgroundPath { defaults.set(appBackgroundPath, forKey: "appBackgroundPath") } else { defaults.removeObject(forKey: "appBackgroundPath") }
        defaults.set(appBackgroundFit.rawValue, forKey: "appBackgroundFit"); defaults.set(appBackgroundOpacity, forKey: "appBackgroundOpacity")
        defaults.set(appBackgroundHorizontalAlignment.rawValue, forKey: "appBackgroundHorizontalAlignment"); defaults.set(appBackgroundVerticalAlignment.rawValue, forKey: "appBackgroundVerticalAlignment")
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
    public func setHomeSectionExpanded(_ section: HomeSection, expanded: Bool) {
        let current: Bool
        switch section {
        case .favorites: current = homeFavoritesExpanded
        case .volumes: current = homeVolumesExpanded
        case .recent: current = homeRecentExpanded
        }
        guard current != expanded else { return }
        switch section {
        case .favorites: homeFavoritesExpanded = expanded; defaults.set(expanded, forKey: "homeFavoritesExpanded")
        case .volumes: homeVolumesExpanded = expanded; defaults.set(expanded, forKey: "homeVolumesExpanded")
        case .recent: homeRecentExpanded = expanded; defaults.set(expanded, forKey: "homeRecentExpanded")
        }
        changed()
    }
    public func toggleHomeSectionExpanded(_ section: HomeSection) {
        switch section {
        case .favorites: setHomeSectionExpanded(section, expanded: !homeFavoritesExpanded)
        case .volumes: setHomeSectionExpanded(section, expanded: !homeVolumesExpanded)
        case .recent: setHomeSectionExpanded(section, expanded: !homeRecentExpanded)
        }
    }
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
