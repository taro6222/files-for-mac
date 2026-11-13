import Foundation
import Testing
@testable import FilesCore

@Test func sftpHostCandidatesRequireExactHostAndProduceStableFingerprint() throws {
    let key = Data("fixture-public-key".utf8).base64EncodedString()
    let candidate = try SFTPHostKeyCandidate.parse("[ssh.example.com]:2222 ssh-ed25519 \(key)", host: "ssh.example.com", port: 2222)
    #expect(candidate.hostToken == "[ssh.example.com]:2222"); #expect(candidate.keyType == "ssh-ed25519")
    #expect(candidate.sha256Fingerprint.hasPrefix("SHA256:")); #expect(!candidate.sha256Fingerprint.hasSuffix("="))
    #expect(try SFTPHostKeyCandidate.parse("[ssh.example.com]:2222 ssh-ed25519 \(key)", host: "ssh.example.com", port: 2222) == candidate)
    #expect(throws: SFTPHostTrustError.unexpectedHost) { try SFTPHostKeyCandidate.parse("other ssh-ed25519 \(key)", host: "ssh.example.com", port: 22) }
    #expect(throws: SFTPHostTrustError.unsupportedKeyType) { try SFTPHostKeyCandidate.parse("ssh.example.com ssh-dss \(key)", host: "ssh.example.com", port: 22) }
    #expect(throws: SFTPHostTrustError.invalidLine) { try SFTPHostKeyCandidate.parse("ssh.example.com ssh-ed25519 not-base64!", host: "ssh.example.com", port: 22) }
}

@Test func sftpTrustStoreRequiresFingerprintAndRefusesSilentKeyChanges() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("sftp-trust-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }; let store = SFTPHostTrustStore(fileURL: root.appendingPathComponent("known_hosts"))
    let first = try SFTPHostKeyCandidate.parse("host ssh-ed25519 \(Data("first".utf8).base64EncodedString())", host: "host", port: 22)
    #expect(throws: SFTPHostTrustError.fingerprintMismatch) { try store.approve(first, fingerprint: "SHA256:wrong", fileManager: fm) }
    try store.approve(first, fingerprint: first.sha256Fingerprint, fileManager: fm)
    try store.approve(first, fingerprint: first.sha256Fingerprint, fileManager: fm)
    let lines = try String(contentsOf: store.fileURL, encoding: .utf8).split(whereSeparator: \Character.isNewline)
    #expect(lines.count == 1); #expect(String(lines[0]) == first.sourceLine)
    let permissions = try #require(fm.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
    let changed = try SFTPHostKeyCandidate.parse("host ssh-ed25519 \(Data("changed".utf8).base64EncodedString())", host: "host", port: 22)
    #expect(throws: SFTPHostTrustError.hostKeyChanged) { try store.approve(changed, fingerprint: changed.sha256Fingerprint, fileManager: fm) }
    #expect(try String(contentsOf: store.fileURL, encoding: .utf8).contains(first.sourceLine))
}
