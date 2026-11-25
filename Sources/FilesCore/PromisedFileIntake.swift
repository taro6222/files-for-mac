import Foundation
import CryptoKit
import Darwin

public enum PromisedFileIntakeError: Error, Equatable, Sendable {
    case invalidLocation, invalidManifest, changedRoot, changedItem
}

/// Durable ownership boundary for incoming promises. File-system methods run off the UI thread.
/// Received data is retained; deinitialization never deletes it.
public final class PromisedFileIntake: @unchecked Sendable {
    private struct Item: Codable {
        let name: String
        let identity: String
        let fingerprint: [String: String]
        let metadata: CopyTransferMetadata
        let receivedAt: Date
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
                            fingerprint: snapshot.withPermissions, metadata: snapshot.metadata, receivedAt: Date())
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
    private func requireOwnedDirectories() throws {
        let url = directoryURL.appendingPathComponent(Self.manifestName)
        guard (try? Self.directoryIdentity(directoryURL)) == header.directoryIdentity,
              (try? Self.directoryIdentity(receivingDirectory)) == header.receivingIdentity,
              (try? Self.directoryIdentity(receiptsDirectory)) == header.receiptsIdentity,
              (try? Self.fileIdentity(url)) == headerIdentity,
              (try? Data(contentsOf: url)) == headerData else { throw PromisedFileIntakeError.changedRoot }
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
