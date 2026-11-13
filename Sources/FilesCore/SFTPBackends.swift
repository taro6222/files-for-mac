import Foundation

public enum SFTPIntent: Sendable, Equatable {
    case list(remotePath: String)
    case download(remotePath: String, local: URL)
    case upload(local: URL, remotePath: String)
    case uploadAndRename(local: URL, stagingRemotePath: String, finalRemotePath: String)
    case remove(remotePath: String)
}

public enum SFTPBackendError: Error, Sendable, Equatable {
    case unsupportedProtocol, invalidPath, invalidUsername, invalidTrustStore, invalidIdentity, staleIdentity, missingIdentity, invalidPrivateConfiguration, invalidListing, listingLimitExceeded, destinationExists, invalidStaging, unverifiedServerCapability, invalidUploadSource
}

public struct SFTPServerCapabilities: Sendable, Equatable {
    public let renameRefusesExistingDestination: Bool
    public init(renameRefusesExistingDestination: Bool = false) { self.renameRefusesExistingDestination = renameRefusesExistingDestination }
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
    public func download(profile: RemoteConnectionProfile, key: SFTPKeyConfiguration, remotePath: String,
                         destination: URL, fileManager: FileManager = .default) async throws -> URL {
        try builder.validateFiles(key)
        guard !fileManager.fileExists(atPath: destination.path) else { throw SFTPBackendError.destinationExists }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".files-sftp-download-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        _ = try await executor.execute(builder.command(profile: profile, key: key, intent: .download(remotePath: remotePath, local: staging)))
        try Self.publishDownload(staging: staging, destination: destination, fileManager: fileManager)
        return destination
    }
    public func upload(profile: RemoteConnectionProfile, key: SFTPKeyConfiguration, local: URL, remotePath: String,
                       capabilities: SFTPServerCapabilities = .init(), fileManager: FileManager = .default) async throws {
        guard capabilities.renameRefusesExistingDestination else { throw SFTPBackendError.unverifiedServerCapability }
        let values = try? local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw SFTPBackendError.invalidUploadSource }
        try builder.validateFiles(key)
        let remote = try Self.remoteStagingPath(for: remotePath)
        do {
            _ = try await executor.execute(builder.command(profile: profile, key: key,
                intent: .uploadAndRename(local: local, stagingRemotePath: remote, finalRemotePath: remotePath)))
        } catch {
            if let cleanup = try? builder.command(profile: profile, key: key, intent: .remove(remotePath: remote)) {
                _ = try? await executor.execute(cleanup)
            }
            throw error
        }
    }
    public static func remoteStagingPath(for remotePath: String) throws -> String {
        guard remotePath.hasPrefix("/"), !remotePath.hasSuffix("/"),
              !remotePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPBackendError.invalidPath }
        let path = remotePath as NSString, parent = path.deletingLastPathComponent
        guard path.lastPathComponent != ".", path.lastPathComponent != ".." else { throw SFTPBackendError.invalidPath }
        return (parent as NSString).appendingPathComponent(".files-sftp-upload-\(UUID().uuidString).tmp")
    }
    public static func publishDownload(staging: URL, destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else { throw SFTPBackendError.destinationExists }
        guard staging.deletingLastPathComponent().standardizedFileURL == parent,
              staging.lastPathComponent.hasPrefix(".files-sftp-download-"), staging.pathExtension == "tmp",
              let values = try? staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw SFTPBackendError.invalidStaging }
        do { try fileManager.moveItem(at: staging, to: destination) }
        catch { if fileManager.fileExists(atPath: destination.path) { throw SFTPBackendError.destinationExists }; throw error }
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
        let commands: [String]
        switch intent {
        case .list(let remote): commands = ["ls -1 \(try quoted(remote))"]
        case .download(let remote, let local): commands = ["get \(try quoted(remote)) \(try quoted(local.path))"]
        case .upload(let local, let remote): commands = ["put \(try quoted(local.path)) \(try quoted(remote))"]
        case .uploadAndRename(let local, let staging, let final):
            commands = ["put \(try quoted(local.path)) \(try quoted(staging))", "rename \(try quoted(staging)) \(try quoted(final))"]
        case .remove(let remote): commands = ["rm \(try quoted(remote))"]
        }
        let alias = "files-remote"
        let config = ["Host \(alias)", "  HostName \(profile.host)", "  Port \(profile.port)", "  User \(key.username)",
                      "  IdentityFile \(sshQuoted(key.identityFile.path))", "  IdentitiesOnly yes",
                      "  UserKnownHostsFile \(sshQuoted(key.knownHostsFile.path))", "  StrictHostKeyChecking yes",
                      "  BatchMode yes", "  PasswordAuthentication no", "  KbdInteractiveAuthentication no",
                      "  ConnectTimeout 15", ""].joined(separator: "\n")
        return SFTPCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/sftp"), arguments: ["-q", "-b", "-", "-F", "<private-config>", alias],
            batchInput: Data((commands.joined(separator: "\n") + "\n").utf8), privateSSHConfiguration: Data(config.utf8),
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
