import Foundation
import Darwin

public enum SevenZipVolumeError: Error, Sendable, Equatable {
    case missingPart(Int), invalidPart(URL), tooManyParts, sizeLimit, sdkRequired
}

/// Standard 7-Zip byte volumes: name.7z.001, .002, ... .1000.
public enum SevenZipVolumes {
    public static let maximumParts = 1024
    public static let maximumBytes: Int64 = 8_000_000_000
    public static func index(of url: URL) -> Int? {
        let suffix = url.pathExtension
        guard url.deletingPathExtension().pathExtension.lowercased() == "7z", suffix.count >= 3,
              suffix.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int(suffix), value > 0,
              suffix == String(repeating: "0", count: max(0, 3 - String(value).count)) + String(value) else { return nil }
        return value
    }
    public static func firstVolumeURL(for url: URL) -> URL {
        index(of: url) == nil ? url : url.deletingPathExtension().appendingPathExtension("001")
    }
    public static func uniqueArchives(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.compactMap { url in
            let first = firstVolumeURL(for: url).standardizedFileURL
            return seen.insert(first).inserted ? first : nil
        }
    }
    /// Called before the SDK is opened. The SDK subsequently retains every part FD and
    /// rechecks each file/path identity for the entire list/extract session.
    static func paths(for selected: URL, check: () throws -> Void) throws -> [URL]? {
        guard let selectedNumber = index(of: selected) else { return nil }
        let parent = try sevenZipCanonicalDirectory(selected.deletingLastPathComponent())
        let base = selected.deletingPathExtension().lastPathComponent
        let caseSensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
        func key(_ value: String) -> String {
            let normalized = value.precomposedStringWithCanonicalMapping
            return caseSensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        var parts: [Int: URL] = [:], failed = false
        guard let enumerator = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else {
            throw SevenZipVolumeError.invalidPart(selected)
        }
        for case let url as URL in enumerator {
            try check()
            guard key(url.deletingPathExtension().lastPathComponent) == key(base), let number = index(of: url) else { continue }
            guard number <= maximumParts, parts.count < maximumParts else { throw SevenZipVolumeError.tooManyParts }
            guard parts[number] == nil else { throw SevenZipVolumeError.invalidPart(url) }
            parts[number] = url
        }
        guard !failed else { throw SevenZipVolumeError.invalidPart(selected) }
        guard let last = parts.keys.max() else { throw SevenZipVolumeError.missingPart(1) }
        guard parts[selectedNumber] != nil else { throw SevenZipVolumeError.missingPart(selectedNumber) }
        var ordered: [URL] = [], total: Int64 = 0, size: Int64?
        for number in 1...last {
            try check()
            guard let url = parts[number] else { throw SevenZipVolumeError.missingPart(number) }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
                  size == nil || (number == last ? info.st_size <= size! : info.st_size == size!) else {
                throw SevenZipVolumeError.invalidPart(url)
            }
            guard info.st_size <= maximumBytes - total else { throw SevenZipVolumeError.sizeLimit }
            size = size ?? info.st_size; total += info.st_size; ordered.append(url)
        }
        return ordered
    }
}
