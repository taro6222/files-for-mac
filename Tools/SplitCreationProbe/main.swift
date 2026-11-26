import Foundation
import Darwin
import FilesCore

/// Headless process-restart probe. It is not included in the app bundle.
private struct Configuration: Decodable {
    let mode: String, journalDirectory: String
    let source: String?, destination: String?, worker: String?, library: String?, journal: String?
}
@main struct SplitCreationProbe {
    static func main() async {
        do {
            let data = try FileHandle.standardInput.readToEnd() ?? Data()
            guard data.count <= 65536 else { throw SevenZipSplitError.invalidJournal }
            let config = try JSONDecoder().decode(Configuration.self, from: data)
            let directory = URL(fileURLWithPath: config.journalDirectory, isDirectory: true)
            if config.mode.hasPrefix("edit-") {
                let mode = config.mode
                let boundary: ArchiveProgressHandler = { update in
                    if update.phase == .publishing && (mode.hasSuffix("prepared") ? update.currentPath == nil : update.currentPath != nil) { _exit(75) }
                }
                if mode == "edit-recover" || mode == "edit-undo" || mode == "edit-redo" || mode.hasPrefix("edit-undo-crash-") || mode.hasPrefix("edit-redo-crash-") {
                    guard let journal = config.journal else { throw ArchiveEditError.invalidJournal }
                    let result = try await SevenZipArchiveProvider.recoverArchiveEdit(journal: URL(fileURLWithPath: journal), journalDirectory: directory,
                        action: mode.hasPrefix("edit-redo") ? .redo : mode == "edit-recover" ? .inspect : .undo, progress: mode.contains("crash") ? boundary : nil)
                    switch result { case .unpublished: print("unpublished"); case .committed: print("committed"); case .undone: print("undone"); case .discarded: print("discarded") }
                } else {
                    guard ["edit-crash-prepared", "edit-crash-published"].contains(mode), let source = config.source,
                          let worker = config.worker, let library = config.library else { throw ArchiveEditError.invalidJournal }
                    let provider = SevenZipArchiveProvider(executable: URL(fileURLWithPath: worker), library: URL(fileURLWithPath: library))
                    _ = try await provider.edit(URL(fileURLWithPath: source), operations: [.createDirectory(path: "added-by-process")], encryptNewData: false, journalDirectory: directory, progress: boundary)
                    exit(2)
                }
            } else if config.mode == "recover", let journal = config.journal {
                let result = try await SevenZipArchiveProvider.recoverSplitCreation(journal: URL(fileURLWithPath: journal), journalDirectory: directory)
                switch result { case .rolledBack: print("rolledBack"); case .committed: print("committed") }
            } else if ["crash-prepared", "crash-published"].contains(config.mode), let source = config.source, let destination = config.destination,
                      let worker = config.worker, let library = config.library {
                let provider = SevenZipArchiveProvider(executable: URL(fileURLWithPath: worker), library: URL(fileURLWithPath: library))
                _ = try await provider.createSplit(from: [URL(fileURLWithPath: source)], at: URL(fileURLWithPath: destination), volumeBytes: 65536,
                                                  journalDirectory: directory, compressionLevel: .store) { update in
                    if update.phase == .publishing && (config.mode == "crash-prepared" ? update.currentPath == nil : update.currentPath != nil) { _exit(75) }
                }
                exit(2) // A successful return did not exercise the requested crash boundary.
            } else { throw SevenZipSplitError.invalidJournal }
        } catch { fputs("Split probe failed: \(error)\n", stderr); exit(1) }
    }
}
