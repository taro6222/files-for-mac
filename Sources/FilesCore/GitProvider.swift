import Foundation

private final class GitProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func install(_ process: Process) { lock.lock(); self.process = process; let stop = cancelled; lock.unlock(); if stop && process.isRunning { process.terminate() } }
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); if process?.isRunning == true { process?.terminate() } }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class GitDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) { lock.lock(); self.data = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

public enum GitBackendError: Error, Sendable, Equatable {
    case gitUnavailable, invalidLocation, notRepository, commandFailed(Int32), invalidOutput, outputLimitExceeded
}

public struct GitStatusEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case ordinary, renamed, unmerged, untracked }
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let workTreeStatus: Character
    public let kind: Kind
    public var id: String { path }
    public var statusCode: String { String([indexStatus, workTreeStatus]) }
}

public struct GitRepositorySnapshot: Sendable, Equatable {
    public let root: URL
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let entries: [GitStatusEntry]
}

public struct GitBranch: Sendable, Equatable, Identifiable {
    public let name: String
    public let upstream: String?
    public var id: String { name }
}

public struct GitRemote: Sendable, Equatable, Identifiable {
    public let name: String
    public let url: String
    public var id: String { name }
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
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { throw GitBackendError.invalidOutput }
                entries.append(try entry(path: String(fields[8]), originalPath: nil, xy: fields[1], kind: .ordinary))
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, index + 1 < records.count else { throw GitBackendError.invalidOutput }
                entries.append(try entry(path: String(fields[9]), originalPath: records[index + 1], xy: fields[1], kind: .renamed)); index += 1
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { throw GitBackendError.invalidOutput }
                entries.append(try entry(path: String(fields[10]), originalPath: nil, xy: fields[1], kind: .unmerged))
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
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GitBackendError.invalidOutput
        }
    }
}

public struct GitFileCommit: Sendable, Equatable {
    public let date: Date
    public let subject: String
    public let author: String
    public let sha: String
}

public struct GitProvider: Sendable {
    private let executable: URL
    public init() { executable = URL(fileURLWithPath: "/usr/bin/git") }
    init(executable: URL) { self.executable = executable }
    public func lastCommit(for file: URL, in repository: URL) async throws -> GitFileCommit? {
        let root = repository.resolvingSymlinksInPath().path
        let path = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.isFileURL, repository.isFileURL, path.hasPrefix(prefix), path.count > prefix.count else {
            throw GitBackendError.invalidLocation
        }
        let relative = String(path.dropFirst(prefix.count))
        let base = ["--literal-pathspecs", "-C", root]
        let tracked = try await run(base + ["ls-tree", "-z", "HEAD", "--", relative], at: repository)
        guard !tracked.isEmpty else { return nil }
        let data = try await run(base + ["-c", "log.showSignature=false", "log", "-1", "--no-notes",
            "--format=%H%x00%ct%x00%an%x00%s%x00", "HEAD", "--", relative], at: repository)
        guard !data.isEmpty else { return nil }
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 5, [40, 64].contains(fields[0].count),
              fields[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let seconds = Int64(fields[1]) else { throw GitBackendError.invalidOutput }
        return GitFileCommit(date: Date(timeIntervalSince1970: Double(seconds)), subject: String(fields[3]),
                             author: String(fields[2]), sha: String(fields[0]))
    }
    public func snapshot(at location: URL, fileManager: FileManager = .default) async throws -> GitRepositorySnapshot {
        guard location.isFileURL, fileManager.fileExists(atPath: location.path), fileManager.isExecutableFile(atPath: executable.path) else {
            throw fileManager.isExecutableFile(atPath: executable.path) ? GitBackendError.invalidLocation : GitBackendError.gitUnavailable
        }
        let rootResult = try await run(["-C", location.path, "rev-parse", "--show-toplevel"], at: location)
        // rev-parse appends one LF. Other trailing whitespace can be part of the path.
        guard rootResult.last == 0x0a,
              let rootPath = String(data: rootResult.dropLast(), encoding: .utf8), rootPath.hasPrefix("/") else {
            throw GitBackendError.notRepository
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let status = try await run(["-C", root.path, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], at: root)
        return try GitStatusParser().parse(status, root: root)
    }
    public func branches(at repository: URL) async throws -> [GitBranch] {
        let data = try await run(["-C", repository.path, "for-each-ref", "--format=%(refname:short)%09%(upstream:short)", "refs/heads"], at: repository)
        guard let text = String(data: data, encoding: .utf8) else { throw GitBackendError.invalidOutput }
        return try text.split(whereSeparator: \Character.isNewline).map { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = fields.first.map(String.init), !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw GitBackendError.invalidOutput }
            let upstream = fields.count == 2 && !fields[1].isEmpty ? String(fields[1]) : nil
            return GitBranch(name: name, upstream: upstream)
        }
    }
    public func remotes(at repository: URL) async throws -> [GitRemote] {
        let namesData = try await run(["-C", repository.path, "remote"], at: repository)
        guard let text = String(data: namesData, encoding: .utf8) else { throw GitBackendError.invalidOutput }
        var result: [GitRemote] = []
        for nameValue in text.split(whereSeparator: \Character.isNewline) {
            let name = String(nameValue)
            guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw GitBackendError.invalidOutput }
            let urlData = try await run(["-C", repository.path, "remote", "get-url", "--", name], at: repository)
            guard let url = String(data: urlData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { throw GitBackendError.invalidOutput }
            result.append(.init(name: name, url: url))
        }
        return result
    }
    public func clone(from source: URL, to destination: URL, fileManager: FileManager = .default) async throws -> URL {
        guard source.isFileURL || (["https", "ssh"].contains(source.scheme?.lowercased() ?? "") && source.user == nil && source.password == nil),
              destination.isFileURL, !fileManager.fileExists(atPath: destination.path) else { throw GitBackendError.invalidLocation }
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard fileManager.fileExists(atPath: parent.path) else { throw GitBackendError.invalidLocation }
        let staging = parent.appendingPathComponent(".files-git-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        _ = try await run(["clone", "--", source.absoluteString, staging.path], at: parent)
        do { try fileManager.moveItem(at: staging, to: destination) }
        catch { if fileManager.fileExists(atPath: destination.path) { throw GitBackendError.invalidLocation }; throw error }
        return destination
    }
    public func initialize(at location: URL, fileManager: FileManager = .default) async throws -> GitRepositorySnapshot {
        var isDirectory: ObjCBool = false
        guard location.isFileURL, fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitBackendError.invalidLocation
        }
        _ = try await run(["-C", location.path, "init"], at: location)
        return try await snapshot(at: location, fileManager: fileManager)
    }
    public func fetch(at repository: URL, remote: String = "origin") async throws {
        try validateRemoteName(remote); _ = try await run(["-C", repository.path, "fetch", "--prune", "--", remote], at: repository)
    }
    public func pullFastForwardOnly(at repository: URL) async throws {
        _ = try await run(["-C", repository.path, "pull", "--no-rebase", "--ff-only"], at: repository)
    }
    public func push(at repository: URL, remote: String = "origin", branch: String? = nil) async throws {
        let source = try await localBranchRef(branch, at: repository)
        try await pushBranch(at: repository, remote: remote, source: source, destination: source)
    }
    public func synchronize(at repository: URL) async throws -> GitRepositorySnapshot {
        let initial = try await snapshot(at: repository)
        let source = try await localBranchRef(nil, at: initial.root)
        let output = try await run(["-C", initial.root.path, "for-each-ref",
            "--format=%(refname)%09%(upstream:remotename)%09%(upstream:remoteref)%09%(upstream)", source], at: initial.root)
        guard let text = String(data: output, encoding: .utf8) else { throw GitBackendError.invalidOutput }
        let fields = text.split(separator: "\n").first { $0.hasPrefix(source + "\t") }?
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard let fields, fields.count == 4, fields[2].hasPrefix("refs/heads/"), fields[3].hasPrefix("refs/") else {
            throw GitBackendError.invalidLocation
        }
        let remote = String(fields[1]), destination = String(fields[2])
        try validateRemoteName(remote)
        try await fetch(at: initial.root, remote: remote)
        guard try await localBranchRef(nil, at: initial.root) == source else { throw GitBackendError.invalidLocation }
        _ = try await run(["-C", initial.root.path, "merge", "--ff-only", "--no-autostash", "--", String(fields[3])],
            at: initial.root)
        guard try await localBranchRef(nil, at: initial.root) == source else { throw GitBackendError.invalidLocation }
        try await pushBranch(at: initial.root, remote: remote, source: source, destination: destination)
        return try await snapshot(at: initial.root)
    }
    private func localBranchRef(_ branch: String?, at repository: URL) async throws -> String {
        let ref: String
        if let branch {
            guard !branch.hasPrefix("-") else { throw GitBackendError.invalidLocation }
            ref = "refs/heads/" + branch
        } else {
            let output: Data
            do {
                output = try await run(["-C", repository.path, "symbolic-ref", "--quiet", "HEAD"], at: repository)
            } catch GitBackendError.commandFailed(1) {
                throw GitBackendError.invalidLocation
            }
            ref = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        guard ref.hasPrefix("refs/heads/") else { throw GitBackendError.invalidLocation }
        do {
            _ = try await run(["check-ref-format", ref], at: repository)
        } catch GitBackendError.commandFailed {
            throw GitBackendError.invalidLocation
        }
        return ref
    }
    private func pushBranch(at repository: URL, remote: String, source: String, destination: String) async throws {
        try validateRemoteName(remote)
        _ = try await run(["-C", repository.path, "-c", "remote.\(remote).mirror=false",
            "push", "--porcelain", "--no-follow-tags", "--", remote, "\(source):\(destination)"], at: repository)
    }
    private func validateRemoteName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { throw GitBackendError.invalidLocation }
    }
    private func run(_ arguments: [String], at directory: URL, outputLimit: Int = 4 * 1_024 * 1_024) async throws -> Data {
        let box = GitProcessBox()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try Self.runSynchronously(executable: executable, arguments: arguments, directory: directory, outputLimit: outputLimit, box: box)
            }.value
        }, onCancel: { box.cancel() })
    }
    private static func runSynchronously(executable: URL, arguments: [String], directory: URL, outputLimit: Int, box: GitProcessBox) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment; environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"; process.environment = environment
        process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { throw GitBackendError.gitUnavailable }
        box.install(process)
        let group = DispatchGroup(), stdoutBox = GitDataBox(), stderrBox = GitDataBox()
        group.enter(); DispatchQueue.global().async { stdoutBox.set(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter(); DispatchQueue.global().async { stderrBox.set(errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        process.waitUntilExit(); group.wait()
        if box.wasCancelled { throw CancellationError() }
        let stdout = stdoutBox.get(), stderr = stderrBox.get()
        guard stdout.count + stderr.count <= outputLimit else { throw GitBackendError.outputLimitExceeded }
        guard process.terminationStatus == 0 else {
            if arguments.contains("rev-parse") { throw GitBackendError.notRepository }
            throw GitBackendError.commandFailed(process.terminationStatus)
        }
        return stdout
    }
}
