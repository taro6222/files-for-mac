import Foundation

public enum RemoteBackendKind: String, Sendable, Equatable { case curlFTP, openSSH }

public struct RemoteBackendAvailability: Sendable, Equatable {
    public let kind: RemoteBackendKind
    public let executable: URL
    public let protocols: Set<RemoteProtocol>
}

public struct RemoteBackendProbe: Sendable {
    public init() {}
    public func available(fileManager: FileManager = .default) -> [RemoteBackendAvailability] {
        var result: [RemoteBackendAvailability] = []
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        if fileManager.isExecutableFile(atPath: curl.path) {
            result.append(.init(kind: .curlFTP, executable: curl, protocols: [.ftp, .ftps]))
        }
        let sftp = URL(fileURLWithPath: "/usr/bin/sftp")
        if fileManager.isExecutableFile(atPath: sftp.path) {
            result.append(.init(kind: .openSSH, executable: sftp, protocols: [.sftp]))
        }
        return result
    }
}

public enum RemoteTransferIntent: Sendable, Equatable {
    case list, download(local: URL), upload(local: URL)
    case uploadAndRename(local: URL, finalRemotePath: String)
    case delete
}

public enum RemoteBackendError: Error, Sendable, Equatable {
    case unsupportedProtocol, invalidRemotePath, invalidCredential, invalidListing, listingLimitExceeded, destinationExists, invalidStaging, unverifiedServerCapability, invalidUploadSource
}

public struct FTPServerCapabilities: Sendable, Equatable {
    public let renameRefusesExistingDestination: Bool
    public init(renameRefusesExistingDestination: Bool = false) { self.renameRefusesExistingDestination = renameRefusesExistingDestination }
}

public struct RemoteDirectoryEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let remotePath: String
    public var id: String { remotePath }
}

public struct FTPRemoteProvider: Sendable {
    private let builder = CurlFTPCommandBuilder(), executor = RemoteCommandExecutor()
    public init() {}
    public func list(profile: RemoteConnectionProfile, credential: RemoteCredential, remotePath: String,
                     maximumEntries: Int = 100_000) async throws -> [RemoteDirectoryEntry] {
        let plan = try builder.command(profile: profile, credential: credential, remotePath: remotePath, intent: .list)
        let result = try await executor.execute(plan, outputLimit: 4 * 1_024 * 1_024)
        return try Self.parseList(result.standardOutput, parent: remotePath, maximumEntries: maximumEntries)
    }
    public func download(profile: RemoteConnectionProfile, credential: RemoteCredential, remotePath: String,
                         destination: URL, fileManager: FileManager = .default) async throws -> URL {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else { throw RemoteBackendError.destinationExists }
        let staging = parent.appendingPathComponent(".files-download-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        let plan = try builder.command(profile: profile, credential: credential, remotePath: remotePath, intent: .download(local: staging))
        _ = try await executor.execute(plan)
        try Self.publishDownload(staging: staging, destination: destination, fileManager: fileManager)
        return destination
    }
    public func upload(profile: RemoteConnectionProfile, credential: RemoteCredential, source: URL, remotePath: String,
                       capabilities: FTPServerCapabilities) async throws {
        guard capabilities.renameRefusesExistingDestination else { throw RemoteBackendError.unverifiedServerCapability }
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteBackendError.invalidUploadSource }
        let final = remotePath as NSString, parent = final.deletingLastPathComponent
        let staging = (parent as NSString).appendingPathComponent(".files-upload-\(UUID().uuidString).tmp")
        let upload = try builder.command(profile: profile, credential: credential, remotePath: staging,
            intent: .uploadAndRename(local: source, finalRemotePath: remotePath))
        do { _ = try await executor.execute(upload) }
        catch {
            if let cleanup = try? builder.command(profile: profile, credential: credential, remotePath: staging, intent: .delete) {
                _ = try? await executor.execute(cleanup)
            }
            throw error
        }
    }
    public static func publishDownload(staging: URL, destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else { throw RemoteBackendError.destinationExists }
        guard staging.deletingLastPathComponent().standardizedFileURL == parent,
              staging.lastPathComponent.hasPrefix(".files-download-"), staging.pathExtension == "tmp",
              let values = try? staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteBackendError.invalidStaging }
        do { try fileManager.moveItem(at: staging, to: destination) }
        catch { if fileManager.fileExists(atPath: destination.path) { throw RemoteBackendError.destinationExists }; throw error }
    }
    public static func parseList(_ data: Data, parent: String, maximumEntries: Int = 100_000) throws -> [RemoteDirectoryEntry] {
        guard parent.hasPrefix("/"), let text = String(data: data, encoding: .utf8) else { throw RemoteBackendError.invalidListing }
        let names = text.split(whereSeparator: \Character.isNewline).map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard names.count <= maximumEntries else { throw RemoteBackendError.listingLimitExceeded }
        guard names.allSatisfy({ !$0.contains("/") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw RemoteBackendError.invalidListing
        }
        let base = parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return names.map { RemoteDirectoryEntry(name: $0, remotePath: "/" + ([base, $0].filter { !$0.isEmpty }.joined(separator: "/"))) }
    }
}

public struct RemoteCommandPlan: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let standardInput: Data
    public let redactedDescription: String
}

public struct RemoteCommandResult: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32
}

public enum RemoteExecutionError: Error, Sendable, Equatable {
    case launchFailed, nonzeroExit(Int32), outputLimitExceeded
}

private final class RemoteProcessBox: @unchecked Sendable {
    private let lock = NSLock(); private var process: Process?; private var cancelled = false
    func install(_ process: Process) { lock.lock(); self.process = process; let stop = cancelled; lock.unlock(); if stop && process.isRunning { process.terminate() } }
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); if process?.isRunning == true { process?.terminate() } }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private final class RemoteDataBox: @unchecked Sendable {
    private let lock = NSLock(); private var value = Data()
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

public struct RemoteCommandExecutor: Sendable {
    public init() {}
    public func execute(_ plan: RemoteCommandPlan, outputLimit: Int = 4 * 1_024 * 1_024) async throws -> RemoteCommandResult {
        let box = RemoteProcessBox()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try Self.runSynchronously(plan, outputLimit: outputLimit, box: box)
            }.value
        }, onCancel: { box.cancel() })
    }
    private static func runSynchronously(_ plan: RemoteCommandPlan, outputLimit: Int, box: RemoteProcessBox) throws -> RemoteCommandResult {
        let process = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
        process.executableURL = plan.executable; process.arguments = plan.arguments
        process.standardOutput = output; process.standardError = errors; process.standardInput = input
        do { try process.run() } catch { throw RemoteExecutionError.launchFailed }
        box.install(process); input.fileHandleForWriting.write(plan.standardInput); try? input.fileHandleForWriting.close()
        let group = DispatchGroup(), stdoutBox = RemoteDataBox(), stderrBox = RemoteDataBox()
        group.enter(); DispatchQueue.global().async { stdoutBox.set(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter(); DispatchQueue.global().async { stderrBox.set(errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        process.waitUntilExit(); group.wait()
        if box.wasCancelled { throw CancellationError() }
        let stdout = stdoutBox.get(), stderr = stderrBox.get()
        guard stdout.count <= outputLimit, stderr.count <= outputLimit, stdout.count + stderr.count <= outputLimit else { throw RemoteExecutionError.outputLimitExceeded }
        guard process.terminationStatus == 0 else { throw RemoteExecutionError.nonzeroExit(process.terminationStatus) }
        return RemoteCommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: process.terminationStatus)
    }
}

public struct CurlFTPCommandBuilder: Sendable {
    public init() {}
    public func command(profile: RemoteConnectionProfile, credential: RemoteCredential,
                        remotePath: String, intent: RemoteTransferIntent) throws -> RemoteCommandPlan {
        guard profile.remoteProtocol == .ftp || profile.remoteProtocol == .ftps else { throw RemoteBackendError.unsupportedProtocol }
        guard remotePath.hasPrefix("/"), !remotePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteBackendError.invalidRemotePath
        }
        guard let secret = String(data: credential.secret, encoding: .utf8), !credential.username.contains("\n"), !secret.contains("\n") else {
            throw RemoteBackendError.invalidCredential
        }
        var components = URLComponents(); components.scheme = profile.remoteProtocol.rawValue; components.host = profile.host
        if profile.port != profile.remoteProtocol.defaultPort { components.port = profile.port }
        components.path = remotePath
        guard let remoteURL = components.url else { throw RemoteBackendError.invalidRemotePath }
        var lines = ["url = \(quoted(remoteURL.absoluteString))", "user = \(quoted(credential.username + ":" + secret))",
                     "fail", "silent", "show-error", "disable-epsv"]
        switch intent {
        case .list: lines.append("list-only")
        case .download(let local): lines.append("output = \(quoted(local.path))")
        case .upload(let local): lines.append("upload-file = \(quoted(local.path))")
        case .uploadAndRename(let local, let finalRemotePath):
            guard finalRemotePath.hasPrefix("/"), !finalRemotePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RemoteBackendError.invalidRemotePath
            }
            lines.append("upload-file = \(quoted(local.path))")
            lines.append("postquote = \(quoted("RNFR " + remotePath))")
            lines.append("postquote = \(quoted("RNTO " + finalRemotePath))")
        case .delete:
            lines.append("quote = \(quoted("DELE " + remotePath))")
            lines.append("no-body")
        }
        if profile.remoteProtocol == .ftps { lines.append("ssl-reqd") }
        let input = Data((lines.joined(separator: "\n") + "\n").utf8)
        return RemoteCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["-q", "--config", "-"],
            standardInput: input, redactedDescription: "curl \(profile.remoteProtocol.rawValue)://<redacted>/<redacted>")
    }
    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
