import Foundation

public enum ArchiveFormat: String, CaseIterable, Sendable, Equatable {
    case zip, sevenZip = "7z", rar

    public static func detect(_ url: URL) -> ArchiveFormat? {
        ArchiveFormat(rawValue: url.pathExtension.lowercased())
    }
}

public struct ArchiveFormatCapabilities: Sendable, Equatable {
    public let format: ArchiveFormat
    public let browse: Bool
    public let extract: Bool
    public let create: Bool
    public let update: Bool
    public let password: Bool
    public let splitVolumes: Bool

    public init(format: ArchiveFormat, browse: Bool, extract: Bool, create: Bool, update: Bool, password: Bool, splitVolumes: Bool) {
        self.format = format; self.browse = browse; self.extract = extract; self.create = create
        self.update = update; self.password = password; self.splitVolumes = splitVolumes
    }
}

public enum ArchiveCapabilityMatrix {
    /// Only capabilities exercised by the bundled provider are advertised.
    public static let current: [ArchiveFormatCapabilities] = [
        .init(format: .zip, browse: true, extract: true, create: true, update: false, password: false, splitVolumes: false),
        .init(format: .sevenZip, browse: true, extract: true, create: true, update: false, password: false, splitVolumes: false),
        .init(format: .rar, browse: true, extract: true, create: false, update: false, password: false, splitVolumes: false)
    ]

    public static func capabilities(for format: ArchiveFormat) -> ArchiveFormatCapabilities {
        current.first { $0.format == format }!
    }
}
