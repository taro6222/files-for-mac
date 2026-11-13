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

@Test func remoteCommandExecutorSeparatesInputOutputAndExitStatus() async throws {
    let cat = RemoteCommandPlan(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: Data("hello".utf8), redactedDescription: "cat")
    let result = try await RemoteCommandExecutor().execute(cat)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello"); #expect(result.standardError.isEmpty); #expect(result.terminationStatus == 0)
    let failure = RemoteCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], standardInput: Data(), redactedDescription: "false")
    await #expect(throws: RemoteExecutionError.nonzeroExit(1)) { try await RemoteCommandExecutor().execute(failure) }
}

@Test func remoteCommandExecutorEnforcesOutputLimitAndCancellation() async throws {
    let output = RemoteCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["12345"], standardInput: Data(), redactedDescription: "printf")
    await #expect(throws: RemoteExecutionError.outputLimitExceeded) { try await RemoteCommandExecutor().execute(output, outputLimit: 4) }
    let sleep = RemoteCommandPlan(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], standardInput: Data(), redactedDescription: "sleep")
    let task = Task { try await RemoteCommandExecutor().execute(sleep) }
    try await Task.sleep(for: .milliseconds(50)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func ftpListParserPreservesUnicodePathsAndRejectsAmbiguousEntries() throws {
    let entries = try FTPRemoteProvider.parseList(Data("alpha.txt\r\n한글 폴더\n.\n..\n".utf8), parent: "/team")
    #expect(entries == [RemoteDirectoryEntry(name: "alpha.txt", remotePath: "/team/alpha.txt"),
                        RemoteDirectoryEntry(name: "한글 폴더", remotePath: "/team/한글 폴더")])
    #expect(try FTPRemoteProvider.parseList(Data("root.txt\n".utf8), parent: "/").first?.remotePath == "/root.txt")
    #expect(throws: RemoteBackendError.invalidListing) { try FTPRemoteProvider.parseList(Data([0xff]), parent: "/") }
    #expect(throws: RemoteBackendError.invalidListing) { try FTPRemoteProvider.parseList(Data("nested/name\n".utf8), parent: "/") }
    #expect(throws: RemoteBackendError.listingLimitExceeded) { try FTPRemoteProvider.parseList(Data("one\ntwo\n".utf8), parent: "/", maximumEntries: 1) }
    let detailed = try FTPRemoteProvider.parseList(Data("drwxr-xr-x   2 owner group 4096 Jan 01 12:00 Folder With Spaces\n-rw-r--r--   1 owner group   10 Jan 01 12:00 file name.txt\nlrwxr-xr-x   1 owner group    4 Jan 01 12:00 link -> file\n".utf8), parent: "/team")
    #expect(detailed.map(\.name) == ["Folder With Spaces", "file name.txt"]); #expect(detailed[0].isDirectory); #expect(!detailed[1].isDirectory)
    let dos = try FTPRemoteProvider.parseList(Data("01-29-97  11:32PM       <DIR>          Program Files\r\n04-27-00  09:09PM       2246 read me.txt\r\n".utf8), parent: "/")
    #expect(dos.map(\.name) == ["Program Files", "read me.txt"]); #expect(dos[0].isDirectory); #expect(!dos[1].isDirectory)
    #expect(throws: RemoteBackendError.unsupportedListingFormat) {
        try FTPRemoteProvider.parseList(Data("01-29-97  11:32PM       ?????          ambiguous.txt\r\n".utf8), parent: "/")
    }
}

@Test func ftpDownloadPublishIsSameDirectoryAtomicAndNeverReplaces() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ftp-download-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let staging = root.appendingPathComponent(".files-download-fixture.tmp"), destination = root.appendingPathComponent("한글 file.txt")
    try Data("complete".utf8).write(to: staging)
    try FTPRemoteProvider.publishDownload(staging: staging, destination: destination, fileManager: fm)
    #expect(!fm.fileExists(atPath: staging.path)); #expect(try String(contentsOf: destination, encoding: .utf8) == "complete")
    let replacement = root.appendingPathComponent(".files-download-replacement.tmp"); try Data("new".utf8).write(to: replacement)
    #expect(throws: RemoteBackendError.destinationExists) { try FTPRemoteProvider.publishDownload(staging: replacement, destination: destination, fileManager: fm) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "complete"); #expect(try String(contentsOf: replacement, encoding: .utf8) == "new")
}

@Test func ftpDownloadPublishRejectsLinksForeignStagingAndMissingFiles() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ftp-download-invalid-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("result.txt"), real = root.appendingPathComponent("real.txt"), link = root.appendingPathComponent(".files-download-link.tmp")
    try Data("real".utf8).write(to: real); try fm.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: RemoteBackendError.invalidStaging) { try FTPRemoteProvider.publishDownload(staging: link, destination: destination, fileManager: fm) }
    let foreign = fm.temporaryDirectory.appendingPathComponent(".files-download-foreign-\(UUID()).tmp"); defer { try? fm.removeItem(at: foreign) }; try Data().write(to: foreign)
    #expect(throws: RemoteBackendError.invalidStaging) { try FTPRemoteProvider.publishDownload(staging: foreign, destination: destination, fileManager: fm) }
    #expect(throws: RemoteBackendError.invalidStaging) { try FTPRemoteProvider.publishDownload(staging: root.appendingPathComponent(".files-download-missing.tmp"), destination: destination, fileManager: fm) }
}

@Test func ftpUploadPlansUseRemoteStagingRenameAndCleanupWithoutArgumentSecrets() throws {
    let profile = try RemoteConnectionProfile(name: "FTP", remoteProtocol: .ftps, host: "files.example.com")
    let credential = RemoteCredential(username: "alice", secret: Data("secret".utf8)), source = URL(fileURLWithPath: "/tmp/local file.txt")
    let builder = CurlFTPCommandBuilder(), staging = "/team/.files-upload-fixture.tmp", final = "/team/final file.txt"
    let upload = try builder.command(profile: profile, credential: credential, remotePath: staging, intent: .uploadAndRename(local: source, finalRemotePath: final))
    let config = String(decoding: upload.standardInput, as: UTF8.self)
    #expect(config.contains("upload-file =")); #expect(config.contains("RNFR \(staging)")); #expect(config.contains("RNTO \(final)"))
    #expect(!upload.arguments.joined().contains("alice")); #expect(!upload.arguments.joined().contains("secret"))
    let cleanup = try builder.command(profile: profile, credential: credential, remotePath: staging, intent: .delete)
    let cleanupConfig = String(decoding: cleanup.standardInput, as: UTF8.self)
    #expect(cleanupConfig.contains("DELE \(staging)")); #expect(cleanupConfig.contains("list-only"))
    #expect(FTPServerCapabilities().renameRefusesExistingDestination == false)
}

@Test func ftpUploadPlansRejectUnsafeFinalPathsAndSources() async throws {
    let profile = try RemoteConnectionProfile(name: "FTP", remoteProtocol: .ftp, host: "host")
    let credential = RemoteCredential(username: "user", secret: Data("secret".utf8)), source = URL(fileURLWithPath: "/tmp/file")
    #expect(throws: RemoteBackendError.invalidRemotePath) {
        try CurlFTPCommandBuilder().command(profile: profile, credential: credential, remotePath: "/.files-upload.tmp", intent: .uploadAndRename(local: source, finalRemotePath: "relative"))
    }
    await #expect(throws: RemoteBackendError.unverifiedServerCapability) {
        try await FTPRemoteProvider().upload(profile: profile, credential: credential, source: source, remotePath: "/file", capabilities: .init())
    }
}

@Test func ftpLocalFixtureListsAndDownloadsThroughRealCurl() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let portText = environment["FILES_TEST_FTP_PORT"], let port = Int(portText),
          let username = environment["FILES_TEST_FTP_USERNAME"], let password = environment["FILES_TEST_FTP_PASSWORD"] else { return }
    let profile = try RemoteConnectionProfile(name: "Fixture", remoteProtocol: .ftp, host: "127.0.0.1", port: port)
    let credential = RemoteCredential(username: username, secret: Data(password.utf8)), provider = FTPRemoteProvider()
    let entries = try await provider.list(profile: profile, credential: credential, remotePath: "/")
    #expect(entries.contains { $0.name == "fixture-한글.txt" })
    #expect(entries.contains { $0.name == "fixture-folder" && $0.isDirectory })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-live-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("downloaded.txt")
    _ = try await provider.download(profile: profile, credential: credential, remotePath: "/fixture-한글.txt", destination: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "live-fixture")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".files-download-") })
    let capabilities = try await provider.probeRenameSafety(profile: profile, credential: credential)
    #expect(capabilities.renameRefusesExistingDestination == false)
    let afterProbe = try await provider.list(profile: profile, credential: credential, remotePath: "/")
    let probeArtifacts = afterProbe.filter { $0.name.hasPrefix(".files-probe-") }
    #expect(probeArtifacts.isEmpty)
}

@Test func ftpsLocalFixtureValidatesCertificateAndHostnameThroughRealCurl() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let validPortText = environment["FILES_TEST_FTPS_VALID_PORT"], let validPort = Int(validPortText),
          let mismatchPortText = environment["FILES_TEST_FTPS_MISMATCH_PORT"], let mismatchPort = Int(mismatchPortText),
          let username = environment["FILES_TEST_FTP_USERNAME"], let password = environment["FILES_TEST_FTP_PASSWORD"],
          let caPath = environment["FILES_TEST_FTPS_CA"] else { return }
    let credential = RemoteCredential(username: username, secret: Data(password.utf8))
    let valid = try RemoteConnectionProfile(name: "Valid FTPS", remoteProtocol: .ftps, host: "localhost", port: validPort)
    let provider = FTPRemoteProvider(trustedCAFile: URL(fileURLWithPath: caPath))
    let entries = try await provider.list(profile: valid, credential: credential, remotePath: "/")
    #expect(entries.contains { $0.name == "fixture-한글.txt" })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftps-live-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("downloaded.txt")
    _ = try await provider.download(profile: valid, credential: credential, remotePath: "/fixture-한글.txt", destination: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "live-ftps-fixture")
    await #expect(throws: RemoteExecutionError.self) {
        try await FTPRemoteProvider().list(profile: valid, credential: credential, remotePath: "/")
    }
    let mismatch = try RemoteConnectionProfile(name: "Mismatch FTPS", remoteProtocol: .ftps, host: "localhost", port: mismatchPort)
    await #expect(throws: RemoteExecutionError.self) {
        try await provider.list(profile: mismatch, credential: credential, remotePath: "/")
    }
}
