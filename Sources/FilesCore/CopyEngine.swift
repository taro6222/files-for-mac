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
}

/// Versioned, inspectable foundation journal. This is not yet an undo/recovery database.
public struct CopyReport: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public var state: String
    public var items: [CopyRecord]
    public var journalError: String? = nil
}

private struct CopyFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

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
                           progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }) async -> CopyReport {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                execute(sources: sources, destination: destination, journalDirectory: journalDirectory,
                        cancellation: cancellation, conflictPolicy: conflictPolicy, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(sources: [URL], destination: URL, journalDirectory: URL,
                                cancellation: CopyCancellation, conflictPolicy: CopyConflictPolicy,
                                progress: @Sendable (CopyProgress) -> Void) -> CopyReport {
        let fm = FileManager()
        let delegate = CopyDelegate(cancellation)
        fm.delegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        var report = CopyReport(version: 1, id: UUID(), state: "running", items: sources.map {
            CopyRecord(source: $0, target: destination.appendingPathComponent($0.lastPathComponent))
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
                guard destinationFD >= 0, matches(destination, descriptor: destinationFD) else {
                    throw CopyFailure(text: "Destination is unavailable or has changed.")
                }
                report.items[index].state = "planning"; try save(); emit("planning")
                let attrs = try fm.attributesOfItem(atPath: source.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory {
                    let root = source.resolvingSymlinksInPath().standardizedFileURL.path
                    let path = destination.path
                    guard path != root, !path.hasPrefix(root == "/" ? "/" : root + "/") else {
                        throw CopyFailure(text: "Cannot copy a folder into itself or a descendant.")
                    }
                }
                var existing = stat()
                let exists = fstatat(destinationFD, source.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0
                let lookupError = errno
                if exists && conflictPolicy == .skip {
                    report.items[index].state = "conflict"
                    report.items[index].message = "An item with this name already exists; skipped."
                } else {
                    guard exists || lookupError == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: lookupError) ?? .EIO) }
                    let before = try snapshot(source, cancellation: cancellation)
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
                    try fm.copyItem(at: source, to: payload)
                    try cancellation.check()
                    emit("verifying")
                    guard try snapshot(payload, cancellation: cancellation) == before,
                          try snapshot(source, cancellation: cancellation) == before else {
                        throw CopyFailure(text: "Source changed or copied contents did not match.")
                    }
                    emit("committing"); try cancellation.check()
                    guard matches(destination, descriptor: destinationFD), matches(temporary, descriptor: stageFD) else {
                        throw CopyFailure(text: "Destination identity changed before commit.")
                    }
                    // Atomic, descriptor-relative publication: never replace even a racing/broken symlink.
                    var suffix = 0
                    while true {
                        try cancellation.check()
                        let name = copyName(source, isDirectory: attrs[.type] as? FileAttributeType == .typeDirectory, suffix: suffix)
                        report.items[index].target = destination.appendingPathComponent(name)
                        try save() // Persist the actual proposed name before publishing it.
                        if renameatx_np(stageFD, "payload", destinationFD, name, UInt32(RENAME_EXCL)) == 0 {
                            report.items[index].state = "completed"; break
                        }
                        guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
        return report
    }

    private static func copyName(_ source: URL, isDirectory: Bool, suffix: Int) -> String {
        guard suffix > 0 else { return source.lastPathComponent }
        let ext = isDirectory ? "" : source.pathExtension
        let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        return stem + " (\(suffix + 1))" + (ext.isEmpty ? "" : "." + ext)
    }

    private static func matches(_ url: URL, descriptor: Int32) -> Bool {
        var pathInfo = stat(); var descriptorInfo = stat()
        return descriptor >= 0 && lstat(url.path, &pathInfo) == 0 && fstat(descriptor, &descriptorInfo) == 0 &&
            pathInfo.st_dev == descriptorInfo.st_dev && pathInfo.st_ino == descriptorInfo.st_ino
    }

    /// No traversal through symlinks; reject special files before FileManager can block on them.
    static func verifiedSnapshot(_ root: URL, cancellation: CopyCancellation = CopyCancellation()) throws -> [String: String] {
        try snapshot(root, cancellation: cancellation)
    }

    private static func snapshot(_ root: URL, cancellation: CopyCancellation) throws -> [String: String] {
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
                result[relative] = "directory:\(attrs[.posixPermissions] ?? 0)"
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
                result[relative] = "file:\(attrs[.posixPermissions] ?? 0):" + hash.finalize().map { String(format: "%02x", $0) }.joined()
            default: throw CopyFailure(text: "Unsupported special file: " + url.path)
            }
        }
        try visit(root, relative: "")
        return result
    }
}
