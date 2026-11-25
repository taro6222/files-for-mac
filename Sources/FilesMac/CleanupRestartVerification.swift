#if DEBUG
import AppKit
import FilesCore
import Darwin

/// Dedicated QA processes use an isolated, runner-owned directory. No user session is restored here.
@MainActor
enum CleanupRestartVerification {
    private static let payloadName = "중단된 수신.txt"
    private static let payload = Data("received payload retained across SIGKILL and a fresh FilesMac process\n".utf8)
    private struct Checkpoint: Codable, Sendable {
        let id: String
        let preparePID: Int32
        let original: URL
        let moved: URL
        let identity: [Int64]
    }
    nonisolated private static func identity(_ url: URL) throws -> [Int64] {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnknown) }
        return [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_birthtimespec.tv_sec), Int64(info.st_birthtimespec.tv_nsec)]
    }
    static func run(output: String) async {
        let environment = ProcessInfo.processInfo.environment
        if let theme = environment["FILES_PROMISE_QA_THEME"], ["light", "dark"].contains(theme) {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }
        let root = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
        let storage = root.appendingPathComponent("intakes"), journals = root.appendingPathComponent("operations")
        let destination = root.appendingPathComponent("copies"), checkpointURL = root.appendingPathComponent("checkpoint.json")
        var checks: [String: Bool] = [:]
        do {
            guard root.lastPathComponent.hasPrefix("files-cleanup-restart."),
                  let token = environment["FILES_CLEANUP_RESTART_QA_ID"],
                  let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".files-cleanup-restart-qa.json"))) as? [String: String],
                  marker == ["id": token] else { throw CocoaError(.fileReadNoPermission) }
            if environment["FILES_CLEANUP_RESTART_QA_PHASE"] == "interrupt" {
                guard !FileManager.default.fileExists(atPath: checkpointURL.path),
                      !FileManager.default.fileExists(atPath: storage.path), !FileManager.default.fileExists(atPath: destination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                let intake = try PromisedFileIntake(storageDirectory: storage)
                let source = intake.receivingDirectory.appendingPathComponent(payloadName)
                try payload.write(to: source); try intake.registerReceivedFile(source)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let report = await CopyEngine.run(sources: [source], destination: destination, journalDirectory: journals,
                    cancellation: CopyCancellation(), sourceIntakes: [intake])
                guard report.state == "completed", intake.copiedItemCount == 1 else { throw CocoaError(.fileWriteUnknown) }
                let expectedIdentity = try identity(intake.directoryURL)
                let _: PromisedFileCleanupResult = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let result = try intake.interruptibleCleanupForVerification(journalDirectory: journals) { moved in
                                guard try identity(moved) == expectedIdentity else { throw CocoaError(.fileReadUnknown) }
                                let checkpoint = Checkpoint(id: token, preparePID: getpid(), original: intake.directoryURL,
                                                            moved: moved, identity: expectedIdentity)
                                try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
                                // The parent verifies the checkpoint, then SIGKILLs this exact child PID.
                                while true { Thread.sleep(forTimeInterval: 1) }
                            }
                            continuation.resume(returning: result)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                throw CocoaError(.userCancelled) // Reaching here means the interruption did not happen.
            }
            guard environment["FILES_CLEANUP_RESTART_QA_PHASE"] == "inspect" else { throw CocoaError(.coderInvalidValue) }
            let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
            guard checkpoint.id == token, checkpoint.preparePID != getpid(),
                  checkpoint.original.deletingLastPathComponent().standardizedFileURL == storage,
                  checkpoint.original.lastPathComponent.hasPrefix("promise-"),
                  UUID(uuidString: String(checkpoint.original.lastPathComponent.dropFirst(8))) != nil,
                  checkpoint.moved.lastPathComponent == checkpoint.original.lastPathComponent,
                  checkpoint.moved.isFileURL, try identity(checkpoint.moved) == checkpoint.identity else { throw CocoaError(.fileReadUnknown) }
            checks["freshFilesMacProcess"] = checkpoint.preparePID != getpid()
            let records = try PromisedFileCleanupRecovery.discover(in: journals, storage: storage)
            let record = try records.first.unwrap()
            let journalBytes = try Data(contentsOf: record.journal)
            checks["restartReadsLastVerifiedCheckpoint"] = records.count == 1 && record.recordedState == "verified"
            checks["restartLeavesUnrecordedTrashLocationUnknown"] = record.status == .unlocated && record.location == nil
            checks["restartShowsNamesWithoutInventingLocation"] = record.receivedNames == [payloadName] && record.location == nil
            checks["restartPreservesReceivedPayload"] = try Data(contentsOf: checkpoint.moved.appendingPathComponent("Files/" + payloadName)) == payload
            checks["restartPreservesPublishedCopy"] = try Data(contentsOf: destination.appendingPathComponent(payloadName)) == payload
            checks["restartDoesNotRecreateOriginalDirectory"] = !FileManager.default.fileExists(atPath: checkpoint.original.path)
            checks.merge(await CleanupHistoryWindow.verifyInterruptedRestart(journals: journals, storage: storage, output: root)) { _, new in new }
            checks["restartDoesNotRewriteInterruptedJournal"] = try Data(contentsOf: record.journal) == journalBytes
            // Recover only this fixture from the system Trash, after identity checks. Never empty Trash.
            let recovered = root.appendingPathComponent("recovered-fixture")
            guard let current = ShelfEntry(checkpoint.moved), current.isCurrent,
                  try identity(checkpoint.moved) == checkpoint.identity else { throw CocoaError(.fileReadUnknown) }
            try FileManager.default.moveItem(at: checkpoint.moved, to: recovered)
            checks["restartFixtureReturnedFromTrash"] = try identity(recovered) == checkpoint.identity
                && Data(contentsOf: recovered.appendingPathComponent("Files/" + payloadName)) == payload
            let result: [String: Any] = ["checks": checks, "preparePID": checkpoint.preparePID, "inspectPID": getpid(),
                "language": Locale.preferredLanguages.first ?? "", "theme": environment["FILES_PROMISE_QA_THEME"] ?? "",
                "journal": record.journal.path, "os": ProcessInfo.processInfo.operatingSystemVersionString]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"), options: .atomic)
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch {
            let result: [String: Any] = ["error": error.localizedDescription, "checks": checks]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"), options: .atomic)
            exit(1)
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CocoaError(.fileReadUnknown) }; return value
    }
}
#endif
