import Foundation

public enum SFTPIntent: Sendable, Equatable {
    case list(remotePath: String)
    case download(remotePath: String, local: URL)
    case upload(local: URL, remotePath: String)
    case remove(remotePath: String)
}

public enum SFTPBackendError: Error, Sendable, Equatable {
    case unsupportedProtocol, invalidPath, invalidUsername, invalidTrustStore, invalidIdentity, staleIdentity, missingIdentity, invalidPrivateConfiguration, invalidListing, listingLimitExceeded
}

public struct SFTPKeyConfiguration: Sendable, Equatable {
    public let username: String
    public let identityFile: URL
    public let knownHostsFile: URL
    public init(username: String, identityFile: URL, knownHostsFile: URL) {
        self.username = username; self.identityFile = identityFile; self.knownHostsFile = knownHostsFile
    }
}

public struct SFTPIdentityReference: Sendable {
    public init() {}
    public func create(for url: URL, securityScoped: Bool = true) throws -> Data {
        guard try validIdentity(url) else { throw SFTPBackendError.invalidIdentity }
        let options: URL.BookmarkCreationOptions = securityScoped ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.minimalBookmark]
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], relativeTo: nil)
    }
    public func resolve(_ data: Data, securityScoped: Bool = true) throws -> (url: URL, stale: Bool) {
        var stale = false
        let options: URL.BookmarkResolutionOptions = securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard try validIdentity(url) else { throw SFTPBackendError.invalidIdentity }
        return (url, stale)
    }
    private func validIdentity(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

public struct PreparedSFTPConnection: Sendable, Equatable {
    public let key: SFTPKeyConfiguration
    public let identityIsStale: Bool
}

public struct SFTPConnectionPreparation: Sendable {
    public init() {}
    public func prepare(profile: RemoteConnectionProfile, knownHostsFile: URL,
                        securityScoped: Bool = true) throws -> PreparedSFTPConnection {
        guard profile.remoteProtocol == .sftp else { throw SFTPBackendError.unsupportedProtocol }
        guard let username = profile.username, !username.isEmpty else { throw SFTPBackendError.invalidUsername }
        guard let bookmark = profile.identityBookmark else { throw SFTPBackendError.missingIdentity }
        let resolved = try SFTPIdentityReference().resolve(bookmark, securityScoped: securityScoped)
        guard !resolved.stale else { throw SFTPBackendError.staleIdentity }
        let key = SFTPKeyConfiguration(username: username, identityFile: resolved.url, knownHostsFile: knownHostsFile)
        try SFTPCommandBuilder().validateFiles(key)
        return PreparedSFTPConnection(key: key, identityIsStale: false)
    }
}

public struct SFTPCommandPlan: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let batchInput: Data
    public let privateSSHConfiguration: Data
    public let redactedDescription: String
}

public struct SFTPCommandExecutor: Sendable {
    private let executor = RemoteCommandExecutor()
    public init() {}
    public func execute(_ plan: SFTPCommandPlan, temporaryRoot: URL = FileManager.default.temporaryDirectory,
                        fileManager: FileManager = .default) async throws -> RemoteCommandResult {
        guard plan.privateSSHConfiguration.count <= 64 * 1_024,
              plan.arguments.filter({ $0 == "<private-config>" }).count == 1 else { throw SFTPBackendError.invalidPrivateConfiguration }
        let directory = temporaryRoot.appendingPathComponent("files-sftp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: directory) }
        let config = directory.appendingPathComponent("ssh_config")
        guard fileManager.createFile(atPath: config.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SFTPBackendError.invalidPrivateConfiguration
        }
        let handle = try FileHandle(forWritingTo: config)
        do { try handle.write(contentsOf: plan.privateSSHConfiguration); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        let command = RemoteCommandPlan(executable: plan.executable,
            arguments: plan.arguments.map { $0 == "<private-config>" ? config.path : $0 },
            standardInput: plan.batchInput, redactedDescription: plan.redactedDescription)
        return try await executor.execute(command)
    }
}

public struct SFTPRemoteProvider: Sendable {
    private let builder = SFTPCommandBuilder(), executor = SFTPCommandExecutor()
    public init() {}
    public func list(profile: RemoteConnectionProfile, key: SFTPKeyConfiguration, remotePath: String,
                     maximumEntries: Int = 100_000) async throws -> [RemoteDirectoryEntry] {
        try builder.validateFiles(key)
        let result = try await executor.execute(builder.command(profile: profile, key: key, intent: .list(remotePath: remotePath)))
        return try Self.parseList(result.standardOutput, parent: remotePath, maximumEntries: maximumEntries)
    }
    public static func parseList(_ data: Data, parent: String, maximumEntries: Int = 100_000) throws -> [RemoteDirectoryEntry] {
        guard parent.hasPrefix("/"), let text = String(data: data, encoding: .utf8) else { throw SFTPBackendError.invalidListing }
        let names = text.split(whereSeparator: \Character.isNewline).map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard names.count <= maximumEntries else { throw SFTPBackendError.listingLimitExceeded }
        guard names.allSatisfy({ !$0.contains("/") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw SFTPBackendError.invalidListing
        }
        let base = parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return names.map { RemoteDirectoryEntry(name: $0, remotePath: "/" + ([base, $0].filter { !$0.isEmpty }.joined(separator: "/"))) }
    }
}

public struct SFTPCommandBuilder: Sendable {
    public init() {}
    public func command(profile: RemoteConnectionProfile, key: SFTPKeyConfiguration, intent: SFTPIntent) throws -> SFTPCommandPlan {
        guard profile.remoteProtocol == .sftp else { throw SFTPBackendError.unsupportedProtocol }
        guard validAtom(key.username) else { throw SFTPBackendError.invalidUsername }
        guard key.identityFile.isFileURL, key.knownHostsFile.isFileURL else { throw SFTPBackendError.invalidPath }
        let command: String
        switch intent {
        case .list(let remote): command = "ls -1 \(try quoted(remote))"
        case .download(let remote, let local): command = "get \(try quoted(remote)) \(try quoted(local.path))"
        case .upload(let local, let remote): command = "put \(try quoted(local.path)) \(try quoted(remote))"
        case .remove(let remote): command = "rm \(try quoted(remote))"
        }
        let alias = "files-remote"
        let config = ["Host \(alias)", "  HostName \(profile.host)", "  Port \(profile.port)", "  User \(key.username)",
                      "  IdentityFile \(sshQuoted(key.identityFile.path))", "  IdentitiesOnly yes",
                      "  UserKnownHostsFile \(sshQuoted(key.knownHostsFile.path))", "  StrictHostKeyChecking yes",
                      "  BatchMode yes", "  PasswordAuthentication no", "  KbdInteractiveAuthentication no",
                      "  ConnectTimeout 15", ""].joined(separator: "\n")
        return SFTPCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/sftp"), arguments: ["-q", "-b", "-", "-F", "<private-config>", alias],
            batchInput: Data((command + "\n").utf8), privateSSHConfiguration: Data(config.utf8),
            redactedDescription: "sftp <redacted>@<redacted>:/<redacted>")
    }
    public func validateFiles(_ key: SFTPKeyConfiguration) throws {
        let identity = try? key.identityFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard identity?.isRegularFile == true, identity?.isSymbolicLink != true else { throw SFTPBackendError.invalidIdentity }
        let trust = try? key.knownHostsFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard trust?.isRegularFile == true, trust?.isSymbolicLink != true else { throw SFTPBackendError.invalidTrustStore }
    }
    private func quoted(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPBackendError.invalidPath }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private func sshQuoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private func validAtom(_ value: String) -> Bool { !value.isEmpty && !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) }
}
