import AppKit
import FilesCore
import UniformTypeIdentifiers

@MainActor
func fileIcon(for item: FileItem, showsThumbnails: Bool) -> NSImage {
    if showsThumbnails { return FileIconCache.shared.icon(for: item) }
    let type: UTType
    if item.isDirectory { type = item.isPackage ? .bundle : .folder }
    else { type = UTType(filenameExtension: item.url.pathExtension) ?? .data }
    return FileIconCache.shared.genericIcon(for: type)
}

// AppKit supplies the file-specific image. The app retains it only in memory.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let genericIcons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private var currentLimit: Int?

    func configure(enabled: Bool, limitMiB: Int) {
        let limit = enabled ? max(1, min(limitMiB, BrowserPreferences.thumbnailCacheLimits.last ?? 512)) * 1024 * 1024 : 0
        guard currentLimit != limit else { return }
        currentLimit = limit
        cache.removeAllObjects()
        cache.totalCostLimit = limit
        cache.countLimit = 4_096
    }

    func genericIcon(for type: UTType) -> NSImage {
        let key = type.identifier as NSString
        if let cached = genericIcons.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        genericIcons.setObject(icon, forKey: key)
        return icon
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func icon(for item: FileItem, load: (String) -> NSImage = NSWorkspace.shared.icon(forFile:)) -> NSImage {
        guard let limit = currentLimit, limit > 0, let identity = item.identity else {
            return load(item.url.path)
        }
        let key = "\(identity)|\(item.modified?.timeIntervalSinceReferenceDate ?? 0)|\(item.size ?? -1)|\(item.url.path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = load(item.url.path)
        // Charge each advertised representation for a 32-bit raster. AppKit
        // may decode lazily and NSCache can evict before reaching this budget.
        let cost = image.representations.reduce(0) { total, representation in
            let width = min(max(representation.pixelsWide, 1), 8192)
            let height = min(max(representation.pixelsHigh, 1), 8192)
            return total + width * height * 4
        }
        if cost > 0 && cost <= limit { cache.setObject(image, forKey: key, cost: cost) }
        return image
    }
}
