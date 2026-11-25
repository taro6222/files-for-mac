import Foundation

public struct FolderSizeCalculator: Sendable {
    private let beforeReading: (@Sendable () -> Void)?
    public init() { beforeReading = nil }
    init(beforeReading: @escaping @Sendable () -> Void) { self.beforeReading = beforeReading }

    public func sizes(of folders: [URL]) async -> [URL: Int64] {
        (try? await FileSystemWork.run(qos: .utility) { cancellation in
            beforeReading?(); try cancellation.check()
            var result: [URL: Int64] = [:]
            for folder in folders {
                try cancellation.check()
                if let size = try? Self.calculate(folder, fileManager: .default, check: cancellation.check) {
                    result[folder.standardizedFileURL] = size
                }
            }
            try cancellation.check(); return result
        }) ?? [:]
    }

    public func size(of item: FileItem) async throws -> Int64 {
        try await FileSystemWork.run(qos: .userInitiated) { cancellation in
            beforeReading?(); try cancellation.check()
            if let identity = item.identity, LocalEntryIdentity.read(item.url) != identity { throw CocoaError(.fileReadNoSuchFile) }
            let size = try Self.calculate(item.url, fileManager: .default, check: cancellation.check)
            try cancellation.check()
            if let identity = item.identity, LocalEntryIdentity.read(item.url) != identity { throw CocoaError(.fileReadNoSuchFile) }
            return size
        }
    }

    public static func size(of folder: URL, fileManager: FileManager = .default) throws -> Int64 {
        try calculate(folder, fileManager: fileManager, check: { try Task.checkCancellation() })
    }
    private static func calculate(_ folder: URL, fileManager: FileManager, check: () throws -> Void) throws -> Int64 {
        try check()
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
            try check()
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
