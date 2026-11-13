import Foundation

public struct MountedVolume: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?
    public let formatDescription: String?
    public let isInternal: Bool?
    public let isLocal: Bool?
    public let isReadOnly: Bool?
    public let isRemovable: Bool?
    public let isEjectable: Bool?

    public init(url: URL, name: String, totalCapacity: Int64? = nil, availableCapacity: Int64? = nil,
                formatDescription: String? = nil, isInternal: Bool? = nil, isLocal: Bool? = nil,
                isReadOnly: Bool? = nil, isRemovable: Bool? = nil, isEjectable: Bool? = nil) {
        self.url = url.standardizedFileURL; self.name = name; self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity; self.formatDescription = formatDescription
        self.isInternal = isInternal; self.isLocal = isLocal; self.isReadOnly = isReadOnly
        self.isRemovable = isRemovable; self.isEjectable = isEjectable
    }

    public var usedFraction: Double? {
        guard let totalCapacity, let availableCapacity, totalCapacity > 0 else { return nil }
        return min(1, max(0, 1 - Double(availableCapacity) / Double(totalCapacity)))
    }
    public var canRequestEject: Bool { isEjectable == true || isRemovable == true }
}

public struct MountedVolumeProvider: Sendable {
    public init() {}
    public func mountedVolumes() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return MountedVolume(url: url, name: values?.volumeName ?? url.lastPathComponent,
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init), availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
                formatDescription: values?.volumeLocalizedFormatDescription, isInternal: values?.volumeIsInternal,
                isLocal: values?.volumeIsLocal, isReadOnly: values?.volumeIsReadOnly,
                isRemovable: values?.volumeIsRemovable, isEjectable: values?.volumeIsEjectable)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
