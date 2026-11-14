import Foundation

public struct FolderSizeCalculator: Sendable {
    public init() {}

    public func sizes(of folders: [URL]) async -> [URL: Int64] {
        await Task.detached(priority: .utility) {
            var result: [URL: Int64] = [:]
            for folder in folders {
                guard !Task.isCancelled else { break }
                if let size = try? Self.size(of: folder) { result[folder.standardizedFileURL] = size }
            }
            return result
        }.value
    }

    public static func size(of folder: URL, fileManager: FileManager = .default) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                       options: [], errorHandler: { _, _ in false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { if values.isDirectory == true { enumerator.skipDescendants() }; continue }
            if values.isRegularFile == true {
                let (sum, overflow) = total.addingReportingOverflow(Int64(values.fileSize ?? 0)); total = overflow ? .max : sum
            }
        }
        return total
    }
}
