import Foundation
import Darwin

public struct PromisedFileRecovery: Sendable {
    public let directoryURL: URL
    public let createdAt: Date?
    public let intake: PromisedFileIntake?
    public let problem: String?
    public var names: [String] { intake?.receivedNames ?? [] }

    /// Lists owned-looking receipt directories without hashing payloads. Copy revalidates bytes.
    /// Damaged receipts remain visible for manual recovery; unrelated entries are never adopted.
    public static func discover(in storage: URL) throws -> [PromisedFileRecovery] {
        guard storage.isFileURL else { throw PromisedFileIntakeError.invalidLocation }
        var info = stat()
        guard lstat(storage.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw PromisedFileIntakeError.invalidLocation }
        let children = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.creationDateKey])
        var result: [PromisedFileRecovery] = []
        for child in children where child.lastPathComponent.hasPrefix("promise-") {
            var childInfo = stat()
            guard lstat(child.path, &childInfo) == 0, childInfo.st_mode & S_IFMT == S_IFDIR else { continue }
            let date = try? child.resourceValues(forKeys: [.creationDateKey]).creationDate
            do {
                let intake = try PromisedFileIntake(recovering: child)
                result.append(PromisedFileRecovery(directoryURL: child, createdAt: date, intake: intake, problem: nil))
            } catch {
                result.append(PromisedFileRecovery(directoryURL: child, createdAt: date, intake: nil, problem: error.localizedDescription))
            }
        }
        return result.sorted {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            return $0.directoryURL.lastPathComponent < $1.directoryURL.lastPathComponent
        }
    }
}
