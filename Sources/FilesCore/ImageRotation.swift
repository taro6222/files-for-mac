import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageRotationDirection: Sendable, Equatable { case left, right }
public enum ImageRotationError: Error, Equatable { case invalidSource, unsupportedFormat, animatedOrMultipage, sourceChanged, outputValidationFailed }

public struct ImageRotationEngine: Sendable {
    public init() {}

    public static func canRotate(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) else { return false }
        return Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(type as String)
    }

    public func rotate(_ url: URL, direction: ImageRotationDirection) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey]
        let before = try url.resourceValues(forKeys: keys)
        let beforeAttributes = try fm.attributesOfItem(atPath: url.path)
        guard before.isRegularFile == true, before.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceType = CGImageSourceGetType(source) else { throw ImageRotationError.invalidSource }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageRotationError.animatedOrMultipage }
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard writable.contains(sourceType as String) else { throw ImageRotationError.unsupportedFormat }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotatedOrientation = Self.rotatedOrientation(orientation, direction: direction)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".files-rotate-\(UUID().uuidString)")
        let encoded = url.deletingLastPathComponent().appendingPathComponent(".files-rotate-encoded-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging); try? fm.removeItem(at: encoded) }
        try fm.copyItem(at: url, to: staging)
        guard let destination = CGImageDestinationCreateWithURL(encoded as CFURL, sourceType, 1, nil) else { throw ImageRotationError.unsupportedFormat }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: rotatedOrientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageRotationError.outputValidationFailed }
        guard let output = CGImageSourceCreateWithURL(encoded as CFURL, nil), CGImageSourceGetCount(output) == 1,
              CGImageSourceGetType(output) == sourceType else { throw ImageRotationError.outputValidationFailed }
        try Self.replaceContents(of: staging, with: encoded)
        let after = try url.resourceValues(forKeys: keys)
        let afterAttributes = try fm.attributesOfItem(atPath: url.path)
        let resourceIdentityMatches = (before.fileResourceIdentifier as? AnyHashable).flatMap { expected in
            (after.fileResourceIdentifier as? AnyHashable).map { $0 == expected }
        }
        let posixIdentityMatches = (beforeAttributes[.systemNumber] as? NSNumber) == (afterAttributes[.systemNumber] as? NSNumber)
            && (beforeAttributes[.systemFileNumber] as? NSNumber) == (afterAttributes[.systemFileNumber] as? NSNumber)
        guard (resourceIdentityMatches ?? posixIdentityMatches),
              before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw ImageRotationError.sourceChanged
        }
        _ = try fm.replaceItemAt(url, withItemAt: staging, backupItemName: nil, options: [])
    }

    public static func rotatedOrientation(_ orientation: Int, direction: ImageRotationDirection) -> Int {
        let right = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
        let left = [1: 8, 8: 3, 3: 6, 6: 1, 2: 5, 5: 4, 4: 7, 7: 2]
        return (direction == .right ? right : left)[orientation] ?? (direction == .right ? 6 : 8)
    }

    private static func replaceContents(of target: URL, with source: URL) throws {
        let reader = try FileHandle(forReadingFrom: source); defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: target); defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { try writer.write(contentsOf: data) }
        try writer.synchronize()
    }
}
