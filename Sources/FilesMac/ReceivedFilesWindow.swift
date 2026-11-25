import AppKit
#if canImport(FilesCore)
import FilesCore
#endif

#if DEBUG
private final class CleanupVerificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (PromisedFileCleanupResult, ShelfEntry?)?
    func record(_ result: PromisedFileCleanupResult) {
        let identity = result.retainedAt.flatMap { ShelfEntry($0) }
        lock.withLock { value = (result, identity) }
    }
    var result: (PromisedFileCleanupResult, ShelfEntry?)? { lock.withLock { value } }
}
#endif

@MainActor
final class ReceivedFilesWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    typealias Prepare = ([URL], [PromisedFileIntake], URL, @escaping (Bool) -> Void) -> Void
    private static weak var cleaningController: ReceivedFilesWindow?
    static var isCleaning: Bool { cleaningController != nil || CleanupHistoryWindow.isRestoring }
    static var activities: [FileOperationActivity] { (cleaningController.map { [$0.activity] } ?? []) + CleanupHistoryWindow.activities }
    private static var shared: ReceivedFilesWindow?
    private let prepare: Prepare
    private let storage: URL
    private var rows: [PromisedFileRecovery] = []
    private var busy = false
    private var cleanupID = UUID()
    private var cleanupProcessed = 0
    private var cleanupTotal = 0
    private var cleanupNames = ""
    private var cleanupResultLocations: [URL] = []
    private var cleanupCancellation: CopyCancellation?
    private var cleanupMove: @Sendable (PromisedFileIntake, CopyCancellation) throws -> PromisedFileCleanupResult = { intake, cancellation in
        let journals = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac").appendingPathComponent("operations")
        return try intake.moveVerifiedCopiesToTrash(journalDirectory: journals, cancellation: cancellation)
    }
    private let cleanup = NSButton(title: L("복사 완료 보관본 정리", "Clean Up Copied Exports"), target: nil, action: #selector(cleanupSelected))
    private let cleanupDetails = NSButton(title: L("정리 결과 보기", "Show Cleanup Results"), target: nil, action: #selector(revealCleanupResults))
    private let cancelCleanup = NSButton(title: L("정리 중지", "Stop Cleanup"), target: nil, action: #selector(stopCleanup))
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton(title: L("복사 재개…", "Resume Copy…"), target: nil, action: #selector(resumeCopy))
    private let reveal = NSButton(title: L("보관된 파일 보기", "Show Retained Files"), target: nil, action: #selector(revealFiles))
    private let refresh = NSButton(title: L("새로 고침", "Refresh"), target: nil, action: #selector(reload))
    private let history = NSButton(title: L("이전 정리 기록…", "Cleanup History…"), target: nil, action: #selector(showCleanupHistory))
    private static var journalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.taro6222.files-for-mac").appendingPathComponent("operations")
    }

    static func present(prepare: @escaping Prepare) {
        let controller = shared ?? ReceivedFilesWindow(storage: FilePromiseReceiveWindow.storageDirectory, prepare: prepare)
        shared = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.reload()
    }
    static func refreshAfterRestore() { shared?.reload() }
    private init(storage: URL, prepare: @escaping Prepare) {
        self.storage = storage; self.prepare = prepare
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("보관된 수신 파일", "Retained Received Files"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 500); window.center()
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        table.setAccessibilityLabel(L("보관된 수신 작업", "Retained receive jobs"))
        for (id, title, width) in [("date", L("수신 시각", "Received"), 160.0), ("files", L("파일", "Files"), 340.0), ("state", L("상태", "Status"), 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        status.maximumNumberOfLines = 3
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        let intro = NSTextField(wrappingLabelWithString: L("다른 앱에서 받은 파일은 앱을 종료해도 보관됩니다. 복사를 재개하면 파일을 다시 검증하고 이름 충돌 처리 방법을 묻습니다.", "Files received from other apps remain available after quitting. Resuming a copy verifies the files again and asks how to handle name conflicts."))
        let buttons = NSStackView(views: [copy, reveal, refresh, history]); buttons.spacing = 10
        let cleanupButtons = NSStackView(views: [cleanup, cancelCleanup, cleanupDetails]); cleanupButtons.spacing = 10
        let cleanupHelp = NSTextField(wrappingLabelWithString: L("정리는 원본과 복사본을 다시 검증한 보관본만 휴지통으로 옮깁니다. 수신 중이거나 일부만 복사된 작업은 보존합니다.", "Cleanup rechecks the retained files and their copies before moving exports to Trash. Active or partly copied receive jobs are retained."))
        for button in [copy, reveal, refresh, history, cleanup, cancelCleanup, cleanupDetails] { button.target = self }
        let stack = NSStackView(views: [intro, scroll, status, buttons, cleanupHelp, cleanupButtons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var selected: [PromisedFileRecovery] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    @objc private func showCleanupHistory() {
        CleanupHistoryWindow.present(journals: Self.journalDirectory, storage: storage)
    }
    @objc private func reload() { load(message: nil) }
    private func load(message: String?) {
        guard !busy else { return }; busy = true; updateButtons()
        status.stringValue = L("보관된 파일 확인 중…", "Checking retained files…")
        let storage = storage
        Task { [self] in
            do {
                rows = try await Task.detached { try PromisedFileRecovery.discover(in: storage) }.value
                status.stringValue = message ?? (rows.isEmpty ? L("보관된 수신 파일이 없습니다.", "No retained received files.")
                    : L("수신 작업 \(rows.count)개 · 복구가 필요한 작업은 파일 보기에서 직접 확인하세요.", "\(rows.count) receive jobs · inspect jobs needing recovery with Show Retained Files."))
            } catch { rows = []; status.stringValue = error.localizedDescription }
            table.reloadData(); busy = false; updateButtons()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let record = rows[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = record.createdAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        case "files": text = record.names.isEmpty ? L("등록된 파일 없음", "No registered files") : record.names.prefix(3).joined(separator: ", ") + (record.names.count > 3 ? "…" : "")
        default:
            if record.problem != nil { text = L("기록 복구 필요", "Receipt needs recovery") }
            else if let intake = record.intake, intake.copiedItemCount == intake.itemCount && intake.itemCount > 0 {
                text = L("복사 기록 있음", "Copy recorded")
            } else { text = L("\(record.names.count)개 · 보관 중", "\(record.names.count) · retained") }
        }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = record.problem ?? text + "\n" + record.names.joined(separator: "\n")
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        let chosen = selected
        status.toolTip = status.stringValue
        copy.isEnabled = !busy && !chosen.isEmpty && chosen.allSatisfy { $0.intake != nil && !$0.names.isEmpty }
        reveal.isEnabled = !chosen.isEmpty
        refresh.isEnabled = !busy
        cleanup.isEnabled = !busy && !chosen.isEmpty && chosen.allSatisfy {
            guard let intake = $0.intake else { return false }
            return intake.itemCount > 0 && intake.copiedItemCount == intake.itemCount && !FilePromiseReceiveWindow.isReceiving(intake)
        }
        cancelCleanup.isHidden = cleanupCancellation == nil
        cancelCleanup.isEnabled = cleanupCancellation?.isCancelled == false
        cleanupDetails.isHidden = cleanupResultLocations.isEmpty
        cleanupDetails.isEnabled = !cleanupResultLocations.isEmpty
    }
    @objc private func revealCleanupResults() {
        NSWorkspace.shared.activateFileViewerSelecting(cleanupResultLocations)
    }
    @objc private func stopCleanup() {
        cleanupCancellation?.cancel()
        status.stringValue = L("안전한 지점에서 정리를 중지하는 중…", "Stopping cleanup at a safe point…")
        updateButtons()
    }
    @objc private func cleanupSelected() {
        guard cleanup.isEnabled else { return }
        guard !BrowserWindow.entryOperationRunning, !CopyWindow.isRunning, !MoveWindow.isRunning, !FolderMergeWindow.isRunning else {
            status.stringValue = L("다른 파일 작업이 끝난 뒤 정리하세요.", "Clean up after the other file operation finishes."); return
        }
        let intakes = selected.compactMap(\.intake)
        guard !intakes.contains(where: { FilePromiseReceiveWindow.isReceiving($0) }) else { return }
        let cancellation = CopyCancellation(), move = cleanupMove
        let trashedMessage = L("검증된 보관본을 휴지통으로 옮겼습니다. 복사본은 유지됩니다.", "Verified retained exports moved to Trash. Their copies remain available.")
        let cancelledMessage = L("정리를 중지했습니다.", "Cleanup stopped.")
        let states = [
            "restored": L("보관본을 원래 위치로 돌려놓았습니다. 정리를 완료하지 않았습니다.", "Retained files were restored. Cleanup was not completed."),
            "retained": L("정리하지 못해 보관본을 유지했습니다.", "Cleanup could not finish; retained files were kept."),
            "needsReview": L("정리를 완료하지 못했습니다. 아래 위치를 확인하세요.", "Cleanup could not finish. Inspect the location below.")
        ]
        let errors: [PromisedFileIntakeError: String] = [
            .noVerifiedCopy: L("복사본을 확인할 수 없어 보관본을 유지했습니다.", "Could not verify a copy; retained originals were kept."),
            .changedItem: L("수신 파일이 바뀌어 정리하지 않았습니다.", "Received files changed; cleanup was refused."),
            .changedRoot: L("보관 위치가 바뀌어 정리하지 않았습니다.", "The retained location changed; cleanup was refused."),
            .unknownContents: L("추가 파일이 있어 보관본을 유지했습니다.", "Additional files were found; retained originals were kept."),
            .invalidManifest: L("수신 기록을 확인하지 못해 보관본을 유지했습니다.", "The receipt could not be verified; retained originals were kept."),
            .invalidLocation: L("보관 위치나 복사 위치를 확인하지 못했습니다.", "Could not verify the retained or copied location.")
        ]
        cleanupID = UUID(); cleanupProcessed = 0; cleanupTotal = intakes.count
        cleanupResultLocations = []
        cleanupNames = intakes.flatMap { $0.receivedNames }.prefix(3).joined(separator: ", ")
        let operationID = cleanupID
        cleanupCancellation = cancellation; busy = true; Self.cleaningController = self
        status.stringValue = L("원본과 복사본 재검증 중…", "Rechecking retained originals and copies…"); updateButtons()
        FileOperationCenter.activityChanged()
        Task { [self] in
            let outcome: (messages: [String], cleaned: [URL], processed: Int, locations: [URL]) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var messages: [String] = []
                    var cleaned: [URL] = []
                    var processed = 0
                    var locations: [URL] = []
                    for intake in intakes {
                        if cancellation.isCancelled { break }
                        do {
                            let result = try move(intake, cancellation)
                            locations.append(result.retainedAt ?? result.journal)
                            if result.state == "trashed" { messages.append(trashedMessage); cleaned.append(result.original) }
                            else {
                                messages.append((states[result.state] ?? states["needsReview"]!) +
                                    "\n" + (result.retainedAt?.path ?? result.journal.path))
                            }
                        } catch is CancellationError { messages.append(cancelledMessage); break }
                        catch {
                            let reason = (error as? PromisedFileIntakeError).flatMap { errors[$0] } ?? error.localizedDescription
                            messages.append(intake.receivedNames.prefix(2).joined(separator: ", ") + ": " + reason)
                            locations.append(intake.directoryURL)
                        }
                        processed += 1
                        let completed = processed
                        Task { @MainActor [weak self] in
                            guard let self, self.cleanupID == operationID, self.cleanupCancellation != nil else { return }
                            self.cleanupProcessed = completed; FileOperationCenter.activityChanged()
                        }
                    }
                    continuation.resume(returning: (messages, cleaned, processed, locations))
                }
            }
            Self.cleaningController = nil; cleanupCancellation = nil; busy = false
            cleanupProcessed = outcome.processed; cleanupResultLocations = outcome.locations
            FilePromiseReceiveWindow.forgetCleanedIntakes(outcome.cleaned)
            let messages = outcome.messages
            let message = messages.isEmpty ? L("정리를 중지했습니다. 보관본은 유지됩니다.", "Cleanup stopped. Retained files remain available.") : messages.joined(separator: "\n")
            status.stringValue = message
            FileOperationCenter.retainResult(activity); FileOperationCenter.activityChanged()
            load(message: message)
        }
    }
    private var activity: FileOperationActivity {
        FileOperationActivity(id: cleanupID, title: L("수신 보관본 정리", "Clean Up Received Exports"),
            destination: cleanupNames, status: status.stringValue,
            progress: cleanupCancellation != nil ? (cleanupProcessed, cleanupTotal) : nil,
            showDetails: { [weak self] in self?.showWindow(nil); self?.window?.makeKeyAndOrderFront(nil) },
            cancel: cleanupCancellation != nil ? { [weak self] in self?.stopCleanup() } : nil)
    }
    @objc private func revealFiles() { NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.directoryURL)) }
    @objc private func resumeCopy() {
        guard copy.isEnabled, let window else { return }
        let intakes = selected.compactMap(\.intake)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("여기로 복사", "Copy Here")
        busy = true; updateButtons()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.busy = false; self.updateButtons(); return }
            self.resume(intakes: intakes, destination: destination)
        }
    }
#if DEBUG
    static func verifyRecovery(storage: URL, destination: URL, pendingReceiver: NSFilePromiseReceiver?) async -> [String: Bool] {
        let controller = ReceivedFilesWindow(storage: storage) { _, _, _, decision in decision(false) }
        defer { controller.window?.close() }
        controller.reload()
        for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        var checks = ["recoveryListsPersistedJobs": !controller.busy && controller.rows.count == 2 && controller.table.numberOfRows == 2]
        if let healthy = controller.rows.firstIndex(where: { $0.intake != nil }) {
            controller.table.selectRowIndexes(IndexSet(integer: healthy), byExtendingSelection: false)
            controller.updateButtons()
            checks["recoveryEnablesVerifiedCopyRequest"] = controller.copy.isEnabled && controller.reveal.isEnabled
        }
        if let damaged = controller.rows.firstIndex(where: { $0.intake == nil }) {
            controller.table.selectRowIndexes(IndexSet(integer: damaged), byExtendingSelection: false)
            controller.updateButtons()
            checks["recoveryDamagedReceiptAllowsRevealOnly"] = !controller.copy.isEnabled && controller.reveal.isEnabled
        }
        controller.table.selectAll(nil); controller.updateButtons()
        checks["recoveryMixedSelectionProtectsDamagedData"] = !controller.copy.isEnabled && controller.reveal.isEnabled
        checks["cleanupRejectsUncopiedAndDamagedSelections"] = !controller.cleanup.isEnabled
        let probe = CleanupVerificationProbe()
        defer {
            // Move only the exact QA directory back out of Trash; never empty user Trash.
            if let (result, identity) = probe.result, result.state == "trashed", let identity, identity.isCurrent {
                let retained = storage.deletingLastPathComponent().appendingPathComponent("verified-trash-fixture-\(UUID())")
                try? FileManager.default.moveItem(at: identity.url, to: retained)
            }
        }
        do {
            guard let intake = controller.rows.compactMap(\.intake).first else { throw PromisedFileIntakeError.invalidManifest }
            let sources = try await Task.detached { try intake.verifiedSources() }.value
            let journals = storage.deletingLastPathComponent().appendingPathComponent("cleanup-qa-operations")
            let copied = await CopyEngine.run(sources: sources, destination: destination,
                journalDirectory: journals, cancellation: CopyCancellation(), sourceIntakes: [intake])
            checks["cleanupReceiptsPersistAfterVerifiedCopy"] = copied.state == "completed" && intake.copiedItemCount == intake.itemCount
            controller.reload()
            for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
            if let healthy = controller.rows.firstIndex(where: { $0.intake != nil }) {
                controller.table.selectRowIndexes(IndexSet(integer: healthy), byExtendingSelection: false); controller.updateButtons()
            }
            checks["cleanupEnablesOnlyRecordedCopyCandidates"] = controller.cleanup.isEnabled
            if let pendingReceiver, let selectedIntake = controller.selected.first?.intake {
                FilePromiseReceiveWindow.duringPendingReceiveVerification(intake: selectedIntake, receiver: pendingReceiver) {
                    controller.updateButtons()
                    checks["cleanupBlocksPendingSDKReceiver"] = !controller.cleanup.isEnabled
                }
                controller.updateButtons()
            }
            if let window = controller.window, let view = window.contentView {
                await prepareReceivedVerificationFrame(window, table: controller.table)
                let buttons = [controller.copy, controller.reveal, controller.refresh, controller.history, controller.cleanup]
                checks["cleanupControlsFitMinimumWindow"] = buttons.allSatisfy {
                    view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
                }
                do {
                    let png = try await captureReceivedVerificationPNG(window, table: controller.table)
                    try png.write(to: storage.deletingLastPathComponent().appendingPathComponent("received-cleanup-controls.png"))
                    checks["cleanupControlsCaptureWritten"] = true
                } catch { checks["cleanupControlsCaptureWritten"] = false }
            }

            controller.cleanupMove = { intake, cancellation in
                let result = try intake.moveVerifiedCopiesToTrash(journalDirectory: journals, cancellation: cancellation)
                probe.record(result); return result
            }
            controller.cleanupSelected()
            checks["cleanupBlocksOtherJobsAndOffersCancellation"] = BrowserWindow.entryOperationRunning && controller.cancelCleanup.isEnabled && !controller.cancelCleanup.isHidden
                && Self.activities.count == 1 && Self.activities.first?.progress?.total == 1
            for _ in 0..<1000 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
            checks["cleanupMovesVerifiedIntakeToSystemTrash"] = probe.result?.0.state == "trashed"
            checks["cleanupResultsCanBeRevealed"] = controller.cleanupDetails.isEnabled && !controller.cleanupDetails.isHidden
                && !controller.cleanupResultLocations.isEmpty
                && controller.cleanupResultLocations.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            checks["cleanupRefreshesListAndReleasesOperationGuard"] = !controller.busy && !BrowserWindow.entryOperationRunning && controller.rows.count == 1 && controller.rows.first?.problem != nil
            checks["cleanupClosesFinishedReceiveWindow"] = FilePromiseReceiveWindow.verifyFinishedIntakeCleanup(intake)
            checks.merge(await CleanupHistoryWindow.verify(journals: journals, storage: storage)) { _, new in new }
            checks.merge(await CleanupHistoryWindow.verifyRestore(journals: journals, storage: storage)) { _, new in new }
            if FileManager.default.fileExists(atPath: intake.directoryURL.path) {
                _ = try intake.verifiedSources()
                let retained = storage.deletingLastPathComponent().appendingPathComponent("verified-restored-fixture-\(UUID())")
                try FileManager.default.moveItem(at: intake.directoryURL, to: retained)
                checks["cleanupFixtureReturnedFromTrash"] = FileManager.default.fileExists(atPath: retained.appendingPathComponent("Files/received.txt").path)
            }
            if let (result, identity) = probe.result, result.state == "trashed", let identity, identity.isCurrent {
                let retained = storage.deletingLastPathComponent().appendingPathComponent("verified-trash-fixture-\(UUID())")
                try FileManager.default.moveItem(at: identity.url, to: retained)
                checks["cleanupFixtureReturnedFromTrash"] = FileManager.default.fileExists(atPath: retained.appendingPathComponent("Files/received.txt").path)
            }

        } catch { checks["cleanupVerificationSetup"] = false }
        return checks
    }
#endif
    private func resume(intakes: [PromisedFileIntake], destination: URL) {
        guard let destinationIdentity = ShelfEntry(destination.resolvingSymlinksInPath()) else {
            busy = false; status.stringValue = L("대상 폴더를 확인할 수 없습니다. 다시 선택하세요.", "Could not identify the destination folder. Select it again."); updateButtons(); return
        }
        status.stringValue = L("받은 파일 재검증 중…", "Verifying received files again…")
        Task { [self] in
            do {
                let sources = try await Task.detached { try intakes.flatMap { try $0.verifiedSources() } }.value
                guard destinationIdentity.isCurrent else { throw EntryOperationError.sourceChanged }
                prepare(sources, intakes, destination) { [weak self] accepted in
                    guard let self else { return }
                    self.busy = false
                    self.status.stringValue = accepted ? L("복사 작업으로 전달했습니다. 보관된 원본은 유지됩니다.", "Handed off to the copy job. Retained originals are preserved.") : L("복사 요청이 취소되었거나 다른 작업이 진행 중입니다. 다시 시도할 수 있습니다.", "The copy request was cancelled or another job is running. You can retry.")
                    self.updateButtons()
                }
            } catch { busy = false; status.stringValue = L("수신 파일을 재검증하지 못했습니다. 보관된 파일을 확인하세요. ", "Could not verify received files. Inspect the retained files. ") + error.localizedDescription; updateButtons() }
        }
    }
}

/// A fresh controller reads durable journals, including jobs interrupted in a previous process.
@MainActor
final class CleanupHistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: CleanupHistoryWindow?
    private static weak var restoringController: CleanupHistoryWindow?
    static var isRestoring: Bool { restoringController != nil }
    static var activities: [FileOperationActivity] { restoringController.map { [$0.activity] } ?? [] }
    private let journals: URL
    private let storage: URL
    private var rows: [PromisedFileCleanupRecovery] = []
    private var busy = false
    private var restoreCancellation: CopyCancellation?
    private var restoreID = UUID()
    private var restoreNames = ""
    private let table = NSTableView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let reveal = NSButton(title: L("보관 위치 보기", "Show Retained Location"), target: nil, action: #selector(showLocation))
    private let record = NSButton(title: L("기록 파일 보기", "Show Record File"), target: nil, action: #selector(showRecord))
    private let refresh = NSButton(title: L("새로 고침", "Refresh"), target: nil, action: #selector(reload))
    private let restore = NSButton(title: L("보관소로 복원", "Restore to Storage"), target: nil, action: #selector(restoreSelected))
    private let stop = NSButton(title: L("복원 중지", "Stop Restore"), target: nil, action: #selector(stopRestore))
    static func present(journals: URL, storage: URL) {
        let controller = CleanupHistoryWindow(journals: journals, storage: storage)
        shared = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.reload()
    }
    private init(journals: URL, storage: URL) {
        self.journals = journals; self.storage = storage
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L("수신 보관본 정리 기록", "Received Export Cleanup History")
        window.minSize = NSSize(width: 620, height: 480); window.isReleasedWhenClosed = false; window.center()
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel(window.title)
        for (id, title, width) in [("job", L("수신 작업", "Receive Job"), 190.0), ("kind", L("작업", "Action"), 80.0), ("state", L("현재 보관 위치", "Current Retention"), 250.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            column.minWidth = id == "job" ? 160 : id == "kind" ? 70 : 200; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        let intro = NSTextField(wrappingLabelWithString: L("앱을 다시 실행해도 이전 정리 기록을 확인할 수 있습니다. 중단되거나 위치를 확인하지 못한 작업은 기록을 보존합니다. 자동 이동이나 삭제는 하지 않습니다.", "Review cleanup records after restarting the app. Interrupted jobs and unknown locations remain recorded. Files are never moved or deleted automatically."))
        let help = NSTextField(wrappingLabelWithString: L("표시는 폴더와 수신 기록의 동일성 확인 결과입니다. 원본·복사본 내용이 현재 일치한다는 뜻은 아닙니다. 위치를 찾지 못하면 기록 파일에서 마지막 상태를 확인하세요.", "Locations are checked against the folder identity and receive receipt. This does not verify current original or copy contents. If a location is unknown, inspect the record for its last saved state."))
        details.maximumNumberOfLines = 3
        let buttons = NSStackView(views: [restore, stop, reveal, record, refresh]); buttons.spacing = 10; buttons.detachesHiddenViews = true
        restore.toolTip = L("보관본을 다시 검증한 뒤 원래 보관소로 옮깁니다. 같은 경로에 있는 항목은 덮어쓰지 않습니다.", "Recheck retained files and move them to the original storage. Existing items are never overwritten.")
        for button in [restore, stop, reveal, record, refresh] { button.target = self }
        let stack = NSStackView(views: [intro, scroll, details, help, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var selected: PromisedFileCleanupRecovery? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    @objc private func reload() { load(message: nil) }
    private func load(message: String?) {
        guard !busy else { return }; busy = true; updateSelection()
        details.stringValue = L("이전 정리 기록 확인 중…", "Checking previous cleanup records…")
        let journals = journals, storage = storage
        Task { [self] in
            let result: Result<[PromisedFileCleanupRecovery], Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result { try PromisedFileCleanupRecovery.discover(in: journals, storage: storage) })
                }
            }
            busy = false
            switch result {
            case .success(let records): rows = records; table.reloadData(); updateSelection(); if let message { details.stringValue = message; details.toolTip = message }
            case .failure(let error): rows = []; table.reloadData(); updateSelection(); details.stringValue = error.localizedDescription
            }
        }
    }
    private func stateText(_ row: PromisedFileCleanupRecovery) -> String {
        switch row.status {
        case .atOriginal: return row.recordedState == "restored" ? L("보관소로 복원됨", "Restored to storage") : L("원래 위치에 보관 중", "Retained at original location")
        case .retainedElsewhere: return L("기록된 이동 위치에 보관 중", "Retained at recorded moved location")
        case .unlocated: return L("위치 확인 필요", "Location needs review")
        case .legacy: return L("이전 형식 · 직접 확인 필요", "Older record · manual review")
        case .invalid: return L("기록 확인 필요", "Record needs review")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let name = item.receivedNames.isEmpty ? (item.original?.lastPathComponent ?? item.journal.lastPathComponent) : item.receivedNames.prefix(3).joined(separator: ", ")
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "job": text = name
        case "kind": text = item.isRestoreRecord ? L("복원", "Restore") : L("정리", "Cleanup")
        default: text = stateText(item)
        }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = text; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { !busy }
    private func updateSelection() {
        reveal.isEnabled = !busy && selected?.location != nil; record.isEnabled = !busy && selected != nil; refresh.isEnabled = !busy
        restore.isEnabled = !busy && selected?.canRestore == true
        restore.isHidden = restoreCancellation != nil; stop.isHidden = restoreCancellation == nil
        stop.isEnabled = restoreCancellation?.isCancelled == false
        if let row = selected {
            let savedState = row.recordedState ?? L("읽기 실패", "Unreadable")
            let interrupted = ["verified", "movedToTrash", "needsReview", "restorePrepared"].contains(savedState)
            details.stringValue = (interrupted ? L("미완료 정리 · ", "Interrupted cleanup · ") : "") + stateText(row)
                + "\n" + (row.location?.path ?? row.journal.path)
                + (row.message.map { "\n" + $0 } ?? "")
        } else { details.stringValue = rows.isEmpty ? L("이전 정리 기록이 없습니다.", "No previous cleanup records.") : L("정리 기록 \(rows.count)개 · 작업을 선택하세요.", "\(rows.count) cleanup records · select a job.") }
        details.toolTip = details.stringValue
    }
    @objc private func showRecord() { if let row = selected { NSWorkspace.shared.activateFileViewerSelecting([row.journal]) } }
    @objc private func stopRestore() {
        restoreCancellation?.cancel(); updateSelection()
        details.stringValue = L("안전한 지점에서 복원을 중지하는 중…", "Stopping restore at a safe point…"); details.toolTip = details.stringValue
        FileOperationCenter.activityChanged()
    }
    @objc private func restoreSelected() {
        guard !busy, let row = selected, row.canRestore else { return }
        guard !BrowserWindow.entryOperationRunning, !CopyWindow.isRunning, !MoveWindow.isRunning, !FolderMergeWindow.isRunning else {
            details.stringValue = L("다른 파일 작업이 끝난 뒤 복원하세요.", "Restore after the other file operation finishes."); return
        }
        let cancellation = CopyCancellation(), storage = storage
        restoreCancellation = cancellation; restoreID = UUID(); restoreNames = row.receivedNames.prefix(3).joined(separator: ", ")
        busy = true; Self.restoringController = self; updateSelection()
        details.stringValue = L("보관본 재검증 및 복원 중…", "Rechecking and restoring retained files…"); FileOperationCenter.activityChanged()
        Task { [self] in
            let outcome: Result<PromisedFileCleanupResult, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result { try row.restore(storage: storage, cancellation: cancellation) })
                }
            }
            busy = false; restoreCancellation = nil; Self.restoringController = nil
            let message: String
            switch outcome {
            case .success(let result):
                let summary: String
                if result.state == "restored" {
                    summary = L("보관소로 복원했습니다. 복사본은 유지됩니다.", "Restored to storage. Published copies remain available.")
                    ReceivedFilesWindow.refreshAfterRestore()
                }
                else if result.restoreFailure == .conflict { summary = L("원래 경로에 다른 항목이 있어 복원하지 않았습니다. 기존 항목과 보관본을 유지했습니다.", "Another item occupies the original path. Both it and the retained files were kept.") }
                else if result.restoreFailure == .cancelled { summary = L("복원을 중지했습니다. 아래 보관 위치를 확인하세요.", "Restore stopped. Inspect the retained location below.") }
                else { summary = L("복원을 완료하지 못했습니다. 기록과 보관 위치를 확인하세요.", "Restore did not complete. Inspect the record and retained location.") }
                message = summary + "\n" + (result.retainedAt?.path ?? result.journal.path)
            case .failure(let error):
#if DEBUG
                if ProcessInfo.processInfo.environment["FILES_PROMISE_QA_OUTPUT"] != nil { print("Restore failure:", String(reflecting: error)) }
#endif
                if error is CancellationError {
                    message = L("복원을 중지했습니다. 보관본은 유지됩니다.", "Restore stopped. Retained files were kept.")
                } else if (error as? PromisedFileRestoreFailure) == .conflict {
                    message = L("원래 경로에 다른 항목이 있어 복원하지 않았습니다. 기존 항목과 보관본을 유지했습니다.", "Another item occupies the original path. Both it and the retained files were kept.")
                } else {
                    message = L("보관본이나 기록이 바뀌었거나 접근할 수 없어 복원하지 않았습니다. 보관 위치와 기록을 확인하세요.", "Retained files or records changed or could not be accessed. Inspect the retained location and record.")
                }
            }
            details.stringValue = message; FileOperationCenter.retainResult(activity); FileOperationCenter.activityChanged()
            load(message: message)
        }
    }
    private var activity: FileOperationActivity {
        FileOperationActivity(id: restoreID, title: L("수신 보관본 복원", "Restore Received Exports"), destination: restoreNames,
            status: details.stringValue, progress: nil,
            showDetails: { [weak self] in self?.showWindow(nil); self?.window?.makeKeyAndOrderFront(nil) },
            cancel: restoreCancellation != nil ? { [weak self] in self?.stopRestore() } : nil)
    }
    @objc private func showLocation() {
        guard let row = selected, let location = row.location else { return }
        // This is a read-only Finder action; a fresh reload rechecks location ownership.
        NSWorkspace.shared.activateFileViewerSelecting([location]); reload()
    }
#if DEBUG
    static func verifyRestore(journals: URL, storage: URL, payloadName: String = "received.txt") async -> [String: Bool] {
        let controller = CleanupHistoryWindow(journals: journals, storage: storage)
        defer { controller.window?.close() }
        controller.reload()
        for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        var checks: [String: Bool] = [:]
        guard let owned = controller.rows.firstIndex(where: { $0.canRestore }) else { return ["restoreActionAvailableForCurrentProof": false] }
        controller.table.selectRowIndexes(IndexSet(integer: owned), byExtendingSelection: false); controller.updateSelection()
        guard let row = controller.selected, let original = row.original, let bytes = try? Data(contentsOf: row.journal) else { return ["restoreSetup": false] }
        checks["restoreActionAvailableForCurrentProof"] = controller.restore.isEnabled
        if let window = controller.window, let view = window.contentView {
            await prepareReceivedVerificationFrame(window, table: controller.table)
            checks["restoreControlsFitMinimumWindow"] = [controller.restore, controller.reveal, controller.record, controller.refresh].allSatisfy {
                view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
            }
            checks["restoreTableColumnsAlign"] = receivedVerificationColumnsAlign(controller.table)
            do {
                    let png = try await captureReceivedVerificationPNG(window, table: controller.table)
                    try png.write(to: storage.deletingLastPathComponent().appendingPathComponent("received-restore-controls.png"))
                    checks["restoreCaptureWritten"] = true
                } catch { checks["restoreCaptureWritten"] = false }
        }
        controller.restoreSelected()
        checks["restorePreventsConcurrentFileJobs"] = isRestoring && BrowserWindow.entryOperationRunning && controller.stop.isEnabled
            && activities.count == 1 && activities.first?.cancel != nil
        for _ in 0..<1000 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        checks["restoreReturnsFixtureToOriginalStorage"] = FileManager.default.fileExists(atPath: original.appendingPathComponent("Files/" + payloadName).path)
        checks["restorePreservesSourceCleanupJournal"] = (try? Data(contentsOf: row.journal)) == bytes
        checks["restoreHistoryPreventsRepeatedRestore"] = !controller.busy && !isRestoring && !BrowserWindow.entryOperationRunning
            && !controller.rows.contains(where: \.canRestore) && controller.rows.contains { $0.recordedState == "restored" && $0.isRestoreRecord }
        return checks
    }
    static func verifyInterruptedRestart(journals: URL, storage: URL, output: URL) async -> [String: Bool] {
        let controller = CleanupHistoryWindow(journals: journals, storage: storage)
        defer { controller.window?.close() }
        controller.reload()
        for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        var checks = ["restartHistoryReadsInterruptedJournal": !controller.busy && controller.rows.count == 1]
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); controller.updateSelection()
        checks["restartHistoryDoesNotInventMovedLocation"] = controller.selected?.status == .unlocated && !controller.reveal.isEnabled && controller.record.isEnabled && !controller.restore.isEnabled
        checks["restartHistoryExplainsInterruptedState"] = controller.selected?.recordedState == "verified"
            && controller.details.stringValue.contains(L("미완료 정리", "Interrupted cleanup"))
        if let window = controller.window, let view = window.contentView {
            await prepareReceivedVerificationFrame(window, table: controller.table)
            checks["restartHistoryControlsFitMinimumWindow"] = [controller.restore, controller.reveal, controller.record, controller.refresh].allSatisfy {
                view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
            }
            do {
                    let png = try await captureReceivedVerificationPNG(window, table: controller.table)
                    try png.write(to: output.appendingPathComponent("interrupted-cleanup-history.png"))
                    checks["restartHistoryCaptureWritten"] = true
                } catch { checks["restartHistoryCaptureWritten"] = false }
        }
        return checks
    }
    static func verify(journals: URL, storage: URL) async -> [String: Bool] {
        let damaged = journals.appendingPathComponent("promise-cleanup-ui-damaged-\(UUID()).json")
        do { try Data("interrupted invalid fixture".utf8).write(to: damaged) }
        catch { return ["cleanupHistoryDamagedSetup": false] }
        defer { try? FileManager.default.removeItem(at: damaged) }
        let controller = CleanupHistoryWindow(journals: journals, storage: storage)
        defer { controller.window?.close() }
        controller.reload()
        for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        var checks = ["cleanupHistoryFreshControllerReadsDurableRecord": !controller.busy && controller.rows.count == 2]
        if let invalid = controller.rows.firstIndex(where: { $0.status == .invalid }) {
            controller.table.selectRowIndexes(IndexSet(integer: invalid), byExtendingSelection: false); controller.updateSelection()
            checks["cleanupHistoryDamagedRecordAllowsJournalOnly"] = !controller.reveal.isEnabled && controller.record.isEnabled
        }
        if let owned = controller.rows.firstIndex(where: { $0.status == .retainedElsewhere }) {
            controller.table.selectRowIndexes(IndexSet(integer: owned), byExtendingSelection: false); controller.updateSelection()
        }
        checks["cleanupHistoryFindsOwnedTrashLocation"] = controller.selected?.status == .retainedElsewhere && controller.reveal.isEnabled && controller.record.isEnabled
        if let window = controller.window, let view = window.contentView {
            await prepareReceivedVerificationFrame(window, table: controller.table)
            checks["cleanupHistoryControlsFitMinimumWindow"] = [controller.restore, controller.reveal, controller.record, controller.refresh].allSatisfy {
                view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
            }
            do {
                    let png = try await captureReceivedVerificationPNG(window, table: controller.table)
                    try png.write(to: storage.deletingLastPathComponent().appendingPathComponent("received-cleanup-history.png"))
                    checks["cleanupHistoryCaptureWritten"] = true
                } catch { checks["cleanupHistoryCaptureWritten"] = false }
        }
        return checks
    }
#endif
}

#if DEBUG
@MainActor
private func prepareReceivedVerificationFrame(_ window: NSWindow, table: NSTableView) async {
    let selection = table.selectedRowIndexes
    window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
    window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded(); table.reloadData(); window.displayIfNeeded()
    // Let AppKit finish its queued column sizing and cell reuse before caching pixels.
    try? await Task.sleep(for: .milliseconds(20))
    window.contentView?.layoutSubtreeIfNeeded(); table.reloadData(); table.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    table.selectRowIndexes(selection, byExtendingSelection: false)
}

@MainActor
private func receivedVerificationColumnsAlign(_ table: NSTableView) -> Bool {
    guard table.numberOfRows > 0 else { return false }
    return table.tableColumns.indices.allSatisfy { column in
        let body = table.rect(ofColumn: column)
        guard let header = table.headerView?.headerRect(ofColumn: column),
              abs(header.minX - body.minX) < 1, abs(header.width - body.width) < 1,
              let cell = table.view(atColumn: column, row: 0, makeIfNecessary: true) else { return false }
        let frame = table.convert(cell.bounds, from: cell)
        return frame.minX >= body.minX - 1 && frame.maxX <= body.maxX + 1
    }
}
#endif

#if DEBUG
@MainActor
private func captureReceivedVerificationPNG(_ window: NSWindow, table: NSTableView) async throws -> Data {
    guard let view = window.contentView else { throw CocoaError(.fileWriteUnknown) }
    let selection = table.selectedRowIndexes
    var previous: [CGFloat]?
    for _ in 0..<4 {
        view.layoutSubtreeIfNeeded(); table.reloadData(); table.selectRowIndexes(selection, byExtendingSelection: false)
        table.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let before = table.tableColumns.map(\.width)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                context.setBlendMode(.destinationOver); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            }
        }
        let after = table.tableColumns.map(\.width)
        if previous == before, before == after, receivedVerificationColumnsAlign(table),
           let png = bitmap.representation(using: .png, properties: [:]) { return png }
        previous = after
    }
    throw CocoaError(.fileWriteUnknown)
}
#endif
