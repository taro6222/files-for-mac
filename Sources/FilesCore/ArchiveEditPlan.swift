import Foundation

/// Operations apply to exact archive paths, with directory changes expanded at component boundaries.
public enum ArchiveEditOperation: Sendable {
    case rename(path: String, newName: String)
    case delete(paths: [String])
    case add(sources: [URL], directory: String)
    case createDirectory(path: String)
}

struct ArchiveEditPlan: Sendable {
    struct Record: Sendable {
        let oldIndex: UInt32?
        let descriptor: ArchiveEntryDescriptor
        let input: SevenZipCreationPlan.Item?
        let syntheticDirectory: Bool
        var request: [String: Any] {
            if let oldIndex { return ["oldIndex": oldIndex, "path": descriptor.path] }
            if let input {
                var value = input.brokerRequest; value["path"] = descriptor.path
                return ["addition": value, "syntheticDirectory": false]
            }
            return ["addition": ["path": descriptor.path, "device": "0", "inode": "0", "size": 0,
                "mode": UInt32(0o40755), "directory": 1, "modifiedSeconds": 0, "modifiedNanos": 0,
                "changedSeconds": 0, "changedNanos": 0], "syntheticDirectory": true]
        }
    }
    let records: [Record]
    let inputs: [Int: SevenZipCreationPlan.Item]
    init(entries: [ArchiveEntryDescriptor], operations: [ArchiveEditOperation], archive: URL, check: () throws -> Void) throws {
        guard !operations.isEmpty, entries.count <= 100_000 else { throw SevenZipWorkerError.invalidConfiguration }
        var records = entries.enumerated().map { Record(oldIndex: UInt32($0.offset), descriptor: $0.element, input: nil, syntheticDirectory: false) }
        func path(_ raw: String, directory: Bool = false) throws -> String {
            try ArchiveExtractionValidator.validate([.init(path: raw, kind: directory ? .directory : .regularFile)])[0].relativePath
        }
        func selected(_ target: String) throws -> (String, Bool) {
            let normalized = try path(target, directory: true)
            guard let record = records.first(where: { $0.descriptor.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalized }) else {
                // Some archives omit explicit directory records.
                guard records.contains(where: { $0.descriptor.path.hasPrefix(normalized + "/") }) else { throw ArchiveValidationError.invalidPath(target) }
                return (normalized, true)
            }
            return (normalized, record.descriptor.kind == .directory)
        }
        for operation in operations {
            try check()
            switch operation {
            case let .rename(target, name):
                let (target, directory) = try selected(target)
                guard !name.contains("/") else { throw ArchiveValidationError.invalidPath(name) }
                let validatedName = try path(name)
                let components = target.split(separator: "/").dropLast()
                let replacement = (components.map(String.init) + [validatedName]).joined(separator: "/")
                records = records.map { record in
                    let old = record.descriptor.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard old == target || (directory && old.hasPrefix(target + "/")) else { return record }
                    let renamed = replacement + String(old.dropFirst(target.count))
                    let descriptor = ArchiveEntryDescriptor(path: renamed, kind: record.descriptor.kind, uncompressedSize: record.descriptor.uncompressedSize, isEncrypted: record.descriptor.isEncrypted)
                    return Record(oldIndex: record.oldIndex, descriptor: descriptor, input: record.input, syntheticDirectory: record.syntheticDirectory)
                }
            case .delete(let paths):
                guard !paths.isEmpty else { throw SevenZipWorkerError.invalidConfiguration }
                let targets = try paths.map(selected)
                records.removeAll { record in targets.contains { target, directory in
                    let name = record.descriptor.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return name == target || (directory && name.hasPrefix(target + "/"))
                } }
            case let .add(sources, directory):
                let prefix = directory.isEmpty ? "" : try path(directory, directory: true) + "/"
                // The creation planner provides no-follow source snapshots and recursive metadata.
                let destination = archive.deletingPathExtension().appendingPathExtension("7z")
                let plan = try SevenZipCreationPlan(sources: sources, destination: destination, check: check)
                for item in plan.items {
                    guard item.url.standardizedFileURL != archive.standardizedFileURL,
                          !item.directory || !archive.path.hasPrefix(item.url.path + "/") else { throw ZipArchiveError.invalidSource(item.url.path) }
                    records.append(Record(oldIndex: nil, descriptor: .init(path: prefix + item.path, kind: item.directory ? .directory : .regularFile, uncompressedSize: item.size), input: item, syntheticDirectory: false))
                }
            case .createDirectory(let raw):
                records.append(Record(oldIndex: nil, descriptor: .init(path: try path(raw, directory: true), kind: .directory), input: nil, syntheticDirectory: true))
            }
            guard records.count <= 100_000 else { throw ArchiveValidationError.tooManyEntries }
            // Opaque existing links are never materialized on the host. Validate names and sizes
            // with a regular-file surrogate, preserving the original kind in the actual plan.
            let validated = try ArchiveExtractionValidator.validate(records.map { .init(path: $0.descriptor.path, kind: $0.descriptor.kind == .directory ? .directory : .regularFile, uncompressedSize: $0.descriptor.uncompressedSize) })
            let kinds = Dictionary(uniqueKeysWithValues: zip(validated, records).map { ($0.0.relativePath.precomposedStringWithCanonicalMapping, $0.1.descriptor.kind) })
            for entry in validated {
                var prefix = ""
                for component in entry.relativePath.split(separator: "/").dropLast() {
                    prefix += (prefix.isEmpty ? "" : "/") + component
                    if let kind = kinds[prefix.precomposedStringWithCanonicalMapping], kind != .directory { throw ArchiveValidationError.invalidPath(entry.relativePath) }
                }
            }
        }
        self.records = records
        inputs = Dictionary(uniqueKeysWithValues: records.enumerated().compactMap { index, record in record.input.map { (index, $0) } })
    }
    func verify(check: () throws -> Void) throws {
        for input in inputs.values { try check(); try input.verify() }
    }
}
