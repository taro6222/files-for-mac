import Foundation
import Darwin
import CryptoKit

public enum ArchiveEditError: Error, Sendable, Equatable {
    case busy, invalidJournal, invalidState, metadataNotPreserved
    case metadataMismatch(String)
    case recoveryRequired(journal: URL, archive: URL, retainedFile: URL)
}
public struct ArchiveEditReport: Sendable {
    public let archive: URL, backup: URL, journal: URL
}
public enum ArchiveEditRecoveryOutcome: Sendable {
    case unpublished(ArchiveEditReport), committed(ArchiveEditReport), undone(ArchiveEditReport)
}

private struct ArchiveEditDirectoryProof: Codable, Equatable {
    let device: Int32, inode: UInt64, mode: UInt16, owner: UInt32, group: UInt32
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino; mode = value.st_mode; owner = value.st_uid; group = value.st_gid }
    static func read(_ fd: Int32) throws -> Self {
        var value = stat(); guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw ArchiveEditError.invalidJournal }
        return Self(value)
    }
}

/// External archive-file metadata, distinct from metadata encoded inside the archive.
private struct ArchiveEditMetadata: Codable, Equatable {
    let attributes: [Data: Data], acl: Data?, birthSeconds: Int64, birthNanos: Int64, flags: UInt32
    static func capture(_ fd: Int32, check: () throws -> Void) throws -> Self {
        var value = stat(); guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw ArchiveEditError.metadataNotPreserved }
        // A metadata-only copy of decmpfs storage would reinterpret the new data fork.
        // Keep compressed originals intact until their storage metadata has a dedicated path.
        guard value.st_flags & UInt32(UF_COMPRESSED | UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw ArchiveEditError.metadataNotPreserved }
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 || errno == ENOTSUP, size <= 1_048_576 else { throw ArchiveEditError.metadataNotPreserved }
        var names = [UInt8](repeating: 0, count: max(0, size)), attributes: [Data: Data] = [:]
        if size > 0 {
            guard flistxattr(fd, &names, size, 0) == size, names.last == 0 else { throw ArchiveEditError.metadataNotPreserved }
            for raw in names.split(separator: 0) {
                try check()
                guard let name = String(bytes: raw, encoding: .utf8) else { throw ArchiveEditError.metadataNotPreserved }
                let length = fgetxattr(fd, name, nil, 0, 0, 0)
                guard length >= 0, UInt32(exactly: length) != nil else { throw ArchiveEditError.metadataNotPreserved }
                var hash = SHA256()
                if name == "com.apple.ResourceFork" {
                    var buffer = [UInt8](repeating: 0, count: 65_536), offset = 0
                    while offset < length {
                        try check(); let amount = min(buffer.count, length - offset)
                        let count = fgetxattr(fd, name, &buffer, amount, UInt32(offset), 0)
                        guard count == amount else { throw ArchiveEditError.metadataNotPreserved }
                        hash.update(data: buffer.prefix(count)); offset += count
                    }
                } else {
                    guard length <= 16_777_216 else { throw ArchiveEditError.metadataNotPreserved }
                    var bytes = Data(count: length)
                    let count = bytes.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
                    guard count == length else { throw ArchiveEditError.metadataNotPreserved }; hash.update(data: bytes)
                }
                attributes[Data(raw)] = Data(hash.finalize())
            }
        }
        var aclDigest: Data?
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var length = 0
            guard let text = acl_to_text(acl, &length), length >= 0, length <= 1_048_576 else { throw ArchiveEditError.metadataNotPreserved }
            defer { acl_free(text) }
            if length > 0 { aclDigest = Data(SHA256.hash(data: Data(bytes: text, count: length))) }
        } else if errno != ENOENT && errno != ENOTSUP && errno != EOPNOTSUPP { throw ArchiveEditError.metadataNotPreserved }
        return Self(attributes: attributes, acl: aclDigest, birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanos: Int64(value.st_birthtimespec.tv_nsec), flags: value.st_flags)
    }
}

/// Used serially across background operations. Immutable chained journal events are
/// published without replacement; the private registry is the recovery trust boundary.
final class ArchiveEditTransaction: @unchecked Sendable {
    private struct Record: Codable {
        let version: Int, id: UUID, parent: URL, base: String, staging: URL
        let parentProof: ArchiveEditDirectoryProof, rootProof: ArchiveEditDirectoryProof
        let source: ArchiveEditFileProof, sourceMetadata: ArchiveEditMetadata
        var candidate: ArchiveEditFileProof?, candidateMetadata: ArchiveEditMetadata?, state: String
    }
    private struct Event: Codable { let sequence: Int, previous: String?, record: Record }
    private struct Envelope: Codable { let payload: Data, checksum: String }
    private var record: Record
    private let parentFD: Int32, rootFD: Int32, journalFD: Int32, lockFD: Int32
    private(set) var outputFD: Int32
    let journal: URL
    var archive: URL { record.parent.appendingPathComponent(record.base) }
    var candidate: URL { record.staging.appendingPathComponent("candidate." + archive.pathExtension.lowercased()) }
    private var sequence = 0, previous: String?
    private var closed = false
    private var candidateName: String { candidate.lastPathComponent }
    var report: ArchiveEditReport { .init(archive: archive, backup: candidate, journal: journal) }
    private var review: ArchiveEditError { .recoveryRequired(journal: journal, archive: archive, retainedFile: candidate) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw SevenZipWorkerError.ioFailure } }
    private static func registry(_ directory: URL) throws -> URL {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw ArchiveEditError.invalidJournal }
        let url = directory.appendingPathComponent("archive-edits", isDirectory: true)
        var missingParents: [URL] = [], cursor = url
        while !FileManager.default.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor, missingParents.count < 256 else { throw ArchiveEditError.invalidJournal }
            missingParents.append(parent); cursor = parent
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let actual = try sevenZipCanonicalDirectory(url); var info = stat()
        guard lstat(actual.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ArchiveEditError.invalidJournal }
        for parent in missingParents {
            let actualParent = try sevenZipCanonicalDirectory(parent)
            let fd = open(actualParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }
            defer { Darwin.close(fd) }; try sync(fd)
        }
        return actual
    }
    private static func lock(registry: URL, parent: ArchiveEditDirectoryProof, base: String) throws -> Int32 {
        let key = String(parent.device) + ":" + String(parent.inode) + ":" + base.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let name = registry.appendingPathComponent(".lock-" + hash(Data(key.utf8)))
        let fd = open(name.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ArchiveEditError.invalidJournal }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0, info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { Darwin.close(fd); throw ArchiveEditError.invalidJournal }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw ArchiveEditError.busy }
        return fd
    }
    init(archive: URL, journalDirectory: URL, check: () throws -> Void) throws {
        guard archive.isFileURL, !archive.path.utf8.contains(0), ["zip", "7z"].contains(archive.pathExtension.lowercased()) else { throw SevenZipWorkerError.invalidConfiguration }
        try EntryOperations.validateName(archive.lastPathComponent)
        let parent = try sevenZipCanonicalDirectory(archive.deletingLastPathComponent()), registry = try Self.registry(journalDirectory), id = UUID()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw SevenZipWorkerError.ioFailure }
        var lockFD: Int32 = -1, rootFD: Int32 = -1, journalFD: Int32 = -1, outputFD: Int32 = -1, adopted = false
        defer { if !adopted { for fd in [outputFD, journalFD, rootFD, lockFD, parentFD] where fd >= 0 { Darwin.close(fd) } } }
        let parentProof = try ArchiveEditDirectoryProof.read(parentFD)
        lockFD = try Self.lock(registry: registry, parent: parentProof, base: archive.lastPathComponent)
        let sourceFD = openat(parentFD, archive.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw SevenZipWorkerError.worker("source-open") }; defer { Darwin.close(sourceFD) }
        let source = try ArchiveEditFileProof.capture(sourceFD, check: check), metadata = try ArchiveEditMetadata.capture(sourceFD, check: check)
        guard try ArchiveEditFileProof.capture(sourceFD, check: check) == source else { throw SevenZipWorkerError.worker("source-changed") }
        let staging = parent.appendingPathComponent(".files-archive-edit-" + id.uuidString, isDirectory: true)
        journal = registry.appendingPathComponent(id.uuidString, isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw SevenZipWorkerError.ioFailure }
        guard mkdir(journal.path, 0o700) == 0 else { throw ArchiveEditError.recoveryRequired(journal: journal, archive: archive, retainedFile: staging) }
        rootFD = openat(parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        journalFD = open(journal.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0, journalFD >= 0 else { throw ArchiveEditError.invalidJournal }
        record = Record(version: 1, id: id, parent: parent, base: archive.lastPathComponent, staging: staging, parentProof: parentProof,
            rootProof: try ArchiveEditDirectoryProof.read(rootFD), source: source, sourceMetadata: metadata, candidate: nil, candidateMetadata: nil, state: "building")
        outputFD = openat(rootFD, "candidate." + archive.pathExtension.lowercased(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw SevenZipWorkerError.ioFailure }
        self.parentFD = parentFD; self.rootFD = rootFD; self.journalFD = journalFD; self.lockFD = lockFD; self.outputFD = outputFD; adopted = true
        do {
            try bound(); try save(); try Self.sync(rootFD); try Self.sync(parentFD)
            let registryFD = open(registry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard registryFD >= 0 else { throw review }; defer { Darwin.close(registryFD) }
            try Self.sync(registryFD)
        } catch { close(); throw error }
    }
    private init(journal: URL, directory: URL) throws {
        let registry = try Self.registry(directory)
        guard journal.isFileURL, try sevenZipCanonicalDirectory(journal.deletingLastPathComponent()) == registry,
              let id = UUID(uuidString: journal.lastPathComponent) else { throw ArchiveEditError.invalidJournal }
        let journalFD = open(journal.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard journalFD >= 0 else { throw ArchiveEditError.invalidJournal }
        var parentFD: Int32 = -1, rootFD: Int32 = -1, lockFD: Int32 = -1, adopted = false
        defer { if !adopted { for fd in [lockFD, rootFD, parentFD, journalFD] where fd >= 0 { Darwin.close(fd) } } }
        let directoryProof = try ArchiveEditDirectoryProof.read(journalFD)
        guard directoryProof.owner == geteuid(), directoryProof.mode & 0o077 == 0 else { throw ArchiveEditError.invalidJournal }
        let (event, sequence, previous) = try Self.load(journalFD)
        let saved = event.record
        guard saved.version == 1, saved.id == id, saved.parent.isFileURL, saved.staging == saved.parent.appendingPathComponent(".files-archive-edit-" + id.uuidString, isDirectory: true),
              ["zip", "7z"].contains(URL(fileURLWithPath: saved.base).pathExtension.lowercased()) else { throw ArchiveEditError.invalidJournal }
        try EntryOperations.validateName(saved.base)
        parentFD = open(saved.parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0, try ArchiveEditDirectoryProof.read(parentFD) == saved.parentProof else { throw ArchiveEditError.invalidJournal }
        lockFD = try Self.lock(registry: registry, parent: saved.parentProof, base: saved.base)
        rootFD = openat(parentFD, saved.staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0, try ArchiveEditDirectoryProof.read(rootFD) == saved.rootProof else { throw ArchiveEditError.invalidJournal }
        // Read again under the archive lock; never recover a stale chain observed during a live edit.
        let (locked, lockedSequence, lockedPrevious) = try Self.load(journalFD)
        guard lockedSequence == sequence, lockedPrevious == previous else { throw ArchiveEditError.busy }
        record = locked.record; self.sequence = sequence; self.previous = previous
        self.parentFD = parentFD; self.rootFD = rootFD; self.lockFD = lockFD; self.journalFD = journalFD; outputFD = -1; self.journal = journal; adopted = true
        do { try bound() } catch { close(); throw error }
    }
    private func close() {
        guard !closed else { return }; closed = true
        for fd in [outputFD, journalFD, rootFD, lockFD, parentFD] where fd >= 0 { Darwin.close(fd) }
    }
    deinit { close() }
    private static func eventName(_ sequence: Int) -> String { String(format: "%08d.json", sequence) }
    private static func read(_ directory: Int32, name: String) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ArchiveEditError.invalidJournal }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, (1...4_194_304).contains(info.st_size) else { throw ArchiveEditError.invalidJournal }
        var data = Data(count: Int(info.st_size)); var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < raw.count { let count = pread(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, off_t(offset)); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw ArchiveEditError.invalidJournal }; offset += count }
        }
        var after = stat(); guard fstat(fd, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino, after.st_size == info.st_size,
            after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw ArchiveEditError.invalidJournal }
        return data
    }
    private static func load(_ fd: Int32) throws -> (Event, Int, String) {
        var previous: String?, result: Event?, total = 0
        for index in 0...128 {
            let name = eventName(index); var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT, let result, let previous else { throw ArchiveEditError.invalidJournal }
                return (result, index, previous)
            }
            guard index < 128 else { throw ArchiveEditError.invalidJournal }
            let bytes = try read(fd, name: name); total += bytes.count
            guard total <= 67_108_864 else { throw ArchiveEditError.invalidJournal }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard hash(envelope.payload) == envelope.checksum else { throw ArchiveEditError.invalidJournal }
            let event = try JSONDecoder().decode(Event.self, from: envelope.payload)
            guard event.sequence == index, event.previous == previous, result == nil || event.record.id == result?.record.id else { throw ArchiveEditError.invalidJournal }
            result = event; previous = hash(bytes)
        }
        throw ArchiveEditError.invalidJournal
    }
    private func save() throws {
        guard sequence < 128 else { throw review }
        if sequence > 0 { let (_, count, digest) = try Self.load(journalFD); guard count == sequence, digest == previous else { throw ArchiveEditError.invalidJournal } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Event(sequence: sequence, previous: previous, record: record))
        let bytes = try encoder.encode(Envelope(payload: payload, checksum: Self.hash(payload)))
        guard bytes.count <= 4_194_304 else { throw ArchiveEditError.invalidJournal }
        let temp = ".pending-" + UUID().uuidString
        let fd = openat(journalFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw review }; defer { Darwin.close(fd) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw review }; offset += count }
        }
        try Self.sync(fd)
        guard renameatx_np(journalFD, temp, journalFD, Self.eventName(sequence), UInt32(RENAME_EXCL)) == 0 else { throw review }
        try Self.sync(journalFD); previous = Self.hash(bytes); sequence += 1
    }
    private func bound() throws {
        var parent = stat(), root = stat(), namedJournal = stat()
        guard lstat(record.parent.path, &parent) == 0, ArchiveEditDirectoryProof(parent) == record.parentProof,
              try ArchiveEditDirectoryProof.read(parentFD) == record.parentProof,
              fstatat(parentFD, record.staging.lastPathComponent, &root, AT_SYMLINK_NOFOLLOW) == 0, ArchiveEditDirectoryProof(root) == record.rootProof,
              try ArchiveEditDirectoryProof.read(rootFD) == record.rootProof,
              lstat(journal.path, &namedJournal) == 0, try ArchiveEditDirectoryProof.read(journalFD) == ArchiveEditDirectoryProof(namedJournal) else { throw review }
    }
    private func file(_ directory: Int32, _ name: String, check: () throws -> Void) throws -> (ArchiveEditFileProof, ArchiveEditMetadata) {
        try bound(); try check()
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw review }; defer { Darwin.close(fd) }
        let proof = try ArchiveEditFileProof.capture(fd, check: check), metadata = try ArchiveEditMetadata.capture(fd, check: check)
        guard try ArchiveEditFileProof.capture(fd, check: check) == proof else { throw review }
        var named = stat(); guard fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            proof.matchesStat(named) else { throw review }
        try bound(); return (proof, metadata)
    }
    private func matches(_ actual: (ArchiveEditFileProof, ArchiveEditMetadata), _ proof: ArchiveEditFileProof, _ metadata: ArchiveEditMetadata) -> Bool {
        proof.sameAfterRename(actual.0) && metadata == actual.1
    }
    func publish(_ verified: ArchiveEditCandidate, check: () throws -> Void, progress: ArchiveProgressHandler?) throws -> ArchiveEditReport {
        guard record.state == "building", record.source == verified.source else { throw review }
        let before = try file(parentFD, record.base, check: check), output = try file(rootFD, candidateName, check: check)
        guard before.0 == record.source, before.1 == record.sourceMetadata, output.0 == verified.candidate else { throw review }
        let input = openat(parentFD, record.base, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        let target = openat(rootFD, candidateName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0, target >= 0 else { if input >= 0 { Darwin.close(input) }; if target >= 0 { Darwin.close(target) }; throw review }
        defer { Darwin.close(input); Darwin.close(target) }
        guard try ArchiveEditFileProof.capture(input, check: check) == record.source,
              try ArchiveEditFileProof.capture(target, check: check) == verified.candidate else { throw review }
        guard fcopyfile(input, target, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw ArchiveEditError.metadataMismatch("copyfile-" + String(errno)) }
        var now = timespec(); guard clock_gettime(CLOCK_REALTIME, &now) == 0 else { throw review }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), now]
        guard futimens(target, &times) == 0 else { throw ArchiveEditError.metadataNotPreserved }
        var birth = timespec(tv_sec: Int(record.sourceMetadata.birthSeconds), tv_nsec: Int(record.sourceMetadata.birthNanos))
        var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        guard fsetattrlist(target, &attributes, &birth, MemoryLayout<timespec>.size, 0) == 0 else { throw ArchiveEditError.metadataMismatch("creation-time-write") }
        try Self.sync(target); try Self.sync(input)
        let ready = try file(rootFD, candidateName, check: check), source = try file(parentFD, record.base, check: check)
        guard source.0 == record.source, source.1 == record.sourceMetadata else { throw ArchiveEditError.metadataMismatch("source-after-copy") }
        guard ready.0.sha256 == verified.candidate.sha256, ready.0.device == verified.candidate.device,
              ready.0.inode == verified.candidate.inode, ready.0.size == verified.candidate.size else { throw ArchiveEditError.metadataMismatch("candidate-content") }
        guard ready.0.mode == record.source.mode, ready.0.owner == record.source.owner, ready.0.group == record.source.group else { throw ArchiveEditError.metadataMismatch("permissions-owner") }
        guard ready.1.attributes == record.sourceMetadata.attributes else { throw ArchiveEditError.metadataMismatch("extended-attributes") }
        guard ready.1.acl == record.sourceMetadata.acl else { throw ArchiveEditError.metadataMismatch("acl") }
        guard ready.1.birthSeconds == record.sourceMetadata.birthSeconds, ready.1.birthNanos == record.sourceMetadata.birthNanos else { throw ArchiveEditError.metadataMismatch("creation-time") }
        guard ready.1.flags == record.sourceMetadata.flags else { throw ArchiveEditError.metadataMismatch("file-flags") }
        record.candidate = ready.0; record.candidateMetadata = ready.1; record.state = "prepared"; try save()
        record.state = "swapIntent"; try save()
        progress?(.init(phase: .publishing, completedEntries: 0, totalEntries: verified.entries.count, completedBytes: 0, totalBytes: ready.0.size, currentPath: nil))
        try check(); try bound()
        guard try file(parentFD, record.base, check: check).0 == record.source,
              try file(rootFD, candidateName, check: check).0 == ready.0 else { throw review }
        // Exchange retains both complete files even if a foreign entry races the syscall.
        guard renameatx_np(rootFD, candidateName, parentFD, record.base, UInt32(RENAME_SWAP)) == 0 else { throw review }
        do {
            try Self.sync(parentFD); try Self.sync(rootFD)
            guard matches(try file(parentFD, record.base, check: {}), ready.0, ready.1),
                  matches(try file(rootFD, candidateName, check: {}), record.source, record.sourceMetadata) else { throw review }
            progress?(.init(phase: .publishing, completedEntries: verified.entries.count, totalEntries: verified.entries.count, completedBytes: ready.0.size, totalBytes: ready.0.size, currentPath: record.base))
            record.state = "committed"; try save(); return report
        } catch { throw review }
    }
    private func reconcile(check: () throws -> Void) throws -> ArchiveEditRecoveryOutcome {
        let source = try file(parentFD, record.base, check: check)
        if record.state == "building" { guard matches(source, record.source, record.sourceMetadata) else { throw review }; return .unpublished(report) }
        guard let candidateProof = record.candidate, let candidateMetadata = record.candidateMetadata else { throw ArchiveEditError.invalidJournal }
        let retained = try file(rootFD, candidateName, check: check)
        let originalPosition = matches(source, record.source, record.sourceMetadata) && matches(retained, candidateProof, candidateMetadata)
        let editedPosition = matches(source, candidateProof, candidateMetadata) && matches(retained, record.source, record.sourceMetadata)
        switch record.state {
        case "prepared": guard originalPosition else { throw review }; return .unpublished(report)
        case "swapIntent":
            guard originalPosition || editedPosition else { throw review }
            record.state = editedPosition ? "committed" : "prepared"; try save()
            return editedPosition ? .committed(report) : .unpublished(report)
        case "committed": guard editedPosition else { throw review }; return .committed(report)
        case "undoIntent":
            guard originalPosition || editedPosition else { throw review }
            record.state = originalPosition ? "undone" : "committed"; try save()
            return originalPosition ? .undone(report) : .committed(report)
        case "undone": guard originalPosition else { throw review }; return .undone(report)
        default: throw ArchiveEditError.invalidJournal
        }
    }
    static func recover(journal: URL, directory: URL, undo: Bool, check: () throws -> Void, progress: ArchiveProgressHandler? = nil) throws -> ArchiveEditRecoveryOutcome {
        let transaction = try Self(journal: journal, directory: directory)
        let result = try transaction.reconcile(check: check)
        guard undo else { return result }
        if case .undone = result { return result }
        guard case .committed = result, let proof = transaction.record.candidate, let metadata = transaction.record.candidateMetadata else { throw ArchiveEditError.invalidState }
        transaction.record.state = "undoIntent"; try transaction.save()
        progress?(.init(phase: .publishing, completedEntries: 0, totalEntries: 1, completedBytes: 0, totalBytes: proof.size, currentPath: nil))
        try check(); try transaction.bound()
        guard transaction.matches(try transaction.file(transaction.parentFD, transaction.record.base, check: check), proof, metadata),
              transaction.matches(try transaction.file(transaction.rootFD, transaction.candidateName, check: check), transaction.record.source, transaction.record.sourceMetadata) else { throw transaction.review }
        guard renameatx_np(transaction.rootFD, transaction.candidateName, transaction.parentFD, transaction.record.base, UInt32(RENAME_SWAP)) == 0 else { throw transaction.review }
        do {
            try sync(transaction.parentFD); try sync(transaction.rootFD)
            guard transaction.matches(try transaction.file(transaction.parentFD, transaction.record.base, check: {}), transaction.record.source, transaction.record.sourceMetadata),
                  transaction.matches(try transaction.file(transaction.rootFD, transaction.candidateName, check: {}), proof, metadata) else { throw transaction.review }
            progress?(.init(phase: .publishing, completedEntries: 1, totalEntries: 1, completedBytes: proof.size, totalBytes: proof.size, currentPath: transaction.record.base))
            transaction.record.state = "undone"; try transaction.save(); return .undone(transaction.report)
        } catch { throw transaction.review }
    }
}
