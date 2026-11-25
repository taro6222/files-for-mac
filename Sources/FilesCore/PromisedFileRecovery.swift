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

/// Read-only restart inspection. A journal never authorizes deletion, restore or a new copy.
public struct PromisedFileCleanupRecovery: Sendable {
    public enum Status: String, Sendable { case atOriginal, retainedElsewhere, unlocated, legacy, invalid }
    public let journal: URL
    public let original: URL?
    public let recordedState: String?
    public let location: URL?
    public let status: Status
    public let message: String?
    public private(set) var receivedNames: [String] = []

    public static func discover(in journals: URL, storage: URL) throws -> [Self] {
        guard journals.isFileURL, storage.isFileURL else { throw PromisedFileIntakeError.invalidLocation }
        var info = stat()
        guard lstat(journals.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw PromisedFileIntakeError.invalidLocation }
        let urls = try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("promise-cleanup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.map { url in
            do {
                var recordInfo = stat()
                guard lstat(url.path, &recordInfo) == 0, recordInfo.st_mode & S_IFMT == S_IFREG,
                      recordInfo.st_size <= 1_048_576, let before = LocalEntryIdentity.read(url) else {
                    throw PromisedFileIntakeError.invalidManifest
                }
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { throw PromisedFileIntakeError.invalidManifest }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                      opened.st_dev == recordInfo.st_dev, opened.st_ino == recordInfo.st_ino,
                      let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else {
                    throw PromisedFileIntakeError.invalidManifest
                }
                let result = try JSONDecoder().decode(PromisedFileCleanupResult.self, from: data)
                guard LocalEntryIdentity.read(url) == before, result.journal.standardizedFileURL == url.standardizedFileURL,
                      result.original.isFileURL,
                      result.original.deletingLastPathComponent().standardizedFileURL == storage.standardizedFileURL,
                      result.original.lastPathComponent.hasPrefix("promise-"),
                      UUID(uuidString: String(result.original.lastPathComponent.dropFirst(8))) != nil,
                      ["verified", "movedToTrash", "trashed", "restored", "retained", "needsReview"].contains(result.state),
                      result.retainedAt == nil || result.retainedAt?.isFileURL == true else {
                    throw PromisedFileIntakeError.invalidManifest
                }
                guard let identity = result.directoryIdentity else {
                    return Self(journal: url, original: result.original, recordedState: result.state,
                                location: nil, status: .legacy, message: result.message)
                }
                // Prefer the original location. A replacement at either path is never adopted.
                for candidate in [result.original, result.retainedAt].compactMap({ $0 }) {
                    var candidateInfo = stat()
                    guard lstat(candidate.path, &candidateInfo) == 0, candidateInfo.st_mode & S_IFMT == S_IFDIR,
                          LocalEntryIdentity.read(candidate) == identity,
                          let intake = try? PromisedFileIntake(recovering: candidate),
                          LocalEntryIdentity.read(candidate) == identity else { continue }
                    var record = Self(journal: url, original: result.original, recordedState: result.state,
                                location: candidate, status: candidate == result.original ? .atOriginal : .retainedElsewhere,
                                message: result.message)
                    record.receivedNames = intake.receivedNames
                    return record
                }
                var unknown = Self(journal: url, original: result.original, recordedState: result.state,
                            location: nil, status: .unlocated, message: result.message)
                unknown.receivedNames = result.receivedNames ?? []
                return unknown
            } catch {
                return Self(journal: url, original: nil, recordedState: nil, location: nil,
                            status: .invalid, message: error.localizedDescription)
            }
        }
    }
}
