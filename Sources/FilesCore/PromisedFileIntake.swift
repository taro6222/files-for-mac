import Foundation
import CryptoKit
import Darwin

public enum PromisedFileIntakeError: Error, Equatable, Hashable, Sendable {
    case invalidLocation, invalidManifest, changedRoot, changedItem, noVerifiedCopy, unknownContents
}

/// Durable ownership boundary for incoming promises. File-system methods run off the UI thread.
/// Received data is retained; deinitialization never deletes it.
public final class PromisedFileIntake: @unchecked Sendable {
    private struct Delivery: Codable, Equatable {
        let operationID: UUID
        let target: URL
        let identity: String
        let fingerprint: [String: String]
        let metadata: CopyTransferMetadata
    }
    private struct Item: Codable, Equatable {
        let name: String
        let identity: String
        let fingerprint: [String: String]
        let metadata: CopyTransferMetadata
        let receivedAt: Date
        var copies: [Delivery]? // Absent in receipts written before verified cleanup was introduced.
    }
    private struct Header: Codable {
        let version: Int
        let directoryIdentity: String
        let receivingIdentity: String
        let receiptsIdentity: String
    }
    static let manifestName = "receipt.json"
    public let directoryURL: URL
    public let receivingDirectory: URL
    private let receiptsDirectory: URL
    private let header: Header
    private let headerData: Data
    private let headerIdentity: String
    private let processing = NSLock()
    private let state = NSLock()
    private var items: [String: Item] = [:]
    private var order: [String] = []

    public init(storageDirectory: URL) throws {
        guard storageDirectory.isFileURL else { throw PromisedFileIntakeError.invalidLocation }
        let fm = FileManager.default
        let storage = storageDirectory.resolvingSymlinksInPath().standardizedFileURL
        try fm.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directoryURL = storage.appendingPathComponent("promise-\(UUID())", isDirectory: true)
        receivingDirectory = directoryURL.appendingPathComponent("Files", isDirectory: true)
        receiptsDirectory = directoryURL.appendingPathComponent("Receipts", isDirectory: true)
        for directory in [directoryURL, receivingDirectory, receiptsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        header = Header(version: 1, directoryIdentity: try Self.directoryIdentity(directoryURL),
                        receivingIdentity: try Self.directoryIdentity(receivingDirectory),
                        receiptsIdentity: try Self.directoryIdentity(receiptsDirectory))
        headerData = try JSONEncoder().encode(header)
        let url = directoryURL.appendingPathComponent(Self.manifestName)
        try headerData.write(to: url, options: .atomic)
        headerIdentity = try Self.fileIdentity(url)
        try requireOwnedDirectories()
    }

    public init(recovering directory: URL) throws {
        guard directory.isFileURL else { throw PromisedFileIntakeError.invalidLocation }
        directoryURL = directory.standardizedFileURL
        receivingDirectory = directoryURL.appendingPathComponent("Files", isDirectory: true)
        receiptsDirectory = directoryURL.appendingPathComponent("Receipts", isDirectory: true)
        let rootIdentity = try Self.directoryIdentity(directoryURL)
        let url = directoryURL.appendingPathComponent(Self.manifestName)
        headerIdentity = try Self.fileIdentity(url)
        do {
            headerData = try Data(contentsOf: url)
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch { throw PromisedFileIntakeError.invalidManifest }
        guard header.version == 1, header.directoryIdentity == rootIdentity else { throw PromisedFileIntakeError.invalidManifest }
        try requireOwnedDirectories()
        let urls = try FileManager.default.contentsOfDirectory(at: receiptsDirectory, includingPropertiesForKeys: nil)
        var recovered: [Item] = []
        for url in urls where url.pathExtension == "json" {
            let key = url.deletingPathExtension().lastPathComponent
            guard key.count == 64, key.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
            let item = try Self.readItem(url)
            guard Self.receiptKey(item.name) == key else { throw PromisedFileIntakeError.invalidManifest }
            recovered.append(item)
        }
        for item in recovered.sorted(by: { $0.receivedAt == $1.receivedAt ? $0.name < $1.name : $0.receivedAt < $1.receivedAt }) {
            guard items[item.name] == nil else { throw PromisedFileIntakeError.invalidManifest }
            items[item.name] = item; order.append(item.name)
        }
        try requireOwnedDirectories()
    }

    public var itemCount: Int { state.withLock { items.count } }
    public var receivedNames: [String] { state.withLock { order } }
    /// A recorded publication is a cleanup candidate, never proof that its target is still valid.
    public var copiedItemCount: Int { state.withLock { items.values.filter { $0.copies?.isEmpty == false }.count } }

    /// Called within the receiver's coordinated read after its item is available.
    public func registerReceivedFile(_ url: URL, cancellation: CopyCancellation = CopyCancellation()) throws {
        try processing.withLock {
            try cancellation.check()
            try requireOwnedDirectories()
            guard url.isFileURL else { throw PromisedFileIntakeError.invalidLocation }
            let itemURL = url.standardizedFileURL
            guard itemURL.deletingLastPathComponent().resolvingSymlinksInPath() == receivingDirectory.resolvingSymlinksInPath(),
                  itemURL.path != receivingDirectory.path else { throw PromisedFileIntakeError.invalidLocation }
            try EntryOperations.validateName(itemURL.lastPathComponent)
            let local = receivingDirectory.appendingPathComponent(itemURL.lastPathComponent)
            guard let identity = LocalEntryIdentity.read(local) else { throw PromisedFileIntakeError.changedItem }
            let snapshot = try CopyEngine.makeSnapshot(local, cancellation: cancellation)
            guard LocalEntryIdentity.read(local) == identity else { throw PromisedFileIntakeError.changedItem }
            try requireOwnedDirectories()
            let item = Item(name: itemURL.lastPathComponent, identity: identity,
                            fingerprint: snapshot.withPermissions, metadata: snapshot.metadata, receivedAt: Date(), copies: nil)
            let record = receiptsDirectory.appendingPathComponent(Self.receiptKey(item.name) + ".json")
            let cached = state.withLock { items[item.name] }
            let previous = try cached ?? Self.optionalItem(record)
            if let previous {
                guard previous.identity == item.identity, previous.fingerprint == item.fingerprint,
                      previous.metadata == item.metadata else { throw PromisedFileIntakeError.changedItem }
                cache(previous)
                return
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(item).write(to: record, options: .atomic)
            try requireOwnedDirectories()
            cache(item)
        }
    }

    /// Recheck the delivered identity, contents and metadata before scheduling its copy.
    public func verifiedSources(cancellation: CopyCancellation = CopyCancellation()) throws -> [URL] {
        try processing.withLock {
            try cancellation.check()
            try requireOwnedDirectories()
            let current = state.withLock { order.compactMap { items[$0] } }
            var result: [URL] = []
            for item in current {
                let url = receivingDirectory.appendingPathComponent(item.name)
                guard LocalEntryIdentity.read(url) == item.identity else { throw PromisedFileIntakeError.changedItem }
                let snapshot = try CopyEngine.makeSnapshot(url, cancellation: cancellation)
                guard snapshot.withPermissions == item.fingerprint, snapshot.metadata == item.metadata,
                      LocalEntryIdentity.read(url) == item.identity else { throw PromisedFileIntakeError.changedItem }
                result.append(url)
            }
            try requireOwnedDirectories()
            return result
        }
    }

    private func cache(_ item: Item) {
        state.withLock {
            if items[item.name] == nil { order.append(item.name) }
            items[item.name] = item
        }
    }
    static func validate(_ url: URL, snapshot: CopyEngine.VerificationSnapshot, in intakes: [PromisedFileIntake]) throws {
        guard !intakes.isEmpty else { return }
        guard let intake = intakes.first(where: { url.deletingLastPathComponent().standardizedFileURL == $0.receivingDirectory }) else {
            throw PromisedFileIntakeError.invalidLocation
        }
        try intake.validateSource(url, snapshot: snapshot)
    }
    func validateSource(_ url: URL, snapshot: CopyEngine.VerificationSnapshot) throws {
        try processing.withLock {
            try requireOwnedDirectories()
            let item = state.withLock { items[url.lastPathComponent] }
            guard let item, url.standardizedFileURL == receivingDirectory.appendingPathComponent(item.name),
                  LocalEntryIdentity.read(url) == item.identity,
                  snapshot.withPermissions == item.fingerprint, snapshot.metadata == item.metadata else {
                throw PromisedFileIntakeError.changedItem
            }
        }
    }
    private func requireOwnedDirectories(at root: URL? = nil) throws {
        let root = root ?? directoryURL
        let url = root.appendingPathComponent(Self.manifestName)
        guard (try? Self.directoryIdentity(root)) == header.directoryIdentity,
              (try? Self.directoryIdentity(root.appendingPathComponent("Files"))) == header.receivingIdentity,
              (try? Self.directoryIdentity(root.appendingPathComponent("Receipts"))) == header.receiptsIdentity,
              (try? Self.fileIdentity(url)) == headerIdentity,
              (try? Data(contentsOf: url)) == headerData else { throw PromisedFileIntakeError.changedRoot }
    }
    // Called only with the copy engine's already verified publication. Cleanup always rehashes.
    func recordVerifiedCopy(source: URL, sourceSnapshot: CopyEngine.VerificationSnapshot,
                            record: CopyRecord, operationID: UUID) throws {
        try processing.withLock {
            try requireOwnedDirectories()
            guard source.standardizedFileURL == receivingDirectory.appendingPathComponent(source.lastPathComponent),
                  let cached = state.withLock({ items[source.lastPathComponent] }),
                  record.state == "completed", let identity = record.targetIdentity,
                  let fingerprint = record.targetSnapshot, let metadata = record.targetMetadata,
                  isExternalTarget(record.target) else { throw PromisedFileIntakeError.invalidLocation }
            let receipt = receiptsDirectory.appendingPathComponent(Self.receiptKey(cached.name) + ".json")
            var item = try Self.readItem(receipt)
            guard item.identity == cached.identity, item.fingerprint == cached.fingerprint, item.metadata == cached.metadata,
                  sourceSnapshot.withPermissions == item.fingerprint, sourceSnapshot.metadata == item.metadata,
                  LocalEntryIdentity.read(source) == item.identity else { throw PromisedFileIntakeError.changedItem }
            guard (try? CopyEngine.entryIdentity(record.target)) == identity,
                  let stableIdentity = LocalEntryIdentity.read(record.target),
                  (try? CopyEngine.entryIdentity(record.target)) == identity else { throw PromisedFileIntakeError.changedItem }
            let delivery = Delivery(operationID: operationID, target: record.target, identity: stableIdentity,
                                    fingerprint: fingerprint, metadata: metadata)
            var copies = item.copies ?? []
            copies.removeAll { $0.target == delivery.target && $0.identity == delivery.identity }
            copies.append(delivery); item.copies = copies
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(item).write(to: receipt, options: .atomic)
            try requireOwnedDirectories(); cache(item)
        }
    }

    private func isExternalTarget(_ target: URL) -> Bool {
        guard target.isFileURL else { return false }
        let target = target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).path
        let storage = directoryURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        return target != storage && !target.hasPrefix(storage + "/")
    }

    private func verifiedCleanupItems(at root: URL, cancellation: CopyCancellation) throws -> [Item] {
        try cancellation.check(); try requireOwnedDirectories(at: root)
        let current = state.withLock { order.compactMap { items[$0] } }
        guard !current.isEmpty else { throw PromisedFileIntakeError.noVerifiedCopy }
        let fm = FileManager.default
        let names: (URL) throws -> Set<String> = { Set(try fm.contentsOfDirectory(atPath: $0.path)) }
        let files = root.appendingPathComponent("Files"), receipts = root.appendingPathComponent("Receipts")
        guard try names(root) == Set([Self.manifestName, "Files", "Receipts"]),
              try names(files) == Set(current.map(\.name)),
              try names(receipts) == Set(current.map { Self.receiptKey($0.name) + ".json" }) else {
            throw PromisedFileIntakeError.unknownContents
        }
        var verified: [Item] = []
        for cached in current {
            try cancellation.check()
            let item = try Self.readItem(receipts.appendingPathComponent(Self.receiptKey(cached.name) + ".json"))
            guard item.name == cached.name, item.identity == cached.identity,
                  item.fingerprint == cached.fingerprint, item.metadata == cached.metadata else { throw PromisedFileIntakeError.changedItem }
            let source = files.appendingPathComponent(item.name)
            guard LocalEntryIdentity.read(source) == item.identity else { throw PromisedFileIntakeError.changedItem }
            let original = try CopyEngine.makeSnapshot(source, cancellation: cancellation)
            guard original.withPermissions == item.fingerprint, original.metadata == item.metadata,
                  LocalEntryIdentity.read(source) == item.identity else { throw PromisedFileIntakeError.changedItem }
            var backedUp = false
            for copy in (item.copies ?? []).reversed() {
                try cancellation.check()
                guard isExternalTarget(copy.target), LocalEntryIdentity.read(copy.target) == copy.identity else { continue }
                do {
                    let target = try CopyEngine.makeSnapshot(copy.target, cancellation: cancellation)
                    guard LocalEntryIdentity.read(copy.target) == copy.identity,
                          target.withPermissions == copy.fingerprint, target.metadata.matchesRecorded(copy.metadata) else { continue }
                    try target.verifyTransferredContents(of: original)
                    backedUp = true; break
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            guard backedUp else { throw PromisedFileIntakeError.noVerifiedCopy }
            verified.append(item)
        }
        try requireOwnedDirectories(at: root)
        // Recheck unknown arrivals after the possibly long source/target verification.
        guard try names(files) == Set(current.map(\.name)),
              try names(receipts) == Set(current.map { Self.receiptKey($0.name) + ".json" }),
              try names(root) == Set([Self.manifestName, "Files", "Receipts"]) else { throw PromisedFileIntakeError.unknownContents }
        return verified
    }

    /// Run outside the UI thread. Never permanently deletes any received data.
    public func moveVerifiedCopiesToTrash(journalDirectory: URL, cancellation: CopyCancellation = CopyCancellation()) throws -> PromisedFileCleanupResult {
        try moveVerifiedCopiesToTrash(journalDirectory: journalDirectory, cancellation: cancellation) { root in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: root, resultingItemURL: &trashed)
            guard let trashed else { throw PromisedFileIntakeError.changedRoot }
            return trashed as URL
        }
    }

    // The injected move permits deterministic race/failure tests using only fixture directories.
    func moveVerifiedCopiesToTrash(journalDirectory: URL, cancellation: CopyCancellation = CopyCancellation(),
                                   trash: (URL) throws -> URL) throws -> PromisedFileCleanupResult {
        try processing.withLock {
            _ = try verifiedCleanupItems(at: directoryURL, cancellation: cancellation)
            let journal = journalDirectory.appendingPathComponent("promise-cleanup-\(UUID()).json")
            guard isExternalTarget(journal) else { throw PromisedFileIntakeError.invalidLocation }
            let fm = FileManager.default
            try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            var result = PromisedFileCleanupResult(original: directoryURL, retainedAt: directoryURL, state: "verified", message: nil, journal: journal)
            func save() throws { try JSONEncoder().encode(result).write(to: journal, options: .atomic) }
            try save(); try cancellation.check(); try requireOwnedDirectories()
            let trashed: URL
            do { trashed = try trash(directoryURL) }
            catch {
                let retained = LocalEntryIdentity.read(directoryURL) == header.directoryIdentity
                result.state = retained ? "retained" : "needsReview"
                result.retainedAt = retained ? directoryURL : nil
                result.message = error.localizedDescription; try? save()
                return result
            }
            result.retainedAt = trashed; result.state = "movedToTrash"
            do {
                try save()
                _ = try verifiedCleanupItems(at: trashed, cancellation: cancellation)
                result.state = "trashed"; try save()
                return result
            } catch {
                let reason = error.localizedDescription
                result.state = "needsReview"; result.message = reason
                if LocalEntryIdentity.read(trashed) != header.directoryIdentity {
                    result.retainedAt = LocalEntryIdentity.read(directoryURL) == header.directoryIdentity ? directoryURL : nil
                }
                // Restore only our unchanged directory identity, with atomic no-overwrite rename.
                if LocalEntryIdentity.read(trashed) == header.directoryIdentity {
                    let from = open(trashed.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    let to = open(directoryURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    defer { if from >= 0 { close(from) }; if to >= 0 { close(to) } }
                    if from >= 0, to >= 0 {
                        do {
                            try CopyEngine.publishNoReplace(payload: trashed, target: directoryURL,
                                sourceDirectoryFD: from, sourceName: trashed.lastPathComponent,
                                destinationDirectoryFD: to, destinationName: directoryURL.lastPathComponent, allowPathFallback: false)
                            if LocalEntryIdentity.read(directoryURL) == header.directoryIdentity {
                                result.retainedAt = directoryURL; result.state = "restored"
                            } else {
                                // The opened parent may have been renamed by another process.
                                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                                if fcntl(to, F_GETPATH, &path) == 0 {
                                    let actual = URL(fileURLWithPath: String(cString: path)).appendingPathComponent(directoryURL.lastPathComponent)
                                    result.retainedAt = LocalEntryIdentity.read(actual) == header.directoryIdentity ? actual : nil
                                } else { result.retainedAt = nil }
                            }
                        } catch { result.message = reason + "; " + error.localizedDescription }
                    }
                }
                try? save()
                return result
            }
        }
    }

    private static func optionalItem(_ url: URL) throws -> Item? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return try readItem(url) }
        guard errno == ENOENT else { throw PromisedFileIntakeError.invalidManifest }
        return nil
    }
    private static func readItem(_ url: URL) throws -> Item {
        do {
            let before = try fileIdentity(url)
            let item = try JSONDecoder().decode(Item.self, from: Data(contentsOf: url))
            try EntryOperations.validateName(item.name)
            guard try fileIdentity(url) == before else { throw PromisedFileIntakeError.invalidManifest }
            return item
        } catch { throw PromisedFileIntakeError.invalidManifest }
    }
    private static func receiptKey(_ name: String) -> String {
        SHA256.hash(data: Data(name.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func fileIdentity(_ url: URL) throws -> String {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
              let identity = LocalEntryIdentity.read(url) else { throw PromisedFileIntakeError.invalidManifest }
        return identity
    }
    private static func directoryIdentity(_ url: URL) throws -> String {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory,
              let identity = LocalEntryIdentity.read(url) else { throw PromisedFileIntakeError.changedRoot }
        return identity
    }
}

public struct PromisedFileCleanupResult: Codable, Sendable {
    public let original: URL
    public var retainedAt: URL?
    public var state: String
    public var message: String?
    public let journal: URL
}
