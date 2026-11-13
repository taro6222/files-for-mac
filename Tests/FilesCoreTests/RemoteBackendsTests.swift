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
}
