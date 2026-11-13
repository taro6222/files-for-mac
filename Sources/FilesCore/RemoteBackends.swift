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

public enum RemoteTransferIntent: Sendable, Equatable { case list, download(local: URL), upload(local: URL) }

public enum RemoteBackendError: Error, Sendable, Equatable {
    case unsupportedProtocol, invalidRemotePath, invalidCredential
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
        }
        if profile.remoteProtocol == .ftps { lines.append("ssl-reqd") }
        let input = Data((lines.joined(separator: "\n") + "\n").utf8)
        return RemoteCommandPlan(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["-q", "--config", "-"],
            standardInput: input, redactedDescription: "curl \(profile.remoteProtocol.rawValue)://<redacted>/<redacted>")
    }
    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
