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
    public var liveTransfer: LiveTransferProgress? = nil
    public var selectionTransfer: SelectionTransferProgress? = nil
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
    var targetMetadata: CopyTransferMetadata? = nil
}

/// Versioned, inspectable foundation journal. This is not yet an undo/recovery database.
public struct CopyReport: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public var state: String
    public var items: [CopyRecord]
    public var journalError: String? = nil
    public var selectionTransfer: SelectionTransferProgress? = nil
}

public struct CopyUndoItem: Codable, Sendable {
    public let target: URL
    public let targetIdentity: String
    public let targetSnapshot: [String: String]
    var targetMetadata: CopyTransferMetadata? = nil
    var descendantIdentities: [String: String]? = nil
}

struct CopyTransferMetadata: Codable, Equatable, Sendable {
    var extendedAttributes: [String: [Data: Data]] = [:]
    var accessControlLists: [String: Data] = [:]
    var modificationDates: [String: Date] = [:]
    // Earlier journals have no creation-time baseline.
    var creationDates: [String: Date]? = nil
    struct Ownership: Codable, Equatable, Sendable { let user: UInt32; let group: UInt32 }
    var owners: [String: Ownership]? = nil

    func matchesRecorded(_ recorded: Self) -> Bool {
        extendedAttributes == recorded.extendedAttributes && accessControlLists == recorded.accessControlLists
            && modificationDates == recorded.modificationDates
            && (recorded.creationDates?.allSatisfy { creationDates?[$0.key] == $0.value } ?? true)
            && (recorded.owners?.allSatisfy { owners?[$0.key] == $0.value } ?? true)
    }
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

public enum CopyConflictPolicy: Sendable { case skip, keepBoth }

public enum CopyEngine {
    public static func run(sources: [URL], destination: URL, journalDirectory: URL,
                           cancellation: CopyCancellation, conflictPolicy: CopyConflictPolicy = .skip,
                           recordUndo: Bool = true,
                           expectedDestination: ShelfEntry? = nil,
                           sourceIntakes: [PromisedFileIntake] = [],
                           progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }) async -> CopyReport {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                execute(sources: sources, destination: destination, journalDirectory: journalDirectory,
                        cancellation: cancellation, conflictPolicy: conflictPolicy,
                        recordUndo: recordUndo, expectedDestination: expectedDestination, sourceIntakes: sourceIntakes, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    static func runPrepared(source: URL, snapshot: VerificationSnapshot, destination: URL,
                            journalDirectory: URL, cancellation: CopyCancellation,
                            expectedDestination: ShelfEntry?, sourceIntakes: [PromisedFileIntake],
                            progress: @escaping @Sendable (CopyProgress) -> Void) async -> CopyReport {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                execute(sources: [source], destination: destination, journalDirectory: journalDirectory,
                    cancellation: cancellation, conflictPolicy: .skip, recordUndo: false,
                    expectedDestination: expectedDestination, sourceIntakes: sourceIntakes, progress: progress, preparedOriginals: [.success(snapshot)])
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

    /// Fulfill an external file promise at its exact, receiver-selected URL without replacing an entry.
    /// Call on the promise provider's operation queue, never on the main actor.
    public static func exportPromisedItem(_ item: FileItem, to target: URL,
                                          journalDirectory: URL) throws -> CopyReport {
        guard let identity = item.identity, LocalEntryIdentity.read(item.url) == identity,
              let entry = ShelfEntry(item.url), LocalEntryIdentity.read(item.url) == identity else {
            throw EntryOperationError.sourceChanged
        }
        return try exportPromisedItem(entry, to: target, journalDirectory: journalDirectory)
    }

    public static func exportPromisedItem(_ source: ShelfEntry, to target: URL,
                                          journalDirectory: URL) throws -> CopyReport {
        guard target.isFileURL, source.isCurrent else { throw EntryOperationError.sourceChanged }
        try EntryOperations.validateName(target.lastPathComponent)
        let destination = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard let expectedDestination = ShelfEntry(destination) else { throw EntryOperationError.sourceChanged }
        return execute(sources: [source.url], destination: destination, journalDirectory: journalDirectory,
                       cancellation: CopyCancellation(), conflictPolicy: .skip, recordUndo: false,
                       explicitName: target.lastPathComponent, expectedDestination: expectedDestination,
                       expectedSource: source, progress: { _ in })
    }

    private static func execute(sources: [URL], destination: URL, journalDirectory: URL,
                                cancellation: CopyCancellation, conflictPolicy: CopyConflictPolicy,
                                recordUndo: Bool, explicitName: String? = nil, expectedDestination: ShelfEntry? = nil,
                                expectedTemplate: ShelfEntry? = nil, expectedSource: ShelfEntry? = nil,
                                sourceIntakes: [PromisedFileIntake] = [],
                                progress: @escaping @Sendable (CopyProgress) -> Void,
                                preparedOriginals: [Result<VerificationSnapshot, any Error>?]? = nil) -> CopyReport {
        let fm = FileManager()
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
        // Reuse the required original snapshots; no second recursive size scan or duplicate hashing.
        // Each consumed snapshot is released as its root starts, bounding retention alongside the journal.
        var prepared = preparedOriginals ?? [Result<VerificationSnapshot, any Error>?](repeating: nil, count: sources.count)
        var plans: [Int64?] = prepared.map { value in
            if case .success(let snapshot) = value { return snapshot.logicalDataBytes }
            return nil
        }
        if destinationFD >= 0, matches(destination, descriptor: destinationFD),
           expectedDestination.map({ $0.url.path == destination.path && $0.isCurrent }) != false {
            for index in sources.indices {
                if cancellation.isCancelled { break }
                let source = sources[index].standardizedFileURL
                progress(CopyProgress(index: 0, total: sources.count, name: source.lastPathComponent,
                                      phase: "sizing", stagedTransfer: nil))
                let name = explicitName ?? source.lastPathComponent
                var existing = stat()
                if conflictPolicy == .skip && fstatat(destinationFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                    plans[index] = 0
                    continue
                }
                if prepared[index] != nil { continue }
                let result = Result { () throws -> VerificationSnapshot in
                    try cancellation.check()
                    let attrs = try fm.attributesOfItem(atPath: source.path)
                    if let expectedSource, expectedSource.url != source || !expectedSource.isCurrent {
                        throw EntryOperationError.sourceChanged
                    }
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
                    return try makeSnapshot(source, cancellation: cancellation)
                }
                prepared[index] = result
                if case .success(let snapshot) = result { plans[index] = snapshot.logicalDataBytes }
            }
        }
        let selection = SelectionTransferTracker(plans: plans)
        for index in report.items.indices {
            let preparedSource = prepared[index]
            prepared[index] = nil
            if cancellation.isCancelled { report.items[index].state = "cancelled"; continue }
            let source = sources[index].standardizedFileURL
            var stage: URL?
            var stageFD: Int32 = -1
            func emit(_ phase: String, stagedTransfer: StagedFileTransfer? = nil) {
                progress(CopyProgress(index: index, total: sources.count, name: source.lastPathComponent,
                                      phase: phase, stagedTransfer: stagedTransfer, selectionTransfer: selection.snapshot()))
            }
            do {
                guard destinationFD >= 0, matches(destination, descriptor: destinationFD),
                      expectedDestination.map({ $0.url.path == destination.path && $0.isCurrent }) != false else {
                    throw CopyFailure(text: "Destination is unavailable or has changed.")
                }
                report.items[index].state = "planning"; try save(); emit("planning")
                let attrs = try fm.attributesOfItem(atPath: source.path)
                let requestedName = explicitName ?? source.lastPathComponent
                if let expectedSource, expectedSource.url != source || !expectedSource.isCurrent {
                    throw EntryOperationError.sourceChanged
                }
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
                    selection.excludeUnstaged(index); emit("planning")
                } else {
                    guard exists || lookupError == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: lookupError) ?? .EIO) }
                    let before: VerificationSnapshot
                    if let preparedSource { before = try preparedSource.get() }
                    else { before = try makeSnapshot(source, cancellation: cancellation) }
                    try PromisedFileIntake.validate(source, snapshot: before, in: sourceIntakes)
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
                    if expectedTemplate?.isCurrent == false || expectedSource?.isCurrent == false {
                        throw EntryOperationError.sourceChanged
                    }
                    let copyStarted = ContinuousClock.now
                    try NativeFileCopy.run(from: source, to: payload, totalBytes: before.logicalDataBytes,
                                           cancellation: cancellation) { update in
                        progress(CopyProgress(index: index, total: sources.count, name: source.lastPathComponent,
                                              phase: "copying", stagedTransfer: nil, liveTransfer: update,
                                              selectionTransfer: selection.record(index, live: update)))
                    }
                    try before.restoreCreationTimes(in: payload, cancellation: cancellation)
                    try before.restoreDirectoryModificationTimes(in: payload, cancellation: cancellation)
                    let copyElapsed = copyStarted.duration(to: .now)
                    if expectedTemplate?.isCurrent == false || expectedSource?.isCurrent == false {
                        throw EntryOperationError.sourceChanged
                    }
                    try cancellation.check()
                    let stagedTransfer = (try? fm.attributesOfItem(atPath: payload.path)).flatMap {
                        StagedFileTransfer(attributes: $0, elapsed: copyElapsed)
                    }
                    emit("verifying", stagedTransfer: stagedTransfer)
                    let verifiedPayload = try makeSnapshot(payload, cancellation: cancellation)
                    let currentSource = try makeSnapshot(source, cancellation: cancellation)
                    try PromisedFileIntake.validate(source, snapshot: currentSource, in: sourceIntakes)
                    guard currentSource.matchesOriginal(before) else {
                        throw CopyFailure(text: "Source changed during copying.")
                    }
                    try verifiedPayload.verifyTransferredContents(of: before)
                    try before.restoreAccessTimes(in: payload, verifiedCopy: verifiedPayload, cancellation: cancellation)
                    // Capture the item we verified before publication. A cancellation or an
                    // external change after publication must not redefine the undo record.
                    let undoIdentity = try entryIdentity(payload)
                    let publicationHandle = try openPublicationHandle(payload, on: stageFD)
                    defer { if let publicationHandle { close(publicationHandle) } }
                    emit("committing"); try cancellation.check()
                    if expectedSource?.isCurrent == false { throw EntryOperationError.sourceChanged }
                    guard matches(destination, descriptor: destinationFD), matches(temporary, descriptor: stageFD),
                          expectedDestination?.isCurrent != false else {
                        throw CopyFailure(text: "Destination identity changed before commit.")
                    }
                    if let publicationHandle {
                        guard try entryIdentity(payload) == undoIdentity, matchesPublicationHandle(payload, descriptor: publicationHandle) else {
                            throw CopyFailure(text: "Staged item identity changed before publication.")
                        }
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
                            let target = report.items[index].target
                            report.items[index].targetIdentity = try identityAfterPublication(of: target,
                                handle: publicationHandle, original: undoIdentity, identity: entryIdentity)
                            report.items[index].state = "completed"
                            report.items[index].targetSnapshot = verifiedPayload.withPermissions
                            report.items[index].targetMetadata = verifiedPayload.metadata
                            if let intake = sourceIntakes.first(where: { source.deletingLastPathComponent().standardizedFileURL == $0.receivingDirectory }) {
                                do {
                                    try intake.recordVerifiedCopy(source: source, sourceSnapshot: currentSource,
                                        record: report.items[index], operationID: report.id)
                                } catch {
                                    report.items[index].message = "Copied file was preserved, but the receive cleanup receipt could not be saved: " + error.localizedDescription
                                }
                            }
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
        report.selectionTransfer = selection.snapshot()
        let completed = report.items.filter { $0.state == "completed" }.count
        report.state = cancellation.isCancelled ? "cancelled" :
            (completed == sources.count && report.journalError == nil ? "completed" : (completed > 0 ? "partiallyCompleted" : "failed"))
        do { try save() } catch { report.journalError = error.localizedDescription }
        let undoItems = report.items.compactMap { item -> CopyUndoItem? in
            guard item.state == "completed", let identity = item.targetIdentity,
                  let snapshot = item.targetSnapshot else { return nil }
            return CopyUndoItem(target: item.target, targetIdentity: identity, targetSnapshot: snapshot,
                                targetMetadata: item.targetMetadata)
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
                    guard try matchesUndoTarget(item) else {
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

    static let consolidatedUndoPrefix = "tree-v1|"
    static func matchesUndoTarget(_ item: CopyUndoItem) throws -> Bool {
        let consolidated = item.targetIdentity.hasPrefix(consolidatedUndoPrefix)
        let identity = consolidated ? String(item.targetIdentity.dropFirst(consolidatedUndoPrefix.count)) : item.targetIdentity
        if consolidated && (item.descendantIdentities?.isEmpty != false) { return false }
        func boundariesMatch() throws -> Bool {
            for (path,expected) in item.descendantIdentities ?? [:] {
                let parts = path.split(separator: "/", omittingEmptySubsequences: true)
                guard !parts.isEmpty, "/" + parts.joined(separator: "/") == path,
                      !parts.contains("."), !parts.contains(".."), !path.utf8.contains(0),
                      try matchesRecordedIdentity(at: item.target.appendingPathComponent(String(path.dropFirst())),
                                                  expected: expected, identity: entryIdentity) else { return false }
            }
            return true
        }
        guard try matchesRecordedIdentity(at: item.target, expected: identity, identity: entryIdentity),
              try boundariesMatch() else { return false }
        let snapshot = try makeSnapshot(item.target, cancellation: CopyCancellation(),
                                        includeTransferMetadata: item.targetMetadata != nil)
        guard snapshot.withPermissions == item.targetSnapshot,
              item.targetMetadata.map(snapshot.metadata.matchesRecorded) != false,
              try boundariesMatch() else { return false }
        return try matchesRecordedIdentity(at: item.target, expected: identity, identity: entryIdentity)
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

    static func matches(_ url: URL, descriptor: Int32) -> Bool {
        var pathInfo = stat(); var descriptorInfo = stat()
        return descriptor >= 0 && lstat(url.path, &pathInfo) == 0 && fstat(descriptor, &descriptorInfo) == 0 &&
            pathInfo.st_dev == descriptorInfo.st_dev && pathInfo.st_ino == descriptorInfo.st_ino
    }

    // Some SMB mounts derive st_ino from the path. Keep the original vnode open so
    // its new identifier can be checked against the published name after rename.
    static func openPublicationHandle(_ payload: URL, on directoryFD: Int32) throws -> Int32? {
        var volume = statfs()
        guard fstatfs(directoryFD, &volume) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let filesystem = withUnsafeBytes(of: volume.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard filesystem == "smbfs" else { return nil }
        let name = payload.lastPathComponent
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let noFollow = info.st_mode & S_IFMT == S_IFLNK ? O_SYMLINK : O_NOFOLLOW
        let descriptor = openat(directoryFD, name, O_RDONLY | noFollow | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard matchesPublicationHandle(payload, descriptor: descriptor) else {
            close(descriptor)
            throw CopyFailure(text: "Staged item identity changed before publication.")
        }
        return descriptor
    }

    static func identityAfterPublication(of target: URL, handle: Int32?, original: String,
                                         identity: (URL) throws -> String) throws -> String {
        guard let handle else { return original }
        return try checkedPublicationIdentity(at: target, descriptor: handle, identity: identity)
    }

    static func checkedPublicationIdentity(at target: URL, descriptor: Int32,
                                           identity: (URL) throws -> String) throws -> String {
        guard matchesPublicationHandle(target, descriptor: descriptor) else { throw CopyFailure(text: "Item identity changed during publication.") }
        let current = try identity(target)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard matchesPublicationHandle(target, descriptor: descriptor) else { throw CopyFailure(text: "Item identity changed during publication.") }
        // A path-derived identifier can repeat if a different item is created at
        // the same path. Preserve a separate change-time baseline for Undo.
        return withChangeTime(current, opened.st_ctimespec)
    }

    static func matchesRecordedIdentity(at url: URL, expected: String, identity: (URL) throws -> String) throws -> Bool {
        let current = try identity(url)
        guard expected.contains("|ctime=") else { return current == expected }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return withChangeTime(current, info.st_ctimespec) == expected
    }

    struct AccessTimeChange {
        let oldChangeTime: timespec
        let newChangeTime: timespec
    }

    static func identityAfterAccessTimeRestoration(_ expected: String, change: AccessTimeChange?) throws -> String {
        guard let suffix = expected.range(of: "|ctime="), let change else { return expected }
        let base = String(expected[..<suffix.lowerBound])
        guard expected == withChangeTime(base, change.oldChangeTime) else { throw TransferMismatch.accessTime }
        return withChangeTime(base, change.newChangeTime)
    }

    private static func withChangeTime(_ identity: String, _ changeTime: timespec) -> String {
        "\(identity)|ctime=\(changeTime.tv_sec):\(changeTime.tv_nsec)"
    }

    static func matchesPublicationHandle(_ url: URL, descriptor: Int32) -> Bool {
        var path = stat(), opened = stat()
        guard lstat(url.path, &path) == 0, fstat(descriptor, &opened) == 0 else { return false }
        return opened.st_nlink > 0 && path.st_dev == opened.st_dev && path.st_ino == opened.st_ino
            && path.st_mode == opened.st_mode && path.st_size == opened.st_size
            && path.st_birthtimespec.tv_sec == opened.st_birthtimespec.tv_sec
            && path.st_birthtimespec.tv_nsec == opened.st_birthtimespec.tv_nsec
            && path.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec
            && path.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat(); return lstat(url.path, &info) == 0
    }

    static func entryIdentity(_ url: URL) throws -> String {
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

    struct VerificationSnapshot: Sendable {
        private static let emptyResourceFork = ":resource:" + SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }.joined()
        var withPermissions: [String: String] = [:]
        var content: [String: String] = [:]
        var metadata = CopyTransferMetadata()
        var accessTimes: [String: timespec] = [:]
        var accessTimeIdentities: [String: (device: dev_t, inode: ino_t)] = [:]
        var modificationTimeResolution: TimeInterval = 0
        var filesystemType = ""
        var hasNativePermissions = true
        var logicalDataBytes: Int64? = 0

        private static func creationTimeResolution(for filesystem: String) -> TimeInterval? {
            switch filesystem {
            case "apfs": return 0.000001
            case "smbfs": return 0.0000001
            // macOS exposes whole-second creation times through stat on exFAT.
            case "exfat": return 1
            case "hfs": return 1
            case "msdos": return 2
            default: return nil
            }
        }

        fileprivate static func supportsAccessTimeRestoration(_ filesystem: String) -> Bool {
            filesystem == "apfs" || filesystem == "exfat" || filesystem == "smbfs"
        }

        private func transferMismatch(_ source: Self) -> TransferMismatch? {
            if !transferEntriesMatch(content, source.content, sourceFilesystem: source.filesystemType) { return .contents }
            if metadata.extendedAttributes != source.metadata.extendedAttributes { return .extendedAttributes }
            if metadata.accessControlLists != source.metadata.accessControlLists { return .accessControlList }
            if hasNativePermissions, source.hasNativePermissions,
               !transferEntriesMatch(withPermissions, source.withPermissions, sourceFilesystem: source.filesystemType) {
                return .permissions
            }
            let resolution = max(modificationTimeResolution, source.modificationTimeResolution)
            let usesSMB = filesystemType == "smbfs" || source.filesystemType == "smbfs"
            guard datesMatch(metadata.modificationDates, source.metadata.modificationDates,
                             resolution: resolution, usesSMB: usesSMB) else { return .modificationTime }
            if let resolution = Self.creationTimeResolution(for: filesystemType),
               let sourceResolution = Self.creationTimeResolution(for: source.filesystemType),
               !datesMatch(metadata.creationDates ?? [:], source.metadata.creationDates ?? [:],
                           resolution: max(resolution, sourceResolution), usesSMB: usesSMB) { return .creationTime }
            return nil
        }

        private func transferEntriesMatch(_ staged: [String: String], _ source: [String: String],
                                          sourceFilesystem: String) -> Bool {
            if staged == source { return true }
            guard staged.count == source.count, filesystemType == "smbfs" || sourceFilesystem == "smbfs" else { return false }
            // SMB can expose an absent resource fork as a zero-byte stream. Compare those
            // representations only for transfers; keep the recorded fingerprints for undo.
            return staged.allSatisfy { path, entry in
                guard let expected = source[path] else { return false }
                if entry == expected { return true }
                guard entry.hasPrefix("file:"), expected.hasPrefix("file:") else { return false }
                return (filesystemType == "smbfs" && entry == expected + Self.emptyResourceFork)
                    || (sourceFilesystem == "smbfs" && expected == entry + Self.emptyResourceFork)
            }
        }

        private func datesMatch(_ dates: [String: Date], _ sourceDates: [String: Date],
                                resolution: TimeInterval, usesSMB: Bool = false) -> Bool {
            dates.count == sourceDates.count && dates.allSatisfy { path, date in
                guard let sourceDate = sourceDates[path] else { return false }
                let difference = abs(date.timeIntervalSince(sourceDate))
                if difference == 0 || difference < resolution { return true }
                guard usesSMB else { return false }
                // SMB FILETIME has 100 ns ticks. Account for one rounding step
                // when the two times are represented as Foundation Dates.
                let dateStep = max(date.timeIntervalSinceReferenceDate.ulp, sourceDate.timeIntervalSinceReferenceDate.ulp)
                return difference <= 0.0000001 + dateStep
            }
        }

        func verifyTransferredContents(of source: Self) throws {
            if let mismatch = transferMismatch(source) { throw mismatch }
        }

        func matchesTransferredContents(of source: Self) -> Bool {
            transferMismatch(source) == nil
        }

        func matchesOriginal(_ original: Self) -> Bool {
            withPermissions == original.withPermissions && content == original.content && metadata == original.metadata
        }

        /// Creating children can change directory timestamps during recursive native copying.
        /// Restore only staged directories through non-following descriptors; verification still follows.
        func restoreDirectoryModificationTimes(in payload: URL, cancellation: CopyCancellation) throws {
            let directories = metadata.modificationDates.filter { content[$0.key] == "directory" }
            guard !directories.isEmpty else { return }
            let parent = open(payload.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw TransferMismatch.modificationTime }
            defer { close(parent) }
            for (path, date) in directories {
                try cancellation.check()
                let descriptor = try openTransferEntry(parent: parent, name: payload.lastPathComponent,
                    path: path, isDirectory: true, mismatch: .modificationTime)
                defer { close(descriptor) }
                let seconds = date.timeIntervalSinceReferenceDate
                let whole = floor(seconds)
                var modification = timespec(tv_sec: Int(whole) + Int(Date.timeIntervalBetween1970AndReferenceDate),
                                            tv_nsec: Int((seconds - whole) * 1_000_000_000))
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = attrgroup_t(ATTR_CMN_MODTIME)
                guard fsetattrlist(descriptor, &attributes, &modification, MemoryLayout<timespec>.size, 0) == 0 else {
                    throw TransferMismatch.modificationTime
                }
            }
        }

        func restoreCreationTimes(in payload: URL, cancellation: CopyCancellation) throws {
            guard Self.creationTimeResolution(for: filesystemType) != nil,
                  let dates = metadata.creationDates, !dates.isEmpty else { return }
            let parent = open(payload.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw TransferMismatch.creationTime }
            defer { close(parent) }
            var volume = statfs()
            guard fstatfs(parent, &volume) == 0 else { throw TransferMismatch.creationTime }
            let filesystem = withUnsafeBytes(of: volume.f_fstypename) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard Self.creationTimeResolution(for: filesystem) != nil else { return }
            for (path, date) in dates {
                try cancellation.check()
                let isDirectory = content[path] == "directory"
                let descriptor = try openTransferEntry(parent: parent, name: payload.lastPathComponent,
                    path: path, isDirectory: isDirectory, mismatch: .creationTime)
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_nlink == 1 || isDirectory,
                      info.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG) else {
                    throw TransferMismatch.creationTime
                }
                // Split off the fractional part before shifting the epoch to
                // avoid losing SMB FILETIME precision in the larger epoch value.
                let seconds = date.timeIntervalSinceReferenceDate
                let whole = floor(seconds)
                let epochSeconds = Int(whole) + Int(Date.timeIntervalBetween1970AndReferenceDate)
                var birth = timespec(tv_sec: epochSeconds, tv_nsec: Int((seconds - whole) * 1_000_000_000))
                if info.st_birthtimespec.tv_sec != birth.tv_sec || info.st_birthtimespec.tv_nsec != birth.tv_nsec {
                    var attributes = attrlist()
                    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                    attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
                    guard fsetattrlist(descriptor, &attributes, &birth, MemoryLayout<timespec>.size, 0) == 0 else {
                        throw TransferMismatch.creationTime
                    }
                }
            }
        }

        @discardableResult
        func restoreAccessTimes(in payload: URL, verifiedCopy: Self, publishedIdentity: String? = nil,
                                cancellation: CopyCancellation) throws -> AccessTimeChange? {
            guard !accessTimes.isEmpty else { return nil }
            let parent = open(payload.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw TransferMismatch.accessTime }
            defer { close(parent) }
            var volume = statfs()
            guard fstatfs(parent, &volume) == 0 else { throw TransferMismatch.accessTime }
            let filesystem = withUnsafeBytes(of: volume.f_fstypename) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard Self.supportsAccessTimeRestoration(filesystem) else { return nil }
            var rootChange: AccessTimeChange?
            for (path, time) in accessTimes {
                try cancellation.check()
                let expected: timespec
                switch filesystem {
                case "exfat":
                    // The macOS exFAT driver stores access times in even seconds.
                    expected = timespec(tv_sec: time.tv_sec & ~1, tv_nsec: 0)
                case "smbfs":
                    // SMB FILETIME stores access times in 100 ns ticks.
                    expected = timespec(tv_sec: time.tv_sec, tv_nsec: time.tv_nsec / 100 * 100)
                default:
                    expected = time
                }
                let isDirectory = content[path] == "directory"
                let descriptor = try openTransferEntry(parent: parent, name: payload.lastPathComponent,
                    path: path, isDirectory: isDirectory, mismatch: .accessTime)
                defer { close(descriptor) }
                var info = stat()
                guard let identity = verifiedCopy.accessTimeIdentities[path],
                      fstat(descriptor, &info) == 0, info.st_nlink == 1 || isDirectory,
                      info.st_dev == identity.device, info.st_ino == identity.inode,
                      info.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG) else {
                    throw TransferMismatch.accessTime
                }
                if info.st_atimespec.tv_sec != expected.tv_sec || info.st_atimespec.tv_nsec != expected.tv_nsec {
                    if path.isEmpty, let publishedIdentity, publishedIdentity.contains("|ctime="),
                       !publishedIdentity.hasSuffix(CopyEngine.withChangeTime("", info.st_ctimespec)) {
                        throw TransferMismatch.accessTime
                    }
                    var attributes = attrlist()
                    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                    attributes.commonattr = attrgroup_t(ATTR_CMN_ACCTIME)
                    var accessTime = expected
                    var updated = stat()
                    guard fsetattrlist(descriptor, &attributes, &accessTime, MemoryLayout<timespec>.size, 0) == 0,
                          fstat(descriptor, &updated) == 0,
                          updated.st_atimespec.tv_sec == expected.tv_sec, updated.st_atimespec.tv_nsec == expected.tv_nsec,
                          updated.st_dev == info.st_dev, updated.st_ino == info.st_ino,
                          updated.st_mode == info.st_mode, updated.st_size == info.st_size, updated.st_nlink == info.st_nlink,
                          updated.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                          updated.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                          updated.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec,
                          updated.st_birthtimespec.tv_nsec == info.st_birthtimespec.tv_nsec else {
                        throw TransferMismatch.accessTime
                    }
                    if path.isEmpty {
                        rootChange = AccessTimeChange(oldChangeTime: info.st_ctimespec, newChangeTime: updated.st_ctimespec)
                    }
                }
            }
            return rootChange
        }

        private func openTransferEntry(parent: Int32, name: String, path: String, isDirectory: Bool,
                                       mismatch: TransferMismatch) throws -> Int32 {
            let components = [name] + path.split(separator: "/").map(String.init)
            var current = parent
            for (index, component) in components.enumerated() {
                let directory = index < components.count - 1 || isDirectory
                let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
                let next = openat(current, component, flags)
                if current != parent { close(current) }
                guard next >= 0 else { throw mismatch }
                current = next
            }
            return current
        }

        var legacyPermissionsSnapshot: [String: String] {
            withPermissions.mapValues { value in
                guard value.hasPrefix("file:"), let suffix = value.range(of: ":resource:") else { return value }
                return String(value[..<suffix.lowerBound])
            }
        }
    }

    enum TransferMismatch: String, LocalizedError {
        case contents, extendedAttributes, accessControlList, permissions, modificationTime, creationTime, accessTime

        var errorDescription: String? {
            message(korean: Locale.preferredLanguages.first?.hasPrefix("ko") == true)
        }

        func message(korean: Bool) -> String {
            let property: (english: String, korean: String)
            switch self {
            case .contents: property = ("file contents or folder structure", "파일 내용 또는 폴더 구조")
            case .extendedAttributes: property = ("extended attributes, including tags", "태그 등 확장 속성")
            case .accessControlList: property = ("access control list (ACL)", "접근 제어 목록(ACL)")
            case .permissions: property = ("POSIX permissions", "POSIX 권한")
            case .modificationTime: property = ("modification time", "수정 시간")
            case .creationTime: property = ("creation time", "생성 시간")
            case .accessTime: property = ("access time", "접근 시간")
            }
            return korean
                ? "복사본의 \(property.korean) 검증에 실패했습니다. 원본을 보존했습니다."
                : "The copy did not preserve the \(property.english). The original was kept."
        }
    }

    static func makeSnapshot(_ root: URL, cancellation: CopyCancellation,
                             includeTransferMetadata: Bool = true) throws -> VerificationSnapshot {
        let fm = FileManager()
        var snapshot = VerificationSnapshot()
        if includeTransferMetadata { snapshot.metadata.creationDates = [:]; snapshot.metadata.owners = [:] }
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
                snapshot.filesystemType = filesystem
                // FAT exposes synthesized modes. Still check the original and
                // the published copy against their own subsequent snapshots.
                snapshot.hasNativePermissions = filesystem != "exfat" && filesystem != "msdos"
                switch filesystem {
                case "exfat":
                    snapshot.modificationTimeResolution = 0.01
                case "msdos":
                    snapshot.modificationTimeResolution = 2
                case "hfs":
                    snapshot.modificationTimeResolution = 1
                default: break
                }
            }
            if includeTransferMetadata, VerificationSnapshot.supportsAccessTimeRestoration(snapshot.filesystemType),
               type != .typeSymbolicLink {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw TransferMismatch.accessTime }
                snapshot.accessTimes[relative] = info.st_atimespec
                snapshot.accessTimeIdentities[relative] = (info.st_dev, info.st_ino)
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
                if let total = snapshot.logicalDataBytes, let size = attrs[.size] as? NSNumber, size.int64Value >= 0 {
                    let (sum, overflow) = total.addingReportingOverflow(size.int64Value)
                    snapshot.logicalDataBytes = overflow ? nil : sum
                } else { snapshot.logicalDataBytes = nil }
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
                if let owner = attrs[.ownerAccountID] as? NSNumber, let group = attrs[.groupOwnerAccountID] as? NSNumber {
                    snapshot.metadata.owners?[relative] = CopyTransferMetadata.Ownership(user: owner.uint32Value, group: group.uint32Value)
                }
                let attributes = try attributeDigests(url, cancellation: cancellation)
                if !attributes.isEmpty { snapshot.metadata.extendedAttributes[relative] = attributes }
                snapshot.metadata.accessControlLists[relative] = try accessControlList(url)
                if type != .typeSymbolicLink {
                    snapshot.metadata.modificationDates[relative] = attrs[.modificationDate] as? Date
                    snapshot.metadata.creationDates?[relative] = attrs[.creationDate] as? Date
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
        return length > 0 ? Data(SHA256.hash(data: Data(bytes: text, count: length))) : nil
    }

    private static func attributeDigests(_ url: URL, cancellation: CopyCancellation) throws -> [Data: Data] {
        let invalidAttributes = CopyFailure(text: "Extended attributes could not be verified: " + url.path)
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if size == 0 || (size == -1 && errno == ENOTSUP) { return [:] }
        guard size > 0 else { throw invalidAttributes }
        var names = Data(count: size)
        let listSize = names.withUnsafeMutableBytes {
            listxattr(url.path, $0.baseAddress?.assumingMemoryBound(to: CChar.self), size, XATTR_NOFOLLOW)
        }
        guard listSize == size, names.last == 0 else { throw invalidAttributes }
        var digests: [Data: Data] = [:]
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
            digests[Data(nameBytes)] = Data(SHA256.hash(data: value))
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
