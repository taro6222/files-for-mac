import Foundation

public enum CloudItemState: String, CaseIterable, Sendable, Equatable {
    case availableOffline, onlineOnly, downloading, uploading, conflict, error, unknown

    static func readUbiquitousState(at url: URL) -> CloudItemState {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .unknown }
        if values.ubiquitousItemDownloadingError != nil || values.ubiquitousItemUploadingError != nil { return .error }
        if values.ubiquitousItemHasUnresolvedConflicts == true { return .conflict }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        switch values.ubiquitousItemDownloadingStatus {
        case .current, .downloaded: return .availableOffline
        case .notDownloaded: return .onlineOnly
        default: return .unknown
        }
    }
}

public struct CloudLocation: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let providerName: String
    public let url: URL
    public let state: CloudItemState
    public let exposesUbiquitousState: Bool
}

public struct CloudItemCapabilities: Sendable, Equatable {
    public let downloadNow: Bool
    public let evictLocalCopy: Bool
    public let keepDownloaded: Bool
    public init(downloadNow: Bool, evictLocalCopy: Bool, keepDownloaded: Bool) {
        self.downloadNow = downloadNow; self.evictLocalCopy = evictLocalCopy; self.keepDownloaded = keepDownloaded
    }
}

public enum CloudOperationError: Error, Sendable, Equatable { case unsupported }

public struct CloudLocationProvider: Sendable {
    public let cloudStorageRoot: URL
    public let iCloudDriveRoot: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                cloudStorageRoot: URL? = nil, iCloudDriveRoot: URL? = nil) {
        self.cloudStorageRoot = cloudStorageRoot ?? home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        self.iCloudDriveRoot = iCloudDriveRoot ?? home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    public func locations(fileManager: FileManager = .default) -> [CloudLocation] {
        var urls: [URL] = []
        if (try? iCloudDriveRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { urls.append(iCloudDriveRoot) }
        if let children = try? fileManager.contentsOfDirectory(at: cloudStorageRoot, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey], options: [.skipsHiddenFiles]) {
            urls += children.filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                return values?.isDirectory == true && values?.isHidden != true
            }
        }
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            let provider = providerName(for: standardized)
            return CloudLocation(id: standardized.path, name: displayName(for: standardized, provider: provider), providerName: provider,
                                 url: standardized, state: state(of: standardized), exposesUbiquitousState: isUbiquitous(standardized))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func state(of url: URL) -> CloudItemState {
        guard isUbiquitous(url) else { return .unknown }
        return CloudItemState.readUbiquitousState(at: url)
    }

    public func capabilities(for url: URL) -> CloudItemCapabilities {
        let ubiquitous = isUbiquitous(url)
        // FileManager exposes fetch/evict for ubiquitous items, but no public API that
        // guarantees a permanent "always keep downloaded" pin.
        return CloudItemCapabilities(downloadNow: ubiquitous, evictLocalCopy: ubiquitous, keepDownloaded: false)
    }

    public func requestDownload(_ url: URL, fileManager: FileManager = .default) throws {
        guard capabilities(for: url).downloadNow else { throw CloudOperationError.unsupported }
        try fileManager.startDownloadingUbiquitousItem(at: url)
    }

    public func evictLocalCopy(_ url: URL, fileManager: FileManager = .default) throws {
        guard capabilities(for: url).evictLocalCopy else { throw CloudOperationError.unsupported }
        try fileManager.evictUbiquitousItem(at: url)
    }

    private func isUbiquitous(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true }
    private func providerName(for url: URL) -> String {
        if url.standardizedFileURL == iCloudDriveRoot.standardizedFileURL { return "iCloud Drive" }
        let raw = url.lastPathComponent
        return raw.split(separator: "-", maxSplits: 1).first.map(String.init) ?? raw
    }
    private func displayName(for url: URL, provider: String) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName).flatMap { $0.isEmpty ? nil : $0 } ?? provider
    }
}
