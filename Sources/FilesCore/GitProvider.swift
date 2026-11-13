import Foundation

public enum GitBackendError: Error, Sendable, Equatable {
    case gitUnavailable, invalidLocation, notRepository, commandFailed(Int32), invalidOutput, outputLimitExceeded
}

public struct GitStatusEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case ordinary, renamed, untracked }
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let workTreeStatus: Character
    public let kind: Kind
    public var id: String { path }
}

public struct GitRepositorySnapshot: Sendable, Equatable {
    public let root: URL
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let entries: [GitStatusEntry]
}

public struct GitStatusParser: Sendable {
    public init() {}
    public func parse(_ data: Data, root: URL) throws -> GitRepositorySnapshot {
        guard let text = String(data: data, encoding: .utf8) else { throw GitBackendError.invalidOutput }
        let records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branch: String?, upstream: String?, ahead = 0, behind = 0, entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst(14)); branch = value == "(detached)" ? nil : value
            } else if record.hasPrefix("# branch.upstream ") {
                upstream = String(record.dropFirst(18))
            } else if record.hasPrefix("# branch.ab ") {
                let values = record.dropFirst(12).split(separator: " ")
                for value in values {
                    if value.hasPrefix("+") { ahead = Int(value.dropFirst()) ?? 0 }
                    if value.hasPrefix("-") { behind = Int(value.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard fields.count == 9 else { throw GitBackendError.invalidOutput }
                entries.append(try entry(path: String(fields[8]), originalPath: nil, xy: fields[1], kind: .ordinary))
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
                guard fields.count == 10, index + 1 < records.count else { throw GitBackendError.invalidOutput }
                entries.append(try entry(path: String(fields[9]), originalPath: records[index + 1], xy: fields[1], kind: .renamed)); index += 1
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2)); try validate(path)
                entries.append(.init(path: path, originalPath: nil, indexStatus: "?", workTreeStatus: "?", kind: .untracked))
            } else if !record.hasPrefix("# ") && !record.hasPrefix("! ") { throw GitBackendError.invalidOutput }
            index += 1
        }
        return .init(root: root.standardizedFileURL, branch: branch, upstream: upstream, ahead: ahead, behind: behind, entries: entries)
    }
    private func entry(path: String, originalPath: String?, xy: Substring, kind: GitStatusEntry.Kind) throws -> GitStatusEntry {
        guard xy.count == 2 else { throw GitBackendError.invalidOutput }; try validate(path); if let originalPath { try validate(originalPath) }
        return .init(path: path, originalPath: originalPath, indexStatus: xy.first!, workTreeStatus: xy.last!, kind: kind)
    }
    private func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t")).contains($0) }) else {
            throw GitBackendError.invalidOutput
        }
    }
}

public struct GitProvider: Sendable {
    private let executable = URL(fileURLWithPath: "/usr/bin/git")
    public init() {}
    public func snapshot(at location: URL, fileManager: FileManager = .default) async throws -> GitRepositorySnapshot {
        guard location.isFileURL, fileManager.fileExists(atPath: location.path), fileManager.isExecutableFile(atPath: executable.path) else {
            throw fileManager.isExecutableFile(atPath: executable.path) ? GitBackendError.invalidLocation : GitBackendError.gitUnavailable
        }
        let rootResult = try await run(["-C", location.path, "rev-parse", "--show-toplevel"], at: location)
        guard let rootPath = String(data: rootResult, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), rootPath.hasPrefix("/") else {
            throw GitBackendError.notRepository
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let status = try await run(["-C", root.path, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], at: root)
        return try GitStatusParser().parse(status, root: root)
    }
    private func run(_ arguments: [String], at directory: URL, outputLimit: Int = 4 * 1_024 * 1_024) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment; environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"; process.environment = environment
            process.standardOutput = output; process.standardError = errors
            do { try process.run() } catch { throw GitBackendError.gitUnavailable }
            let stdout = output.fileHandleForReading.readDataToEndOfFile(), stderr = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard stdout.count + stderr.count <= outputLimit else { throw GitBackendError.outputLimitExceeded }
            guard process.terminationStatus == 0 else {
                if arguments.contains("rev-parse") { throw GitBackendError.notRepository }
                throw GitBackendError.commandFailed(process.terminationStatus)
            }
            return stdout
        }.value
    }
}
