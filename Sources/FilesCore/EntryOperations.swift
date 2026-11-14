import Foundation
import Darwin

public enum EntryOperationError: Error, Sendable {
    case invalidName, conflict, sourceChanged, noSources
}

public struct EntryOperationResult: Sendable {
    public let target: URL
    public let journalWarning: String?
}

public struct TrashItemOperationResult: Sendable {
    public let source: URL
    public let trashed: URL?
    public let state: String
    public let message: String?
}

public struct TrashOperationResult: Sendable {
    public let id: String
    public let state: String
    public let items: [TrashItemOperationResult]
    public let journalError: String?
}

public struct RestoreItemOperationResult: Sendable {
    public let source: URL
    public let target: URL
    public let state: String
    public let message: String?
}

public struct RestoreOperationResult: Sendable {
    public let id: String
    public let state: String
    public let items: [RestoreItemOperationResult]
    public let journalError: String?
}

public struct PermanentDeleteItemOperationResult: Sendable {
    public let source: URL
    public let state: String
    public let message: String?
}

public struct PermanentDeleteOperationResult: Sendable {
    public let id: String
    public let state: String
    public let items: [PermanentDeleteItemOperationResult]
    public let journalError: String?
}

public struct MoveItemOperationResult: Sendable {
    public let source: URL
    public let target: URL
    public let state: String
    public let message: String?
    public fileprivate(set) var recoveryBackup: URL? = nil
    public fileprivate(set) var retrySource: ShelfEntry? = nil
}

public struct MoveOperationResult: Sendable {
    public let id: String
    public let state: String
    public let items: [MoveItemOperationResult]
    public let journalError: String?
}

public struct MoveProgress: Sendable {
    public let index: Int
    public let total: Int
    public let name: String
    public let phase: String
    public let stagedTransfer: StagedFileTransfer?
}

public struct MoveUndoItem: Codable, Sendable {
    public let source: URL
    public let target: URL
    public let targetIdentity: String
    public let backup: URL?
    public let backupIdentity: String?
    public let crossVolume: Bool
    public let targetSnapshot: [String: String]?
    public let backupSnapshot: [String: String]?
    private(set) var backupRestorePending: Bool?
    var restoredCopyIdentity: String? = nil
    var restoredCopySnapshot: [String: String]? = nil

    public init(source: URL, target: URL, targetIdentity: String, backup: URL? = nil,
                backupIdentity: String? = nil, crossVolume: Bool = false,
                targetSnapshot: [String: String]? = nil, backupSnapshot: [String: String]? = nil) {
        self.init(source: source, target: target, targetIdentity: targetIdentity, backup: backup,
                  backupIdentity: backupIdentity, crossVolume: crossVolume, targetSnapshot: targetSnapshot,
                  backupSnapshot: backupSnapshot, backupRestorePending: nil)
    }

    private init(source: URL, target: URL, targetIdentity: String, backup: URL?,
                 backupIdentity: String?, crossVolume: Bool, targetSnapshot: [String: String]?,
                 backupSnapshot: [String: String]?, backupRestorePending: Bool?) {
        self.source = source; self.target = target; self.targetIdentity = targetIdentity
        self.backup = backup; self.backupIdentity = backupIdentity; self.crossVolume = crossVolume
        self.targetSnapshot = targetSnapshot; self.backupSnapshot = backupSnapshot
        self.backupRestorePending = backupRestorePending
    }

    func awaitingBackupRestore() -> Self {
        var item = self
        item.backupRestorePending = true
        return item
    }

    private enum CodingKeys: String, CodingKey {
        case source, target, targetIdentity, backup, backupIdentity, crossVolume, targetSnapshot, backupSnapshot, backupRestorePending
        case restoredCopyIdentity, restoredCopySnapshot
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(URL.self, forKey: .source)
        target = try values.decode(URL.self, forKey: .target)
        targetIdentity = try values.decode(String.self, forKey: .targetIdentity)
        backup = try values.decodeIfPresent(URL.self, forKey: .backup)
        backupIdentity = try values.decodeIfPresent(String.self, forKey: .backupIdentity)
        crossVolume = try values.decodeIfPresent(Bool.self, forKey: .crossVolume) ?? false
        targetSnapshot = try values.decodeIfPresent([String: String].self, forKey: .targetSnapshot)
        backupSnapshot = try values.decodeIfPresent([String: String].self, forKey: .backupSnapshot)
        backupRestorePending = try values.decodeIfPresent(Bool.self, forKey: .backupRestorePending)
        restoredCopyIdentity = try values.decodeIfPresent(String.self, forKey: .restoredCopyIdentity)
        restoredCopySnapshot = try values.decodeIfPresent([String: String].self, forKey: .restoredCopySnapshot)
    }
}

public struct MoveUndoRecord: Codable, Sendable {
    public let operationId: String
    public let items: [MoveUndoItem]
    public let createdAt: Date
}

public struct MoveUndoItemResult: Sendable {
    public let source: URL
    public let target: URL
    public let state: String
    public let message: String?
}

public struct MoveRedoRecord: Sendable {
    public struct Item: Sendable {
        public let source: URL
        public let target: URL
        fileprivate let identity: String
        fileprivate let snapshot: [String: String]
        fileprivate let destinationFolder: ShelfEntry
    }

    public let items: [Item]
    public let undoneAt: Date
}

public struct MoveUndoResult: Sendable {
    public let redo: MoveRedoRecord?
    public let operationId: String
    public let state: String
    public let items: [MoveUndoItemResult]
    public let journalError: String?
}

public enum MoveConflictPolicy: String, Sendable {
    case skip
    case replace
}

/// Local directory-entry operations with durable operation records.
public enum EntryOperations {
    private static func operationDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func snapshotIdentity(_ url: URL, fileManager: FileManager = .default) throws -> String {
        let values = try fileManager.attributesOfItem(atPath: url.path)
        guard let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else { throw EntryOperationError.sourceChanged }
        let created = (values[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(device):\(inode):\(created):\(modified):\(size)"
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func matchesTransfer(_ url: URL, identity: String, contents: [String: String],
                                        fileManager: FileManager) -> Bool {
        (try? snapshotIdentity(url, fileManager: fileManager)) == identity
            && (try? CopyEngine.verifiedContentSnapshot(url)) == contents
            && (try? snapshotIdentity(url, fileManager: fileManager)) == identity
    }

    private static func matchesUndoEntry(_ url: URL, identity: String, snapshot: [String: String]?,
                                         fileManager: FileManager) throws -> Bool {
        guard try snapshotIdentity(url, fileManager: fileManager) == identity else { return false }
        guard let snapshot else { return true }
        return try CopyEngine.verifiedSnapshot(url) == snapshot
            && snapshotIdentity(url, fileManager: fileManager) == identity
    }

    private static func restoreUndoBackup(_ backup: URL, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        guard backup.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path else {
            throw EntryOperationError.sourceChanged
        }
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        do {
            try CopyEngine.publishNoReplace(payload: backup, target: target,
                sourceDirectoryFD: descriptor, sourceName: backup.lastPathComponent,
                destinationDirectoryFD: descriptor, destinationName: target.lastPathComponent)
        } catch CopyPublicationError.conflict {
            throw EntryOperationError.conflict
        }
    }

    private static func transferForUndo(_ source: URL, to target: URL, crossVolume: Bool,
                                        expectedSnapshot: [String: String]?,
                                        checkpointCopy: (String, [String: String]) throws -> Void,
                                        afterCopyPublication: () throws -> Void) throws {
        let fm = FileManager.default
        if !crossVolume { try fm.moveItem(at: source, to: target); return }
        let sourceIdentity = try snapshotIdentity(source, fileManager: fm)
        let before = try CopyEngine.verifiedSnapshot(source)
        guard expectedSnapshot == nil || before == expectedSnapshot else { throw EntryOperationError.sourceChanged }
        let contentBefore = try CopyEngine.verifiedContentSnapshot(source)
        let stage = target.deletingLastPathComponent().appendingPathComponent(".files-undo-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { if entryExists(stage) { try? fm.removeItem(at: stage) } }
        let payload = stage.appendingPathComponent("payload")
        try fm.copyItem(at: source, to: payload)
        let verifiedPayload = try CopyEngine.makeSnapshot(payload, cancellation: CopyCancellation())
        guard verifiedPayload.content == contentBefore,
              try CopyEngine.verifiedSnapshot(source) == before else {
            throw MoveFailure(text: LString.crossVolumeVerificationFailed)
        }
        let payloadIdentity = try snapshotIdentity(payload, fileManager: fm)
        try checkpointCopy(payloadIdentity, verifiedPayload.withPermissions)
        try fm.moveItem(at: payload, to: target)
        try afterCopyPublication()
        do {
            guard try CopyEngine.verifiedSnapshot(source) == before,
                  try snapshotIdentity(source, fileManager: fm) == sourceIdentity else {
                throw MoveFailure(text: LString.crossVolumeSourceChanged)
            }
        } catch {
            let originalError = error
            if matchesTransfer(target, identity: payloadIdentity, contents: contentBefore, fileManager: fm) {
                try? fm.removeItem(at: target)
            }
            throw originalError
        }
        guard matchesTransfer(target, identity: payloadIdentity, contents: contentBefore, fileManager: fm) else {
            throw MoveFailure(text: LString.crossVolumeDestinationChanged)
        }
        guard try snapshotIdentity(source, fileManager: fm) == sourceIdentity else {
            throw MoveFailure(text: LString.crossVolumeSourceChanged)
        }
        try fm.removeItem(at: source)
    }

    public static func latestUndoMove(journalDirectory: URL) -> MoveUndoRecord? {
        let fm = FileManager.default
        guard let candidates = try? fm.contentsOfDirectory(at: journalDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return candidates
            .filter { $0.lastPathComponent.hasPrefix("undo-move-") && $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(MoveUndoRecord.self, from: Data(contentsOf: $0)) }
            .filter { !$0.items.isEmpty }
            .max {
                if $0.createdAt == $1.createdAt { return $0.operationId < $1.operationId }
                return $0.createdAt < $1.createdAt
            }
    }

    public enum PendingTransferUndo: Sendable {
        case copy(CopyUndoRecord)
        case move(MoveUndoRecord)

        public var completedAt: Date {
            switch self {
            case let .copy(record): record.createdAt
            case let .move(record): record.createdAt
            }
        }

        public static func latest(in journalDirectory: URL) -> Self? {
            let copy = CopyEngine.latestUndoCopy(journalDirectory: journalDirectory)
            let move = EntryOperations.latestUndoMove(journalDirectory: journalDirectory)
            if let move, copy.map({ move.createdAt >= $0.createdAt }) ?? true {
                return .move(move)
            }
            return copy.map(Self.copy)
        }
    }

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\0") else { throw EntryOperationError.invalidName }
    }

    public static func createFolder(in parent: URL, name: String, journalDirectory: URL) async throws -> EntryOperationResult {
        try await perform(parent: parent, source: nil, expectedIdentity: nil, name: name, journalDirectory: journalDirectory)
    }

    public static func createFile(in parent: URL, name: String, journalDirectory: URL) async throws -> EntryOperationResult {
        try validateName(name)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager()
            let parent = parent.standardizedFileURL
            let target = parent.appendingPathComponent(name)
            let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(directoryFD) }
            var journal = Journal(operation: "createFile", source: nil, target: target, state: "planned")
            let journalURL = journalDirectory.appendingPathComponent("entry-\(UUID()).json")
            func save() throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }
            try save()
            do {
                var opened = stat(), current = stat()
                guard fstat(directoryFD, &opened) == 0, stat(parent.path, &current) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                    throw EntryOperationError.sourceChanged
                }
                let fileFD = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
                guard fileFD >= 0 else {
                    if errno == EEXIST { throw EntryOperationError.conflict }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                close(fileFD)
            } catch {
                journal.state = "failed"; try? save(); throw error
            }
            journal.state = "completed"
            do { try save(); return EntryOperationResult(target: target, journalWarning: nil) }
            catch { return EntryOperationResult(target: target, journalWarning: error.localizedDescription) }
        }.value
    }

    /// Creates a relative macOS symbolic link without replacing an existing entry.
    public static func createSymbolicLink(to source: URL, in parent: URL, name: String) async throws -> URL {
        try validateName(name)
        return try await Task.detached(priority: .userInitiated) {
            let source = source.standardizedFileURL
            let parent = parent.standardizedFileURL
            guard entryExists(source) else { throw EntryOperationError.sourceChanged }
            let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var opened = stat(), current = stat()
            guard fstat(fd, &opened) == 0, stat(parent.path, &current) == 0,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                throw EntryOperationError.sourceChanged
            }
            let destination = parent.appendingPathComponent(name)
            let linkTarget = source.deletingLastPathComponent() == parent ? source.lastPathComponent : source.path
            guard symlinkat(linkTarget, fd, name) == 0 else {
                if errno == EEXIST { throw EntryOperationError.conflict }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return destination
        }.value
    }

    public static func rename(_ source: URL, to name: String, expectedIdentity: String? = nil,
                              journalDirectory: URL) async throws -> EntryOperationResult {
        try await perform(parent: source.deletingLastPathComponent(), source: source,
                          expectedIdentity: expectedIdentity, name: name, journalDirectory: journalDirectory)
    }

    public static func moveToTrash(_ sources: [URL], journalDirectory: URL) async throws -> TrashOperationResult {
        let normalizedSources = sources.map(\.standardizedFileURL)
        guard !normalizedSources.isEmpty else { throw EntryOperationError.noSources }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let operationId = UUID().uuidString
            let journalURL = journalDirectory.appendingPathComponent("trash-\(operationId).json")

            struct TrashItemJournal: Codable {
                let source: URL
                let state: String
                let trashed: URL?
                let message: String?
                let updatedAt: String
            }

            struct TrashJournal: Codable {
                let version = 1
                let operation = "moveToTrash"
                let operationId: String
                let state: String
                let items: [TrashItemJournal]
                let journalError: String?
            }

            let dateFormatter = operationDateFormatter()
            var itemStates = normalizedSources.map {
                TrashItemOperationResult(source: $0, trashed: nil, state: "queued", message: nil)
            }
            var finalState = "completed"
            var journalError: String?

            func currentItemStates() -> [TrashItemJournal] {
                return itemStates.enumerated().map { index, item in
                    return TrashItemJournal(source: item.source, state: item.state, trashed: item.trashed, message: item.message,
                                            updatedAt: dateFormatter.string(from: Date()))
                }
            }

            func save(state: String) throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                let journal = TrashJournal(operationId: operationId, state: state, items: currentItemStates(), journalError: journalError)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }

            do {
                try save(state: "queued")
            for index in normalizedSources.indices {
                let source = normalizedSources[index]
                do {
                    guard fm.fileExists(atPath: source.path) else {
                        itemStates[index] = TrashItemOperationResult(source: source, trashed: nil, state: "notFound", message: LString.fileMissing)
                        finalState = "partial"
                        continue
                    }

                    var trashedURL: NSURL?
                    try fm.trashItem(at: source, resultingItemURL: &trashedURL)
                    itemStates[index] = TrashItemOperationResult(source: source, trashed: trashedURL as URL?, state: "completed", message: nil)
                    } catch {
                        itemStates[index] = TrashItemOperationResult(source: source, trashed: nil, state: "failed", message: error.localizedDescription)
                        finalState = "partial"
                    }
                    try save(state: finalState)
                }
            } catch {
                finalState = "failed"
                journalError = error.localizedDescription
                try? save(state: finalState)
                throw error
            }

            do {
                try save(state: finalState)
            } catch {
                journalError = error.localizedDescription
                try? save(state: finalState)
            }

            return TrashOperationResult(id: operationId, state: finalState, items: itemStates, journalError: journalError)
        }.value
    }

    public static func restoreFromTrash(_ sources: [URL], to destination: URL, journalDirectory: URL) async throws -> RestoreOperationResult {
        let normalizedSources = sources.map(\.standardizedFileURL)
        let normalizedDestination = destination.standardizedFileURL
        guard !normalizedSources.isEmpty else { throw EntryOperationError.noSources }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let operationId = UUID().uuidString
            let journalURL = journalDirectory.appendingPathComponent("restore-\(operationId).json")

            struct RestoreItemJournal: Codable {
                let source: URL
                let target: URL
                let state: String
                let message: String?
                let updatedAt: String
            }

            struct RestoreJournal: Codable {
                let version = 1
                let operation = "restoreFromTrash"
                let operationId: String
                let state: String
                let items: [RestoreItemJournal]
                let journalError: String?
            }

            let dateFormatter = operationDateFormatter()
            var itemStates = normalizedSources.map {
                RestoreItemOperationResult(source: $0, target: normalizedDestination.appendingPathComponent($0.lastPathComponent), state: "queued", message: nil)
            }
            var finalState = "completed"
            var journalError: String?

            func currentItemStates() -> [RestoreItemJournal] {
                return itemStates.enumerated().map { index, item in
                    RestoreItemJournal(source: item.source, target: item.target, state: item.state, message: item.message, updatedAt: dateFormatter.string(from: Date()))
                }
            }

            func save(state: String) throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                let journal = RestoreJournal(operationId: operationId, state: state, items: currentItemStates(), journalError: journalError)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }

            func isInTrash(_ source: URL) -> Bool {
                let path = source.standardizedFileURL.path
                let roots = [
                    FileManager.SearchPathDirectory.trashDirectory
                ]
                for domain in [FileManager.SearchPathDomainMask.userDomainMask, .localDomainMask] as [FileManager.SearchPathDomainMask] {
                    for root in FileManager.default.urls(for: roots[0], in: domain) {
                        let candidate = root.standardizedFileURL.path
                        if path == candidate || path.hasPrefix(candidate + "/") { return true }
                    }
                }
                return false
            }

            do {
                try save(state: "queued")
                for index in normalizedSources.indices {
                    let source = normalizedSources[index]
                    let destination = normalizedDestination.appendingPathComponent(source.lastPathComponent)
                    itemStates[index] = RestoreItemOperationResult(source: source, target: destination, state: itemStates[index].state, message: itemStates[index].message)
                    if !isInTrash(source) {
                        itemStates[index] = RestoreItemOperationResult(source: source, target: destination, state: "failed", message: LString.restoreSourceNotInTrash)
                        finalState = "partial"
                        try save(state: finalState)
                        continue
                    }
                    do {
                        if fm.fileExists(atPath: destination.path) {
                            itemStates[index] = RestoreItemOperationResult(source: source, target: destination, state: "conflict", message: LString.pathConflictMessage)
                            finalState = "partial"
                            try save(state: finalState)
                            continue
                        }
                        try fm.moveItem(at: source, to: destination)
                        itemStates[index] = RestoreItemOperationResult(source: source, target: destination, state: "completed", message: nil)
                    } catch {
                        itemStates[index] = RestoreItemOperationResult(source: source, target: destination, state: "failed", message: error.localizedDescription)
                        finalState = "partial"
                    }
                    try save(state: finalState)
                }
            } catch {
                finalState = "failed"
                journalError = error.localizedDescription
                try? save(state: finalState)
                throw error
            }

            do {
                try save(state: finalState)
            } catch {
                journalError = error.localizedDescription
                try? save(state: finalState)
            }

            return RestoreOperationResult(id: operationId, state: finalState, items: itemStates, journalError: journalError)
        }.value
    }

    public static func permanentlyDelete(_ sources: [URL], journalDirectory: URL) async throws -> PermanentDeleteOperationResult {
        let normalizedSources = sources.map(\.standardizedFileURL)
        guard !normalizedSources.isEmpty else { throw EntryOperationError.noSources }

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let operationId = UUID().uuidString
            let journalURL = journalDirectory.appendingPathComponent("permanent-delete-\(operationId).json")

            struct PermanentDeleteItemJournal: Codable {
                let source: URL
                let state: String
                let message: String?
                let updatedAt: String
            }

            struct PermanentDeleteJournal: Codable {
                let version = 1
                let operation = "permanentlyDelete"
                let operationId: String
                let state: String
                let items: [PermanentDeleteItemJournal]
                let journalError: String?
            }

            let dateFormatter = operationDateFormatter()
            var itemStates = normalizedSources.map { PermanentDeleteItemOperationResult(source: $0, state: "queued", message: nil) }
            var finalState = "completed"
            var journalError: String?

            func currentItemStates() -> [PermanentDeleteItemJournal] {
                return itemStates.enumerated().map { index, item in
                    PermanentDeleteItemJournal(source: item.source, state: item.state, message: item.message,
                                              updatedAt: dateFormatter.string(from: Date()))
                }
            }

            func save(state: String) throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                let journal = PermanentDeleteJournal(operationId: operationId, state: state, items: currentItemStates(),
                                                     journalError: journalError)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }

            do {
                try save(state: "queued")
                for index in normalizedSources.indices {
                    let source = normalizedSources[index]
                    do {
                        guard fm.fileExists(atPath: source.path) else {
                            itemStates[index] = PermanentDeleteItemOperationResult(source: source, state: "notFound", message: LString.fileMissing)
                            finalState = "partial"
                            try save(state: finalState)
                            continue
                        }
                        try fm.removeItem(at: source)
                        itemStates[index] = PermanentDeleteItemOperationResult(source: source, state: "completed", message: nil)
                    } catch {
                        itemStates[index] = PermanentDeleteItemOperationResult(source: source, state: "failed", message: error.localizedDescription)
                        finalState = "partial"
                    }
                    try save(state: finalState)
                }
            } catch {
                finalState = "failed"
                journalError = error.localizedDescription
                try? save(state: finalState)
                throw error
            }

            do {
                try save(state: finalState)
            } catch {
                journalError = error.localizedDescription
                try? save(state: finalState)
            }

            return PermanentDeleteOperationResult(id: operationId, state: finalState, items: itemStates, journalError: journalError)
        }.value
    }

    public static func move(_ sources: [URL], to destination: URL, conflictPolicy: MoveConflictPolicy = .skip,
                            journalDirectory: URL, cancellation: CopyCancellation = CopyCancellation(),
                            progress: @escaping @Sendable (MoveProgress) -> Void = { _ in }) async throws -> MoveOperationResult {
        try await moveImpl(sources, to: destination, conflictPolicy: conflictPolicy,
                           journalDirectory: journalDirectory, forceCrossVolume: false,
                           cancellation: cancellation, progress: progress)
    }

    public static func retryMove(_ sources: [ShelfEntry], to destination: ShelfEntry, journalDirectory: URL,
                                 cancellation: CopyCancellation,
                                 progress: @escaping @Sendable (MoveProgress) -> Void = { _ in }) async throws -> MoveOperationResult {
        try await moveImpl(sources.map(\.url), to: destination.url, conflictPolicy: .skip,
                           journalDirectory: journalDirectory, forceCrossVolume: false,
                           cancellation: cancellation, progress: progress,
                           retrySources: sources, retryDestination: destination)
    }

    static func moveAcrossVolumeForTesting(_ sources: [URL], to destination: URL,
                                           conflictPolicy: MoveConflictPolicy = .skip,
                                           journalDirectory: URL, cancellation: CopyCancellation = CopyCancellation(),
                                           progress: @escaping @Sendable (MoveProgress) -> Void = { _ in }) async throws -> MoveOperationResult {
        try await moveImpl(sources, to: destination, conflictPolicy: conflictPolicy,
                           journalDirectory: journalDirectory, forceCrossVolume: true,
                           cancellation: cancellation, progress: progress)
    }

    public static func flatten(_ plan: FolderFlattenPlan, journalDirectory: URL,
                               cancellation: CopyCancellation = CopyCancellation(),
                               progress: @escaping @Sendable (MoveProgress) -> Void = { _ in }) async throws -> MoveOperationResult {
        try await moveImpl(plan.sources, to: plan.destination, conflictPolicy: .skip,
                           journalDirectory: journalDirectory, forceCrossVolume: false,
                           cancellation: cancellation, progress: progress, flattenPlan: plan)
    }

    public static func redoMove(_ record: MoveRedoRecord, journalDirectory: URL) async -> [MoveItemOperationResult] {
        var results: [MoveItemOperationResult] = []
        for item in record.items {
            do {
                let report = try await moveImpl([item.source], to: item.target.deletingLastPathComponent(),
                    conflictPolicy: .skip, journalDirectory: journalDirectory, forceCrossVolume: false,
                    cancellation: CopyCancellation(), progress: { _ in }, redoItem: item)
                results += report.items
            } catch {
                results.append(MoveItemOperationResult(source: item.source, target: item.target,
                                                      state: "failed", message: error.localizedDescription))
            }
        }
        return results
    }

    private static func moveImpl(_ sources: [URL], to destination: URL, conflictPolicy: MoveConflictPolicy,
                                 journalDirectory: URL, forceCrossVolume: Bool, cancellation: CopyCancellation,
                                 progress: @escaping @Sendable (MoveProgress) -> Void,
                                 flattenPlan: FolderFlattenPlan? = nil, redoItem: MoveRedoRecord.Item? = nil,
                                 retrySources: [ShelfEntry]? = nil, retryDestination: ShelfEntry? = nil) async throws -> MoveOperationResult {
        let normalizedSources = sources.map(\.standardizedFileURL)
        guard !normalizedSources.isEmpty else { throw EntryOperationError.noSources }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let operationId = UUID().uuidString
            let journalURL = journalDirectory.appendingPathComponent("move-\(operationId).json")
            let normalizedDestination = destination.standardizedFileURL
            let destinationFD = open(normalizedDestination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard destinationFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(destinationFD) }
            if let expectedDestination = redoItem?.destinationFolder ?? retryDestination {
                var opened = stat(), current = stat()
                guard expectedDestination.isCurrent,
                      fstat(destinationFD, &opened) == 0, lstat(normalizedDestination.path, &current) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                    throw EntryOperationError.sourceChanged
                }
            }

            struct MoveItemJournal: Codable {
                let source: URL
                let target: URL
                let backup: URL?
                let state: String
                let message: String?
                let updatedAt: String
            }

            struct MoveJournal: Codable {
                let version = 1
                let operation = "move"
                let operationId: String
                let state: String
                let items: [MoveItemJournal]
                let journalError: String?
            }

            let dateFormatter = operationDateFormatter()
            var itemStates = normalizedSources.map {
                MoveItemOperationResult(source: $0, target: normalizedDestination.appendingPathComponent($0.lastPathComponent),
                                       state: "queued", message: nil)
            }
            var publishedIdentities = Array<String?>(repeating: nil, count: normalizedSources.count)
            var publishedSnapshots = Array<[String: String]?>(repeating: nil, count: normalizedSources.count)
            var backupIdentities = Array<String?>(repeating: nil, count: normalizedSources.count)
            var backupSnapshots = Array<[String: String]?>(repeating: nil, count: normalizedSources.count)
            var canRecordUndo = Array(repeating: true, count: normalizedSources.count)
            var backupURLs = Array<URL?>(repeating: nil, count: normalizedSources.count)
            var crossVolumeItems = Array(repeating: false, count: normalizedSources.count)
            var finalState = "completed"
            var journalError: String?

            func currentItemStates() -> [MoveItemJournal] {
                return itemStates.enumerated().map { index, item in
                    MoveItemJournal(source: item.source, target: item.target, backup: backupURLs[index], state: item.state, message: item.message,
                                   updatedAt: dateFormatter.string(from: Date()))
                }
            }

            func save(state: String) throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                let journal = MoveJournal(operationId: operationId, state: state, items: currentItemStates(), journalError: journalError)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }

            do {
                try save(state: "queued")
                for index in normalizedSources.indices {
                    let source = normalizedSources[index]
                    let target = normalizedDestination.appendingPathComponent(source.lastPathComponent)
                    var backup: URL?
                    var backupVerified = false
                    var retrySource: ShelfEntry?
                    func snapshotForUndo(_ url: URL) throws -> [String: String]? {
                        do {
                            let attributes = try fm.attributesOfItem(atPath: url.path)
                            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
                            emit("verifyingUndo")
                            return try CopyEngine.verifiedSnapshot(url, cancellation: cancellation)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // A rename may work on a folder we cannot read or which
                            // contains special files. Never offer an unchecked Undo.
                            canRecordUndo[index] = false
                            return nil
                        }
                    }
                    func emit(_ phase: String, stagedTransfer: StagedFileTransfer? = nil) {
                        progress(MoveProgress(index: index, total: normalizedSources.count,
                                              name: source.lastPathComponent, phase: phase, stagedTransfer: stagedTransfer))
                    }
                    func restoreBackup() -> URL? {
                        guard let backup else {
                            backupURLs[index] = nil
                            return nil
                        }
                        do {
                            var opened = stat(), current = stat()
                            guard fstat(destinationFD, &opened) == 0,
                                  lstat(normalizedDestination.path, &current) == 0,
                                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                                throw EntryOperationError.sourceChanged
                            }
                            guard backupVerified, let identity = backupIdentities[index],
                                  try matchesUndoEntry(backup, identity: identity, snapshot: backupSnapshots[index],
                                                       fileManager: fm) else { return backup }
                            try CopyEngine.publishNoReplace(payload: backup, target: target,
                                sourceDirectoryFD: destinationFD, sourceName: backup.lastPathComponent,
                                destinationDirectoryFD: destinationFD, destinationName: target.lastPathComponent)
                            backupURLs[index] = nil
                            return nil
                        } catch {
                            return backup
                        }
                    }
                    if cancellation.isCancelled {
                        itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "cancelled", message: nil)
                        finalState = "cancelled"
                        try save(state: finalState)
                        continue
                    }
                    do {
                        try cancellation.check(); emit("planning")
                        if let flattenPlan {
                            let parent = source.deletingLastPathComponent()
                            guard flattenPlan.root.isCurrent, flattenPlan.entries[index].isCurrent,
                                  FolderFlattenPlan.isDirectoryWithoutLink(parent),
                                  let base = FolderFlattenPlan.canonicalPath(flattenPlan.destination),
                                  FolderFlattenPlan.canonicalPath(parent)?.hasPrefix(base + "/") == true else {
                                itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "failed",
                                    message: "Source changed after the flatten plan was created.")
                                finalState = "partial"
                                try save(state: finalState)
                                continue
                            }
                        }
                        guard entryExists(source) else {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "notFound", message: LString.fileMissing)
                            finalState = "partial"
                            try save(state: finalState)
                            continue
                        }

                        do {
                            if let retrySources, !retrySources[index].isCurrent {
                                throw EntryOperationError.sourceChanged
                            }
                            if let redoItem {
                                guard redoItem.target.standardizedFileURL.path == target.path,
                                      redoItem.destinationFolder.isCurrent,
                                      try snapshotIdentity(source, fileManager: fm) == redoItem.identity,
                                      try CopyEngine.verifiedSnapshot(source, cancellation: cancellation) == redoItem.snapshot else {
                                    throw EntryOperationError.sourceChanged
                                }
                            }
                            guard let sourceDevice = (try fm.attributesOfItem(atPath: source.path)[.systemNumber] as? NSNumber)?.uint64Value,
                                  let destinationDevice = (try fm.attributesOfItem(atPath: normalizedDestination.path)[.systemNumber] as? NSNumber)?.uint64Value else {
                                throw EntryOperationError.sourceChanged
                            }
                            let crossVolume = forceCrossVolume || sourceDevice != destinationDevice
                            if retrySources != nil && crossVolume { throw EntryOperationError.sourceChanged }
                            crossVolumeItems[index] = crossVolume
                            if entryExists(target) {
                                if conflictPolicy == .skip {
                                    itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "conflict", message: LString.pathConflictMessage)
                                    finalState = "partial"
                                    try save(state: finalState)
                                    continue
                                }
                                let proposedBackup = normalizedDestination.appendingPathComponent(".files-move-backup-\(operationId)-\(index)")
                                backupURLs[index] = proposedBackup
                                itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "backingUp", message: nil)
                                try save(state: finalState)
                                let backupIdentity = try snapshotIdentity(target, fileManager: fm)
                                let backupSnapshot = try snapshotForUndo(target)
                                emit("backingUp"); try cancellation.check()
                                guard try snapshotIdentity(target, fileManager: fm) == backupIdentity else {
                                    throw EntryOperationError.sourceChanged
                                }
                                do {
                                    try CopyEngine.publishNoReplace(payload: target, target: proposedBackup,
                                        sourceDirectoryFD: destinationFD, sourceName: target.lastPathComponent,
                                        destinationDirectoryFD: destinationFD, destinationName: proposedBackup.lastPathComponent)
                                } catch CopyPublicationError.conflict { throw EntryOperationError.conflict }
                                backup = proposedBackup
                                backupURLs[index] = proposedBackup
                                backupIdentities[index] = backupIdentity
                                backupSnapshots[index] = backupSnapshot
                                backupVerified = canRecordUndo[index]
                            }
                            if crossVolume {
                                let sourceIdentity = try snapshotIdentity(source, fileManager: fm)
                                let before = try CopyEngine.verifiedSnapshot(source, cancellation: cancellation)
                                if let redoItem, before != redoItem.snapshot { throw EntryOperationError.sourceChanged }
                                let contentBefore = try CopyEngine.verifiedContentSnapshot(source, cancellation: cancellation)
                                let stage = normalizedDestination.appendingPathComponent(".files-move-\(operationId)-\(index)")
                                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                                defer { if entryExists(stage) { try? fm.removeItem(at: stage) } }
                                let payload = stage.appendingPathComponent("payload")
                                itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "copying", message: nil)
                                try save(state: finalState); emit("copying"); try cancellation.check()
                                let copyStarted = ContinuousClock.now
                                try fm.copyItem(at: source, to: payload)
                                let copyElapsed = copyStarted.duration(to: .now)
                                try cancellation.check()
                                itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "verifying", message: nil)
                                try save(state: finalState)
                                let stagedTransfer = (try? fm.attributesOfItem(atPath: payload.path)).flatMap {
                                    StagedFileTransfer(attributes: $0, elapsed: copyElapsed)
                                }
                                emit("verifying", stagedTransfer: stagedTransfer)
                                let verifiedPayload = try CopyEngine.makeSnapshot(payload, cancellation: cancellation)
                                guard verifiedPayload.content == contentBefore,
                                      try CopyEngine.verifiedSnapshot(source, cancellation: cancellation) == before else {
                                    throw MoveFailure(text: LString.crossVolumeVerificationFailed)
                                }
                                let payloadIdentity = try snapshotIdentity(payload, fileManager: fm)
                                let payloadSnapshot = verifiedPayload.content[""] == "directory"
                                    ? verifiedPayload.withPermissions : nil
                                try cancellation.check(); emit("committing")
                                let stageFD = open(stage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                                guard stageFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                                defer { close(stageFD) }
                                if let redoItem, !redoItem.destinationFolder.isCurrent {
                                    throw EntryOperationError.sourceChanged
                                }
                                do {
                                    try CopyEngine.publishNoReplace(payload: payload, target: target,
                                        sourceDirectoryFD: stageFD, sourceName: "payload",
                                        destinationDirectoryFD: destinationFD, destinationName: target.lastPathComponent)
                                } catch CopyPublicationError.conflict { throw EntryOperationError.conflict }
                                do {
                                    try cancellation.check(); emit("removingSource")
                                    try cancellation.check()
                                    guard try CopyEngine.verifiedSnapshot(source, cancellation: cancellation) == before,
                                          try snapshotIdentity(source, fileManager: fm) == sourceIdentity else {
                                        throw MoveFailure(text: LString.crossVolumeSourceChanged)
                                    }
                                } catch {
                                    let originalError = error
                                    if matchesTransfer(target, identity: payloadIdentity, contents: contentBefore, fileManager: fm) {
                                        try? fm.removeItem(at: target)
                                    }
                                    throw originalError
                                }
                                guard matchesTransfer(target, identity: payloadIdentity, contents: contentBefore, fileManager: fm) else {
                                    throw MoveFailure(text: LString.crossVolumeDestinationChanged)
                                }
                                try cancellation.check()
                                guard try snapshotIdentity(source, fileManager: fm) == sourceIdentity else {
                                    throw MoveFailure(text: LString.crossVolumeSourceChanged)
                                }
                                // Directory removal can fail after deleting some children.
                                // Keep the verified destination if source removal was attempted.
                                try fm.removeItem(at: source)
                                publishedIdentities[index] = payloadIdentity
                                publishedSnapshots[index] = payloadSnapshot
                            } else {
                                if conflictPolicy == .skip, flattenPlan == nil, redoItem == nil {
                                    retrySource = retrySources?[index] ?? ShelfEntry(source)
                                }
                                let identity = try snapshotIdentity(source, fileManager: fm)
                                let snapshot = try snapshotForUndo(source)
                                try cancellation.check(); emit("committing")
                                try cancellation.check()
                                guard try snapshotIdentity(source, fileManager: fm) == identity else {
                                    throw EntryOperationError.sourceChanged
                                }
                                if flattenPlan != nil || redoItem != nil || retrySources != nil {
                                    let sourceFD = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                                    guard sourceFD >= 0 else { throw EntryOperationError.sourceChanged }
                                    defer { close(sourceFD) }
                                    if let redoItem {
                                        guard redoItem.destinationFolder.isCurrent,
                                              try snapshotIdentity(source, fileManager: fm) == redoItem.identity else {
                                            throw EntryOperationError.sourceChanged
                                        }
                                    }
                                    if let retrySources {
                                        guard retryDestination?.isCurrent == true,
                                              retrySources[index].isCurrent else { throw EntryOperationError.sourceChanged }
                                    }
                                    do {
                                        try CopyEngine.publishNoReplace(payload: source, target: target,
                                            sourceDirectoryFD: sourceFD, sourceName: source.lastPathComponent,
                                            destinationDirectoryFD: destinationFD, destinationName: target.lastPathComponent,
                                            allowPathFallback: retrySources == nil)
                                    } catch CopyPublicationError.conflict { throw EntryOperationError.conflict }
                                } else {
                                    try fm.moveItem(at: source, to: target)
                                }
                                publishedIdentities[index] = identity
                                publishedSnapshots[index] = snapshot
                            }
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "completed",
                                message: canRecordUndo[index] ? nil : LString.moveUndoSnapshotUnavailable,
                                recoveryBackup: canRecordUndo[index] ? nil : backup)
                        } catch is CancellationError {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "cancelled",
                                message: nil, recoveryBackup: restoreBackup())
                            finalState = "cancelled"
                        } catch EntryOperationError.conflict {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "conflict",
                                message: LString.pathConflictMessage, recoveryBackup: restoreBackup())
                            finalState = "partial"
                        } catch {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "failed",
                                message: error.localizedDescription, recoveryBackup: restoreBackup(),
                                retrySource: retrySource?.isCurrent == true ? retrySource : nil)
                            finalState = "partial"
                        }
                    }
                    try save(state: finalState)
                }
            } catch {
                finalState = "failed"
                journalError = error.localizedDescription
                try? save(state: finalState)
                throw error
            }

            do {
                try save(state: finalState)
            } catch {
                journalError = error.localizedDescription
                try? save(state: finalState)
            }

            do {
                let completed = itemStates.enumerated().filter {
                    $0.element.state == "completed" && canRecordUndo[$0.offset]
                }
                if !completed.isEmpty {
                        let undoItems = try completed.map { indexed in
                            let item = indexed.element
                            let backup = backupURLs[indexed.offset]
                            return MoveUndoItem(source: item.source, target: item.target,
                                targetIdentity: try publishedIdentities[indexed.offset] ?? snapshotIdentity(item.target, fileManager: fm),
                                backup: backup, backupIdentity: backupIdentities[indexed.offset],
                                crossVolume: crossVolumeItems[indexed.offset],
                                targetSnapshot: publishedSnapshots[indexed.offset],
                                backupSnapshot: backupSnapshots[indexed.offset])
                        }
                        let record = MoveUndoRecord(operationId: operationId, items: undoItems, createdAt: Date())
                        try JSONEncoder().encode(record).write(
                            to: journalDirectory.appendingPathComponent("undo-move-\(operationId).json"), options: .atomic)
                }
            } catch {
                journalError = error.localizedDescription
                try? save(state: finalState)
            }

            return MoveOperationResult(id: operationId, state: finalState, items: itemStates, journalError: journalError)
        }.value
    }

    public static func undoMove(_ record: MoveUndoRecord, journalDirectory: URL) async -> MoveUndoResult {
        await undoMove(record, journalDirectory: journalDirectory, beforeBackupRestore: { _ in })
    }

    static func undoMove(_ record: MoveUndoRecord, journalDirectory: URL,
                         afterCopyPublication: @escaping @Sendable () throws -> Void = {},
                         beforeBackupRestore: @escaping @Sendable (URL) -> Void) async -> MoveUndoResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var results: [MoveUndoItemResult] = []
            var replay: [MoveRedoRecord.Item] = []
            var pendingBackupRestorations = Set<Int>()
            var undoItems = record.items
            let pending = journalDirectory.appendingPathComponent("undo-move-\(record.operationId).json")
            func savePending(_ items: [MoveUndoItem]) throws {
                let retryRecord = MoveUndoRecord(operationId: record.operationId, items: items, createdAt: record.createdAt)
                try JSONEncoder().encode(retryRecord).write(to: pending, options: .atomic)
            }
            func checkpoint(_ index: Int) throws {
                let remaining = undoItems.enumerated().compactMap { offset, candidate -> MoveUndoItem? in
                    if offset > index, results[undoItems.count - 1 - offset].state == "completed" { return nil }
                    return pendingBackupRestorations.contains(offset) ? candidate.awaitingBackupRestore() : candidate
                }
                try savePending(remaining)
            }
            for (index, item) in record.items.enumerated().reversed() {
                let result: MoveUndoItemResult
                do {
                    // A same-volume rename preserves the item's identity. If the
                    // process stopped before saving the checkpoint, the original
                    // location can prove that the first half of Undo already ran.
                    let sourceAlreadyRenamed = item.backupRestorePending != true && !item.crossVolume
                        && item.backup != nil && entryExists(item.source)
                        && (try? matchesUndoEntry(item.source, identity: item.targetIdentity,
                                                  snapshot: item.targetSnapshot, fileManager: fm)) == true
                    let sourceAlreadyCopied: Bool
                    if item.backupRestorePending != true, item.crossVolume, item.backup != nil,
                       let identity = item.restoredCopyIdentity, let snapshot = item.restoredCopySnapshot,
                       entryExists(item.source) {
                        sourceAlreadyCopied = try matchesUndoEntry(item.source, identity: identity, snapshot: snapshot, fileManager: fm)
                    } else {
                        sourceAlreadyCopied = false
                    }
                    let sourceAlreadyRestored = sourceAlreadyRenamed || sourceAlreadyCopied
                    if item.backupRestorePending == true || sourceAlreadyRestored,
                       let backup = item.backup, let identity = item.backupIdentity,
                       !entryExists(backup), entryExists(item.target),
                       try matchesUndoEntry(item.target, identity: identity, snapshot: item.backupSnapshot, fileManager: fm) {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target,
                            state: "completed", message: nil))
                        continue
                    }
                    if let backup = item.backup {
                        guard entryExists(backup), let expected = item.backupIdentity,
                              try matchesUndoEntry(backup, identity: expected, snapshot: item.backupSnapshot, fileManager: fm) else {
                            results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "changed", message: LString.undoBackupChanged)); continue
                        }
                    }
                    if sourceAlreadyCopied, entryExists(item.target),
                       let restoredIdentity = item.restoredCopyIdentity {
                        let original = try CopyEngine.makeSnapshot(item.target, cancellation: CopyCancellation())
                        guard item.targetSnapshot == nil || original.withPermissions == item.targetSnapshot,
                              matchesTransfer(item.source, identity: restoredIdentity, contents: original.content,
                                              fileManager: fm),
                              try snapshotIdentity(item.target, fileManager: fm) == item.targetIdentity else {
                            results.append(MoveUndoItemResult(source: item.source, target: item.target,
                                state: "changed", message: LString.undoTargetChanged))
                            continue
                        }
                        try fm.removeItem(at: item.target)
                    }
                    if item.backupRestorePending == true || sourceAlreadyRestored {
                        if sourceAlreadyRestored {
                            pendingBackupRestorations.insert(index)
                            try checkpoint(index)
                        }
                        guard let backup = item.backup, item.backupIdentity != nil else {
                            throw MoveFailure(text: LString.undoBackupChanged)
                        }
                        guard !entryExists(item.target) else {
                            results.append(MoveUndoItemResult(source: item.source, target: item.target,
                                state: "conflict", message: LString.pathConflictMessage))
                            continue
                        }
                        try restoreUndoBackup(backup, to: item.target)
                        results.append(MoveUndoItemResult(source: item.source, target: item.target,
                            state: "completed", message: nil))
                        continue
                    }
                    guard entryExists(item.target) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "notFound", message: LString.undoTargetMissing)); continue
                    }
                    guard try matchesUndoEntry(item.target, identity: item.targetIdentity, snapshot: item.targetSnapshot, fileManager: fm) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "changed", message: LString.undoTargetChanged)); continue
                    }
                    guard !entryExists(item.source) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "conflict", message: LString.undoSourceConflict)); continue
                    }
                    guard fm.fileExists(atPath: item.source.deletingLastPathComponent().path) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "notFound", message: LString.undoSourceParentMissing)); continue
                    }
                    let replaySnapshot = item.backup == nil ? item.targetSnapshot ?? (try? CopyEngine.verifiedSnapshot(item.target)) : nil
                    let destinationFolder = ShelfEntry(item.target.deletingLastPathComponent())
                    try transferForUndo(item.target, to: item.source, crossVolume: item.crossVolume,
                                        expectedSnapshot: item.targetSnapshot, checkpointCopy: { identity, snapshot in
                        guard item.backup != nil else { return }
                        undoItems[index].restoredCopyIdentity = identity
                        undoItems[index].restoredCopySnapshot = snapshot
                        try checkpoint(index)
                    }, afterCopyPublication: afterCopyPublication)
                    if let replaySnapshot, let destinationFolder,
                       let identity = try? snapshotIdentity(item.source, fileManager: fm) {
                        replay.append(.init(source: item.source, target: item.target, identity: identity,
                                            snapshot: replaySnapshot, destinationFolder: destinationFolder))
                    }
                    if let backup = item.backup, let identity = item.backupIdentity {
                        pendingBackupRestorations.insert(index)
                        // Save before publishing the backup, so a restart can resume
                        // without moving the already-restored source again.
                        try checkpoint(index)
                        beforeBackupRestore(item.target)
                        guard try matchesUndoEntry(backup, identity: identity, snapshot: item.backupSnapshot, fileManager: fm) else {
                            throw MoveFailure(text: LString.undoBackupChanged)
                        }
                        try restoreUndoBackup(backup, to: item.target)
                    }
                    result = MoveUndoItemResult(source: item.source, target: item.target, state: "completed", message: nil)
                } catch EntryOperationError.conflict {
                    result = MoveUndoItemResult(source: item.source, target: item.target,
                        state: "conflict", message: LString.pathConflictMessage)
                } catch {
                    result = MoveUndoItemResult(source: item.source, target: item.target, state: "failed", message: error.localizedDescription)
                }
                results.append(result)
            }
            results.reverse()
            let state = results.allSatisfy { $0.state == "completed" } ? "completed" : "partial"
            var journalError: String?
            struct UndoItem: Encodable { let source: URL; let target: URL; let state: String; let message: String? }
            struct UndoJournal: Encodable {
                let version = 1; let operation = "undoMove"; let operationId: String; let state: String; let items: [UndoItem]
            }
            do {
                let journal = UndoJournal(operationId: record.operationId, state: state,
                    items: results.map { UndoItem(source: $0.source, target: $0.target, state: $0.state, message: $0.message) })
                try JSONEncoder().encode(journal).write(
                    to: journalDirectory.appendingPathComponent("undo-result-\(record.operationId).json"), options: .atomic)
                let consumed = journalDirectory.appendingPathComponent("undo-consumed-\(record.operationId).json")
                if state == "completed" {
                    if fm.fileExists(atPath: pending.path) { try fm.moveItem(at: pending, to: consumed) }
                } else {
                    let remaining = zip(undoItems, results).enumerated().compactMap { index, pair -> MoveUndoItem? in
                        let (item, result) = pair
                        guard result.state != "completed" else { return nil }
                        return pendingBackupRestorations.contains(index) ? item.awaitingBackupRestore() : item
                    }
                    try savePending(remaining)
                }
            } catch { journalError = error.localizedDescription }
            let redo = journalError == nil && state == "completed" && replay.count == results.count && !replay.isEmpty
                ? MoveRedoRecord(items: Array(replay.reversed()), undoneAt: Date()) : nil
            return MoveUndoResult(redo: redo, operationId: record.operationId, state: state, items: results, journalError: journalError)
        }.value
    }

    private struct Journal: Encodable {
        let version = 1
        let operation: String
        let source: URL?
        let target: URL
        var state: String
    }

    private static func perform(parent: URL, source: URL?, expectedIdentity: String?, name: String,
                                journalDirectory: URL) async throws -> EntryOperationResult {
        try validateName(name)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager()
            let parent = parent.standardizedFileURL
            let target = parent.appendingPathComponent(name)
            let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var journal = Journal(operation: source == nil ? "createFolder" : "rename", source: source, target: target, state: "planned")
            let journalURL = journalDirectory.appendingPathComponent("entry-\(UUID()).json")
            func save() throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }
            try save() // No mutation when the initial journal cannot be saved.
            do {
                var opened = stat(), current = stat()
                guard fstat(fd, &opened) == 0, stat(parent.path, &current) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                    throw EntryOperationError.sourceChanged
                }
                if let source {
                    if let expectedIdentity {
                        guard LocalEntryIdentity.read(source, fileManager: fm) == expectedIdentity else {
                            throw EntryOperationError.sourceChanged
                        }
                    } else {
                        _ = try fm.attributesOfItem(atPath: source.path)
                    }
                    if source.lastPathComponent != name {
                        do {
                            try CopyEngine.publishNoReplace(payload: source, target: target,
                                sourceDirectoryFD: fd, sourceName: source.lastPathComponent,
                                destinationDirectoryFD: fd, destinationName: name)
                        } catch CopyPublicationError.conflict {
                            throw EntryOperationError.conflict
                        }
                    }
                } else {
                    guard mkdirat(fd, name, 0o777) == 0 else {
                        if errno == EEXIST { throw EntryOperationError.conflict }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            } catch {
                journal.state = "failed"; try? save(); throw error
            }
            journal.state = "completed"
            do { try save(); return EntryOperationResult(target: target, journalWarning: nil) }
            catch { return EntryOperationResult(target: target, journalWarning: error.localizedDescription) }
        }.value
    }
}

private enum LString {
    static let fileMissing = "원본 항목이 없습니다."
    static let restoreSourceNotInTrash = "휴지통에 없는 항목입니다."
    static let pathConflictMessage = "대상 폴더에 같은 이름의 항목이 이미 존재합니다."
    static let undoTargetMissing = "이동된 항목이 대상 위치에 없습니다."
    static let undoTargetChanged = "이동 후 항목이 변경되어 실행 취소하지 않았습니다."
    static let undoSourceConflict = "원래 위치에 같은 이름의 항목이 있어 실행 취소하지 않았습니다."
    static let undoSourceParentMissing = "원래 상위 폴더가 없어 실행 취소하지 않았습니다."
    static let undoBackupChanged = "교체 전 백업이 없거나 변경되어 실행 취소하지 않았습니다."
    static let moveUndoSnapshotUnavailable = Locale.preferredLanguages.first?.hasPrefix("ko") == true
        ? "폴더의 하위 항목을 검증할 수 없어 이 항목의 실행 취소를 기록하지 않았습니다."
        : "Undo is unavailable for this item because its folder contents could not be verified."
    static let crossVolumeVerificationFailed = "복사 결과가 원본과 일치하지 않거나 복사 중 원본이 변경됐습니다."
    static let crossVolumeSourceChanged = "복사 결과를 확정한 뒤 원본이 변경되어 원본 삭제를 중단했습니다."
    static let crossVolumeDestinationChanged = "복사 결과를 확정한 뒤 대상이 변경되어 원본 삭제를 중단했습니다."
}

private struct MoveFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
