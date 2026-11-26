import Foundation

/// MiB presets from the pinned Files create-archive dialog. Zero means no split.
public enum ArchiveSplitSize: Int, CaseIterable, Codable, Sendable {
    case none = 0, mib10 = 10, mib100 = 100, cd650 = 650, cd700 = 700
    case mib1024 = 1024, mib2048 = 2048, fat4092 = 4092, dvd4480 = 4480
    case mib5120 = 5120, dvd8128 = 8128, bluray23040 = 23040

    public var volumeBytes: Int64? { self == .none ? nil : Int64(rawValue) * 1_048_576 }
    public var mediaName: String? {
        switch self {
        case .cd650, .cd700: return "CD"
        case .fat4092: return "FAT"
        case .dvd4480, .dvd8128: return "DVD"
        case .bluray23040: return "Blu-ray"
        default: return nil
        }
    }
}
