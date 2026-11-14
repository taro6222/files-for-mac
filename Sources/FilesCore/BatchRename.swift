import Foundation
import Darwin

public struct BatchRenameRequest: Sendable {
    public let source: URL
    public let name: String
    public init(source: URL, name: String) { self.source = source; self.name = name }
}

public struct BatchRenameItemResult: Sendable {
    public let source: URL
    public let target: URL
    public let state: String
    public let message: String?
}

public struct BatchRenameResult: Sendable {
    public let id: String
    public let state: String
    public let items: [BatchRenameItemResult]
    public let journalError: String?
}

public enum BatchRenamePattern {
    public static func replacing(_ sources: [URL], find: String, replacement: String) -> [BatchRenameRequest] {
        sources.map { BatchRenameRequest(source: $0, name: $0.lastPathComponent.replacingOccurrences(of: find, with: replacement)) }
    }

    public static func numbered(_ sources: [URL], base: String, start: Int = 1) -> [BatchRenameRequest] {
        sources.enumerated().map { index, source in
            let ext = source.pathExtension
            let suffix = ext.isEmpty ? "" : "." + ext
            return BatchRenameRequest(source: source, name: "\(base) \(start + index)\(suffix)")
        }
    }

    public static func regularExpression(_ sources: [URL], pattern: String,
                                         replacement: String) throws -> [BatchRenameRequest] {
        let expression = try NSRegularExpression(pattern: pattern)
        return sources.map { source in
            let name = source.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return BatchRenameRequest(source: source,
                name: expression.stringByReplacingMatches(in: name, range: range, withTemplate: replacement))
        }
    }
}

public extension EntryOperations {
    static func batchRename(_ requests: [BatchRenameRequest], journalDirectory: URL) async throws -> BatchRenameResult {
        guard !requests.isEmpty else { throw EntryOperationError.noSources }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
            let id = UUID().uuidString
            let parents = Set(requests.map { $0.source.deletingLastPathComponent().standardizedFileURL })
            guard parents.count == 1, let parent = parents.first else { throw EntryOperationError.sourceChanged }
            let journalURL = journalDirectory.appendingPathComponent("batch-rename-\(id).json")
            var results = requests.map {
                BatchRenameItemResult(source: $0.source.standardizedFileURL,
                    target: parent.appendingPathComponent($0.name), state: "planned", message: nil)
            }
            var journalError: String?
            struct Item: Encodable { let source: URL; let target: URL; let state: String; let message: String? }
            struct Journal: Encodable { let version = 1; let operation = "batchRename"; let id: String; let state: String; let items: [Item] }
            func save(_ state: String) throws {
                try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(Journal(id: id, state: state, items: results.map {
                    Item(source: $0.source, target: $0.target, state: $0.state, message: $0.message)
                })).write(to: journalURL, options: .atomic)
            }
            try save("planned")

            let sourcePaths = Set(results.map { $0.source.path })
            var targetNames = Set<String>()
            var invalid = false
            for index in requests.indices {
                do { try validateName(requests[index].name) } catch {
                    results[index] = BatchRenameItemResult(source: results[index].source, target: results[index].target,
                        state: "invalid", message: "유효하지 않은 이름입니다."); invalid = true; continue
                }
                if !targetNames.insert(requests[index].name).inserted {
                    results[index] = BatchRenameItemResult(source: results[index].source, target: results[index].target,
                        state: "conflict", message: "계획 안에 중복된 이름이 있습니다."); invalid = true
                } else if exists(results[index].target), !sourcePaths.contains(results[index].target.path) {
                    results[index] = BatchRenameItemResult(source: results[index].source, target: results[index].target,
                        state: "conflict", message: "선택하지 않은 기존 항목과 이름이 충돌합니다."); invalid = true
                } else if !exists(results[index].source) {
                    results[index] = BatchRenameItemResult(source: results[index].source, target: results[index].target,
                        state: "notFound", message: "원본 항목이 없습니다."); invalid = true
                }
            }
            if invalid { try save("rejected"); return BatchRenameResult(id: id, state: "rejected", items: results, journalError: nil) }

            let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            func rename(_ from: String, to: String) throws {
                try CopyEngine.publishNoReplace(payload: parent.appendingPathComponent(from),
                    target: parent.appendingPathComponent(to), sourceDirectoryFD: fd,
                    sourceName: from, destinationDirectoryFD: fd, destinationName: to)
            }
            var staged: [(index: Int, temporary: String)] = []
            do {
                for index in requests.indices where requests[index].source.lastPathComponent != requests[index].name {
                    let temporary = ".files-rename-\(id)-\(index)"
                    try rename(results[index].source.lastPathComponent, to: temporary)
                    staged.append((index, temporary))
                }
                for entry in staged {
                    try rename(entry.temporary, to: requests[entry.index].name)
                    results[entry.index] = BatchRenameItemResult(source: results[entry.index].source, target: results[entry.index].target,
                        state: "completed", message: nil)
                }
                for index in requests.indices where requests[index].source.lastPathComponent == requests[index].name {
                    results[index] = BatchRenameItemResult(source: results[index].source, target: results[index].target,
                        state: "unchanged", message: nil)
                }
            } catch {
                let failure = error.localizedDescription
                for entry in staged.reversed() where results[entry.index].state == "planned" {
                    let item = results[entry.index]
                    do {
                        try rename(entry.temporary, to: item.source.lastPathComponent)
                    } catch {
                        let temporaryURL = parent.appendingPathComponent(entry.temporary)
                        results[entry.index] = BatchRenameItemResult(source: item.source, target: item.target,
                            state: "failed", message: "\(failure)\n\(temporaryURL.path): \(error.localizedDescription)")
                    }
                }
                for index in results.indices where results[index].state == "planned" {
                    results[index] = BatchRenameItemResult(source: results[index].source, target: results[index].target,
                        state: "failed", message: failure)
                }
                do { try save("failed") } catch { journalError = error.localizedDescription }
                return BatchRenameResult(id: id, state: "failed", items: results, journalError: journalError)
            }
            do { try save("completed") } catch { journalError = error.localizedDescription }
            return BatchRenameResult(id: id, state: "completed", items: results, journalError: journalError)
        }.value
    }
}
