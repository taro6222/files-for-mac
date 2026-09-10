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
}

public struct MoveOperationResult: Sendable {
    public let id: String
    public let state: String
    public let items: [MoveItemOperationResult]
    public let journalError: String?
}

public struct MoveUndoItem: Codable, Sendable {
    public let source: URL
    public let target: URL
    public let targetIdentity: String
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

public struct MoveUndoResult: Sendable {
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

    public static func latestUndoMove(journalDirectory: URL) -> MoveUndoRecord? {
        let fm = FileManager.default
        guard let candidates = try? fm.contentsOfDirectory(at: journalDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return candidates
            .filter { $0.lastPathComponent.hasPrefix("undo-move-") && $0.pathExtension == "json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .lazy.compactMap { try? JSONDecoder().decode(MoveUndoRecord.self, from: Data(contentsOf: $0)) }.first
    }

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\0") else { throw EntryOperationError.invalidName }
    }

    public static func createFolder(in parent: URL, name: String, journalDirectory: URL) async throws -> EntryOperationResult {
        try await perform(parent: parent, source: nil, expectedIdentity: nil, name: name, journalDirectory: journalDirectory)
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
                            journalDirectory: URL) async throws -> MoveOperationResult {
        try await moveImpl(sources, to: destination, conflictPolicy: conflictPolicy,
                           journalDirectory: journalDirectory, forceCrossVolume: false)
    }

    static func moveAcrossVolumeForTesting(_ sources: [URL], to destination: URL,
                                           conflictPolicy: MoveConflictPolicy = .skip,
                                           journalDirectory: URL) async throws -> MoveOperationResult {
        try await moveImpl(sources, to: destination, conflictPolicy: conflictPolicy,
                           journalDirectory: journalDirectory, forceCrossVolume: true)
    }

    private static func moveImpl(_ sources: [URL], to destination: URL, conflictPolicy: MoveConflictPolicy,
                                 journalDirectory: URL, forceCrossVolume: Bool) async throws -> MoveOperationResult {
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

            struct MoveItemJournal: Codable {
                let source: URL
                let target: URL
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
            var undoEligible = Array(repeating: false, count: normalizedSources.count)
            var finalState = "completed"
            var journalError: String?

            func currentItemStates() -> [MoveItemJournal] {
                return itemStates.enumerated().map { index, item in
                    MoveItemJournal(source: item.source, target: item.target, state: item.state, message: item.message,
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
                    do {
                        guard entryExists(source) else {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "notFound", message: LString.fileMissing)
                            finalState = "partial"
                            try save(state: finalState)
                            continue
                        }

                        do {
                            guard let sourceDevice = (try fm.attributesOfItem(atPath: source.path)[.systemNumber] as? NSNumber)?.uint64Value,
                                  let destinationDevice = (try fm.attributesOfItem(atPath: normalizedDestination.path)[.systemNumber] as? NSNumber)?.uint64Value else {
                                throw EntryOperationError.sourceChanged
                            }
                            let crossVolume = forceCrossVolume || sourceDevice != destinationDevice
                            if entryExists(target) {
                                if conflictPolicy == .skip {
                                    itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "conflict", message: LString.pathConflictMessage)
                                    finalState = "partial"
                                    try save(state: finalState)
                                    continue
                                }
                                guard !crossVolume else { throw MoveFailure(text: LString.crossVolumeReplaceRequiresBackup) }
                                try fm.removeItem(at: target)
                            }
                            if crossVolume {
                                let before = try CopyEngine.verifiedSnapshot(source)
                                let stage = normalizedDestination.appendingPathComponent(".files-move-\(operationId)-\(index)")
                                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                                defer { if entryExists(stage) { try? fm.removeItem(at: stage) } }
                                let payload = stage.appendingPathComponent("payload")
                                itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "copying", message: nil)
                                try save(state: finalState)
                                try fm.copyItem(at: source, to: payload)
                                itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "verifying", message: nil)
                                try save(state: finalState)
                                guard try CopyEngine.verifiedSnapshot(payload) == before,
                                      try CopyEngine.verifiedSnapshot(source) == before else {
                                    throw MoveFailure(text: LString.crossVolumeVerificationFailed)
                                }
                                let stageFD = open(stage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                                guard stageFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                                defer { close(stageFD) }
                                guard renameatx_np(stageFD, "payload", destinationFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                                    if errno == EEXIST { throw EntryOperationError.conflict }
                                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                }
                                do {
                                    guard try CopyEngine.verifiedSnapshot(source) == before else {
                                        throw MoveFailure(text: LString.crossVolumeSourceChanged)
                                    }
                                    try fm.removeItem(at: source)
                                } catch {
                                    let originalError = error
                                    if entryExists(target), (try? CopyEngine.verifiedSnapshot(target)) == before { try? fm.removeItem(at: target) }
                                    throw originalError
                                }
                            } else {
                                try fm.moveItem(at: source, to: target)
                                undoEligible[index] = true
                            }
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "completed", message: nil)
                        } catch EntryOperationError.conflict {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "conflict", message: LString.pathConflictMessage)
                            finalState = "partial"
                        } catch {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "failed", message: error.localizedDescription)
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

            if conflictPolicy == .skip {
                let completed = itemStates.enumerated().filter {
                    $0.element.state == "completed" && undoEligible[$0.offset]
                }.map(\.element)
                if !completed.isEmpty {
                    do {
                        let undoItems = try completed.map {
                            MoveUndoItem(source: $0.source, target: $0.target,
                                targetIdentity: try snapshotIdentity($0.target, fileManager: fm))
                        }
                        let record = MoveUndoRecord(operationId: operationId, items: undoItems, createdAt: Date())
                        try JSONEncoder().encode(record).write(
                            to: journalDirectory.appendingPathComponent("undo-move-\(operationId).json"), options: .atomic)
                    } catch {
                        journalError = error.localizedDescription
                        try? save(state: finalState)
                    }
                }
            }

            return MoveOperationResult(id: operationId, state: finalState, items: itemStates, journalError: journalError)
        }.value
    }

    public static func undoMove(_ record: MoveUndoRecord, journalDirectory: URL) async -> MoveUndoResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var results: [MoveUndoItemResult] = []
            for item in record.items.reversed() {
                let result: MoveUndoItemResult
                do {
                    guard entryExists(item.target) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "notFound", message: LString.undoTargetMissing)); continue
                    }
                    guard try snapshotIdentity(item.target, fileManager: fm) == item.targetIdentity else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "changed", message: LString.undoTargetChanged)); continue
                    }
                    guard !entryExists(item.source) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "conflict", message: LString.undoSourceConflict)); continue
                    }
                    guard fm.fileExists(atPath: item.source.deletingLastPathComponent().path) else {
                        results.append(MoveUndoItemResult(source: item.source, target: item.target, state: "notFound", message: LString.undoSourceParentMissing)); continue
                    }
                    try fm.moveItem(at: item.target, to: item.source)
                    result = MoveUndoItemResult(source: item.source, target: item.target, state: "completed", message: nil)
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
                let pending = journalDirectory.appendingPathComponent("undo-move-\(record.operationId).json")
                let consumed = journalDirectory.appendingPathComponent("undo-consumed-\(record.operationId).json")
                if fm.fileExists(atPath: pending.path) { try fm.moveItem(at: pending, to: consumed) }
            } catch { journalError = error.localizedDescription }
            return MoveUndoResult(operationId: record.operationId, state: state, items: results, journalError: journalError)
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
                    let attrs = try fm.attributesOfItem(atPath: source.path)
                    if let expectedIdentity {
                        guard let device = attrs[.systemNumber] as? NSNumber,
                              let inode = attrs[.systemFileNumber] as? NSNumber,
                              let birth = attrs[.creationDate] as? Date,
                              "\(device):\(inode):\(birth.timeIntervalSince1970)" == expectedIdentity else {
                            throw EntryOperationError.sourceChanged
                        }
                    }
                    if source.lastPathComponent != name {
                        guard renameatx_np(fd, source.lastPathComponent, fd, name, UInt32(RENAME_EXCL)) == 0 else {
                            if errno == EEXIST { throw EntryOperationError.conflict }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
    static let crossVolumeReplaceRequiresBackup = "교차 볼륨 교체 이동은 기존 대상 백업이 필요합니다. 건너뛰기 정책을 사용하세요."
    static let crossVolumeVerificationFailed = "복사 결과가 원본과 일치하지 않거나 복사 중 원본이 변경됐습니다."
    static let crossVolumeSourceChanged = "복사 결과를 확정한 뒤 원본이 변경되어 원본 삭제를 중단했습니다."
}

private struct MoveFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
