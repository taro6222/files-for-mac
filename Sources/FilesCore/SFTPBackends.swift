import Foundation

public enum SFTPIntent: Sendable, Equatable {
    case list(remotePath: String)
    case download(remotePath: String, local: URL)
    case upload(local: URL, remotePath: String)
    case remove(remotePath: String)
}

public enum SFTPBackendError: Error, Sendable, Equatable {
    case unsupportedProtocol, invalidPath, invalidUsername, invalidTrustStore, invalidIdentity
}

public struct SFTPKeyConfiguration: Sendable, Equatable {
    public let username: String
    public let identityFile: URL
    public let knownHostsFile: URL
    public init(username: String, identityFile: URL, knownHostsFile: URL) {
        self.username = username; self.identityFile = identityFile; self.knownHostsFile = knownHostsFile
    }
}

public struct SFTPCommandPlan: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let batchInput: Data
    public let privateSSHConfiguration: Data
    public let redactedDescription: String
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
