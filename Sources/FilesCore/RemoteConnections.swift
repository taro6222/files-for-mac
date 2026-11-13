import Foundation
import Security

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

public struct RemoteProfileStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load(fileManager: FileManager = .default) throws -> [RemoteConnectionProfile] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let decoded = try JSONDecoder().decode([RemoteConnectionProfile].self, from: Data(contentsOf: fileURL))
        return try decoded.map {
            try RemoteConnectionProfile(id: $0.id, name: $0.name, remoteProtocol: $0.remoteProtocol, host: $0.host,
                port: $0.port, rootPath: $0.rootPath, username: $0.username, credentialID: $0.credentialID)
        }
    }

    public func save(_ profiles: [RemoteConnectionProfile], fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        let staging = directory.appendingPathComponent(".remote-profiles-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: staging)
            } else { try fileManager.moveItem(at: staging, to: fileURL) }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { try? fileManager.removeItem(at: staging); throw error }
    }
}

public struct RemoteCredential: Equatable, Sendable {
    public let username: String
    public let secret: Data
    public init(username: String, secret: Data) { self.username = username; self.secret = secret }
}

public enum RemoteCredentialError: Error, Equatable, Sendable {
    case keychain(OSStatus), malformedItem
}

public struct KeychainRemoteCredentialStore: Sendable {
    public let service: String
    public init(service: String = "community.files.FilesMac.remote") { self.service = service }

    public func save(_ credential: RemoteCredential, id: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id]
        let attributes: [String: Any] = [kSecValueData as String: credential.secret,
            kSecAttrLabel as String: credential.username, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base; attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw RemoteCredentialError.keychain(addStatus) }
        } else if status != errSecSuccess { throw RemoteCredentialError.keychain(status) }
    }

    public func load(id: String) throws -> RemoteCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id,
            kSecReturnAttributes as String: true, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemoteCredentialError.keychain(status) }
        guard let item = result as? [String: Any], let secret = item[kSecValueData as String] as? Data else {
            throw RemoteCredentialError.malformedItem
        }
        return RemoteCredential(username: item[kSecAttrLabel as String] as? String ?? "", secret: secret)
    }

    public func remove(id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteCredentialError.keychain(status) }
    }
}
