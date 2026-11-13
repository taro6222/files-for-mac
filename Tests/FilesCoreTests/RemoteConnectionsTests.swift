import Foundation
import Testing
@testable import FilesCore

@Test func remoteProfilesNormalizeSafeEndpointsWithoutEmbeddingCredentials() throws {
    let profile = try RemoteConnectionProfile(name: " Work SFTP ", remoteProtocol: .sftp,
        host: " Files.Example.COM ", rootPath: "/team", username: "alice", credentialID: "keychain:fixture")
    #expect(profile.name == "Work SFTP")
    #expect(profile.host == "files.example.com")
    #expect(profile.port == 22)
    #expect(profile.endpoint == "sftp://files.example.com:22/team")
    #expect(!profile.endpoint.contains("alice")); #expect(!profile.endpoint.contains("keychain"))
    let encoded = try JSONEncoder().encode(profile)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("password"))
    #expect(try JSONDecoder().decode(RemoteConnectionProfile.self, from: encoded) == profile)
}

@Test(arguments: RemoteProtocol.allCases)
func remoteProtocolsUseExplicitSecurityAndTransportCapabilities(remoteProtocol: RemoteProtocol) throws {
    let profile = try RemoteConnectionProfile(name: remoteProtocol.rawValue, remoteProtocol: remoteProtocol, host: "localhost")
    #expect(profile.port == remoteProtocol.defaultPort)
    let capability = RemoteProviderCapabilities.planned(for: remoteProtocol)
    #expect(capability.mountedVolume == (remoteProtocol == .smb))
    #expect(capability.directConnection == (remoteProtocol != .smb))
    #expect(capability.tlsValidation == (remoteProtocol == .ftps))
    #expect(capability.hostKeyValidation == (remoteProtocol == .sftp))
}

@Test func remoteProfilesRejectUnsafeOrAmbiguousAddresses() {
    #expect(throws: RemoteConnectionValidationError.emptyName) { try RemoteConnectionProfile(name: " ", remoteProtocol: .ftp, host: "host") }
    #expect(throws: RemoteConnectionValidationError.invalidHost) { try RemoteConnectionProfile(name: "x", remoteProtocol: .ftp, host: "bad host") }
    #expect(throws: RemoteConnectionValidationError.embeddedCredential) { try RemoteConnectionProfile(name: "x", remoteProtocol: .ftp, host: "user@host") }
    #expect(throws: RemoteConnectionValidationError.invalidPort) { try RemoteConnectionProfile(name: "x", remoteProtocol: .ftps, host: "host", port: 0) }
    #expect(throws: RemoteConnectionValidationError.invalidRootPath) { try RemoteConnectionProfile(name: "x", remoteProtocol: .sftp, host: "host", rootPath: "relative") }
    #expect(throws: RemoteConnectionValidationError.embeddedCredential) { try RemoteConnectionProfile(name: "x", remoteProtocol: .sftp, host: "host", username: "user:name") }
}

@Test func smbMountURLsDelegateAuthenticationWithoutEmbeddingSecrets() throws {
    let profile = try RemoteConnectionProfile(name: "NAS", remoteProtocol: .smb, host: "nas.local", rootPath: "/Team Files", username: "reader", credentialID: "keychain-id")
    let url = try profile.smbMountURL()
    #expect(url.scheme == "smb"); #expect(url.host == "nas.local"); #expect(url.path == "/Team Files")
    #expect(url.user == nil); #expect(url.password == nil); #expect(!url.absoluteString.contains("reader")); #expect(!url.absoluteString.contains("keychain"))
    let ftp = try RemoteConnectionProfile(name: "FTP", remoteProtocol: .ftp, host: "ftp.example.com")
    #expect(throws: RemoteConnectionValidationError.unsupportedProtocol) { try ftp.smbMountURL() }
    let noShare = try RemoteConnectionProfile(name: "NAS", remoteProtocol: .smb, host: "nas.local")
    #expect(throws: RemoteConnectionValidationError.missingShare) { try noShare.smbMountURL() }
}

@Test func remoteProfileStoreSortsRoundTripsAndUsesPrivatePermissions() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("remote-profiles-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let store = RemoteProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
    let z = try RemoteConnectionProfile(name: "Zulu", remoteProtocol: .ftp, host: "ftp.example.com")
    let a = try RemoteConnectionProfile(name: "Alpha", remoteProtocol: .smb, host: "nas.local", username: "reader", credentialID: "credential-a")
    try store.save([z, a], fileManager: fm)
    try store.save([a, z], fileManager: fm)
    #expect(try store.load(fileManager: fm).map(\.name) == ["Alpha", "Zulu"])
    let permissions = try #require(fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
    let serialized = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(!serialized.contains("secret")); #expect(!serialized.contains("password"))
    #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".tmp") })
}

@Test func remoteProfileStoreRejectsCorruptAndInvalidPersistedProfiles() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("remote-corrupt-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let store = RemoteProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
    try Data("not-json".utf8).write(to: store.fileURL)
    #expect(throws: (any Error).self) { try store.load(fileManager: fm) }
    let invalid = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Bad\",\"remoteProtocol\":\"ftp\",\"host\":\"user@host\",\"port\":21,\"rootPath\":\"/\"}]"
    try Data(invalid.utf8).write(to: store.fileURL)
    #expect(throws: RemoteConnectionValidationError.embeddedCredential) { try store.load(fileManager: fm) }
}
