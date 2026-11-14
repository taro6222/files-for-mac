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
    public let stagedTransfer: StagedFileTransfer?
}

/// Logical bytes staged by one completed copy call and its elapsed time.
public struct StagedFileTransfer: Sendable {
    public let bytes: Int64
    public let seconds: Double

    init?(attributes: [FileAttributeKey: Any], elapsed: Duration) {
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else { return nil }
        bytes = size.int64Value
        let time = elapsed.components
        seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
    }
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
                           expectedDestination: ShelfEntry? = nil,
                           progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }) async -> CopyReport {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                execute(sources: sources, destination: destination, journalDirectory: journalDirectory,
                        cancellation: cancellation, conflictPolicy: conflictPolicy,
                        recordUndo: recordUndo, expectedDestination: expectedDestination, progress: progress)
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
            func emit(_ phase: String, stagedTransfer: StagedFileTransfer? = nil) {
                progress(CopyProgress(index: index, total: sources.count, name: source.lastPathComponent,
                                      phase: phase, stagedTransfer: stagedTransfer))
            }
            do {
                guard destinationFD >= 0, matches(destination, descriptor: destinationFD),
                      expectedDestination.map({ $0.url.path == destination.path && $0.isCurrent }) != false else {
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
                    let before = try makeSnapshot(source, cancellation: cancellation)
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
                    let copyStarted = ContinuousClock.now
                    try fm.copyItem(at: source, to: payload)
                    let copyElapsed = copyStarted.duration(to: .now)
                    if let expectedTemplate, !expectedTemplate.isCurrent {
                        throw EntryOperationError.sourceChanged
                    }
                    try cancellation.check()
                    let stagedTransfer = (try? fm.attributesOfItem(atPath: payload.path)).flatMap {
                        StagedFileTransfer(attributes: $0, elapsed: copyElapsed)
                    }
                    emit("verifying", stagedTransfer: stagedTransfer)
                    let verifiedPayload = try makeSnapshot(payload, cancellation: cancellation)
                    guard verifiedPayload.matchesTransferredContents(of: before),
                          try makeSnapshot(source, cancellation: cancellation).matchesOriginal(before) else {
                        throw CopyFailure(text: "Source changed or copied contents did not match.")
                    }
                    // Capture the item we verified before publication. A cancellation or an
                    // external change after publication must not redefine the undo record.
                    let undoIdentity = try entryIdentity(payload)
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
                            report.items[index].targetIdentity = undoIdentity
                            report.items[index].targetSnapshot = verifiedPayload.withPermissions
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
                                 destinationDirectoryFD: Int32, destinationName: String,
                                 allowPathFallback: Bool = true) throws {
        if renameatx_np(sourceDirectoryFD, sourceName, destinationDirectoryFD,
                        destinationName, UInt32(RENAME_EXCL)) == 0 { return }
        let publicationError = errno
        if publicationError == EEXIST { throw CopyPublicationError.conflict }
        guard allowPathFallback, publicationError == ENOTSUP || publicationError == EINVAL else {
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

    private static func snapshot(_ root: URL, cancellation: CopyCancellation) throws -> [String: String] {
        try makeSnapshot(root, cancellation: cancellation, includeTransferMetadata: false).withPermissions
    }

    struct VerificationSnapshot {
        var withPermissions: [String: String] = [:]
        var content: [String: String] = [:]
        var extendedAttributes: [String: [Data: SHA256.Digest]] = [:]
        var accessControlLists: [String: Data] = [:]
        var modificationDates: [String: Date] = [:]
        var modificationTimeResolution: TimeInterval = 0
        var hasNativePermissions = true

        func matchesTransferredContents(of source: Self) -> Bool {
            let resolution = max(modificationTimeResolution, source.modificationTimeResolution)
            guard content == source.content, extendedAttributes == source.extendedAttributes,
                  accessControlLists == source.accessControlLists,
                  !hasNativePermissions || !source.hasNativePermissions || withPermissions == source.withPermissions,
                  modificationDates.count == source.modificationDates.count else { return false }
            return modificationDates.allSatisfy { path, date in
                guard let sourceDate = source.modificationDates[path] else { return false }
                return date == sourceDate || abs(date.timeIntervalSince(sourceDate)) < resolution
            }
        }

        func matchesOriginal(_ original: Self) -> Bool {
            withPermissions == original.withPermissions && modificationDates == original.modificationDates
                && matchesTransferredContents(of: original)
        }

        var legacyPermissionsSnapshot: [String: String] {
            withPermissions.mapValues { value in
                guard value.hasPrefix("file:"), let suffix = value.range(of: ":resource:") else { return value }
                return String(value[..<suffix.lowerBound])
            }
        }
    }

    static func makeSnapshot(_ root: URL, cancellation: CopyCancellation,
                             includeTransferMetadata: Bool = true) throws -> VerificationSnapshot {
        let fm = FileManager()
        var snapshot = VerificationSnapshot()
        func visit(_ url: URL, relative: String) throws {
            try cancellation.check()
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            if includeTransferMetadata, relative.isEmpty, type != .typeSymbolicLink {
                var volume = statfs()
                guard statfs(url.path, &volume) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let filesystem = withUnsafeBytes(of: volume.f_fstypename) {
                    String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                // FAT exposes synthesized modes. Still check the original and
                // the published copy against their own subsequent snapshots.
                snapshot.hasNativePermissions = filesystem != "exfat" && filesystem != "msdos"
                switch filesystem {
                case "exfat": snapshot.modificationTimeResolution = 0.01
                case "msdos": snapshot.modificationTimeResolution = 2
                case "hfs": snapshot.modificationTimeResolution = 1
                default: break
                }
            }
            switch type {
            case .typeSymbolicLink:
                let link = "link:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
                snapshot.withPermissions[relative] = link
                snapshot.content[relative] = link
            case .typeDirectory:
                snapshot.withPermissions[relative] = "directory:\(attrs[.posixPermissions] ?? 0)"
                snapshot.content[relative] = "directory"
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
                var digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                if let resource = try resourceForkDigest(url, cancellation: cancellation) {
                    digest += ":resource:" + resource
                }
                snapshot.withPermissions[relative] = "file:\(attrs[.posixPermissions] ?? 0):" + digest
                snapshot.content[relative] = "file:" + digest
            default: throw CopyFailure(text: "Unsupported special file: " + url.path)
            }
            if includeTransferMetadata {
                let attributes = try attributeDigests(url, cancellation: cancellation)
                if !attributes.isEmpty { snapshot.extendedAttributes[relative] = attributes }
                snapshot.accessControlLists[relative] = try accessControlList(url)
                if type != .typeSymbolicLink {
                    snapshot.modificationDates[relative] = attrs[.modificationDate] as? Date
                }
            }
        }
        try visit(root, relative: "")
        return snapshot
    }

    private static func accessControlList(_ url: URL) throws -> Data? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(text) }
        return length > 0 ? Data(bytes: text, count: length) : nil
    }

    private static func attributeDigests(_ url: URL, cancellation: CopyCancellation) throws -> [Data: SHA256.Digest] {
        let invalidAttributes = CopyFailure(text: "Extended attributes could not be verified: " + url.path)
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if size == 0 || (size == -1 && errno == ENOTSUP) { return [:] }
        guard size > 0 else { throw invalidAttributes }
        var names = Data(count: size)
        let listSize = names.withUnsafeMutableBytes {
            listxattr(url.path, $0.baseAddress?.assumingMemoryBound(to: CChar.self), size, XATTR_NOFOLLOW)
        }
        guard listSize == size, names.last == 0 else { throw invalidAttributes }
        var digests: [Data: SHA256.Digest] = [:]
        for nameBytes in names.split(separator: 0) {
            try cancellation.check()
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw invalidAttributes }
            // The resource fork is already verified in bounded chunks.
            if name == "com.apple.ResourceFork" { continue }
            let valueSize = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else { throw invalidAttributes }
            var value = Data(count: valueSize)
            let read = value.withUnsafeMutableBytes {
                getxattr(url.path, name, $0.baseAddress, valueSize, 0, XATTR_NOFOLLOW)
            }
            guard read == valueSize else { throw invalidAttributes }
            digests[Data(nameBytes)] = SHA256.hash(data: value)
        }
        return digests
    }

    private static func resourceForkDigest(_ url: URL, cancellation: CopyCancellation) throws -> String? {
        let key = "com.apple.ResourceFork"
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if size == -1 && (errno == ENOATTR || errno == ENOTSUP) { return nil }
        guard size >= 0, UInt32(exactly: size) != nil else {
            throw CopyFailure(text: "Unable to verify the resource fork: " + url.path)
        }
        var hash = SHA256()
        var offset = 0
        var buffer = Data(count: min(size, 1024 * 1024))
        while offset < size {
            try cancellation.check()
            let requested = min(buffer.count, size - offset)
            let count = buffer.withUnsafeMutableBytes {
                getxattr(url.path, key, $0.baseAddress, requested, UInt32(offset), XATTR_NOFOLLOW)
            }
            guard count == requested else {
                throw CopyFailure(text: "Resource fork changed during verification: " + url.path)
            }
            hash.update(data: buffer.prefix(count))
            offset += count
        }
        guard getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW) == size else {
            throw CopyFailure(text: "Resource fork changed during verification: " + url.path)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
