import Foundation
import CryptoKit
import Darwin

public final class CopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

public struct CopyProgress: Sendable {
    public let index: Int
    public let total: Int
    public let name: String
    public let phase: String
}

public struct CopyRecord: Codable, Sendable {
    public let source: URL
    public var target: URL
    public var state: String = "queued"
    public var message: String? = nil
    public var temporary: URL? = nil
    public var targetIdentity: String? = nil
    public var targetSnapshot: [String: String]? = nil
}

/// Versioned, inspectable foundation journal. This is not yet an undo/recovery database.
public struct CopyReport: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public var state: String
    public var items: [CopyRecord]
    public var journalError: String? = nil
}

public struct CopyUndoItem: Codable, Sendable {
    public let target: URL
    public let targetIdentity: String
    public let targetSnapshot: [String: String]
}

public struct CopyUndoRecord: Codable, Sendable {
    public let operationId: UUID
    public let items: [CopyUndoItem]
    public let createdAt: Date
}

public struct CopyUndoItemResult: Sendable {
    public let target: URL
    public let state: String
    public let message: String?
}

public struct CopyUndoResult: Sendable {
    public let operationId: UUID
    public let state: String
    public let items: [CopyUndoItemResult]
    public let journalError: String?
}

private struct CopyFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

enum CopyPublicationError: Error { case conflict }

private final class CopyDelegate: NSObject, FileManagerDelegate, @unchecked Sendable {
    let cancellation: CopyCancellation
    init(_ cancellation: CopyCancellation) { self.cancellation = cancellation }
    func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
        !cancellation.isCancelled
    }
}

public enum CopyConflictPolicy: Sendable { case skip, keepBoth }

public enum CopyEngine {
    public static func run(sources: [URL], destination: URL, journalDirectory: URL,
                           cancellation: CopyCancellation, conflictPolicy: CopyConflictPolicy = .skip,
                           recordUndo: Bool = true,
                           progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }) async -> CopyReport {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                execute(sources: sources, destination: destination, journalDirectory: journalDirectory,
                        cancellation: cancellation, conflictPolicy: conflictPolicy,
                        recordUndo: recordUndo, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    /// Creates a named copy of a user-selected regular template without replacing an entry.
    public static func instantiateTemplate(_ template: URL, in destination: URL, name: String,
                                           journalDirectory: URL) async throws -> CopyReport {
        try EntryOperations.validateName(name)
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard template.isFileURL, destination.isFileURL,
              let targetFolder = ShelfEntry(target), let templateEntry = ShelfEntry(template) else {
            throw EntryOperationError.sourceChanged
        }
        return try await Task.detached(priority: .userInitiated) {
            guard templateEntry.isCurrent,
                  try FileManager.default.attributesOfItem(atPath: template.path)[.type] as? FileAttributeType == .typeRegular else {
                throw EntryOperationError.sourceChanged
            }
            return execute(sources: [template], destination: target, journalDirectory: journalDirectory,
                           cancellation: CopyCancellation(), conflictPolicy: .skip, recordUndo: true,
                           explicitName: name, expectedDestination: targetFolder, expectedTemplate: templateEntry, progress: { _ in })
        }.value
    }

    private static func execute(sources: [URL], destination: URL, journalDirectory: URL,
                                cancellation: CopyCancellation, conflictPolicy: CopyConflictPolicy,
                                recordUndo: Bool, explicitName: String? = nil, expectedDestination: ShelfEntry? = nil,
                                expectedTemplate: ShelfEntry? = nil,
                                progress: @Sendable (CopyProgress) -> Void) -> CopyReport {
        let fm = FileManager()
        let delegate = CopyDelegate(cancellation)
        fm.delegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        var report = CopyReport(version: 1, id: UUID(), state: "running", items: sources.map {
            CopyRecord(source: $0, target: destination.appendingPathComponent(explicitName ?? $0.lastPathComponent))
        })
        let journal = journalDirectory.appendingPathComponent(report.id.uuidString + ".json")
        func save() throws {
            try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: journal, options: .atomic)
        }
        do { try save() } catch {
            report.state = "failed"; report.journalError = error.localizedDescription
            return report
        }
        let destinationFD = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if destinationFD >= 0 { close(destinationFD) } }
        for index in report.items.indices {
            if cancellation.isCancelled { report.items[index].state = "cancelled"; continue }
            let source = sources[index].standardizedFileURL
            var stage: URL?
            var stageFD: Int32 = -1
            func emit(_ phase: String) {
                progress(CopyProgress(index: index, total: sources.count, name: source.lastPathComponent, phase: phase))
            }
            do {
                guard destinationFD >= 0, matches(destination, descriptor: destinationFD),
                      expectedDestination?.isCurrent != false else {
                    throw CopyFailure(text: "Destination is unavailable or has changed.")
                }
                report.items[index].state = "planning"; try save(); emit("planning")
                let attrs = try fm.attributesOfItem(atPath: source.path)
                let requestedName = explicitName ?? source.lastPathComponent
                if let expectedTemplate,
                   !expectedTemplate.isCurrent || attrs[.type] as? FileAttributeType != .typeRegular {
                    throw EntryOperationError.sourceChanged
                }
                if attrs[.type] as? FileAttributeType == .typeDirectory {
                    let root = source.resolvingSymlinksInPath().standardizedFileURL.path
                    let path = destination.path
                    guard path != root, !path.hasPrefix(root == "/" ? "/" : root + "/") else {
                        throw CopyFailure(text: "Cannot copy a folder into itself or a descendant.")
                    }
                }
                var existing = stat()
                let exists = fstatat(destinationFD, requestedName, &existing, AT_SYMLINK_NOFOLLOW) == 0
                let lookupError = errno
                if exists && conflictPolicy == .skip {
                    report.items[index].state = "conflict"
                    report.items[index].message = "An item with this name already exists; skipped."
                } else {
                    guard exists || lookupError == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: lookupError) ?? .EIO) }
                    let before = try snapshot(source, cancellation: cancellation)
                    let contentBefore = try contentSnapshot(source, cancellation: cancellation)
                    let temporary = destination.appendingPathComponent(".files-copy-" + report.id.uuidString + "-\(index)")
                    report.items[index].temporary = temporary
                    report.items[index].state = "copying"; try save()
                    guard mkdirat(destinationFD, temporary.lastPathComponent, 0o700) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    stage = temporary
                    stageFD = openat(destinationFD, temporary.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard stageFD >= 0, matches(destination, descriptor: destinationFD), matches(temporary, descriptor: stageFD) else {
                        throw CopyFailure(text: "Temporary directory identity changed.")
                    }
                    emit("copying"); try cancellation.check()
                    let payload = temporary.appendingPathComponent("payload")
                    if let expectedTemplate, !expectedTemplate.isCurrent {
                        throw EntryOperationError.sourceChanged
                    }
                    try fm.copyItem(at: source, to: payload)
                    if let expectedTemplate, !expectedTemplate.isCurrent {
                        throw EntryOperationError.sourceChanged
                    }
                    try cancellation.check()
                    emit("verifying")
                    guard try contentSnapshot(payload, cancellation: cancellation) == contentBefore,
                          try snapshot(source, cancellation: cancellation) == before else {
                        throw CopyFailure(text: "Source changed or copied contents did not match.")
                    }
                    emit("committing"); try cancellation.check()
                    guard matches(destination, descriptor: destinationFD), matches(temporary, descriptor: stageFD),
                          expectedDestination?.isCurrent != false else {
                        throw CopyFailure(text: "Destination identity changed before commit.")
                    }
                    // Atomic, descriptor-relative publication: never replace even a racing/broken symlink.
                    var suffix = 0
                    while true {
                        try cancellation.check()
                        let name = explicitName ?? copyName(source, isDirectory: attrs[.type] as? FileAttributeType == .typeDirectory, suffix: suffix)
                        report.items[index].target = destination.appendingPathComponent(name)
                        try save() // Persist the actual proposed name before publishing it.
                        do {
                            try publishNoReplace(payload: payload,
                                                 target: report.items[index].target,
                                                 sourceDirectoryFD: stageFD, sourceName: "payload",
                                                 destinationDirectoryFD: destinationFD, destinationName: name)
                            report.items[index].state = "completed"
                            report.items[index].targetIdentity = try entryIdentity(report.items[index].target)
                            report.items[index].targetSnapshot = try snapshot(report.items[index].target,
                                                                              cancellation: cancellation)
                            break
                        } catch CopyPublicationError.conflict {}
                        if conflictPolicy == .skip {
                            report.items[index].state = "conflict"
                            report.items[index].message = "Destination appeared during copying; skipped."
                            break
                        }
                        suffix += 1
                        guard suffix <= 10_000 else { throw CopyFailure(text: "Too many conflicting names.") }
                    }
                }
            } catch {
                report.items[index].state = cancellation.isCancelled ? "cancelled" : "failed"
                report.items[index].message = error.localizedDescription
            }
            // Remove only our still-identical staging directory. Completed results are never rolled back.
            if let stage {
                if matches(stage, descriptor: stageFD) {
                    do { try fm.removeItem(at: stage); report.items[index].temporary = nil }
                    catch { report.items[index].message = "Temporary cleanup failed: " + error.localizedDescription }
                } else {
                    report.items[index].message = "Temporary location changed; automatic cleanup skipped."
                }
            }
            if stageFD >= 0 { close(stageFD) }
            do { try save() } catch {
                report.journalError = error.localizedDescription
                break // Keep truthful completed states if persistence fails after publication.
            }
        }
        let completed = report.items.filter { $0.state == "completed" }.count
        report.state = cancellation.isCancelled ? "cancelled" :
            (completed == sources.count && report.journalError == nil ? "completed" : (completed > 0 ? "partiallyCompleted" : "failed"))
        do { try save() } catch { report.journalError = error.localizedDescription }
        let undoItems = report.items.compactMap { item -> CopyUndoItem? in
            guard item.state == "completed", let identity = item.targetIdentity,
                  let snapshot = item.targetSnapshot else { return nil }
            return CopyUndoItem(target: item.target, targetIdentity: identity, targetSnapshot: snapshot)
        }
        if recordUndo && !undoItems.isEmpty {
            do {
                let record = CopyUndoRecord(operationId: report.id, items: undoItems, createdAt: Date())
                let data = try JSONEncoder().encode(record)
                try data.write(to: journalDirectory.appendingPathComponent("undo-copy-\(report.id.uuidString).json"), options: .atomic)
            } catch {
                report.journalError = [report.journalError, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")
                try? save()
            }
        }
        return report
    }

    public static func latestUndoCopy(journalDirectory: URL) -> CopyUndoRecord? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: journalDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return files.filter { $0.lastPathComponent.hasPrefix("undo-copy-") && $0.pathExtension == "json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .lazy.compactMap { try? JSONDecoder().decode(CopyUndoRecord.self, from: Data(contentsOf: $0)) }.first
    }

    public static func undoCopy(_ record: CopyUndoRecord, journalDirectory: URL) async -> CopyUndoResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var results: [CopyUndoItemResult] = []
            for item in record.items.reversed() {
                do {
                    guard entryExists(item.target) else {
                        results.append(CopyUndoItemResult(target: item.target, state: "missing", message: "Copied item no longer exists.")); continue
                    }
                    guard try entryIdentity(item.target) == item.targetIdentity,
                          try verifiedSnapshot(item.target) == item.targetSnapshot else {
                        results.append(CopyUndoItemResult(target: item.target, state: "changed", message: "Copied item changed after the copy; preserved.")); continue
                    }
                    try fm.removeItem(at: item.target)
                    results.append(CopyUndoItemResult(target: item.target, state: "completed", message: nil))
                } catch {
                    results.append(CopyUndoItemResult(target: item.target, state: "failed", message: error.localizedDescription))
                }
            }
            var journalError: String?
            do {
                let source = journalDirectory.appendingPathComponent("undo-copy-\(record.operationId.uuidString).json")
                if entryExists(source) { try fm.removeItem(at: source) }
                let payload = try JSONEncoder().encode(results.map { ["target": $0.target.path, "state": $0.state, "message": $0.message ?? ""] })
                try payload.write(to: journalDirectory.appendingPathComponent("undo-copy-result-\(record.operationId.uuidString).json"), options: .atomic)
            } catch { journalError = error.localizedDescription }
            let completed = results.filter { $0.state == "completed" }.count
            return CopyUndoResult(operationId: record.operationId,
                                  state: completed == results.count ? "completed" : (completed > 0 ? "partiallyCompleted" : "failed"),
                                  items: results, journalError: journalError)
        }.value
    }

    private static func copyName(_ source: URL, isDirectory: Bool, suffix: Int) -> String {
        guard suffix > 0 else { return source.lastPathComponent }
        let ext = isDirectory ? "" : source.pathExtension
        let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        return stem + " (\(suffix + 1))" + (ext.isEmpty ? "" : "." + ext)
    }

    /// APFS supports descriptor-relative no-replace rename. Some removable file systems return
    /// ENOTSUP; FileManager's move contract is used there after an explicit no-follow absence check.
    /// Any destination observed before or after a failed fallback is reported as a conflict.
    static func publishNoReplace(payload: URL, target: URL,
                                 sourceDirectoryFD: Int32, sourceName: String,
                                 destinationDirectoryFD: Int32, destinationName: String) throws {
        if renameatx_np(sourceDirectoryFD, sourceName, destinationDirectoryFD,
                        destinationName, UInt32(RENAME_EXCL)) == 0 { return }
        let publicationError = errno
        if publicationError == EEXIST { throw CopyPublicationError.conflict }
        guard publicationError == ENOTSUP || publicationError == EINVAL else {
            throw POSIXError(POSIXErrorCode(rawValue: publicationError) ?? .EIO)
        }
        var existing = stat()
        if fstatat(destinationDirectoryFD, destinationName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw CopyPublicationError.conflict
        }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try FileManager.default.moveItem(at: payload, to: target) }
        catch {
            if lstat(target.path, &existing) == 0 { throw CopyPublicationError.conflict }
            throw error
        }
    }

    private static func matches(_ url: URL, descriptor: Int32) -> Bool {
        var pathInfo = stat(); var descriptorInfo = stat()
        return descriptor >= 0 && lstat(url.path, &pathInfo) == 0 && fstat(descriptor, &descriptorInfo) == 0 &&
            pathInfo.st_dev == descriptorInfo.st_dev && pathInfo.st_ino == descriptorInfo.st_ino
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat(); return lstat(url.path, &info) == 0
    }

    private static func entryIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)"
    }

    /// No traversal through symlinks; reject special files before FileManager can block on them.
    static func verifiedSnapshot(_ root: URL, cancellation: CopyCancellation = CopyCancellation()) throws -> [String: String] {
        try snapshot(root, cancellation: cancellation)
    }

    static func verifiedContentSnapshot(_ root: URL, cancellation: CopyCancellation = CopyCancellation()) throws -> [String: String] {
        try contentSnapshot(root, cancellation: cancellation)
    }

    private static func snapshot(_ root: URL, cancellation: CopyCancellation) throws -> [String: String] {
        try makeSnapshot(root, cancellation: cancellation, includePermissions: true)
    }

    private static func contentSnapshot(_ root: URL, cancellation: CopyCancellation) throws -> [String: String] {
        try makeSnapshot(root, cancellation: cancellation, includePermissions: false)
    }

    private static func makeSnapshot(_ root: URL, cancellation: CopyCancellation,
                                     includePermissions: Bool) throws -> [String: String] {
        let fm = FileManager()
        var result: [String: String] = [:]
        func visit(_ url: URL, relative: String) throws {
            try cancellation.check()
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            switch type {
            case .typeSymbolicLink:
                result[relative] = "link:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory:
                result[relative] = includePermissions ? "directory:\(attrs[.posixPermissions] ?? 0)" : "directory"
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            case .typeRegular:
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try cancellation.check(); hash.update(data: data)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                result[relative] = includePermissions ? "file:\(attrs[.posixPermissions] ?? 0):" + digest : "file:" + digest
            default: throw CopyFailure(text: "Unsupported special file: " + url.path)
            }
        }
        try visit(root, relative: "")
        return result
    }
}
