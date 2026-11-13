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
