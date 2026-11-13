import Foundation

public enum CloudItemState: String, Sendable, Equatable {
    case availableOffline, onlineOnly, downloading, uploading, conflict, error, unknown
}

public struct CloudLocation: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let providerName: String
    public let url: URL
    public let state: CloudItemState
    public let exposesUbiquitousState: Bool
}

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
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return .unknown }
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
