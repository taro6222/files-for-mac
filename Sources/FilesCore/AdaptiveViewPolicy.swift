import Foundation

public struct AdaptiveViewPolicy: Sendable {
    public let sampleLimit: Int
    public let mediaRatioThreshold: Double
    public let compactWidth: Double

    public init(sampleLimit: Int = 200, mediaRatioThreshold: Double = 0.6,
                compactWidth: Double = 560) {
        self.sampleLimit = max(1, sampleLimit)
        self.mediaRatioThreshold = min(max(mediaRatioThreshold, 0), 1)
        self.compactWidth = max(1, compactWidth)
    }

    public func resolve(items: [FileItem], availableWidth: Double) -> BrowserViewMode {
        let files = items.lazy.filter { !$0.isDirectory }.prefix(sampleLimit)
        let sampled = Array(files)
        let mediaCount = sampled.reduce(into: 0) { count, item in
            if Self.mediaExtensions.contains(item.url.pathExtension.lowercased()) { count += 1 }
        }
        if sampled.count >= 3, Double(mediaCount) / Double(sampled.count) >= mediaRatioThreshold {
            return .grid
        }
        return availableWidth < compactWidth ? .list : .details
    }

    private static let mediaExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
        "m4v", "mov", "mp4", "mpeg", "mpg", "webm"
    ]
}
