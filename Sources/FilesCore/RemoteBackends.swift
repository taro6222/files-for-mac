import Foundation

public enum RemoteBackendKind: String, Sendable, Equatable { case curlFTP, openSSH }

public struct RemoteBackendAvailability: Sendable, Equatable {
    public let kind: RemoteBackendKind
    public let executable: URL
    public let protocols: Set<RemoteProtocol>
}

public struct RemoteBackendProbe: Sendable {
    public init() {}
    public func available(fileManager: FileManager = .default) -> [RemoteBackendAvailability] {
        var result: [RemoteBackendAvailability] = []
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        if fileManager.isExecutableFile(atPath: curl.path) {
            result.append(.init(kind: .curlFTP, executable: curl, protocols: [.ftp, .ftps]))
        }
        let sftp = URL(fileURLWithPath: "/usr/bin/sftp")
        if fileManager.isExecutableFile(atPath: sftp.path) {
            result.append(.init(kind: .openSSH, executable: sftp, protocols: [.sftp]))
        }
        return result
    }
}

public enum RemoteTransferIntent: Sendable, Equatable { case list, download(local: URL), upload(local: URL) }

public enum RemoteBackendError: Error, Sendable, Equatable {
    case unsupportedProtocol, invalidRemotePath, invalidCredential
}

public struct RemoteCommandPlan: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let standardInput: Data
    public let redactedDescription: String
}

public struct CurlFTPCommandBuilder: Sendable {
    public init() {}
    public func command(profile: RemoteConnectionProfile, credential: RemoteCredential,
                        remotePath: String, intent: RemoteTransferIntent) throws -> RemoteCommandPlan {
        guard profile.remoteProtocol == .ftp || profile.remoteProtocol == .ftps else { throw RemoteBackendError.unsupportedProtocol }
        guard remotePath.hasPrefix("/"), !remotePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteBackendError.invalidRemotePath
        }
        guard let secret = String(data: credential.secret, encoding: .utf8), !credential.username.contains("\n"), !secret.contains("\n") else {
            throw RemoteBackendError.invalidCredential
        }
        var components = URLComponents(); components.scheme = profile.remoteProtocol.rawValue; components.host = profile.host
        if profile.port != profile.remoteProtocol.defaultPort { components.port = profile.port }
        components.path = remotePath
        guard let remoteURL = components.url else { throw RemoteBackendError.invalidRemotePath }
        var lines = ["url = \(quoted(remoteURL.absoluteString))", "user = \(quoted(credential.username + ":" + secret))",
                     "fail", "silent", "show-error", "disable-epsv"]
        switch intent {
        case .list: lines.append("list-only")
        case .download(let local): lines.append("output = \(quoted(local.path))")
        case .upload(let local): lines.append("upload-file = \(quoted(local.path))")
        }
        if profile.remoteProtocol == .ftps { lines.append("ssl-reqd") }
        let input = Data((lines.joined(separator: "\n") + "\n").utf8)
        return RemoteCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["-q", "--config", "-"],
            standardInput: input, redactedDescription: "curl \(profile.remoteProtocol.rawValue)://<redacted>/<redacted>")
    }
    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
