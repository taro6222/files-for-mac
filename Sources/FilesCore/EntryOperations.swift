import Foundation
import Darwin

public enum EntryOperationError: Error, Sendable {
    case invalidName, conflict, sourceChanged
}

public struct EntryOperationResult: Sendable {
    public let target: URL
    public let journalWarning: String?
}

/// Single directory-entry operations. No replacement, recursive rename, or undo.
public enum EntryOperations {
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
