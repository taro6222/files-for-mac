import Foundation
import Darwin

public enum SevenZipWorkerError: Error, Sendable, Equatable {
    case unavailable, invalidConfiguration, invalidResponse, ioFailure, timedOut, unexpectedExit, memoryLimitExceeded
    case worker(String)
    case stagingPreserved(URL)
    case publicationRecovery(staging: URL, published: [URL])
}

/// Explicit locations are available for integration tools; bundled() validates private app code.
public struct SevenZipArchiveProvider: Sendable {
    public let executable: URL, library: URL
    public let timeout: TimeInterval
    /// Parent-observed physical footprint budget; polling can overshoot this value.
    public let maximumPhysicalFootprintBytes: UInt64
    public static var defaultMaximumPhysicalFootprintBytes: UInt64 {
        max(256 << 20, ProcessInfo.processInfo.physicalMemory / 2)
    }
    private let verifiedBundle: URL?
    private let verifiedIdentity: SevenZipBundleVerifier.Identity?
    public init(executable: URL, library: URL, timeout: TimeInterval = 300,
                maximumPhysicalFootprintBytes: UInt64 = Self.defaultMaximumPhysicalFootprintBytes) {
        self.executable = executable; self.library = library; self.timeout = timeout; verifiedBundle = nil; verifiedIdentity = nil
        self.maximumPhysicalFootprintBytes = maximumPhysicalFootprintBytes
    }
    init(verifiedExecutable: URL, library: URL, bundle: URL, identity: SevenZipBundleVerifier.Identity, timeout: TimeInterval,
         maximumPhysicalFootprintBytes: UInt64) {
        executable = verifiedExecutable; self.library = library; self.timeout = timeout; verifiedBundle = bundle; verifiedIdentity = identity
        self.maximumPhysicalFootprintBytes = maximumPhysicalFootprintBytes
    }

    /// Create a 7z archive in a private file and atomically publish without replacement.
    /// Passwords travel only through the private framed request pipe, never argv/environment.
    public func create(from sources: [URL], at destination: URL, compressionLevel: ArchiveCompressionLevel = .normal,
                       password: String? = nil, encryptHeader: Bool = true, options: SevenZipCompressionOptions = .init(),
                       progress: ArchiveProgressHandler? = nil) async throws -> URL {
        guard destination.isFileURL, !destination.path(percentEncoded: false).utf8.contains(0), destination.pathExtension.lowercased() == "7z", options.isValid, password == nil || (password?.isEmpty == false && password?.utf8.contains(0) == false) else {
            throw SevenZipWorkerError.invalidConfiguration
        }
        let parent = try sevenZipCanonicalDirectory(destination.deletingLastPathComponent())
        let target = parent.appendingPathComponent(destination.lastPathComponent)
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ZipArchiveError.destinationNotDirectory }
        defer { Darwin.close(parentFD) }
        var existing = stat()
        guard fstatat(parentFD, target.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else {
            throw ZipArchiveError.destinationConflict(target.lastPathComponent)
        }
        let plan = try await Self.prepareCreationPlan(sources: sources, destination: target)
        try Task.checkCancellation()
        let name = ".files-create-\(UUID().uuidString).7z"
        let fd = openat(parentFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SevenZipWorkerError.ioFailure }
        defer { Darwin.close(fd) }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { throw SevenZipWorkerError.ioFailure }
        let device = identity.st_dev, inode = identity.st_ino
        defer {
            var current = stat()
            if fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 && current.st_dev == device && current.st_ino == inode {
                _ = unlinkat(parentFD, name, 0)
            }
        }
        return try await perform(outputFD: fd) { session in
            try plan.verify(check: session.check)
            progress?(.init(phase: .writing, completedEntries: 0, totalEntries: plan.items.count,
                            completedBytes: 0, totalBytes: plan.totalBytes, currentPath: nil))
            try session.check()
            try session.create(plan, level: compressionLevel, password: password, encryptHeader: encryptHeader && password != nil, options: options)
            progress?(.init(phase: .publishing, completedEntries: plan.items.count, totalEntries: plan.items.count,
                            completedBytes: plan.totalBytes, totalBytes: plan.totalBytes, currentPath: target.lastPathComponent))
            try plan.verify(check: session.check)
            var held = stat(), current = stat(), heldParent = stat(), pathParent = stat()
            guard fstat(fd, &held) == 0, held.st_size > 0, held.st_nlink == 1,
                  fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == device, current.st_ino == inode,
                  fstat(parentFD, &heldParent) == 0, lstat(parent.path, &pathParent) == 0,
                  heldParent.st_dev == pathParent.st_dev, heldParent.st_ino == pathParent.st_ino else {
                throw SevenZipWorkerError.ioFailure
            }
            try session.check()
            guard renameatx_np(parentFD, name, parentFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ZipArchiveError.destinationConflict(target.lastPathComponent) }
                throw SevenZipWorkerError.ioFailure
            }
            return destination
        }
    }

    /// Split 7z files are published in the destination's existing parent folder, never in
    /// a replacement container directory. A durable private journal records every move.
    public func createSplit(from sources: [URL], at destination: URL, volumeBytes: Int64, journalDirectory: URL,
                            compressionLevel: ArchiveCompressionLevel = .normal, password: String? = nil,
                            encryptHeader: Bool = true, options: SevenZipCompressionOptions = .init(),
                            progress: ArchiveProgressHandler? = nil) async throws -> SevenZipSplitCreationReport {
        guard options.isValid, password == nil || (password?.isEmpty == false && password?.utf8.contains(0) == false) else { throw SevenZipWorkerError.invalidConfiguration }
        return try await perform(creationStream: true) { session in
            let plan = try SevenZipCreationPlan(sources: sources, destination: destination, check: session.check)
            let staging = try SevenZipSplitStaging(destination: destination, volumeBytes: volumeBytes, journalDirectory: journalDirectory)
            do {
                progress?(.init(phase: .writing, completedEntries: 0, totalEntries: plan.items.count, completedBytes: 0, totalBytes: plan.totalBytes, currentPath: nil))
                try session.createSplit(plan, level: compressionLevel, password: password, encryptHeader: encryptHeader && password != nil, options: options, staging: staging)
                try staging.prepare(check: session.check)
                try plan.verify(check: session.check)
                progress?(.init(phase: .publishing, completedEntries: plan.items.count, totalEntries: plan.items.count, completedBytes: plan.totalBytes, totalBytes: plan.totalBytes, currentPath: nil))
                try plan.verify(check: session.check)
                return try staging.publish(check: session.check) { name in
                    progress?(.init(phase: .publishing, completedEntries: plan.items.count, totalEntries: plan.items.count, completedBytes: plan.totalBytes, totalBytes: plan.totalBytes, currentPath: name))
                }
            } catch {
                do { try staging.rollback() }
                catch { throw staging.recoveryError() }
                throw error
            }
        }
    }
    private static func prepareCreationPlan(sources: [URL], destination: URL) async throws -> SevenZipCreationPlan {
        let control = SevenZipProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try SevenZipCreationPlan(sources: sources, destination: destination, check: control.check) })
                }
            }
        }, onCancel: { control.cancel() })
    }
    public static func splitCreationHistory(journalDirectory: URL) async throws -> [SevenZipSplitJournalSummary] {
        let control = SevenZipProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try SevenZipSplitStaging.history(directory: journalDirectory, check: control.check) })
                }
            }
        }, onCancel: { control.cancel() })
    }
    public static func recoverSplitCreation(journal: URL, journalDirectory: URL) async throws -> SevenZipSplitRecoveryOutcome {
        let control = SevenZipProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try SevenZipSplitStaging.recover(journal: journal, directory: journalDirectory, check: control.check) })
                }
            }
        }, onCancel: { control.cancel() })
    }

    public func entries(at archive: URL, password: String? = nil) async throws -> [ArchiveEntryDescriptor] {
        try await perform { session in
            let listed = try session.open(archive, password: password)
            try session.close()
            return listed.map(\.descriptor)
        }
    }

    /// Publish one new directory only after all entries and the worker's final exit succeed.
    public func extractToNewDirectory(_ archive: URL, at destination: URL, password: String? = nil,
                                     limits: ArchiveExtractionLimits = .init(),
                                     progress: ArchiveProgressHandler? = nil) async throws -> ArchiveExtractionReport {
        try await extract(archive, destination: destination, intoExisting: false, password: password, limits: limits, progress: progress)
    }

    public func extract(_ archive: URL, to destination: URL, password: String? = nil,
                        limits: ArchiveExtractionLimits = .init(), progress: ArchiveProgressHandler? = nil) async throws -> ArchiveExtractionReport {
        try await extract(archive, destination: destination, intoExisting: true, password: password, limits: limits, progress: progress)
    }

    private func extract(_ archive: URL, destination: URL, intoExisting: Bool, password: String?,
                         limits: ArchiveExtractionLimits, progress: ArchiveProgressHandler?) async throws -> ArchiveExtractionReport {
        try await perform { session in
            let listed = try session.open(archive, password: password, maximumEntries: limits.maximumEntries)
            let validated = try ArchiveExtractionValidator.validate(listed.map(\.descriptor), limits: limits)
            let tree = try SevenZipStagingTree(destination: destination, intoExisting: intoExisting)
            do {
                if intoExisting { try tree.preflight(names: Set(validated.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) }).sorted()) }
                let total = validated.reduce(Int64(0)) { $0 + $1.uncompressedSize }
                var completed: Int64 = 0
                for (index, entry) in validated.enumerated() {
                    try session.check()
                    if entry.kind == .directory { try tree.directory(entry.relativePath) }
                    else {
                        let fd = try tree.file(entry.relativePath)
                        defer { Darwin.close(fd) }
                        try session.extract(listed[index], maximum: limits.maximumSingleFileBytes) { data in
                            var offset = 0
                            try data.withUnsafeBytes { bytes in
                                while offset < bytes.count {
                                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                                    if count < 0 && errno == EINTR { continue }
                                    guard count > 0 else { throw SevenZipWorkerError.ioFailure }
                                    offset += count
                                }
                            }
                            completed += Int64(data.count)
                            guard completed <= limits.maximumTotalBytes else { throw ArchiveValidationError.totalSizeLimit }
                            progress?(.init(phase: .reading, completedEntries: index, totalEntries: validated.count,
                                            completedBytes: completed, totalBytes: total, currentPath: entry.relativePath))
                        }
                        try tree.completedFile(entry.relativePath, fd: fd, size: entry.uncompressedSize)
                    }
                    progress?(.init(phase: .reading, completedEntries: index + 1, totalEntries: validated.count,
                                    completedBytes: completed, totalBytes: total, currentPath: entry.relativePath))
                }
                try session.close()
                try session.check()
                progress?(.init(phase: .publishing, completedEntries: validated.count, totalEntries: validated.count,
                                completedBytes: completed, totalBytes: total, currentPath: nil))
                try session.check()
                try session.verifySource()
                let published = try tree.publish(intoExisting: intoExisting, check: session.check) { name in
                    progress?(.init(phase: .publishing, completedEntries: validated.count, totalEntries: validated.count,
                                    completedBytes: completed, totalBytes: total, currentPath: name))
                }
                return ArchiveExtractionReport(entries: validated.count, extractedBytes: completed, publishedURLs: published)
            } catch {
                if let worker = error as? SevenZipWorkerError, case .publicationRecovery = worker { throw error }
                guard tree.clean() else { throw SevenZipWorkerError.stagingPreserved(tree.staging) }
                throw error
            }
        }
    }

    private func perform<T: Sendable>(outputFD: Int32? = nil, creationStream: Bool = false, _ body: @escaping @Sendable (SevenZipSession) throws -> T) async throws -> T {
        let control = SevenZipProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        guard timeout.isFinite, timeout > 0, executable.isFileURL, library.isFileURL else {
                            throw SevenZipWorkerError.invalidConfiguration
                        }
                        if let verifiedBundle {
                            let locations = try SevenZipBundleVerifier.verify(verifiedBundle, check: control.check)
                            guard locations.worker == executable, locations.library == library, locations.identity == verifiedIdentity else { throw SevenZipBundleError.changedBundle }
                        }
                        let session = try SevenZipSession(provider: self, control: control, outputFD: outputFD, creationStream: creationStream)
                        defer { session.stop() }
                        return try body(session)
                    })
                }
            }
        }, onCancel: { control.cancel() })
    }
}

private final class SevenZipProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var child: pid_t?
    private var cancelled = false
    private var observationFailure: SevenZipWorkerError?
    private var memoryMonitor: DispatchSourceTimer?
    func install(_ pid: pid_t, maximumPhysicalFootprintBytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        child = pid
        if cancelled { kill(pid, SIGKILL) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "files.sevenzip.memory"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.observeMemory(maximum: maximumPhysicalFootprintBytes) }
        memoryMonitor = timer
        timer.resume()
    }
    private func observeMemory(maximum: UInt64) {
        lock.lock(); defer { lock.unlock() }
        // The lock also protects reaping: an observed PID cannot have been reused.
        guard let child, observationFailure == nil, !cancelled else { return }
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(child, RUSAGE_INFO_V0, $0)
            }
        }
        if result == 0 {
            guard info.ri_phys_footprint > maximum else { return }
            observationFailure = .memoryLimitExceeded
        } else {
            // A child may already be exiting; its normal waitpid path owns the result.
            guard errno != ESRCH else { return }
            observationFailure = .ioFailure
        }
        kill(child, SIGKILL)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let child { kill(child, SIGKILL) }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if let observationFailure { throw observationFailure }
    }
    func reap() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let child else { return nil }
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        if result == child { self.child = nil; memoryMonitor?.cancel(); memoryMonitor = nil; return status }
        return nil
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        memoryMonitor?.cancel(); memoryMonitor = nil
        if let child {
            kill(child, SIGKILL)
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self.child = nil
        }
    }
}

private struct SevenZipItem: Decodable {
    let index: UInt32, path: String, kind: String, size: Int64, encrypted: Bool
    var descriptor: ArchiveEntryDescriptor {
        .init(path: path, kind: ArchiveEntryKind(rawValue: kind)!, uncompressedSize: size, isEncrypted: encrypted)
    }
}
private struct SevenZipReply: Decodable {
    struct Failure: Decodable { let code: String }
    struct Source: Decodable, Equatable { let device: String, inode: String, size: UInt64 }
    let version: Int, ok: Bool
    let session: String?, source: Source?, items: [SevenZipItem]?, error: Failure?, written: UInt64?, closed: Bool?
}

private final class SevenZipSession {
    private let control: SevenZipProcessControl, deadline: UInt64
    private var requestFD: Int32 = -1, responseFD: Int32 = -1, dataFD: Int32 = -1, errorFD: Int32 = -1
    private var token: String?
    private var diagnosticsEnded = false
    private var inputFD: Int32 = -1
    private var readSource: SevenZipReadSource?
    init(provider: SevenZipArchiveProvider, control: SevenZipProcessControl, outputFD: Int32? = nil, creationStream: Bool = false) throws {
        self.control = control
        let now = DispatchTime.now().uptimeNanoseconds
        guard provider.timeout <= 86_400, provider.maximumPhysicalFootprintBytes > 0 else { throw SevenZipWorkerError.invalidConfiguration }
        deadline = now + UInt64(provider.timeout * 1_000_000_000)
        // Normalize all originals above stdio/data targets, avoiding dup2 source/target collisions.
        var pipes: [Int32] = []
        defer { for fd in pipes { Darwin.close(fd) } }
        for _ in 0..<4 {
            var pair: [Int32] = [0, 0]
            guard pipe(&pair) == 0 else { throw SevenZipWorkerError.ioFailure }
            let normalized = pair.map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
            for fd in pair { Darwin.close(fd) }
            if normalized.contains(where: { $0 < 10 }) {
                for fd in normalized where fd >= 10 { Darwin.close(fd) }
                throw SevenZipWorkerError.ioFailure
            }
            pipes.append(contentsOf: normalized)
        }
        var inputPair: [Int32] = []
        do {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SevenZipWorkerError.ioFailure }
            inputPair = pair.map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
            for fd in pair { Darwin.close(fd) }
            guard inputPair.allSatisfy({ $0 >= 10 }) else {
                for fd in inputPair where fd >= 10 { Darwin.close(fd) }
                throw SevenZipWorkerError.ioFailure
            }
            pipes.append(contentsOf: inputPair)
        }
        var outputDuplicate: Int32?
        if let outputFD {
            let duplicate = fcntl(outputFD, F_DUPFD_CLOEXEC, 10)
            guard duplicate >= 10 else { throw SevenZipWorkerError.ioFailure }
            outputDuplicate = duplicate; pipes.append(duplicate)
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SevenZipWorkerError.ioFailure }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SevenZipWorkerError.ioFailure }
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, target) in [(pipes[0], Int32(0)), (pipes[3], 1), (pipes[5], 2), (outputDuplicate ?? pipes[7], 3)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw SevenZipWorkerError.ioFailure }
        }
        if let socket = inputPair.last {
            guard posix_spawn_file_actions_adddup2(&actions, socket, 4) == 0 else { throw SevenZipWorkerError.ioFailure }
        }
        for fd in pipes {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw SevenZipWorkerError.ioFailure }
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw SevenZipWorkerError.ioFailure }
        var argumentStrings = [provider.executable.path, provider.library.path, creationStream ? "--create-stream-fd" : (outputFD == nil ? "--output-fd" : "--create-output-fd"), "3"]
        if !inputPair.isEmpty { argumentStrings += ["--input-fd", "4"] }
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { $0.withCString { strdup($0) } } + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = ["LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8", "PATH=/usr/bin:/bin"].map { $0.withCString { strdup($0) } } + [nil]
        defer { for item in arguments + environment { free(item) } }
        var pid: pid_t = 0
        try control.check()
        let result = posix_spawn(&pid, provider.executable.path, &actions, &attributes, &arguments, &environment)
        guard result == 0 else { throw SevenZipWorkerError.unavailable }
        control.install(pid, maximumPhysicalFootprintBytes: provider.maximumPhysicalFootprintBytes)
        if let socket = inputPair.first { inputFD = socket; pipes.removeAll { $0 == socket } }
        requestFD = pipes[1]; responseFD = pipes[2]; errorFD = pipes[4]; dataFD = pipes[6]
        pipes.removeAll { [requestFD, responseFD, errorFD, dataFD].contains($0) }
        for fd in [requestFD, responseFD, errorFD, dataFD, inputFD] where fd >= 0 {
            if fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0 { stop(); throw SevenZipWorkerError.ioFailure }
        }
        if fcntl(requestFD, F_SETNOSIGPIPE, 1) < 0 { stop(); throw SevenZipWorkerError.ioFailure }
    }
    deinit { stop() }
    func stop() {
        control.stop()
        for fd in [requestFD, responseFD, errorFD, dataFD, inputFD] where fd >= 0 { Darwin.close(fd) }
        requestFD = -1; responseFD = -1; errorFD = -1; dataFD = -1; inputFD = -1
    }
    func check() throws {
        try control.check()
        if DispatchTime.now().uptimeNanoseconds >= deadline { throw SevenZipWorkerError.timedOut }
    }
    private func wait(_ descriptors: inout [pollfd]) throws {
        try check()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw SevenZipWorkerError.timedOut }
        let remaining = deadline - now
        let milliseconds = Int32(min(50, (remaining / 1_000_000) + 1))
        let result = poll(&descriptors, nfds_t(descriptors.count), milliseconds)
        if result < 0 && errno != EINTR { throw SevenZipWorkerError.ioFailure }
        try check()
    }
    private func send(_ value: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: value)
        guard payload.count > 0, payload.count <= 1_048_576 else { throw SevenZipWorkerError.invalidConfiguration }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(payload)
        var offset = 0
        while offset < frame.count {
            var descriptors = [pollfd(fd: requestFD, events: Int16(POLLOUT), revents: 0)]
            try wait(&descriptors)
            if descriptors[0].revents == 0 { continue }
            let count = frame.withUnsafeBytes { Darwin.write(requestFD, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { try check(); throw SevenZipWorkerError.ioFailure }
            offset += count
        }
    }
    private func receive(expectedBytes: UInt64? = nil, sink: ((Data) throws -> Void)? = nil, creation: SevenZipSplitStaging? = nil, brokerPlan: SevenZipCreationPlan? = nil) throws -> SevenZipReply {
        var frame = Data(), frameSize: Int?, result: SevenZipReply?, received: UInt64 = 0
        var dataEnded = false, inputEnded = false
        var inputRequest = Data(), inputRequests = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result == nil || received < (expectedBytes ?? 0) || (creation != nil && creation?.ended == false) || (brokerPlan != nil && !inputEnded) {
            var descriptors = [pollfd(fd: responseFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: dataEnded ? -1 : dataFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: diagnosticsEnded ? -1 : errorFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: brokerPlan != nil && !inputEnded ? inputFD : -1, events: Int16(POLLIN), revents: 0)]
            try wait(&descriptors)
            if descriptors[3].revents & Int16(POLLIN | POLLHUP) != 0, let brokerPlan {
                var requestBytes = [UInt8](repeating: 0, count: 5 - inputRequest.count)
                let count = Darwin.read(inputFD, &requestBytes, requestBytes.count)
                if count == 0 {
                    guard inputRequest.isEmpty else { throw SevenZipWorkerError.invalidResponse }
                    inputEnded = true
                } else if count > 0 {
                    inputRequest.append(contentsOf: requestBytes.prefix(count))
                    if inputRequest.count == 5 {
                        let index = inputRequest.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        inputRequests += 1
                        guard inputRequest.first == 0x43, Int(index) < brokerPlan.items.count,
                              inputRequests <= brokerPlan.items.count * 4 + 64 else { throw SevenZipWorkerError.invalidResponse }
                        try brokerPlan.items[Int(index)].withDescriptor { try sendDescriptor($0) }
                        inputRequest.removeAll(keepingCapacity: true)
                    }
                } else if errno != EAGAIN && errno != EINTR { throw SevenZipWorkerError.ioFailure }
            }
            if descriptors[2].revents & Int16(POLLIN | POLLHUP) != 0 {
                // Darwin reports POLLIN at EOF too. A readiness flag alone is not diagnostic data.
                var byte: UInt8 = 0
                let count = Darwin.read(errorFD, &byte, 1)
                if count > 0 { throw SevenZipWorkerError.invalidResponse }
                if count == 0 { diagnosticsEnded = true }
                else if errno != EAGAIN && errno != EINTR { throw SevenZipWorkerError.ioFailure }
            }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = Darwin.read(dataFD, &buffer, buffer.count)
                if count > 0 {
                    if let creation { try creation.consume(Data(buffer.prefix(count)), check: check) }
                    else {
                        guard let expectedBytes, received + UInt64(count) <= expectedBytes, let sink else { throw SevenZipWorkerError.invalidResponse }
                        try sink(Data(buffer.prefix(count)))
                    }
                    received += UInt64(count)
                    guard received <= 16_100_000_000 else { throw SevenZipWorkerError.invalidResponse }
                } else if count == 0 {
                    guard creation?.ended != false, received >= (expectedBytes ?? 0) else { throw SevenZipWorkerError.unexpectedExit }
                    dataEnded = true
                } else if count < 0 && errno != EAGAIN && errno != EINTR { throw SevenZipWorkerError.ioFailure }
            }
            if result == nil && descriptors[0].revents != 0 {
                let remaining = (frameSize ?? 4) - frame.count
                let count = Darwin.read(responseFD, &buffer, min(buffer.count, remaining))
                if count == 0 { try check(); throw SevenZipWorkerError.unexpectedExit }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw SevenZipWorkerError.ioFailure
                }
                frame.append(contentsOf: buffer.prefix(count))
                if frameSize == nil && frame.count == 4 {
                    let size = frame.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard size > 0, size <= 8_388_608 else { throw SevenZipWorkerError.invalidResponse }
                    frameSize = Int(size) + 4
                } else if let frameSize, frame.count == frameSize {
                    guard let decoded = try? JSONDecoder().decode(SevenZipReply.self, from: frame.dropFirst(4)), decoded.version == 1 else { throw SevenZipWorkerError.invalidResponse }
                    if !decoded.ok {
                        let known = ["sdk-load", "source-open", "password-required", "password-or-corrupt", "not-archive", "invalid-metadata", "limit", "source-changed", "internal", "output-write", "unsupported-item", "corrupt-data", "missing-volume"]
                        guard let code = decoded.error?.code, known.contains(code) else { throw SevenZipWorkerError.invalidResponse }
                        throw SevenZipWorkerError.worker(code)
                    }
                    guard decoded.error == nil else { throw SevenZipWorkerError.invalidResponse }
                    result = decoded
                }
            }
        }
        return result!
    }
    private func sendDescriptor(_ fd: Int32) throws {
        // Darwin CMSG_SPACE/CMSG_LEN align to 32 bits on both supported CPUs.
        let headerSize = (MemoryLayout<cmsghdr>.size + 3) & ~3
        let size = headerSize + MemoryLayout<Int32>.size
        var controlBytes = [UInt8](repeating: 0, count: size), marker: UInt8 = 0x46
        while true {
            try check()
            let count = controlBytes.withUnsafeMutableBytes { bytes in
                bytes.baseAddress!.storeBytes(of: cmsghdr(cmsg_len: socklen_t(size), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
                bytes.baseAddress!.advanced(by: headerSize).storeBytes(of: fd, as: Int32.self)
                return withUnsafeMutablePointer(to: &marker) { pointer in
                    var vector = iovec(iov_base: UnsafeMutableRawPointer(pointer), iov_len: 1)
                    return withUnsafeMutablePointer(to: &vector) { vectors in
                        var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectors, msg_iovlen: 1,
                                             msg_control: bytes.baseAddress, msg_controllen: socklen_t(size), msg_flags: 0)
                        return sendmsg(inputFD, &message, MSG_NOSIGNAL | MSG_DONTWAIT)
                    }
                }
            }
            if count == 1 { return }
            if count < 0 && errno == EINTR { continue }
            guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { throw SevenZipWorkerError.unexpectedExit }
            var descriptors = [pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)]
            try wait(&descriptors)
        }
    }
    func open(_ archive: URL, password: String?, maximumEntries: Int = 100_000) throws -> [SevenZipItem] {
        guard archive.isFileURL, maximumEntries > 0, maximumEntries <= 100_000,
              password?.utf8.contains(0) != true else { throw SevenZipWorkerError.invalidConfiguration }
        var request: [String: Any] = ["version": 1, "operation": "list", "password": password as Any? ?? NSNull(), "maxEntries": maximumEntries]
        let source = try SevenZipReadSource(archive: archive, check: check)
        request["sourceFDs"] = source.records.map(\.request); request["splitVolumes"] = source.split
        try source.verify(check: check)
        try send(request)
        for index in source.records.indices { try source.withDescriptor(index) { try sendDescriptor($0) } }
        Darwin.close(inputFD); inputFD = -1
        let response = try receive()
        try source.verify(check: check)
        readSource = source
        guard let items = response.items, items.count <= maximumEntries, let token = response.session, UUID(uuidString: token) != nil,
              let source = response.source, UInt64(source.device) != nil, UInt64(source.inode) != nil else { throw SevenZipWorkerError.invalidResponse }
        for (index, item) in items.enumerated() {
            guard item.index == UInt32(index), ArchiveEntryKind(rawValue: item.kind) != nil, item.size >= 0,
                  !item.path.utf8.contains(0) else { throw SevenZipWorkerError.invalidResponse }
        }
        self.token = token
        return items
    }
    func extract(_ item: SevenZipItem, maximum: Int64, sink: @escaping (Data) throws -> Void) throws {
        guard let token else { throw SevenZipWorkerError.invalidResponse }
        try send(["version": 1, "operation": "extract", "session": token, "index": item.index,
                  "expectedSize": item.size, "maximumBytes": min(maximum, 8_000_000_000)])
        let response = try receive(expectedBytes: UInt64(item.size), sink: sink)
        guard response.session == token, response.written == UInt64(item.size) else { throw SevenZipWorkerError.invalidResponse }
    }
    func verifySource() throws { try check(); try readSource?.verify(check: check) }
    func close() throws {
        guard let token else { throw SevenZipWorkerError.invalidResponse }
        try send(["version": 1, "operation": "close", "session": token])
        let response = try receive()
        guard response.closed == true else { throw SevenZipWorkerError.invalidResponse }
        try waitForExit()
        try readSource?.verify(check: check)
        self.token = nil
    }
    func create(_ plan: SevenZipCreationPlan, level: ArchiveCompressionLevel, password: String?, encryptHeader: Bool, options: SevenZipCompressionOptions) throws {
        try send(["version": 1, "operation": "create", "items": plan.items.map(\.brokerRequest), "level": level.rawValue,
                  "password": password as Any? ?? NSNull(), "encryptHeader": encryptHeader,
                  "dictionarySize": options.effectiveDictionarySize(for: level), "wordSize": options.effectiveWordSize(for: level), "threads": options.threadCount])
        guard try receive(brokerPlan: plan).closed == true else { throw SevenZipWorkerError.invalidResponse }
        try waitForExit()
    }
    func createSplit(_ plan: SevenZipCreationPlan, level: ArchiveCompressionLevel, password: String?, encryptHeader: Bool,
                     options: SevenZipCompressionOptions, staging: SevenZipSplitStaging) throws {
        try send(["version": 1, "operation": "create", "items": plan.items.map(\.brokerRequest), "level": level.rawValue,
                  "password": password as Any? ?? NSNull(), "encryptHeader": encryptHeader,
                  "dictionarySize": options.effectiveDictionarySize(for: level), "wordSize": options.effectiveWordSize(for: level), "threads": options.threadCount])
        guard try receive(creation: staging, brokerPlan: plan).closed == true else { throw SevenZipWorkerError.invalidResponse }
        try waitForExit()
    }
    private func waitForExit() throws {
        while true {
            try check()
            if let status = control.reap() {
                try control.check()
                guard status == 0 else { throw SevenZipWorkerError.unexpectedExit }
                break
            }
            var descriptors: [pollfd] = []
            try wait(&descriptors)
        }
        // Successful completion must not leave unconsumed bytes in any output channel.
        for fd in [responseFD, dataFD, errorFD] {
            var byte: UInt8 = 0
            var count: Int
            repeat { count = Darwin.read(fd, &byte, 1) } while count < 0 && errno == EINTR
            guard count == 0 else { throw SevenZipWorkerError.invalidResponse }
        }
    }
}

private final class SevenZipStagingTree {
    let parent: URL, staging: URL, destination: URL
    private let parentFD: Int32, rootFD: Int32
    private var published = false
    private var records: [String: stat] = [:]
    init(destination: URL, intoExisting: Bool) throws {
        guard destination.isFileURL, !["", ".", "..", "/"].contains(destination.lastPathComponent) else { throw SevenZipWorkerError.invalidConfiguration }
        self.destination = destination
        parent = intoExisting ? destination : destination.deletingLastPathComponent()
        staging = parent.appendingPathComponent(".files-7z-\(UUID().uuidString)")
        parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ZipArchiveError.destinationNotDirectory }
        var info = stat()
        guard intoExisting || (fstatat(parentFD, destination.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) else {
            Darwin.close(parentFD); throw ZipArchiveError.destinationConflict(destination.lastPathComponent)
        }
        guard mkdirat(parentFD, staging.lastPathComponent, 0o700) == 0 else { Darwin.close(parentFD); throw SevenZipWorkerError.ioFailure }
        rootFD = openat(parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { Darwin.close(parentFD); throw SevenZipWorkerError.stagingPreserved(staging) }
    }
    deinit { Darwin.close(rootFD); Darwin.close(parentFD) }
    private func matches(_ fd: Int32, at path: String) -> Bool {
        var held = stat(), current = stat()
        return fstat(fd, &held) == 0 && lstat(path, &current) == 0 && held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }
    private func directoryFD(_ parts: [Substring]) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else { throw SevenZipWorkerError.ioFailure }
        do {
            var prefix = ""
            for part in parts {
                let name = String(part)
                prefix = prefix.isEmpty ? name : prefix + "/" + name
                let made = mkdirat(current, name, 0o700) == 0
                if !made && (errno != EEXIST || records[prefix] == nil) { throw SevenZipWorkerError.ioFailure }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SevenZipWorkerError.ioFailure }
                var info = stat()
                guard fstat(next, &info) == 0 else { Darwin.close(next); throw SevenZipWorkerError.ioFailure }
                if let expected = records[prefix], !sameIdentity(expected, info) {
                    Darwin.close(next); throw SevenZipWorkerError.ioFailure
                }
                records[prefix] = info
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }
    func directory(_ path: String) throws { Darwin.close(try directoryFD(path.split(separator: "/"))) }
    func file(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/"), fd = try directoryFD(Array(parts.dropLast()))
        defer { Darwin.close(fd) }
        let output = openat(fd, String(parts.last!), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw SevenZipWorkerError.ioFailure }
        var info = stat()
        guard fstat(output, &info) == 0 else { Darwin.close(output); throw SevenZipWorkerError.ioFailure }
        records[path] = info
        return output
    }
    func completedFile(_ path: String, fd: Int32, size: Int64) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, let expected = records[path], sameIdentity(expected, info), info.st_size == size else { throw SevenZipWorkerError.ioFailure }
        records[path] = info
    }
    private func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && (first.st_mode & S_IFMT) == (second.st_mode & S_IFMT)
    }
    private func checkedDirectory(_ path: String, base: Int32, expectedRecords: [String: stat]) -> Int32? {
        var current = dup(base), prefix = ""
        guard current >= 0 else { return nil }
        for part in path.split(separator: "/") {
            let name = String(part); prefix = prefix.isEmpty ? name : prefix + "/" + name
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(current)
            guard next >= 0 else { return nil }
            var info = stat()
            guard fstat(next, &info) == 0, let expected = expectedRecords[prefix], sameIdentity(expected, info) else { Darwin.close(next); return nil }
            current = next
        }
        return current
    }
    private func verify(contents: Bool) -> Bool {
        verifyRecords(contents: contents, base: rootFD, expectedRecords: records, allowOtherTopLevel: false)
    }
    private func verifyRecords(contents: Bool, base: Int32, expectedRecords: [String: stat], allowOtherTopLevel: Bool) -> Bool {
        guard matches(parentFD, at: parent.path), matches(rootFD, at: staging.path) else { return false }
        let directories = [""] + expectedRecords.filter { ($0.value.st_mode & S_IFMT) == S_IFDIR }.map(\.key)
        var seen = Set<String>()
        for path in directories {
            guard let fd = checkedDirectory(path, base: base, expectedRecords: expectedRecords) else { return false }
            guard let stream = fdopendir(fd) else { Darwin.close(fd); return false }
            rewinddir(stream)
            var valid = true
            while true {
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { valid = false }; break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let key = path.isEmpty ? name : path + "/" + name
                if path.isEmpty && allowOtherTopLevel && expectedRecords[key] == nil { continue }
                var actual = stat()
                guard let expected = expectedRecords[key], fstatat(fd, name, &actual, AT_SYMLINK_NOFOLLOW) == 0, sameIdentity(expected, actual) else { valid = false; break }
                if contents && (actual.st_mode & S_IFMT) == S_IFREG &&
                    (actual.st_size != expected.st_size || actual.st_mtimespec.tv_sec != expected.st_mtimespec.tv_sec ||
                     actual.st_mtimespec.tv_nsec != expected.st_mtimespec.tv_nsec || actual.st_ctimespec.tv_sec != expected.st_ctimespec.tv_sec ||
                     actual.st_ctimespec.tv_nsec != expected.st_ctimespec.tv_nsec) { valid = false; break }
                seen.insert(key)
            }
            closedir(stream)
            if !valid { return false }
        }
        return seen == Set(expectedRecords.keys) && matches(parentFD, at: parent.path) && matches(rootFD, at: staging.path)
    }
    func preflight(names suppliedNames: [String]? = nil) throws {
        guard matches(parentFD, at: parent.path) else { throw SevenZipWorkerError.ioFailure }
        let names = suppliedNames ?? Set(records.keys.compactMap { $0.split(separator: "/").first.map(String.init) }).sorted()
        for name in names {
            var info = stat()
            guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ZipArchiveError.destinationConflict(name) }
        }
    }
    func publish(intoExisting: Bool, check: () throws -> Void, onItem: (String) -> Void) throws -> [URL] {
        guard verify(contents: true) else { throw SevenZipWorkerError.ioFailure }
        if intoExisting { return try publishItems(check: check, onItem: onItem) }
        // Strict descriptor-relative no-replace publication; unsupported file systems fail safely.
        guard renameatx_np(parentFD, staging.lastPathComponent, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ZipArchiveError.destinationConflict(destination.lastPathComponent) }
            throw SevenZipWorkerError.ioFailure
        }
        published = true
        return [destination]
    }
    private func publishItems(check: () throws -> Void, onItem: (String) -> Void) throws -> [URL] {
        try preflight()
        let names = Set(records.keys.compactMap { $0.split(separator: "/").first.map(String.init) }).sorted()
        var moved: [String] = [], remaining = records, movedRecords: [String: stat] = [:]
        func subset(_ values: [String: stat], name: String) -> [String: stat] { values.filter { $0.key == name || $0.key.hasPrefix(name + "/") } }
        func refreshTop(_ name: String, at fd: Int32) -> Bool {
            var now = stat()
            guard let old = records[name], fstatat(fd, name, &now, AT_SYMLINK_NOFOLLOW) == 0, sameIdentity(old, now) else { return false }
            records[name] = now; return true
        }
        do {
            for name in names {
                try check()
                guard verifyRecords(contents: true, base: rootFD, expectedRecords: remaining, allowOtherTopLevel: false),
                      verifyRecords(contents: true, base: parentFD, expectedRecords: movedRecords, allowOtherTopLevel: true) else { throw SevenZipWorkerError.ioFailure }
                guard renameatx_np(rootFD, name, parentFD, name, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw ZipArchiveError.destinationConflict(name) }
                    throw SevenZipWorkerError.ioFailure
                }
                moved.append(name)
                guard refreshTop(name, at: parentFD) else { throw SevenZipWorkerError.ioFailure }
                let selected = subset(records, name: name)
                movedRecords.merge(selected) { _, new in new }
                remaining = remaining.filter { selected[$0.key] == nil }
                onItem(name)
            }
            try check()
            guard verifyRecords(contents: true, base: parentFD, expectedRecords: movedRecords, allowOtherTopLevel: true),
                  verifyRecords(contents: true, base: rootFD, expectedRecords: [:], allowOtherTopLevel: false),
                  unlinkat(parentFD, staging.lastPathComponent, AT_REMOVEDIR) == 0 else { throw SevenZipWorkerError.ioFailure }
            published = true
            return names.map { destination.appendingPathComponent($0) }
        } catch {
            var retained: [String] = []
            for name in moved.reversed() {
                let expected = subset(movedRecords, name: name)
                var occupied = stat()
                guard !expected.isEmpty, verifyRecords(contents: true, base: parentFD, expectedRecords: expected, allowOtherTopLevel: true),
                      fstatat(rootFD, name, &occupied, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
                      renameatx_np(parentFD, name, rootFD, name, UInt32(RENAME_EXCL)) == 0,
                      refreshTop(name, at: rootFD) else { retained.append(name); continue }
            }
            if !retained.isEmpty { throw SevenZipWorkerError.publicationRecovery(staging: staging, published: retained.sorted().map { destination.appendingPathComponent($0) }) }
            throw error
        }
    }
    func clean() -> Bool {
        if published { return true }
        guard verify(contents: false) else { return false }
        do { try FileManager.default.removeItem(at: staging); return true }
        catch { return false }
    }
}
