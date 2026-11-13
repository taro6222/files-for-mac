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

@Test func sftpUploadPlanStagesThenRenamesWithoutExposingTheFinalPathEarly() throws {
    let profile = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host")
    let key = SFTPKeyConfiguration(username: "user", identityFile: URL(fileURLWithPath: "/key"), knownHostsFile: URL(fileURLWithPath: "/known"))
    let plan = try SFTPCommandBuilder().command(profile: profile, key: key,
        intent: .uploadAndRename(local: URL(fileURLWithPath: "/tmp/한글 file"), stagingRemotePath: "/team/.files-sftp-upload-id.tmp", finalRemotePath: "/team/최종 file"))
    #expect(String(decoding: plan.batchInput, as: UTF8.self) == "put \"/tmp/한글 file\" \"/team/.files-sftp-upload-id.tmp\"\nrename \"/team/.files-sftp-upload-id.tmp\" \"/team/최종 file\"\n")
    #expect(throws: SFTPBackendError.invalidPath) {
        try SFTPCommandBuilder().command(profile: profile, key: key,
            intent: .uploadAndRename(local: URL(fileURLWithPath: "/tmp/file"), stagingRemotePath: "relative", finalRemotePath: "/final"))
    }
    let rename = try SFTPCommandBuilder().command(profile: profile, key: key,
        intent: .rename(remotePath: "/probe-a", finalRemotePath: "/probe-b"))
    #expect(String(decoding: rename.batchInput, as: UTF8.self) == "rename \"/probe-a\" \"/probe-b\"\n")
}

@Test func sftpDownloadPublishRequiresOwnedSameDirectoryRegularStaging() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sftp-publish-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("final.txt"), staging = root.appendingPathComponent(".files-sftp-download-id.tmp")
    try Data("payload".utf8).write(to: staging)
    try SFTPRemoteProvider.publishDownload(staging: staging, destination: destination, fileManager: fm)
    #expect(try Data(contentsOf: destination) == Data("payload".utf8)); #expect(!fm.fileExists(atPath: staging.path))
    let replacement = root.appendingPathComponent(".files-sftp-download-replacement.tmp"); try Data("new".utf8).write(to: replacement)
    #expect(throws: SFTPBackendError.destinationExists) { try SFTPRemoteProvider.publishDownload(staging: replacement, destination: destination, fileManager: fm) }
    #expect(try Data(contentsOf: destination) == Data("payload".utf8))
    let source = root.appendingPathComponent("source"); try Data("source".utf8).write(to: source)
    let link = root.appendingPathComponent(".files-sftp-download-link.tmp"); try fm.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: SFTPBackendError.invalidStaging) { try SFTPRemoteProvider.publishDownload(staging: link, destination: root.appendingPathComponent("link-result"), fileManager: fm) }
    let foreign = root.appendingPathComponent("foreign.tmp"); try Data("foreign".utf8).write(to: foreign)
    #expect(throws: SFTPBackendError.invalidStaging) { try SFTPRemoteProvider.publishDownload(staging: foreign, destination: root.appendingPathComponent("foreign-result"), fileManager: fm) }
}

@Test func sftpUploadSafetyDefaultsToBlockedAndUsesSiblingStagingPaths() async throws {
    #expect(SFTPServerCapabilities().renameRefusesExistingDestination == false)
    let staging = try SFTPRemoteProvider.remoteStagingPath(for: "/team/최종 file")
    #expect(staging.hasPrefix("/team/.files-sftp-upload-")); #expect(staging.hasSuffix(".tmp"))
    #expect(throws: SFTPBackendError.invalidPath) { try SFTPRemoteProvider.remoteStagingPath(for: "relative") }
    let profile = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host")
    let key = SFTPKeyConfiguration(username: "user", identityFile: URL(fileURLWithPath: "/missing-key"), knownHostsFile: URL(fileURLWithPath: "/missing-trust"))
    await #expect(throws: SFTPBackendError.unverifiedServerCapability) {
        try await SFTPRemoteProvider().upload(profile: profile, key: key, local: URL(fileURLWithPath: "/missing-source"), remotePath: "/final")
    }
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

@Test func sftpExecutorUsesPrivatePermissionsAndRemovesConfiguration() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sftp-executor-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let modePlan = SFTPCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/stat"), arguments: ["-f", "%Lp", "<private-config>"],
        batchInput: Data(), privateSSHConfiguration: Data("private-value".utf8), redactedDescription: "stat private config")
    let mode = try await SFTPCommandExecutor().execute(modePlan, temporaryRoot: root, fileManager: fm)
    #expect(String(decoding: mode.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "600")
    #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
    let catPlan = SFTPCommandPlan(executable: URL(fileURLWithPath: "/bin/cat"), arguments: ["<private-config>", "-"],
        batchInput: Data("batch-value".utf8), privateSSHConfiguration: Data("config-value\n".utf8), redactedDescription: "cat private config")
    let output = try await SFTPCommandExecutor().execute(catPlan, temporaryRoot: root, fileManager: fm)
    #expect(String(decoding: output.standardOutput, as: UTF8.self) == "config-value\nbatch-value")
    #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func sftpExecutorRejectsInvalidPrivateConfigurationPlans() async {
    let missing = SFTPCommandPlan(executable: URL(fileURLWithPath: "/bin/true"), arguments: [], batchInput: Data(), privateSSHConfiguration: Data(), redactedDescription: "invalid")
    await #expect(throws: SFTPBackendError.invalidPrivateConfiguration) { try await SFTPCommandExecutor().execute(missing) }
    let duplicate = SFTPCommandPlan(executable: URL(fileURLWithPath: "/bin/true"), arguments: ["<private-config>", "<private-config>"], batchInput: Data(), privateSSHConfiguration: Data(), redactedDescription: "invalid")
    await #expect(throws: SFTPBackendError.invalidPrivateConfiguration) { try await SFTPCommandExecutor().execute(duplicate) }
}

@Test func sftpListParserPreservesUnicodeAndRejectsUnsafeOutput() throws {
    let entries = try SFTPRemoteProvider.parseList(Data("alpha.txt\n한글 폴더\n.\n..\n".utf8), parent: "/team")
    #expect(entries == [RemoteDirectoryEntry(name: "alpha.txt", remotePath: "/team/alpha.txt"), RemoteDirectoryEntry(name: "한글 폴더", remotePath: "/team/한글 폴더")])
    #expect(throws: SFTPBackendError.invalidListing) { try SFTPRemoteProvider.parseList(Data([0xff]), parent: "/") }
    #expect(throws: SFTPBackendError.invalidListing) { try SFTPRemoteProvider.parseList(Data("nested/name\n".utf8), parent: "/") }
    #expect(throws: SFTPBackendError.listingLimitExceeded) { try SFTPRemoteProvider.parseList(Data("one\ntwo\n".utf8), parent: "/", maximumEntries: 1) }
    let openSSH = try SFTPRemoteProvider.parseList(Data("sftp> ls -1 \"/team\"\n/team/alpha.txt\n/team/한글 폴더\n".utf8), parent: "/team")
    #expect(openSSH.map(\.name) == ["alpha.txt", "한글 폴더"])
    #expect(throws: SFTPBackendError.invalidListing) { try SFTPRemoteProvider.parseList(Data("/other/nested.txt\n".utf8), parent: "/team") }
}

@Test func sftpIdentityBookmarksRoundTripRegularFilesAndRejectLinks() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sftp-bookmark-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let identity = root.appendingPathComponent("id_ed25519"), link = root.appendingPathComponent("linked-key")
    try Data("private-key-fixture".utf8).write(to: identity); try fm.createSymbolicLink(at: link, withDestinationURL: identity)
    let reference = SFTPIdentityReference(), bookmark = try reference.create(for: identity, securityScoped: false)
    let resolved = try reference.resolve(bookmark, securityScoped: false)
    #expect(resolved.url.standardizedFileURL == identity.standardizedFileURL); #expect(resolved.stale == false)
    #expect(throws: SFTPBackendError.invalidIdentity) { try reference.create(for: link, securityScoped: false) }
    #expect(throws: (any Error).self) { try reference.resolve(Data("invalid".utf8), securityScoped: false) }
}

@Test func sftpConnectionPreparationRequiresProfileIdentityAndApprovedTrust() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sftp-ready-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let identity = root.appendingPathComponent("id"), trust = root.appendingPathComponent("known_hosts")
    try Data("key".utf8).write(to: identity); try Data("host key".utf8).write(to: trust)
    let bookmark = try SFTPIdentityReference().create(for: identity, securityScoped: false)
    let profile = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host", username: "alice", identityBookmark: bookmark)
    let prepared = try SFTPConnectionPreparation().prepare(profile: profile, knownHostsFile: trust, securityScoped: false)
    #expect(prepared.key.username == "alice"); #expect(prepared.key.identityFile.standardizedFileURL == identity.standardizedFileURL)
    let missingIdentity = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host", username: "alice")
    #expect(throws: SFTPBackendError.missingIdentity) { try SFTPConnectionPreparation().prepare(profile: missingIdentity, knownHostsFile: trust, securityScoped: false) }
    let missingUser = try RemoteConnectionProfile(name: "SFTP", remoteProtocol: .sftp, host: "host", identityBookmark: bookmark)
    #expect(throws: SFTPBackendError.invalidUsername) { try SFTPConnectionPreparation().prepare(profile: missingUser, knownHostsFile: trust, securityScoped: false) }
    #expect(throws: SFTPBackendError.invalidTrustStore) { try SFTPConnectionPreparation().prepare(profile: profile, knownHostsFile: root.appendingPathComponent("missing"), securityScoped: false) }
}

@Test func sftpLocalFixtureListsDownloadsAndProbesRenameThroughOpenSSH() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let portText = environment["FILES_TEST_SFTP_PORT"], let port = Int(portText),
          let username = environment["FILES_TEST_SFTP_USERNAME"],
          let identityPath = environment["FILES_TEST_SFTP_IDENTITY"],
          let knownHostsPath = environment["FILES_TEST_SFTP_KNOWN_HOSTS"],
          let remoteRoot = environment["FILES_TEST_SFTP_REMOTE_ROOT"] else { return }
    let profile = try RemoteConnectionProfile(name: "Fixture", remoteProtocol: .sftp, host: "127.0.0.1", port: port, rootPath: remoteRoot, username: username)
    let key = SFTPKeyConfiguration(username: username, identityFile: URL(fileURLWithPath: identityPath), knownHostsFile: URL(fileURLWithPath: knownHostsPath))
    let provider = SFTPRemoteProvider(), entries = try await provider.list(profile: profile, key: key, remotePath: remoteRoot)
    #expect(entries.contains { $0.name == "fixture-한글.txt" })
    let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-live-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: localRoot) }; try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    let destination = localRoot.appendingPathComponent("downloaded.txt")
    _ = try await provider.download(profile: profile, key: key, remotePath: remoteRoot + "/fixture-한글.txt", destination: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "live-fixture")
    #expect(try FileManager.default.contentsOfDirectory(atPath: localRoot.path).allSatisfy { !$0.hasPrefix(".files-sftp-download-") })
    let capabilities = try await provider.probeRenameSafety(profile: profile, key: key, parent: remoteRoot)
    #expect(capabilities.renameRefusesExistingDestination == false)
    let afterProbe = try await provider.list(profile: profile, key: key, remotePath: remoteRoot)
    #expect(afterProbe.allSatisfy { !$0.name.hasPrefix(".files-sftp-probe-") })
}
