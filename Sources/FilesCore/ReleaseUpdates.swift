import Foundation

public enum ReleaseUpdate: Equatable, Sendable {
    case unavailable
    case upToDate
    case available(version: String, page: URL)
}

public enum ReleaseUpdates {
    private static let endpoint = URL(string: "https://api.github.com/repos/taro6222/files-for-mac/releases/latest")!

    public static func check(currentVersion: String, isPreview: Bool) async throws -> ReleaseUpdate {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == endpoint else {
            throw URLError(.badServerResponse)
        }
        return try evaluate(data, status: http.statusCode, currentVersion: currentVersion, isPreview: isPreview)
    }

    static func evaluate(_ data: Data, status: Int, currentVersion: String, isPreview: Bool = false) throws -> ReleaseUpdate {
        if status == 404 { return .unavailable }
        guard status == 200, let installed = components(of: currentVersion) else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let published = components(of: release.tag) else {
            return .unavailable
        }
        guard installed.lexicographicallyPrecedes(published) || (isPreview && installed == published) else {
            return .upToDate
        }
        let assets = Set(release.assets.filter { $0.state == "uploaded" && $0.size > 0 }.map(\.name))
        guard assets.contains("Files-macOS.dmg"), assets.contains("Files-macOS.dmg.sha256") else {
            return .unavailable
        }
        let page = URL(string: "https://github.com/taro6222/files-for-mac/releases/tag/")!
            .appendingPathComponent(release.tag)
        return .available(version: published.map(String.init).joined(separator: "."), page: page)
    }

    private static func components(of version: String) -> [Int]? {
        let numeric = version.hasPrefix("v") ? version.dropFirst() : version[...]
        let fields = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let values = fields.compactMap { field -> Int? in
            guard let value = Int(field), value >= 0, String(value) == field else { return nil }
            return value
        }
        return values.count == fields.count ? values : nil
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let size: Int
        }
        let tag: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease, assets
        }
    }
}
