import Foundation
import UniformTypeIdentifiers

public enum SystemContentCompatibility {
    private static let certificateExtensions: Set<String> = ["cer", "crt", "der", "p12", "pfx", "pem"]
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "dfont"]

    public static func isCertificate(_ url: URL) -> Bool {
        certificateExtensions.contains(url.pathExtension.lowercased())
    }
    public static func isFont(_ url: URL) -> Bool {
        fontExtensions.contains(url.pathExtension.lowercased())
    }
    public static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
