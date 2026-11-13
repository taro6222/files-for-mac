import Foundation
import Testing
@testable import FilesCore

@Test func remoteBackendProbeMatchesBuiltInMacOSTools() {
    let available = RemoteBackendProbe().available()
    #expect(available.contains { $0.kind == .curlFTP && $0.protocols == [.ftp, .ftps] })
    #expect(available.contains { $0.kind == .openSSH && $0.protocols == [.sftp] })
    #expect(!available.flatMap(\.protocols).contains(.smb))
}

@Test(arguments: [RemoteProtocol.ftp, .ftps])
func curlFTPPlansKeepCredentialsOffArgumentsAndDescriptions(remoteProtocol: RemoteProtocol) throws {
    let profile = try RemoteConnectionProfile(name: "Remote", remoteProtocol: remoteProtocol, host: "files.example.com", rootPath: "/team")
    let credential = RemoteCredential(username: "alice", secret: Data("p@ss word".utf8))
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("download.txt")
    let plan = try CurlFTPCommandBuilder().command(profile: profile, credential: credential, remotePath: "/team/한글 file.txt", intent: .download(local: target))
    #expect(plan.executable.path == "/usr/bin/curl"); #expect(plan.arguments == ["-q", "--config", "-"])
    #expect(!plan.arguments.joined().contains("alice")); #expect(!plan.arguments.joined().contains("p@ss"))
    #expect(!plan.redactedDescription.contains("files.example.com")); #expect(!plan.redactedDescription.contains("alice"))
    let config = String(decoding: plan.standardInput, as: UTF8.self)
    #expect(config.contains("alice:p@ss word")); #expect(config.contains("output ="))
    #expect(config.contains("ssl-reqd") == (remoteProtocol == .ftps))
}

@Test func curlFTPPlansRejectUnsupportedProtocolsAndUnsafeInput() throws {
    let sftp = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host")
    let credential = RemoteCredential(username: "user", secret: Data("secret".utf8))
    #expect(throws: RemoteBackendError.unsupportedProtocol) { try CurlFTPCommandBuilder().command(profile: sftp, credential: credential, remotePath: "/", intent: .list) }
    let ftp = try RemoteConnectionProfile(name: "FTP", remoteProtocol: .ftp, host: "host")
    #expect(throws: RemoteBackendError.invalidRemotePath) { try CurlFTPCommandBuilder().command(profile: ftp, credential: credential, remotePath: "relative", intent: .list) }
    #expect(throws: RemoteBackendError.invalidCredential) { try CurlFTPCommandBuilder().command(profile: ftp, credential: .init(username: "bad\nuser", secret: Data()), remotePath: "/", intent: .list) }
}
