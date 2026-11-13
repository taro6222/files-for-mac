import Foundation
import ImageIO

enum AppBackgroundStoreError: Error { case invalidSource, tooLarge, sourceChanged }

struct AppBackgroundStore: Sendable {
    static let maximumBytes = 100 * 1024 * 1024
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilesMac", isDirectory: true)
    }

    func install(from source: URL) throws -> URL {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileResourceIdentifierKey, .contentModificationDateKey]
        let before = try source.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true, let size = before.fileSize,
              size <= Self.maximumBytes, let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 0 else {
            throw sizeOrInvalid(before.fileSize)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("background-image")
        let staging = directory.appendingPathComponent(".background-image-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: staging)
            let after = try source.resourceValues(forKeys: keys)
            guard before.fileResourceIdentifier as? AnyHashable == after.fileResourceIdentifier as? AnyHashable,
                  before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                throw AppBackgroundStoreError.sourceChanged
            }
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staging) }
            else { try fm.moveItem(at: staging, to: destination) }
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func remove() throws {
        let destination = directory.appendingPathComponent("background-image")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    }

    private func sizeOrInvalid(_ size: Int?) -> AppBackgroundStoreError {
        if let size, size > Self.maximumBytes { return .tooLarge }
        return .invalidSource
    }
}
