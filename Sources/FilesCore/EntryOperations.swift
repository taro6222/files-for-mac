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

public enum MoveConflictPolicy: String, Sendable {
    case skip
    case replace
}

/// Single directory-entry operations. No replacement, recursive rename, or undo.
public enum EntryOperations {
    private static func operationDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
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
        let normalizedSources = sources.map(\.standardizedFileURL)
        guard !normalizedSources.isEmpty else { throw EntryOperationError.noSources }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let operationId = UUID().uuidString
            let journalURL = journalDirectory.appendingPathComponent("move-\(operationId).json")
            let normalizedDestination = destination.standardizedFileURL

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
                        guard fm.fileExists(atPath: source.path) else {
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "notFound", message: LString.fileMissing)
                            finalState = "partial"
                            try save(state: finalState)
                            continue
                        }

                        do {
                            let conflictInfo = fm.fileExists(atPath: target.path)
                            if conflictInfo {
                                if conflictPolicy == .skip {
                                    itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "conflict", message: LString.pathConflictMessage)
                                    finalState = "partial"
                                    try save(state: finalState)
                                    continue
                                }
                                try fm.removeItem(at: target)
                            }
                            try fm.moveItem(at: source, to: target)
                            itemStates[index] = MoveItemOperationResult(source: source, target: target, state: "completed", message: nil)
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

            return MoveOperationResult(id: operationId, state: finalState, items: itemStates, journalError: journalError)
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
}
