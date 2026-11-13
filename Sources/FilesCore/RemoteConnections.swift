import Foundation

public enum RemoteProtocol: String, Codable, CaseIterable, Sendable {
    case ftp, ftps, sftp, smb

    public var defaultPort: Int {
        switch self { case .ftp: 21; case .ftps: 990; case .sftp: 22; case .smb: 445 }
    }

    public var requiresTLSValidation: Bool { self == .ftps }
    public var requiresHostKeyValidation: Bool { self == .sftp }
    public var usesMountedVolume: Bool { self == .smb }
}

public enum RemoteConnectionValidationError: Error, Equatable, Sendable {
    case emptyName, invalidHost, invalidPort, invalidRootPath, embeddedCredential
}

public struct RemoteConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let remoteProtocol: RemoteProtocol
    public let host: String
    public let port: Int
    public let rootPath: String
    public let username: String?
    public let credentialID: String?

    public init(id: UUID = UUID(), name: String, remoteProtocol: RemoteProtocol, host: String,
                port: Int? = nil, rootPath: String = "/", username: String? = nil,
                credentialID: String? = nil) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw RemoteConnectionValidationError.emptyName }
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.contains("@"), !cleanHost.contains("://") else { throw RemoteConnectionValidationError.embeddedCredential }
        guard Self.isValidHost(cleanHost) else { throw RemoteConnectionValidationError.invalidHost }
        let resolvedPort = port ?? remoteProtocol.defaultPort
        guard (1...65_535).contains(resolvedPort) else { throw RemoteConnectionValidationError.invalidPort }
        guard rootPath.hasPrefix("/"), !rootPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteConnectionValidationError.invalidRootPath
        }
        let cleanUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanUsername?.contains(":") != true, cleanUsername?.contains("@") != true else {
            throw RemoteConnectionValidationError.embeddedCredential
        }
        self.id = id; self.name = cleanName; self.remoteProtocol = remoteProtocol
        self.host = cleanHost; self.port = resolvedPort; self.rootPath = rootPath
        self.username = cleanUsername.flatMap { $0.isEmpty ? nil : $0 }; self.credentialID = credentialID
    }

    public var endpoint: String { "\(remoteProtocol.rawValue)://\(host):\(port)\(rootPath)" }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        return host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == ":"
        }
    }
}

public struct RemoteProviderCapabilities: Equatable, Sendable {
    public let directConnection: Bool
    public let mountedVolume: Bool
    public let tlsValidation: Bool
    public let hostKeyValidation: Bool

    public static func planned(for remoteProtocol: RemoteProtocol) -> Self {
        .init(directConnection: remoteProtocol != .smb, mountedVolume: remoteProtocol.usesMountedVolume,
              tlsValidation: remoteProtocol.requiresTLSValidation, hostKeyValidation: remoteProtocol.requiresHostKeyValidation)
    }
}
