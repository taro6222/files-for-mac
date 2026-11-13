import Foundation

public struct FileTagSnapshot: Sendable, Equatable {
    public let identity: String?
    public let tags: [String]
    public init(identity: String?, tags: [String]) { self.identity = identity; self.tags = tags }
}

public enum FileTagError: Error, Equatable {
    case invalidName
    case changedIdentity
}

public struct FileTagService: Sendable {
    public init() {}
    public func snapshot(_ url: URL) throws -> FileTagSnapshot {
        FileTagSnapshot(identity: try identity(url), tags: try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }
    public func setTags(_ tags: [String], at url: URL, expectedIdentity: String?) throws -> FileTagSnapshot {
        let normalized = try normalize(tags)
        if let expectedIdentity, try identity(url) != expectedIdentity { throw FileTagError.changedIdentity }
        try (url as NSURL).setResourceValue(normalized, forKey: .tagNamesKey)
        if let expectedIdentity, try identity(url) != expectedIdentity { throw FileTagError.changedIdentity }
        return try snapshot(url)
    }
    private func normalize(_ tags: [String]) throws -> [String] {
        var result: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, tag.count <= 255,
                  tag.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw FileTagError.invalidName }
            if !result.contains(where: { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { result.append(tag) }
        }
        return result
    }
    private func identity(_ url: URL) throws -> String? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let birth = attributes[.creationDate] as? Date else { return nil }
        return "\(device):\(inode):\(birth.timeIntervalSince1970)"
    }
}
