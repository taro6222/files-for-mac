import Foundation

public struct FolderSizeCalculator: Sendable {
    public init() {}

    public func sizes(of folders: [URL]) async -> [URL: Int64] {
        let worker = Task.detached(priority: .utility) {
            var result: [URL: Int64] = [:]
            for folder in folders {
                guard !Task.isCancelled else { break }
                if let size = try? Self.size(of: folder) { result[folder.standardizedFileURL] = size }
            }
            return result
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    public func size(of item: FileItem) async throws -> Int64 {
        let worker = Task.detached(priority: .userInitiated) {
            if let identity = item.identity, LocalEntryIdentity.read(item.url) != identity {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let size = try Self.size(of: item.url)
            if let identity = item.identity, LocalEntryIdentity.read(item.url) != identity {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return size
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public static func size(of folder: URL, fileManager: FileManager = .default) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw CocoaError(.fileReadUnknown) }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                       options: [], errorHandler: { _, error in
                                                           enumerationError = error
                                                           return false
                                                       }) else {
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
        if let enumerationError { throw enumerationError }
        return total
    }
}
