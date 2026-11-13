import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FilesCore

@Test func imageRotationChangesOrientationWithoutChangingPixelPayloadDimensions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-rotation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("image.png")
    try makeRotationPNG(at: image)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: image.path)

    let engine = ImageRotationEngine()
    try engine.rotate(image, direction: .right)
    #expect(try imageOrientation(image) == 6)
    let source = try #require(CGImageSourceCreateWithURL(image as CFURL, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 2 && decoded.height == 1)
    let mode = try #require((FileManager.default.attributesOfItem(atPath: image.path)[.posixPermissions] as? NSNumber)?.intValue)
    #expect(mode == 0o640)

    try engine.rotate(image, direction: .left)
    #expect(try imageOrientation(image) == 1)
}

@Test func imageRotationRejectsNonImagesAndMapsMirroredOrientations() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-image-\(UUID()).txt")
    try Data("not an image".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: ImageRotationError.invalidSource) { try ImageRotationEngine().rotate(file, direction: .right) }
    #expect(ImageRotationEngine.rotatedOrientation(2, direction: .right) == 7)
    #expect(ImageRotationEngine.rotatedOrientation(7, direction: .left) == 2)
}

private func makeRotationPNG(at url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func imageOrientation(_ url: URL) throws -> Int {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
}
