#if DEBUG
import AppKit
import FilesCore

@MainActor
func verifyArchiveEditingUI(_ controller: ArchiveWindow, root: URL, progress: (String) -> Void = { _ in }, capture: (String, NSView?) throws -> Void) async throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let fm = FileManager.default
    controller.qaJournalDirectory = root.appendingPathComponent("archive-edit-journals")
    func idle() async throws {
        let start = ContinuousClock.now
        while (controller.qaIsRunning || controller.window?.attachedSheet != nil) && start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
        guard !controller.qaIsRunning, controller.window?.attachedSheet == nil else { throw SevenZipWorkerError.timedOut }
    }
    // Editing keeps recovery versions beside the archive. Keep those retained files
    // outside the separate 10,001-row browser fixture used later in this suite.
    guard let sourceArchive = controller.qaArchiveURL else { throw ArchiveEditError.invalidState }
    progress("plain-copy")
    let workingArchive = root.appendingPathComponent("archive-edit-working.zip")
    try fm.copyItem(at: sourceArchive, to: workingArchive)
    controller.present(archiveURL: workingArchive); try await idle()
    checks["archiveEditingAvailable"] = controller.qaEditReady
    controller.window?.makeKeyAndOrderFront(nil)
    checks["archiveEditingMenuRoute"] = NSApp.target(forAction: #selector(ArchiveWindow.createFolder(_:))) as? ArchiveWindow === controller
    controller.qaCreateFolder(); controller.qaSubmitName("../invalid")
    checks["archiveEditingInvalidName"] = controller.qaNameRejected
    try capture("archive-edit-invalid-name", controller.window?.attachedSheet?.contentView)
    controller.qaSubmitName("QA-folder"); try await idle()
    checks["archiveEditingNewFolder"] = controller.qaEntryPaths.contains("QA-folder")
    checks["archiveEditingUndoEnabled"] = controller.qaCanUndoEdit
    controller.qaSelectPaths(["QA-folder"]); controller.qaRename(); controller.qaSubmitName("renamed-folder"); try await idle()
    checks["archiveEditingRenameFolder"] = controller.qaEntryPaths.contains("renamed-folder") && !controller.qaEntryPaths.contains("QA-folder")
    let added = root.appendingPathComponent("archive-added-한글.txt"), bytes = Data("archive UI added payload".utf8)
    try bytes.write(to: added)
    controller.qaAdd([added], directory: "renamed-folder")
    checks["archiveEditingDisablesDuplicateOperation"] = controller.qaIsRunning && !controller.qaEditReady
    try await idle()
    checks["archiveEditingAddFile"] = controller.qaEntryPaths.contains("renamed-folder/" + added.lastPathComponent)
    checks["archiveEditingPreservesInput"] = (try Data(contentsOf: added)) == bytes
    let count = controller.qaEntryCount
    controller.qaAdd([added], directory: "renamed-folder"); try await idle()
    checks["archiveEditingDuplicateRejected"] = controller.qaEntryCount == count && controller.qaEntryPaths.filter { $0 == "renamed-folder/" + added.lastPathComponent }.count == 1
    controller.qaSelectPaths(["renamed-folder"]); controller.qaDelete(); controller.qaConfirm(false); try await idle()
    checks["archiveEditingDeleteCancel"] = controller.qaEntryCount == count
    controller.qaDelete(); controller.qaConfirm(true); try await idle()
    checks["archiveEditingDeleteTree"] = !controller.qaEntryPaths.contains(where: { $0 == "renamed-folder" || $0.hasPrefix("renamed-folder/") })
    controller.qaUndoEdit(); controller.qaConfirm(true); try await idle()
    checks["archiveEditingUndoDelete"] = controller.qaEntryPaths.contains("renamed-folder/" + added.lastPathComponent)
    controller.qaUndoEdit(); controller.qaConfirm(true); try await idle()
    checks["archiveEditingUndoAdd"] = controller.qaEntryPaths.contains("renamed-folder") && !controller.qaEntryPaths.contains("renamed-folder/" + added.lastPathComponent)
    checks["archiveEditingRedoAvailable"] = controller.qaCanRedoEdit
    controller.qaRedoEdit(); controller.qaConfirm(true); try await idle()
    checks["archiveEditingRedoAdd"] = controller.qaEntryPaths.contains("renamed-folder/" + added.lastPathComponent)
    controller.qaUndoEdit(); controller.qaConfirm(true); try await idle()
    checks["archiveEditingUndoRedoRoundTrip"] = !controller.qaEntryPaths.contains("renamed-folder/" + added.lastPathComponent)
    ArchiveEditRecoveryWindow.present(journalDirectory: root.appendingPathComponent("archive-edit-journals"))
    guard let history = ArchiveEditRecoveryWindow.qaLatest else { throw ArchiveEditError.invalidState }
    func historyIdle() async throws {
        let start = ContinuousClock.now
        while (history.qaBusy || history.window?.attachedSheet != nil) && start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
        guard !history.qaBusy, history.window?.attachedSheet == nil else { throw SevenZipWorkerError.timedOut }
    }
    try await historyIdle()
    checks["archiveHistoryListsRecords"] = !history.qaRecords.isEmpty
    guard let row = history.qaRecords.firstIndex(where: { $0.journal == controller.qaRedoJournal }) else { throw ArchiveEditError.invalidJournal }
    history.qaSelect(row)
    checks["archiveHistoryRequiresVerification"] = !history.qaCanUndo && !history.qaCanRedo
    history.qaVerify(); try await historyIdle()
    checks["archiveHistoryVerifiesRedoCandidate"] = history.qaCanRedo && !history.qaCanUndo
    checks["archiveHistoryDetailsVisible"] = history.qaDetailsVisible
    guard let currentArchive = controller.qaArchiveURL else { throw ArchiveEditError.invalidState }
    let beforeRecoveryCancel = try Data(contentsOf: currentArchive)
    history.qaRedo(); history.qaConfirm(false); try await historyIdle()
    checks["archiveHistoryCancelPreservesFiles"] = (try Data(contentsOf: currentArchive)) == beforeRecoveryCancel
    try capture("archive-edit-history", history.window?.contentView)
    history.close(); controller.window?.makeKeyAndOrderFront(nil)
    try capture("archive-edit-actions", controller.window?.contentView)

    progress("encrypted-zip-create")
    let archive = root.appendingPathComponent("archive-edit-encrypted.zip"), password = "UI-375-한글-🔑"
    _ = try await ZipArchiveProvider().create(from: [added], at: archive, password: password)
    controller.present(archiveURL: archive); try await idle()
    controller.qaSelectPaths([added.lastPathComponent]); controller.qaRename(); controller.qaSubmitName("renamed-secure.txt")
    guard let window = controller.window, let first = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    checks["archiveEditingPasswordPrompt"] = first.qaRejectsEmpty
    let original = try Data(contentsOf: archive); first.qaSubmit("incorrect")
    guard let retry = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    let afterWrongPassword = try Data(contentsOf: archive)
    checks["archiveEditingWrongPasswordPreservesArchive"] = afterWrongPassword == original && first !== retry
    retry.qaSubmit(password); try await idle()
    checks["archiveEditingPasswordRetry"] = controller.qaEntryPaths == ["renamed-secure.txt"]
    controller.qaAdd([added], directory: "")
    guard let addPassword = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    addPassword.qaSubmit(password); try await idle()
    progress("encrypted-zip-verify")
    let extracted = root.appendingPathComponent("archive-edit-encrypted-restored")
    try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
    _ = try await ZipArchiveProvider().extract(archive, to: extracted, password: password)
    checks["archiveEditingUnicodePasswordAddition"] = (try Data(contentsOf: extracted.appendingPathComponent(added.lastPathComponent))) == bytes
    controller.qaSelectPaths([added.lastPathComponent]); controller.qaRename(); controller.qaSubmitName("cancelled.txt")
    guard let cancelPassword = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    let beforeCancel = try Data(contentsOf: archive); cancelPassword.qaSubmit(nil); try await idle()
    checks["archiveEditingPasswordCancel"] = (try Data(contentsOf: archive)) == beforeCancel && !controller.qaEntryPaths.contains("cancelled.txt")
    let held = root.appendingPathComponent("archive-edit-held.zip")
    try fm.moveItem(at: archive, to: held)
    _ = try await ZipArchiveProvider().create(from: [added], at: archive)
    let foreign = try Data(contentsOf: archive)
    controller.qaCreateFolder(); controller.qaSubmitName("stale-selection"); try await idle()
    checks["archiveEditingStaleSelectionPreserved"] = (try Data(contentsOf: archive)) == foreign
    checks["archiveEditingStaleSelectionNeedsReload"] = !controller.qaEditReady
    progress("empty-zip-policy")
    let policyArchive = root.appendingPathComponent("archive-empty-zip-policy.zip"), policyPassword = "UI-379-한글-🔑"
    _ = try await ZipArchiveProvider().create(from: [added], at: policyArchive, password: password)
    controller.present(archiveURL: policyArchive); try await idle()
    let lockedOptions = controller.qaAdditionOptions()
    checks["archiveAdditionLocksExistingEncryption"] = lockedOptions.encryptNewData && !lockedOptions.encryption.isEnabled
    controller.qaSelectPaths([added.lastPathComponent]); controller.qaDelete()
    checks["archiveDeletingLastEncryptedZIPNotice"] = controller.qaDeleteNotice?.contains(L("암호화된 파일이 모두 삭제", "All encrypted files will be removed")) == true
    controller.qaConfirm(true)
    guard let deletePassword = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    deletePassword.qaSubmit(password); try await idle()
    let emptyZIP = try Data(contentsOf: policyArchive), emptyOptions = controller.qaAdditionOptions()
    checks["archiveEmptyZIPEncryptsByDefault"] = controller.qaEntryCount == 0 && emptyOptions.encryptNewData && emptyOptions.encryption.isEnabled
    emptyOptions.appearance = window.effectiveAppearance
    try capture("archive-add-encryption", emptyOptions)
    controller.qaAdd([added], directory: "", encryptNewData: emptyOptions.encryptNewData)
    guard let cancelAddition = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    cancelAddition.qaSubmit(nil); try await idle()
    let afterCancelledAddition = try Data(contentsOf: policyArchive)
    checks["archiveEmptyZIPPasswordCancelPreservesArchive"] = controller.qaEntryCount == 0 && afterCancelledAddition == emptyZIP
    controller.qaAdd([added], directory: "", encryptNewData: emptyOptions.encryptNewData)
    guard let newPassword = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    newPassword.qaSubmit(policyPassword); try await idle()
    let encryptedAdditionEntries = try ZipArchiveProvider().entries(at: policyArchive)
    checks["archiveEmptyZIPEncryptedAddition"] = controller.qaEntryPaths == [added.lastPathComponent] && encryptedAdditionEntries.first?.isEncrypted == true
    controller.qaUndoEdit(); controller.qaConfirm(true); try await idle()
    let plainOptions = controller.qaAdditionOptions(); plainOptions.encryption.performClick(nil)
    checks["archiveEmptyZIPExplicitPlaintextOption"] = controller.qaEntryCount == 0 && !plainOptions.encryptNewData
    controller.qaAdd([added], directory: "", encryptNewData: plainOptions.encryptNewData); try await idle()
    let plainAdditionEntries = try ZipArchiveProvider().entries(at: policyArchive)
    checks["archiveEmptyZIPExplicitPlaintextAddition"] = controller.qaEntryPaths == [added.lastPathComponent] && plainAdditionEntries.first?.isEncrypted == false
    progress("empty-7z-provider")
    let emptySevenZip = root.appendingPathComponent("archive-empty-header-policy.7z"), sdk = try await ArchiveReadBackend.editingProvider()
    progress("empty-7z-create")
    _ = try await sdk.create(from: [added], at: emptySevenZip, password: policyPassword)
    progress("empty-7z-delete-last")
    _ = try await sdk.edit(emptySevenZip, operations: [.delete(paths: [added.lastPathComponent])], password: policyPassword, encryptNewData: true, journalDirectory: root.appendingPathComponent("archive-edit-journals"))
    progress("empty-7z-open")
    controller.present(archiveURL: emptySevenZip)
    guard let headerPassword = await ArchivePasswordPrompt.qaWait(for: window) else { throw SevenZipWorkerError.timedOut }
    headerPassword.qaSubmit(policyPassword); try await idle()
    let headerOptions = controller.qaAdditionOptions()
    checks["archiveEmpty7zLocksHeaderEncryption"] = controller.qaEntryCount == 0 && headerOptions.encryptNewData && !headerOptions.encryption.isEnabled
    return checks
}
#endif
