import Foundation
import Testing
@testable import FilesCore

@Test func stableUpdateRequiresNewerVersionAndBothAssets() throws {
    let page = URL(string: "https://github.com/taro6222/files-for-mac/releases/tag/v0.10.0")!
    let data = releaseFixture()
    #expect(try ReleaseUpdates.evaluate(data, status: 200, currentVersion: "0.9.9") == .available(version: "0.10.0", page: page))
    #expect(try ReleaseUpdates.evaluate(data, status: 200, currentVersion: "0.10.0") == .upToDate)
    #expect(try ReleaseUpdates.evaluate(data, status: 200, currentVersion: "0.10.0", isPreview: true) == .available(version: "0.10.0", page: page))
    #expect(try ReleaseUpdates.evaluate(data, status: 200, currentVersion: "1.0.0") == .upToDate)
    let incomplete = releaseFixture(checksumState: "new")
    #expect(try ReleaseUpdates.evaluate(incomplete, status: 200, currentVersion: "0.9.9") == .unavailable)
}

@Test func developmentAndInvalidReleaseMetadataAreNotOffered() throws {
    for data in [releaseFixture(prerelease: true), releaseFixture(draft: true),
                 releaseFixture(tag: "v0.10.0-rc.1"), releaseFixture(tag: "../downloads")] {
        let result = try ReleaseUpdates.evaluate(data, status: 200, currentVersion: "0.1.0")
        #expect(result == .unavailable)
    }
    #expect(try ReleaseUpdates.evaluate(Data(), status: 404, currentVersion: "0.1.0") == .unavailable)
    #expect(throws: URLError.self) {
        try ReleaseUpdates.evaluate(Data(), status: 403, currentVersion: "0.1.0")
    }
    #expect(throws: DecodingError.self) {
        try ReleaseUpdates.evaluate(Data(), status: 200, currentVersion: "0.1.0")
    }
}

private func releaseFixture(tag: String = "v0.10.0", prerelease: Bool = false, draft: Bool = false,
                            checksumState: String = "uploaded") -> Data {
    Data("""
    {
        "tag_name": "\(tag)",
        "draft": \(draft),
        "prerelease": \(prerelease),
        "html_url": "https://other.example/unsafe",
        "assets": [
            {"name": "Files-macOS.dmg", "state": "uploaded", "size": 100000},
            {"name": "Files-macOS.dmg.sha256", "state": "\(checksumState)", "size": 90}
        ]
    }
    """.utf8)
}
