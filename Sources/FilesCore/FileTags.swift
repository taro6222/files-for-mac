import Foundation
import Darwin

/// Prefer the stored Finder tag plist when NSURL's independently cached tag property disagrees.
/// Unknown, unsupported or malformed storage retains the resource-provider result.
enum StoredFileTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    static func names(at url: URL, fallback: [String]) -> [String] {
        for _ in 0..<3 {
            let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return fallback }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes {
                getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            if read < 0 && errno == ERANGE { continue }
            guard read == size,
                  let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else {
                return fallback
            }
            return values.map { value in
                let suffix = value.suffix(2)
                if suffix.first == "\n", let color = suffix.last, "01234567".contains(color) {
                    return String(value.dropLast(2))
                }
                return value
            }
        }
        return fallback
    }
}

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
        let identifier = try identity(url)
        let resourceTags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        return FileTagSnapshot(identity: identifier, tags: StoredFileTags.names(at: url, fallback: resourceTags))
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
            if tag.isEmpty { continue }
            guard tag.count <= 255,
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
