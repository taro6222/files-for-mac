import Foundation
import Testing
import Darwin
@testable import FilesCore

private func resolverManifest() -> [String: Any] {
    let hash = String(repeating: "a", count: 64)
    let inputs: [String: Any] = ["architecture": "arm64", "SDKVersion": "26.06", "SDKSourceSHA256": SevenZipBundleVerifier.sourceSHA256,
        "minimumOS": "14.0", "helperSourcesSHA256": Dictionary(uniqueKeysWithValues: SevenZipBundleVerifier.helperSources.map { ($0, hash) }),
        "buildRecipeSHA256": hash]
    return ["version": 1, "SDKVersion": "26.06", "SDKSourceSHA256": SevenZipBundleVerifier.sourceSHA256, "architectures": ["arm64"],
            "filesSHA256": Dictionary(uniqueKeysWithValues: SevenZipBundleVerifier.files.map { ($0, hash) }), "builds": ["arm64": ["inputs": inputs]]]
}

@Test func sevenZipSDKBundleManifestRejectsUntrustedMetadata() throws {
    let valid = resolverManifest()
    func decode(_ value: [String: Any]) throws -> SevenZipBundleVerifier.Manifest {
        try JSONDecoder().decode(SevenZipBundleVerifier.Manifest.self, from: JSONSerialization.data(withJSONObject: value))
    }
    try decode(valid).validate()
    for (key, value) in [("version", true as Any), ("SDKVersion", "old" as Any), ("SDKSourceSHA256", String(repeating: "0", count: 64) as Any),
                         ("architectures", ["arm64", "arm64"] as Any), ("filesSHA256", ["../escape": String(repeating: "a", count: 64)] as Any)] {
        var changed = valid; changed[key] = value
        #expect(throws: (any Error).self) { try decode(changed).validate() }
    }
}

@Test func sevenZipSDKBundleRejectsMissingLinksAndNonregularManifest() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sdk-resolver-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
    await #expect(throws: SevenZipBundleError.unavailable) { try await SevenZipArchiveProvider.bundled(in: root.appendingPathComponent("missing.app")) }
    await #expect(throws: SevenZipBundleError.unavailable) { try await SevenZipArchiveProvider.bundled(in: URL(string: "https://example.invalid/app")!) }
    let real = root.appendingPathComponent("real.app"), link = root.appendingPathComponent("link.app")
    try fm.createDirectory(at: real, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    await #expect(throws: SevenZipBundleError.unavailable) { try await SevenZipArchiveProvider.bundled(in: link) }
    let resources = real.appendingPathComponent(SevenZipBundleVerifier.resource)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "org.taro6222.files-for-mac", "CFBundleExecutable": "FilesMac", "FilesReleaseChannel": "preview", "FilesArchiveSDKVersion": "26.06"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: real.appendingPathComponent("Contents/Info.plist"))
    #expect(mkfifo(resources.appendingPathComponent("manifest.json").path, 0o600) == 0)
    await #expect(throws: SevenZipBundleError.invalidLayout) { try await SevenZipArchiveProvider.bundled(in: real) }
    #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["link.app", "real.app"])
}

@Test func sevenZipSDKBundleCancellationAndInvalidTimeout() async throws {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SevenZipArchiveProvider.bundled(in: URL(fileURLWithPath: "/does-not-exist.app"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    for timeout in [Double.nan, -1, 0, 86401] {
        await #expect(throws: SevenZipWorkerError.invalidConfiguration) {
            try await SevenZipArchiveProvider.bundled(in: URL(fileURLWithPath: "/does-not-exist.app"), timeout: timeout)
        }
    }
}

@Test func sevenZipSDKBundleDeveloperIDRequirementRejectsInvalidTeam() throws {
    // Parsing a requirement is not proof of a certificate, signing, or notarization.
    _ = try SevenZipBundleVerifier.developerIDRequirement(team: "ABCDE12345")
    for team in [nil, "", "short", "abcde12345", "ABCDE1234\"", "ABCDE123456"] {
        #expect(throws: SevenZipBundleError.invalidSignature) { try SevenZipBundleVerifier.developerIDRequirement(team: team) }
    }
}

@Test func sevenZipSDKBundleBindsExecutingHostIdentity() async throws {
    let executable = try #require(Bundle.main.executableURL)
    let signature = await CodeSignatureInspector.inspect(executable)
    // Test runners need not be signed on every development toolchain; unsigned hosts are rejected.
    if signature.state == .unsigned {
        #expect(throws: SevenZipBundleError.invalidSignature) { try SevenZipBundleVerifier.checkRunningHost(against: executable) }
    } else {
        // SwiftPM's on-disk test container may fail resource validation while the running
        // code still matches its designated identity. The factory separately validates app resources.
        try SevenZipBundleVerifier.checkRunningHost(against: executable)
    }
}

@Test func sevenZipSDKBundleWorkerPolicyRejectsExpandedAuthority() throws {
    let sandbox: [String: Any] = ["com.apple.security.app-sandbox": true]
    let info: [String: Any] = ["CFBundleIdentifier": "org.taro6222.files-for-mac.sevenzip-worker", "CFBundleExecutable": "SevenZipWorker", "LSBackgroundOnly": true]
    try SevenZipBundleVerifier.validateWorkerPolicy(entitlements: sandbox, info: info)
    for policy: [String: Any] in [[:], ["com.apple.security.app-sandbox": false], ["com.apple.security.app-sandbox": 1],
                                ["com.apple.security.app-sandbox": true, "com.apple.security.network.client": true],
                                ["com.apple.security.app-sandbox": true, "com.apple.security.network.server": true],
                                ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true],
                                ["com.apple.security.app-sandbox": true, "com.apple.security.files.user-selected.read-write": true]] {
        #expect(throws: SevenZipBundleError.invalidSignature) { try SevenZipBundleVerifier.validateWorkerPolicy(entitlements: policy, info: info) }
    }
    for (key, value) in [("CFBundleIdentifier", "wrong" as Any), ("CFBundleExecutable", "wrong" as Any), ("LSBackgroundOnly", false as Any)] {
        var changed = info; changed[key] = value
        #expect(throws: SevenZipBundleError.invalidSignature) { try SevenZipBundleVerifier.validateWorkerPolicy(entitlements: sandbox, info: changed) }
    }
}
