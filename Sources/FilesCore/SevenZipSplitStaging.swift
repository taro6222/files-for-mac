import Foundation
import Darwin
import CryptoKit

public struct SevenZipSplitCreationReport: Sendable {
    public let publishedURLs: [URL]
    public let journal: URL
    public let retainedStaging: URL?
}
public enum SevenZipSplitError: Error, Sendable, Equatable {
    case invalidVolumeSize, busy, invalidJournal
    case recoveryRequired(journal: URL, staging: URL, possibleOutputs: [URL])
}
public enum SevenZipSplitRecoveryOutcome: Sendable {
    case rolledBack
    case committed(SevenZipSplitCreationReport)
}

/// Serialized by its caller. A private registry is the recovery trust boundary;
/// checksums detect corruption, not hostile code already able to edit that registry.
final class SevenZipSplitStaging: @unchecked Sendable {
    struct Proof: Codable, Equatable {
        let device: String, inode: String, size: Int64, mode: UInt32, uid: UInt32, gid: UInt32
        let modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
        init(_ value: stat) {
            device = String(value.st_dev); inode = String(value.st_ino); size = value.st_size; mode = UInt32(value.st_mode)
            uid = value.st_uid; gid = value.st_gid
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        func identity(_ other: Proof) -> Bool { device == other.device && inode == other.inode }
        func sameExceptChange(_ other: Proof) -> Bool {
            identity(other) && size == other.size && mode == other.mode && uid == other.uid && gid == other.gid && modified == other.modified && modifiedNanos == other.modifiedNanos
        }
    }
    struct Part: Codable {
        let name: String
        var proof: Proof
        var digest: String?
        var moved: Bool
    }
    struct Journal: Codable {
        let version: Int, id: UUID, base: String, parent: URL, staging: URL, volumeBytes: Int64
        let parentProof: Proof, rootProof: Proof, lockProof: Proof
        var state: String, intent: Int?, parts: [Part], stagingRemoved: Bool
    }
    private struct Envelope: Codable { let payload: Data, checksum: String }
    let staging: URL, journalURL: URL
    private let parentFD: Int32, rootFD: Int32, lockFD: Int32, registryFD: Int32
    private var record: Journal
    private var journalDisk: Data?
    private var journalProof: Proof?
    private var buffer = Data(), logicalSize: UInt64 = 0
    private(set) var ended = false
    private var closed = false
    var totalBytes: Int64 { Int64(logicalSize) }
    private static let ceiling: UInt64 = 8_000_000_000

    static func registry(in directory: URL) throws -> URL {
        guard directory.isFileURL else { throw SevenZipSplitError.invalidJournal }
        let value = directory.appendingPathComponent("archive-splits", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonical = try sevenZipCanonicalDirectory(value)
        var info = stat()
        guard lstat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw SevenZipSplitError.invalidJournal }
        return canonical
    }
    init(destination: URL, volumeBytes: Int64, journalDirectory: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "7z", (16...SevenZipVolumes.maximumSplitVolumeBytes).contains(volumeBytes) else { throw SevenZipSplitError.invalidVolumeSize }
        let parent = try sevenZipCanonicalDirectory(destination.deletingLastPathComponent()), id = UUID()
        staging = parent.appendingPathComponent(".files-split-" + id.uuidString, isDirectory: true)
        let registry = try Self.registry(in: journalDirectory)
        journalURL = registry.appendingPathComponent(id.uuidString + ".json")
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw SevenZipWorkerError.ioFailure }
        var rootFD: Int32 = -1, lockFD: Int32 = -1, registryFD: Int32 = -1, adopted = false
        defer { if !adopted { for fd in [lockFD, rootFD, registryFD, parentFD] where fd >= 0 { Darwin.close(fd) } } }
        try Self.preflight(parent: parent, fd: parentFD, base: destination.lastPathComponent)
        guard mkdirat(parentFD, staging.lastPathComponent, 0o700) == 0 else { throw SevenZipWorkerError.ioFailure }
        rootFD = openat(parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SevenZipWorkerError.stagingPreserved(staging) }
        lockFD = openat(rootFD, "lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        registryFD = open(registry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lockFD >= 0, registryFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SevenZipWorkerError.stagingPreserved(staging) }
        self.parentFD = parentFD; self.rootFD = rootFD; self.lockFD = lockFD; self.registryFD = registryFD
        record = Journal(version: 1, id: id, base: destination.lastPathComponent, parent: parent, staging: staging, volumeBytes: volumeBytes,
                         parentProof: try Self.statFD(parentFD), rootProof: try Self.statFD(rootFD), lockProof: try Self.statFD(lockFD), state: "building", intent: nil, parts: [], stagingRemoved: false)
        adopted = true
        do { try sync(lockFD); try save(); try sync(rootFD); try sync(parentFD) }
        catch { close(); throw SevenZipWorkerError.stagingPreserved(staging) }
    }
    private init(recovering journal: URL, directory: URL) throws {
        let registry = try Self.registry(in: directory)
        guard try sevenZipCanonicalDirectory(journal.deletingLastPathComponent()) == registry,
              let id = UUID(uuidString: journal.deletingPathExtension().lastPathComponent), journal.pathExtension == "json" else { throw SevenZipSplitError.invalidJournal }
        let registryFD = open(registry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard registryFD >= 0 else { throw SevenZipSplitError.invalidJournal }
        var parentFD: Int32 = -1, rootFD: Int32 = -1, lockFD: Int32 = -1, adopted = false
        defer { if !adopted { for fd in [lockFD, rootFD, parentFD, registryFD] where fd >= 0 { Darwin.close(fd) } } }
        let (bytes, proof) = try Self.readFile(registryFD, name: journal.lastPathComponent, maximum: 4_194_304)
        let saved = try Self.decodeRecord(bytes, id: id)
        parentFD = open(saved.parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0, saved.parentProof.identity(try Self.statFD(parentFD)) else { throw SevenZipSplitError.invalidJournal }
        rootFD = openat(parentFD, saved.staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if rootFD >= 0 {
            let heldRoot = try Self.statFD(rootFD)
            guard saved.rootProof.identity(heldRoot), heldRoot.mode == saved.rootProof.mode, heldRoot.uid == geteuid(), heldRoot.gid == saved.rootProof.gid else { throw SevenZipSplitError.invalidJournal }
            lockFD = openat(rootFD, "lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lockFD >= 0, saved.lockProof == (try Self.statFD(lockFD)) else { throw SevenZipSplitError.invalidJournal }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SevenZipSplitError.busy }
        } else if !(saved.stagingRemoved && ["committed", "rolledBack"].contains(saved.state) && errno == ENOENT) { throw SevenZipSplitError.invalidJournal }
        self.parentFD = parentFD; self.rootFD = rootFD; self.lockFD = lockFD; self.registryFD = registryFD
        staging = saved.staging; journalURL = journal; record = saved; journalDisk = bytes; journalProof = proof; adopted = true
    }
    private static func decodeRecord(_ bytes: Data, id: UUID) throws -> Journal {
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.checksum == Self.digest(envelope.payload) else { throw SevenZipSplitError.invalidJournal }
        let saved = try JSONDecoder().decode(Journal.self, from: envelope.payload)
        guard saved.version == 1, saved.id == id, saved.parent.isFileURL, saved.staging.isFileURL,
              saved.staging.deletingLastPathComponent() == saved.parent,
              saved.staging.lastPathComponent == ".files-split-" + id.uuidString,
              saved.base == (saved.base as NSString).lastPathComponent, !saved.base.utf8.contains(0), (saved.base as NSString).pathExtension.lowercased() == "7z",
              (16...SevenZipVolumes.maximumSplitVolumeBytes).contains(saved.volumeBytes), saved.parts.count <= SevenZipVolumes.maximumParts,
              ["building", "prepared", "publishing", "discarding", "rolledBack", "committed"].contains(saved.state),
              saved.intent == nil || saved.parts.indices.contains(saved.intent!) else { throw SevenZipSplitError.invalidJournal }
        if ["prepared", "publishing", "committed"].contains(saved.state) {
            guard !saved.parts.isEmpty, saved.parts.allSatisfy({ $0.digest?.count == 64 && $0.digest?.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) == true }) else { throw SevenZipSplitError.invalidJournal }
        }
        if ["building", "prepared", "discarding", "rolledBack"].contains(saved.state) { guard saved.parts.allSatisfy({ !$0.moved }) else { throw SevenZipSplitError.invalidJournal } }
        if saved.state == "committed" { guard saved.intent == nil, saved.parts.allSatisfy(\.moved) else { throw SevenZipSplitError.invalidJournal } }
        var savedBytes: Int64 = 0
        for (index, part) in saved.parts.enumerated() {
            guard part.proof.size >= 0, part.proof.size <= Int64(ceiling) - savedBytes else { throw SevenZipSplitError.invalidJournal }
            savedBytes += part.proof.size
            guard part.name == Self.partName(saved.base, index), part.proof.size >= 0, part.proof.size <= saved.volumeBytes,
                  part.proof.mode & UInt32(S_IFMT) == UInt32(S_IFREG), part.proof.uid == geteuid(), part.proof.mode & 0o077 == 0 else { throw SevenZipSplitError.invalidJournal }
        }
        return saved
    }

    static func history(directory: URL, check: () throws -> Void) throws -> [SevenZipSplitJournalSummary] {
        let proposed = directory.appendingPathComponent("archive-splits", isDirectory: true)
        var info = stat()
        if lstat(proposed.path, &info) != 0 && errno == ENOENT { return [] }
        let registry = try Self.registry(in: directory)
        let fd = open(registry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SevenZipSplitError.invalidJournal }
        defer { Darwin.close(fd) }
        var result: [SevenZipSplitJournalSummary] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: registry.path).sorted() {
            try check()
            guard (name as NSString).pathExtension == "json" else { continue }
            let url = registry.appendingPathComponent(name)
            do {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw SevenZipSplitError.invalidJournal }
                let (bytes, proof) = try readFile(fd, name: name, maximum: 4_194_304)
                let saved = try decodeRecord(bytes, id: id)
                result.append(SevenZipSplitJournalSummary(journal: url, destination: saved.parent.appendingPathComponent(saved.base),
                    staging: saved.stagingRemoved ? nil : saved.staging, phase: saved.state, ambiguousIntent: saved.intent != nil,
                    updatedAt: Date(timeIntervalSince1970: Double(proof.modified) + Double(proof.modifiedNanos) / 1_000_000_000)))
            } catch {
                result.append(SevenZipSplitJournalSummary(journal: url, destination: nil, staging: nil, phase: "unreadable", ambiguousIntent: true, updatedAt: .distantPast))
            }
        }
        return result.sorted { a, b in
            if a.isUnfinished != b.isUnfinished { return a.isUnfinished }
            return a.updatedAt == b.updatedAt ? a.journal.lastPathComponent < b.journal.lastPathComponent : a.updatedAt > b.updatedAt
        }
    }
    deinit { close() }
    private func close() {
        if !closed { for fd in [lockFD, rootFD, parentFD, registryFD] where fd >= 0 { Darwin.close(fd) }; closed = true }
    }
    private static func preflight(parent: URL, fd: Int32, base: String, allowed: [String: Proof] = [:]) throws {
        var info = stat()
        guard fstatat(fd, base, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else { throw ZipArchiveError.destinationConflict(base) }
        let sensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
        func key(_ name: String) -> String { let normalized = name.precomposedStringWithCanonicalMapping; return sensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        var failed = false
        guard let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in failed = true; return false }) else { throw SevenZipWorkerError.ioFailure }
        for case let url as URL in entries where key(url.deletingPathExtension().lastPathComponent) == key(base) && SevenZipVolumes.index(of: url) != nil {
            guard let proof = allowed[url.lastPathComponent], fstatat(fd, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0, proof == Proof(info) else { throw ZipArchiveError.destinationConflict(url.lastPathComponent) }
        }
        guard !failed else { throw SevenZipWorkerError.ioFailure }
    }
    private static func partName(_ base: String, _ index: Int) -> String { base + "." + String(format: "%03d", index + 1) }
    private static func statFD(_ fd: Int32) throws -> Proof {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw SevenZipWorkerError.ioFailure }; return Proof(info)
    }
    private func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw SevenZipWorkerError.ioFailure } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func readFile(_ directory: Int32, name: String, maximum: Int64) throws -> (Data, Proof) {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SevenZipSplitError.invalidJournal }; defer { Darwin.close(fd) }
        let proof = try statFD(fd)
        var info = stat(); guard fstat(fd, &info) == 0, info.st_nlink == 1, proof.mode & UInt32(S_IFMT) == UInt32(S_IFREG), proof.uid == geteuid(), proof.mode & 0o077 == 0, proof.size >= 0, proof.size <= maximum else { throw SevenZipSplitError.invalidJournal }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true { let count = Darwin.read(fd, &buffer, buffer.count); if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw SevenZipSplitError.invalidJournal }; if count == 0 { break }; data.append(contentsOf: buffer.prefix(count)); guard Int64(data.count) <= maximum else { throw SevenZipSplitError.invalidJournal } }
        guard try statFD(fd) == proof, Int64(data.count) == proof.size else { throw SevenZipSplitError.invalidJournal }
        return (data, proof)
    }
    private func save() throws {
        if let journalDisk, let journalProof {
            let current = try Self.readFile(registryFD, name: journalURL.lastPathComponent, maximum: 4_194_304)
            guard current.0 == journalDisk, current.1 == journalProof else { throw SevenZipSplitError.invalidJournal }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(record), data = try encoder.encode(Envelope(payload: payload, checksum: Self.digest(payload)))
        guard data.count <= 4_194_304 else { throw SevenZipSplitError.invalidJournal }
        let name = ".next-" + UUID().uuidString
        let fd = openat(registryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }
        defer { Darwin.close(fd); _ = unlinkat(registryFD, name, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw SevenZipWorkerError.ioFailure }; offset += count }
        }
        try sync(fd)
        let result = journalDisk == nil ? renameatx_np(registryFD, name, registryFD, journalURL.lastPathComponent, UInt32(RENAME_EXCL)) : renameat(registryFD, name, registryFD, journalURL.lastPathComponent)
        guard result == 0 else { throw SevenZipWorkerError.ioFailure }
        try sync(registryFD)
        journalDisk = data; journalProof = try Self.statFD(fd)
    }
    private func boundDirectories() throws {
        var parent = stat(), root = stat()
        guard lstat(record.parent.path, &parent) == 0, record.parentProof.identity(Proof(parent)),
              parent.st_mode == record.parentProof.mode, parent.st_uid == record.parentProof.uid, parent.st_gid == record.parentProof.gid,
              fstatat(parentFD, staging.lastPathComponent, &root, AT_SYMLINK_NOFOLLOW) == 0, record.rootProof.identity(Proof(root)),
              root.st_mode == record.rootProof.mode, root.st_uid == record.rootProof.uid, root.st_gid == record.rootProof.gid else { throw SevenZipWorkerError.ioFailure }
    }
    private func openPart(_ index: Int, at directory: Int32, check: () throws -> Void, hash: Bool = true) throws -> Int32 {
        try check(); let part = record.parts[index]
        let fd = openat(directory, part.name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }
        do {
            var info = stat(); guard fstat(fd, &info) == 0, info.st_nlink == 1, part.proof == Proof(info) else { throw SevenZipWorkerError.ioFailure }
            if hash, let expected = part.digest { guard try hashPart(fd, check: check) == expected else { throw SevenZipWorkerError.ioFailure } }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func hashPart(_ fd: Int32, check: () throws -> Void) throws -> String {
        let before = try Self.statFD(fd); var hash = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
        while offset < before.size {
            try check(); let count = pread(fd, &buffer, min(buffer.count, Int(before.size - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw SevenZipWorkerError.ioFailure }
            hash.update(data: Data(buffer.prefix(count))); offset += Int64(count)
        }
        guard try Self.statFD(fd) == before else { throw SevenZipWorkerError.ioFailure }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func resize(_ size: UInt64, check: () throws -> Void) throws {
        guard size <= Self.ceiling else { throw SevenZipWorkerError.invalidResponse }
        let volume = UInt64(record.volumeBytes), count = size == 0 ? 0 : Int((size - 1) / volume + 1)
        guard count <= SevenZipVolumes.maximumParts else { throw SevenZipVolumeError.tooManyParts }
        while record.parts.count > count {
            let index = record.parts.count - 1, fd = try openPart(index, at: rootFD, check: check, hash: false); defer { Darwin.close(fd) }
            guard unlinkat(rootFD, record.parts[index].name, 0) == 0 else { throw SevenZipWorkerError.ioFailure }; record.parts.removeLast()
        }
        while record.parts.count < count {
            try check(); let name = Self.partName(record.base, record.parts.count)
            let fd = openat(rootFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }; defer { Darwin.close(fd) }
            record.parts.append(Part(name: name, proof: try Self.statFD(fd), digest: nil, moved: false))
        }
        for index in record.parts.indices {
            let target = Int64(min(volume, size - UInt64(index) * volume))
            if record.parts[index].proof.size == target { continue }
            let fd = try openPart(index, at: rootFD, check: check, hash: false); defer { record.parts[index].proof = (try? Self.statFD(fd)) ?? record.parts[index].proof; Darwin.close(fd) }
            guard ftruncate(fd, off_t(target)) == 0 else { throw SevenZipWorkerError.ioFailure }
        }
        logicalSize = size
    }
    func consume(_ data: Data, check: () throws -> Void) throws {
        guard !ended, record.state == "building" else { throw SevenZipWorkerError.invalidResponse }
        buffer.append(data)
        while buffer.count >= 17 {
            try check()
            let type = buffer[buffer.startIndex]
            func number(_ offset: Int) -> UInt64 { buffer.dropFirst(offset).prefix(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            let offset = number(1), count = number(9)
            guard offset <= Self.ceiling, count <= 65536, type <= 2, type == 0 || count == 0,
                  type != 0 || (count > 0 && count <= Self.ceiling - offset) else { throw SevenZipWorkerError.invalidResponse }
            let length = 17 + Int(count); guard buffer.count >= length else { break }
            if type == 0 {
                if offset + count > logicalSize { try resize(offset + count, check: check) }
                var done: UInt64 = 0
                while done < count {
                    let position = offset + done, index = Int(position / UInt64(record.volumeBytes)), within = position % UInt64(record.volumeBytes)
                    let amount = Int(min(count - done, UInt64(record.volumeBytes) - within))
                    let fd = try openPart(index, at: rootFD, check: check, hash: false)
                    defer { record.parts[index].proof = (try? Self.statFD(fd)) ?? record.parts[index].proof; Darwin.close(fd) }
                    let bytes = Data(buffer.dropFirst(17 + Int(done)).prefix(amount))
                    try bytes.withUnsafeBytes { raw in
                        var wrote = 0
                        while wrote < raw.count { try check(); let n = pwrite(fd, raw.baseAddress!.advanced(by: wrote), raw.count - wrote, off_t(within) + off_t(wrote)); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw SevenZipWorkerError.ioFailure }; wrote += n }
                    }
                    done += UInt64(amount)
                }
            } else if type == 1 { try resize(offset, check: check) }
            else {
                guard offset == logicalSize, offset > 0 else { throw SevenZipWorkerError.invalidResponse }; ended = true
            }
            buffer.removeFirst(length)
            guard !ended || buffer.isEmpty else { throw SevenZipWorkerError.invalidResponse }
        }
        guard buffer.count <= 65553 else { throw SevenZipWorkerError.invalidResponse }
    }
    func prepare(check: () throws -> Void) throws {
        guard ended, buffer.isEmpty, !record.parts.isEmpty else { throw SevenZipWorkerError.invalidResponse }
        try boundDirectories()
        try validateStartHeader(check: check)
        for index in record.parts.indices {
            let fd = try openPart(index, at: rootFD, check: check, hash: false); defer { Darwin.close(fd) }
            try sync(fd); record.parts[index].digest = try hashPart(fd, check: check)
        }
        record.state = "prepared"; try save(); try sync(rootFD)
    }
    private func validateStartHeader(check: () throws -> Void) throws {
        guard logicalSize >= 32 else { throw SevenZipWorkerError.invalidResponse }
        var header: [UInt8] = []
        for index in record.parts.indices where header.count < 32 {
            let fd = try openPart(index, at: rootFD, check: check, hash: false); defer { Darwin.close(fd) }
            let amount = min(32 - header.count, Int(record.parts[index].proof.size))
            var bytes = [UInt8](repeating: 0, count: amount), offset = 0
            try bytes.withUnsafeMutableBytes { raw in
                while offset < amount {
                    let count = pread(fd, raw.baseAddress!.advanced(by: offset), amount - offset, off_t(offset))
                    if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw SevenZipWorkerError.ioFailure }; offset += count
                }
            }
            header.append(contentsOf: bytes)
        }
        guard header.count == 32, Array(header.prefix(6)) == [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], header[6] == 0 else { throw SevenZipWorkerError.invalidResponse }
        func little(_ offset: Int, _ count: Int) -> UInt64 { (offset..<(offset + count)).reversed().reduce(0) { ($0 << 8) | UInt64(header[$1]) } }
        var crc = UInt32.max
        for byte in header.suffix(20) { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) } }
        let (next, overflow1) = little(12, 8).addingReportingOverflow(32)
        let (total, overflow2) = next.addingReportingOverflow(little(20, 8))
        guard UInt64(~crc) == little(8, 4), !overflow1, !overflow2, total == logicalSize else { throw SevenZipWorkerError.invalidResponse }
    }
    private func absent(_ fd: Int32, name: String) -> Bool { var value = stat(); return fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT }
    func recoveryError() -> SevenZipSplitError { review() }
    private func review() -> SevenZipSplitError { .recoveryRequired(journal: journalURL, staging: staging, possibleOutputs: record.parts.map { record.parent.appendingPathComponent($0.name) }) }
    func publish(check: () throws -> Void, progress: (String) -> Void) throws -> SevenZipSplitCreationReport {
        guard record.state == "prepared" else { throw SevenZipSplitError.invalidJournal }
        try boundDirectories()
        try Self.preflight(parent: record.parent, fd: parentFD, base: record.base)
        for index in record.parts.indices {
            try check(); try boundDirectories()
            let fd = try openPart(index, at: rootFD, check: check); defer { Darwin.close(fd) }
            record.state = "publishing"; record.intent = index; try save()
            if renameatx_np(rootFD, record.parts[index].name, parentFD, record.parts[index].name, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw review() }
                record.intent = nil; try save(); throw ZipArchiveError.destinationConflict(record.parts[index].name)
            }
            try sync(parentFD); try sync(rootFD)
            let now = try Self.statFD(fd)
            guard record.parts[index].proof.sameExceptChange(now), try hashPart(fd, check: check) == record.parts[index].digest else { throw review() }
            record.parts[index].proof = now; record.parts[index].moved = true; record.intent = nil; try save()
            progress(record.parts[index].name)
        }
        try check(); try validateAll(check: check)
        try Self.preflight(parent: record.parent, fd: parentFD, base: record.base, allowed: Dictionary(uniqueKeysWithValues: record.parts.map { ($0.name, $0.proof) }))
        record.state = "committed"; try save()
        let cleaned = cleanupRoot(); record.stagingRemoved = cleaned; try? save()
        return SevenZipSplitCreationReport(publishedURLs: record.parts.map { record.parent.appendingPathComponent($0.name) }, journal: journalURL, retainedStaging: cleaned ? nil : staging)
    }
    private func validateAll(check: () throws -> Void) throws {
        try boundDirectories()
        let parentNames = Set(try FileManager.default.contentsOfDirectory(atPath: record.parent.path))
        guard record.parts.filter(\.moved).allSatisfy({ parentNames.contains($0.name) }) else { throw review() }
        for index in record.parts.indices {
            let part = record.parts[index], fd = try openPart(index, at: part.moved ? parentFD : rootFD, check: check)
            Darwin.close(fd)
            if part.moved && !absent(rootFD, name: part.name) { throw review() }
        }
        let allowed = Set(["lock"] + record.parts.filter { !$0.moved }.map(\.name))
        let names = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        guard Set(names) == allowed else { throw review() }
    }
    private func cleanupRoot() -> Bool {
        do {
            try boundDirectories()
            guard try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["lock"], record.lockProof == (try Self.statFD(lockFD)), unlinkat(rootFD, "lock", 0) == 0 else { return false }
            guard unlinkat(parentFD, staging.lastPathComponent, AT_REMOVEDIR) == 0 else { return false }
            try sync(parentFD); return true
        } catch { return false }
    }
    func rollback() throws {
        guard record.state != "committed", record.intent == nil else { throw review() }
        try validateAll(check: {})
        for index in record.parts.indices.reversed() where record.parts[index].moved {
            let fd = try openPart(index, at: parentFD, check: {}); defer { Darwin.close(fd) }
            record.intent = index; try save()
            guard renameatx_np(parentFD, record.parts[index].name, rootFD, record.parts[index].name, UInt32(RENAME_EXCL)) == 0 else { throw review() }
            try sync(rootFD); try sync(parentFD)
            let now = try Self.statFD(fd)
            guard record.parts[index].proof.sameExceptChange(now) else { throw review() }
            record.parts[index].proof = now; record.parts[index].moved = false; record.intent = nil; try save()
        }
        record.state = "discarding"; try save()
        try discardPrivate()
    }
    private func discardPrivate() throws {
        for index in record.parts.indices {
            if absent(rootFD, name: record.parts[index].name) { continue }
            let fd = try openPart(index, at: rootFD, check: {}); defer { Darwin.close(fd) }
            guard unlinkat(rootFD, record.parts[index].name, 0) == 0 else { throw review() }
        }
        try sync(rootFD)
        guard cleanupRoot() else { throw review() }
        record.stagingRemoved = true; record.state = "rolledBack"; try save()
    }
    static func recover(journal: URL, directory: URL, check: () throws -> Void) throws -> SevenZipSplitRecoveryOutcome {
        let staging = try SevenZipSplitStaging(recovering: journal, directory: directory)
        try check()
        if staging.record.state == "committed" {
            return .committed(SevenZipSplitCreationReport(publishedURLs: staging.record.parts.map { staging.record.parent.appendingPathComponent($0.name) }, journal: journal, retainedStaging: staging.record.stagingRemoved ? nil : staging.staging))
        }
        if staging.record.state == "rolledBack" && staging.record.stagingRemoved { return .rolledBack }
        guard staging.record.state != "building", staging.record.intent == nil else { throw staging.review() }
        if staging.record.state == "discarding" {
            // Interrupted private-file deletion has no published outputs; missing own files are expected.
            guard staging.record.parts.allSatisfy({ !$0.moved }) else { throw staging.review() }
            for index in staging.record.parts.indices where !staging.absent(staging.rootFD, name: staging.record.parts[index].name) {
                let fd = try staging.openPart(index, at: staging.rootFD, check: check); Darwin.close(fd)
            }
            let allowed = Set(["lock"] + staging.record.parts.map(\.name))
            guard Set(try FileManager.default.contentsOfDirectory(atPath: staging.staging.path)).isSubset(of: allowed) else { throw staging.review() }
            try staging.discardPrivate(); return .rolledBack
        }
        do { try staging.rollback(); return .rolledBack }
        catch { throw staging.review() }
    }
}
