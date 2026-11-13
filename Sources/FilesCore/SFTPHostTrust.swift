import CryptoKit
import Foundation

public enum SFTPHostTrustError: Error, Sendable, Equatable {
    case invalidLine, unexpectedHost, unsupportedKeyType, fingerprintMismatch, hostKeyChanged
}

public struct SFTPHostKeyCandidate: Sendable, Equatable {
    public let hostToken: String
    public let keyType: String
    public let keyData: Data
    public let sourceLine: String
    public let sha256Fingerprint: String

    public static func parse(_ line: String, host: String, port: Int) throws -> Self {
        guard !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SFTPHostTrustError.invalidLine
        }
        let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard fields.count == 3 else { throw SFTPHostTrustError.invalidLine }
        let expected = port == 22 ? host : "[\(host)]:\(port)"
        guard fields[0] == expected else { throw SFTPHostTrustError.unexpectedHost }
        let allowed = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"]
        guard allowed.contains(fields[1]) else { throw SFTPHostTrustError.unsupportedKeyType }
        guard let data = Data(base64Encoded: fields[2]), !data.isEmpty else { throw SFTPHostTrustError.invalidLine }
        let fingerprint = Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return .init(hostToken: fields[0], keyType: fields[1], keyData: data,
            sourceLine: fields.joined(separator: " "), sha256Fingerprint: "SHA256:\(fingerprint)")
    }
}

public struct SFTPHostTrustStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func approve(_ candidate: SFTPHostKeyCandidate, fingerprint: String, fileManager: FileManager = .default) throws {
        guard candidate.sha256Fingerprint == fingerprint else { throw SFTPHostTrustError.fingerprintMismatch }
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8))?.split(whereSeparator: \Character.isNewline).map(String.init) ?? []
        let sameHostType = existing.filter {
            let fields = $0.split(whereSeparator: \Character.isWhitespace)
            return fields.count >= 2 && fields[0] == candidate.hostToken && fields[1] == candidate.keyType
        }
        if sameHostType.contains(candidate.sourceLine) { return }
        guard sameHostType.isEmpty else { throw SFTPHostTrustError.hostKeyChanged }
        let directory = fileURL.deletingLastPathComponent(); try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".known-hosts-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fileManager.removeItem(at: staging) }
        var lines = existing; lines.append(candidate.sourceLine)
        let handle = try FileHandle(forWritingTo: staging)
        do { try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8)); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if fileManager.fileExists(atPath: fileURL.path) { _ = try fileManager.replaceItemAt(fileURL, withItemAt: staging) }
        else { try fileManager.moveItem(at: staging, to: fileURL) }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
