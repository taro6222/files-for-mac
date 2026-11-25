import Foundation
import Darwin

public enum PromisedFileRestoreFailure: String, Codable, Error, Equatable, Sendable {
    case conflict, cancelled, changed, unavailable
}

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

/// Restart inspection is read-only. Explicit restore revalidates the saved proof and never overwrites.
public struct PromisedFileCleanupRecovery: Sendable {
    public enum Status: String, Sendable { case atOriginal, retainedElsewhere, unlocated, legacy, invalid }
    public let journal: URL
    public let original: URL?
    public let recordedState: String?
    public let location: URL?
    public let status: Status
    public let message: String?
    public private(set) var receivedNames: [String] = []
    private var savedResult: PromisedFileCleanupResult?
    private var savedData: Data?
    private var savedIdentity: String?
    public var isRestoreRecord: Bool { savedResult?.recoveryOf != nil }
    public var canRestore: Bool {
        status == .retainedElsewhere && savedResult?.storageIdentity != nil && savedResult?.retainedFingerprint != nil
    }

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
        let rows: [Self] = urls.map { url in
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
                      ["verified", "movedToTrash", "trashed", "restored", "retained", "needsReview", "restorePrepared"].contains(result.state),
                      result.retainedAt == nil || result.retainedAt?.isFileURL == true else {
                    throw PromisedFileIntakeError.invalidManifest
                }
                func row(_ status: Status, location: URL?) -> Self {
                    var record = Self(journal: url, original: result.original, recordedState: result.state,
                                      location: location, status: status, message: result.message)
                    record.receivedNames = result.receivedNames ?? []
                    record.savedResult = result; record.savedData = data; record.savedIdentity = before
                    return record
                }
                guard let identity = result.directoryIdentity else {
                    return row(.legacy, location: nil)
                }
                // Prefer the original location. A replacement at either path is never adopted.
                for (index, candidate) in [result.original, result.retainedAt].compactMap({ $0 }).enumerated() {
                    var candidateInfo = stat()
                    guard lstat(candidate.path, &candidateInfo) == 0, candidateInfo.st_mode & S_IFMT == S_IFDIR,
                          LocalEntryIdentity.read(candidate) == identity,
                          let intake = try? PromisedFileIntake(recovering: candidate),
                          LocalEntryIdentity.read(candidate) == identity else { continue }
                    var record = row(index == 0 ? .atOriginal : .retainedElsewhere, location: candidate)
                    record.receivedNames = intake.receivedNames
                    return record
                }
                return row(.unlocated, location: nil)
            } catch {
                return Self(journal: url, original: nil, recordedState: nil, location: nil,
                            status: .invalid, message: error.localizedDescription)
            }
        }
        let completed = Set(rows.compactMap { $0.recordedState != "restorePrepared" ? $0.savedResult?.restoreAttempt : nil })
        return rows.filter { $0.recordedState != "restorePrepared" || $0.savedResult?.restoreAttempt.map { !completed.contains($0) } != false }
    }

    public func restore(storage: URL, cancellation: CopyCancellation = CopyCancellation()) throws -> PromisedFileCleanupResult {
        try restore(storage: storage, cancellation: cancellation, beforeMove: {})
    }

    // A bounded seam tests cancellation, parent changes and conflicting arrivals at publication.
    func restore(storage: URL, cancellation: CopyCancellation, beforeMove: () throws -> Void) throws -> PromisedFileCleanupResult {
        try restore(storage: storage, cancellation: cancellation, beforeMove: beforeMove, afterMove: {})
    }
    func restore(storage: URL, cancellation: CopyCancellation, beforeMove: () throws -> Void,
                 afterMove: () throws -> Void) throws -> PromisedFileCleanupResult {
        guard canRestore, let saved = savedResult, let source = location,
              let identity = saved.directoryIdentity, let fingerprint = saved.retainedFingerprint,
              let storageIdentity = saved.storageIdentity,
              saved.original.deletingLastPathComponent().standardizedFileURL == storage.standardizedFileURL else {
            throw PromisedFileIntakeError.invalidLocation
        }
        try cancellation.check()
        let sourceParent = source.deletingLastPathComponent(), journals = journal.deletingLastPathComponent()
        // Search permission is sufficient for renameat; do not request enumeration of user Trash.
        let from = open(sourceParent.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        let to = open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let recordParent = open(journals.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let payload = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { for fd in [from, to, recordParent, payload] where fd >= 0 { close(fd) } }
        let journalParentIdentity = LocalEntryIdentity.read(journals)
        let intake = try PromisedFileIntake(recovering: source)
        func journalUnchanged() -> Bool {
            guard let savedData, savedData.count <= 1_048_576, LocalEntryIdentity.read(journal) == savedIdentity else { return false }
            let fd = open(journal.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  CopyEngine.matches(journal, descriptor: fd),
                  (try? handle.read(upToCount: savedData.count + 1)) == savedData else { return false }
            return CopyEngine.matches(journal, descriptor: fd) && LocalEntryIdentity.read(journal) == savedIdentity
        }
        func verify() throws {
            try cancellation.check()
            guard CopyEngine.matches(sourceParent, descriptor: from), CopyEngine.matches(storage, descriptor: to),
                  CopyEngine.matches(journals, descriptor: recordParent), CopyEngine.matches(source, descriptor: payload),
                  LocalEntryIdentity.read(storage) == storageIdentity, LocalEntryIdentity.read(source) == identity,
                  journalUnchanged() else {
#if DEBUG
                if ProcessInfo.processInfo.environment["FILES_PROMISE_QA_OUTPUT"] != nil {
                    print("Restore ownership check:", from, to, recordParent, payload,
                          CopyEngine.matches(sourceParent, descriptor: from), CopyEngine.matches(storage, descriptor: to),
                          CopyEngine.matches(journals, descriptor: recordParent), CopyEngine.matches(source, descriptor: payload),
                          LocalEntryIdentity.read(storage) == storageIdentity, LocalEntryIdentity.read(source) == identity, journalUnchanged())
                }
#endif
                throw PromisedFileIntakeError.changedRoot
            }
            try intake.verifyForRestoration(cancellation: cancellation)
            guard try PromisedFileIntake.cleanupFingerprint(source, cancellation: cancellation) == fingerprint else {
                throw PromisedFileIntakeError.changedItem
            }
            var destination = stat()
            guard fstatat(to, saved.original.lastPathComponent, &destination, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw PromisedFileRestoreFailure.conflict
            }
        }
        try verify()
        let attempt = UUID()
        func receipt(_ state: String, at location: URL?, message: String?, failure: PromisedFileRestoreFailure? = nil) throws -> PromisedFileCleanupResult {
            guard CopyEngine.matches(journals, descriptor: recordParent), LocalEntryIdentity.read(journals) == journalParentIdentity else {
                throw PromisedFileIntakeError.changedRoot
            }
            let url = journals.appendingPathComponent("promise-cleanup-restore-\(UUID()).json")
            var result = PromisedFileCleanupResult(original: saved.original, retainedAt: location, state: state, message: message, journal: url)
            result.directoryIdentity = identity; result.storageIdentity = storageIdentity
            result.retainedFingerprint = fingerprint; result.receivedNames = receivedNames
            result.recoveryOf = journal; result.restoreAttempt = attempt
            result.restoreFailure = failure
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(result)
            let fd = openat(recordParent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            try handle.write(contentsOf: data); try handle.synchronize()
            guard CopyEngine.matches(journals, descriptor: recordParent), CopyEngine.matches(url, descriptor: fd) else {
                throw PromisedFileIntakeError.changedRoot
            }
            return result
        }
        let intent = try receipt("restorePrepared", at: source, message: nil)
        let intentIdentity = LocalEntryIdentity.read(intent.journal)
        do {
            try beforeMove(); try verify()
            try CopyEngine.publishNoReplace(payload: source, target: saved.original, sourceDirectoryFD: from,
                sourceName: source.lastPathComponent, destinationDirectoryFD: to,
                destinationName: saved.original.lastPathComponent, allowPathFallback: false)
            try afterMove()
            guard CopyEngine.matches(saved.original, descriptor: payload), LocalEntryIdentity.read(storage) == storageIdentity else {
                throw PromisedFileIntakeError.changedRoot
            }
            let restored = try PromisedFileIntake(recovering: saved.original)
            try restored.verifyForRestoration(cancellation: cancellation)
            guard try PromisedFileIntake.cleanupFingerprint(saved.original, cancellation: cancellation) == fingerprint else {
                throw PromisedFileIntakeError.changedItem
            }
            return try receipt("restored", at: saved.original, message: nil)
        } catch {
            let failure: PromisedFileRestoreFailure
            if let typed = error as? PromisedFileRestoreFailure { failure = typed }
            else if (error as? CopyPublicationError) == .conflict { failure = .conflict }
            else if error is CancellationError { failure = .cancelled }
            else if error is PromisedFileIntakeError { failure = .changed }
            else { failure = .unavailable }
            // Preserve the entire directory wherever the opened vnode actually resides. Never guess or delete.
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            var retained: URL?
            for candidate in [source, saved.original] where CopyEngine.matches(candidate, descriptor: payload) && LocalEntryIdentity.read(candidate) == identity {
                retained = candidate; break
            }
            if retained == nil, fcntl(payload, F_GETPATH, &buffer) == 0 {
                let candidate = URL(fileURLWithPath: String(cString: buffer), isDirectory: false)
                if CopyEngine.matches(candidate, descriptor: payload), LocalEntryIdentity.read(candidate) == identity { retained = candidate }
            }
            if let failed = try? receipt("needsReview", at: retained, message: error.localizedDescription, failure: failure) { return failed }
            var actualJournal = intent.journal
            if fcntl(recordParent, F_GETPATH, &buffer) == 0 {
                let candidate = URL(fileURLWithPath: String(cString: buffer), isDirectory: true).appendingPathComponent(intent.journal.lastPathComponent)
                if let intentIdentity, LocalEntryIdentity.read(candidate) == intentIdentity { actualJournal = candidate }
            }
            var fallback = PromisedFileCleanupResult(original: intent.original, retainedAt: retained,
                state: "needsReview", message: error.localizedDescription, journal: actualJournal)
            fallback.directoryIdentity = identity; fallback.storageIdentity = storageIdentity
            fallback.retainedFingerprint = fingerprint; fallback.receivedNames = receivedNames
            fallback.recoveryOf = journal; fallback.restoreAttempt = attempt
            fallback.restoreFailure = failure
            return fallback
        }
    }
}
