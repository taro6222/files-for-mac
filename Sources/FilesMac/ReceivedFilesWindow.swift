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
    static var isCleaning: Bool { cleaningController != nil }
    static var activities: [FileOperationActivity] { cleaningController.map { [$0.activity] } ?? [] }
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
                window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false); view.layoutSubtreeIfNeeded()
                let buttons = [controller.copy, controller.reveal, controller.refresh, controller.history, controller.cleanup]
                checks["cleanupControlsFitMinimumWindow"] = buttons.allSatisfy {
                    view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
                }
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                            context.setBlendMode(.destinationOver); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                            context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                        }
                    }
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: storage.deletingLastPathComponent().appendingPathComponent("received-cleanup-controls.png"))
                        checks["cleanupControlsCaptureWritten"] = true
                    }
                }
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
    private let journals: URL
    private let storage: URL
    private var rows: [PromisedFileCleanupRecovery] = []
    private var busy = false
    private let table = NSTableView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let reveal = NSButton(title: L("보관 위치 보기", "Show Retained Location"), target: nil, action: #selector(showLocation))
    private let record = NSButton(title: L("기록 파일 보기", "Show Record File"), target: nil, action: #selector(showRecord))
    private let refresh = NSButton(title: L("새로 고침", "Refresh"), target: nil, action: #selector(reload))
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
        for (id, title, width) in [("job", L("수신 작업", "Receive Job"), 240.0), ("state", L("현재 보관 위치", "Current Retention"), 260.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        let intro = NSTextField(wrappingLabelWithString: L("앱을 다시 실행해도 이전 정리 기록을 확인할 수 있습니다. 중단되거나 위치를 확인하지 못한 작업은 기록을 보존합니다. 자동 이동이나 삭제는 하지 않습니다.", "Review cleanup records after restarting the app. Interrupted jobs and unknown locations remain recorded. Files are never moved or deleted automatically."))
        let help = NSTextField(wrappingLabelWithString: L("표시는 폴더와 수신 기록의 동일성 확인 결과입니다. 원본·복사본 내용이 현재 일치한다는 뜻은 아닙니다. 위치를 찾지 못하면 기록 파일에서 마지막 상태를 확인하세요.", "Locations are checked against the folder identity and receive receipt. This does not verify current original or copy contents. If a location is unknown, inspect the record for its last saved state."))
        details.maximumNumberOfLines = 3
        let buttons = NSStackView(views: [reveal, record, refresh]); buttons.spacing = 10
        for button in [reveal, record, refresh] { button.target = self }
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
    @objc private func reload() {
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
            case .success(let records): rows = records; table.reloadData(); updateSelection()
            case .failure(let error): rows = []; table.reloadData(); updateSelection(); details.stringValue = error.localizedDescription
            }
        }
    }
    private func stateText(_ row: PromisedFileCleanupRecovery) -> String {
        switch row.status {
        case .atOriginal: return L("원래 위치에 보관 중", "Retained at original location")
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
        let text = tableColumn?.identifier.rawValue == "job" ? name : stateText(item)
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = text; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        reveal.isEnabled = !busy && selected?.location != nil; record.isEnabled = !busy && selected != nil; refresh.isEnabled = !busy
        if let row = selected {
            let savedState = row.recordedState ?? L("읽기 실패", "Unreadable")
            let interrupted = ["verified", "movedToTrash", "needsReview"].contains(savedState)
            details.stringValue = (interrupted ? L("미완료 정리 · ", "Interrupted cleanup · ") : "") + stateText(row)
                + "\n" + (row.location?.path ?? row.journal.path)
                + (row.message.map { "\n" + $0 } ?? "")
        } else { details.stringValue = rows.isEmpty ? L("이전 정리 기록이 없습니다.", "No previous cleanup records.") : L("정리 기록 \(rows.count)개 · 작업을 선택하세요.", "\(rows.count) cleanup records · select a job.") }
        details.toolTip = details.stringValue
    }
    @objc private func showRecord() { if let row = selected { NSWorkspace.shared.activateFileViewerSelecting([row.journal]) } }
    @objc private func showLocation() {
        guard let row = selected, let location = row.location else { return }
        // This is a read-only Finder action; a fresh reload rechecks location ownership.
        NSWorkspace.shared.activateFileViewerSelecting([location]); reload()
    }
#if DEBUG
    static func verifyInterruptedRestart(journals: URL, storage: URL, output: URL) async -> [String: Bool] {
        let controller = CleanupHistoryWindow(journals: journals, storage: storage)
        defer { controller.window?.close() }
        controller.reload()
        for _ in 0..<500 where controller.busy { try? await Task.sleep(for: .milliseconds(10)) }
        var checks = ["restartHistoryReadsInterruptedJournal": !controller.busy && controller.rows.count == 1]
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); controller.updateSelection()
        checks["restartHistoryDoesNotInventMovedLocation"] = controller.selected?.status == .unlocated && !controller.reveal.isEnabled && controller.record.isEnabled
        checks["restartHistoryExplainsInterruptedState"] = controller.selected?.recordedState == "verified"
            && controller.details.stringValue.contains(L("미완료 정리", "Interrupted cleanup"))
        if let window = controller.window, let view = window.contentView {
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false); view.layoutSubtreeIfNeeded()
            checks["restartHistoryControlsFitMinimumWindow"] = [controller.reveal, controller.record, controller.refresh].allSatisfy {
                view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
            }
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                        context.setBlendMode(.destinationOver); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                    }
                }
                do {
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try png.write(to: output.appendingPathComponent("interrupted-cleanup-history.png"))
                    checks["restartHistoryCaptureWritten"] = true
                } catch { checks["restartHistoryCaptureWritten"] = false }
            }
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
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false); view.layoutSubtreeIfNeeded()
            checks["cleanupHistoryControlsFitMinimumWindow"] = [controller.reveal, controller.record, controller.refresh].allSatisfy {
                view.bounds.contains(view.convert($0.bounds, from: $0)) && $0.frame.width >= $0.fittingSize.width - 1
            }
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                        context.setBlendMode(.destinationOver); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                    }
                }
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do {
                        try png.write(to: storage.deletingLastPathComponent().appendingPathComponent("received-cleanup-history.png"))
                        checks["cleanupHistoryCaptureWritten"] = true
                    } catch { checks["cleanupHistoryCaptureWritten"] = false }
                }
            }
        }
        return checks
    }
#endif
}
