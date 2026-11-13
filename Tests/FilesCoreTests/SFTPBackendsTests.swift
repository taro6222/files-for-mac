import Foundation
import Testing
@testable import FilesCore

@Test func sftpPlansRequireStrictPinnedHostTrustAndKeyOnlyAuthentication() throws {
    let profile = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "ssh.example.com", port: 2222)
    let key = SFTPKeyConfiguration(username: "alice", identityFile: URL(fileURLWithPath: "/private/keys/id_ed25519"), knownHostsFile: URL(fileURLWithPath: "/private/trust/known_hosts"))
    let plan = try SFTPCommandBuilder().command(profile: profile, key: key, intent: .list(remotePath: "/team/한글 폴더"))
    let config = String(decoding: plan.privateSSHConfiguration, as: UTF8.self), batch = String(decoding: plan.batchInput, as: UTF8.self)
    #expect(plan.executable.path == "/usr/bin/sftp"); #expect(plan.arguments == ["-q", "-b", "-", "-F", "<private-config>", "files-remote"])
    #expect(config.contains("StrictHostKeyChecking yes")); #expect(config.contains("UserKnownHostsFile")); #expect(config.contains("IdentitiesOnly yes"))
    #expect(config.contains("BatchMode yes")); #expect(config.contains("PasswordAuthentication no")); #expect(config.contains("KbdInteractiveAuthentication no"))
    #expect(batch == "ls -1 \"/team/한글 폴더\"\n"); #expect(!plan.redactedDescription.contains("alice")); #expect(!plan.redactedDescription.contains("ssh.example.com"))
}

@Test func sftpPlansEscapeBatchPathsAndRejectUnsafeInputs() throws {
    let profile = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host")
    let key = SFTPKeyConfiguration(username: "user", identityFile: URL(fileURLWithPath: "/key"), knownHostsFile: URL(fileURLWithPath: "/known"))
    let plan = try SFTPCommandBuilder().command(profile: profile, key: key, intent: .download(remotePath: "/a/quoted\" file", local: URL(fileURLWithPath: "/tmp/local file")))
    #expect(String(decoding: plan.batchInput, as: UTF8.self).contains("\\\""))
    #expect(throws: SFTPBackendError.invalidPath) { try SFTPCommandBuilder().command(profile: profile, key: key, intent: .remove(remotePath: "relative")) }
    let badUser = SFTPKeyConfiguration(username: "bad user", identityFile: key.identityFile, knownHostsFile: key.knownHostsFile)
    #expect(throws: SFTPBackendError.invalidUsername) { try SFTPCommandBuilder().command(profile: profile, key: badUser, intent: .list(remotePath: "/")) }
    let ftp = try RemoteConnectionProfile(name: "FTP", remoteProtocol: .ftp, host: "host")
    #expect(throws: SFTPBackendError.unsupportedProtocol) { try SFTPCommandBuilder().command(profile: ftp, key: key, intent: .list(remotePath: "/")) }
}

@Test func sftpTrustAndIdentityFilesMustBeRegularAndNotLinks() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sftp-files-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let identity = root.appendingPathComponent("id"), trust = root.appendingPathComponent("known_hosts"), link = root.appendingPathComponent("linked-hosts")
    try Data("key".utf8).write(to: identity); try Data("host key".utf8).write(to: trust); try fm.createSymbolicLink(at: link, withDestinationURL: trust)
    let builder = SFTPCommandBuilder(); try builder.validateFiles(.init(username: "user", identityFile: identity, knownHostsFile: trust))
    #expect(throws: SFTPBackendError.invalidTrustStore) { try builder.validateFiles(.init(username: "user", identityFile: identity, knownHostsFile: link)) }
    #expect(throws: SFTPBackendError.invalidIdentity) { try builder.validateFiles(.init(username: "user", identityFile: root.appendingPathComponent("missing"), knownHostsFile: trust)) }
}
