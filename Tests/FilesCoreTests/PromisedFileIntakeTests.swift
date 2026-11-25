import Foundation
import Darwin
import Testing
@testable import FilesCore

private struct PromiseIntakeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-intake-\(UUID())", isDirectory: true)
    let intake: PromisedFileIntake
    init() throws { intake = try PromisedFileIntake(storageDirectory: root) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func promisedIntakePersistsAndRecoversReceivedFilesAndFolderLinks() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let file = f.intake.receivingDirectory.appendingPathComponent("한글 file.txt")
    try Data("received bytes".utf8).write(to: file)
    try f.intake.registerReceivedFile(file)
    try f.intake.registerReceivedFile(file)
    let folder = f.intake.receivingDirectory.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "nested.txt")
    try f.intake.registerReceivedFile(folder)
    let recovered = try PromisedFileIntake(recovering: f.intake.directoryURL)
    #expect(recovered.itemCount == 2)
    #expect(recovered.receivedNames == ["한글 file.txt", "folder"])
    #expect(try recovered.verifiedSources() == [file, folder])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path) == "nested.txt")
}

@Test func promisedIntakeRejectsPathsOutsideItsReceivingDirectory() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let outside = f.root.appendingPathComponent("outside.txt")
    try Data("outside must stay".utf8).write(to: outside)
    #expect(throws: PromisedFileIntakeError.invalidLocation) { try f.intake.registerReceivedFile(outside) }
    let nested = f.intake.receivingDirectory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let child = nested.appendingPathComponent("child.txt")
    try Data("nested".utf8).write(to: child)
    #expect(throws: PromisedFileIntakeError.invalidLocation) { try f.intake.registerReceivedFile(child) }
    #expect(f.intake.itemCount == 0)
    #expect(try Data(contentsOf: outside) == Data("outside must stay".utf8))
}

@Test func promisedIntakeProtectsChangedAndReplacedReceivedData() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let file = f.intake.receivingDirectory.appendingPathComponent("payload.txt")
    try Data("original".utf8).write(to: file)
    try f.intake.registerReceivedFile(file)
    try Data("modified".utf8).write(to: file)
    #expect(throws: PromisedFileIntakeError.changedItem) { try f.intake.verifiedSources() }
    let retained = f.root.appendingPathComponent("retained.txt")
    try FileManager.default.moveItem(at: file, to: retained)
    try Data("original".utf8).write(to: file)
    #expect(throws: PromisedFileIntakeError.changedItem) { try f.intake.verifiedSources() }
    #expect(try Data(contentsOf: retained) == Data("modified".utf8))
    #expect(try Data(contentsOf: file) == Data("original".utf8))
}

@Test func promisedIntakeRefusesReplacedReceivingDirectory() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let retained = f.intake.directoryURL.appendingPathComponent("retained", isDirectory: true)
    try FileManager.default.moveItem(at: f.intake.receivingDirectory, to: retained)
    try FileManager.default.createDirectory(at: f.intake.receivingDirectory, withIntermediateDirectories: true)
    let file = f.intake.receivingDirectory.appendingPathComponent("new.txt")
    try Data("replacement".utf8).write(to: file)
    #expect(throws: PromisedFileIntakeError.changedRoot) { try f.intake.registerReceivedFile(file) }
    #expect(FileManager.default.fileExists(atPath: retained.path))
    #expect(try Data(contentsOf: file) == Data("replacement".utf8))
}

@Test func promisedIntakeRefusesCorruptManifestWithoutRemovingPayload() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let file = f.intake.receivingDirectory.appendingPathComponent("payload.txt")
    try Data("keep this".utf8).write(to: file)
    try f.intake.registerReceivedFile(file)
    let manifest = f.intake.directoryURL.appendingPathComponent(PromisedFileIntake.manifestName)
    try Data("{broken".utf8).write(to: manifest)
    #expect(throws: PromisedFileIntakeError.invalidManifest) { try PromisedFileIntake(recovering: f.intake.directoryURL) }
    #expect(try Data(contentsOf: file) == Data("keep this".utf8))
}

@Test func promisedIntakeCancellationPreservesUnregisteredAndRegisteredData() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let file = f.intake.receivingDirectory.appendingPathComponent("payload.txt")
    try Data("keep this".utf8).write(to: file)
    let cancellation = CopyCancellation(); cancellation.cancel()
    #expect(throws: CancellationError.self) { try f.intake.registerReceivedFile(file, cancellation: cancellation) }
    #expect(f.intake.itemCount == 0)
    try f.intake.registerReceivedFile(file)
    #expect(throws: CancellationError.self) { try f.intake.verifiedSources(cancellation: cancellation) }
    #expect(f.intake.itemCount == 1)
    #expect(try Data(contentsOf: file) == Data("keep this".utf8))
}

@Test func promisedIntakeDetectsMetadataChangesAfterRecovery() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let file = f.intake.receivingDirectory.appendingPathComponent("payload.txt")
    try Data("unchanged bytes".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    try f.intake.registerReceivedFile(file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let recovered = try PromisedFileIntake(recovering: f.intake.directoryURL)
    #expect(throws: PromisedFileIntakeError.changedItem) { try recovered.verifiedSources() }
    #expect(try Data(contentsOf: file) == Data("unchanged bytes".utf8))
}

@Test func promisedIntakeRejectsSpecialFilesWithoutConsumingThem() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let pipe = f.intake.receivingDirectory.appendingPathComponent("pipe")
    try #require(mkfifo(pipe.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try f.intake.registerReceivedFile(pipe) }
    #expect(f.intake.itemCount == 0)
    var info = stat()
    #expect(lstat(pipe.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
}

@Test func promisedIntakeRefusesSymlinkReceivingRootWithoutReadingOutsidePayload() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let outside = f.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("sentinel.txt")
    try Data("outside payload".utf8).write(to: sentinel)
    let retained = f.intake.directoryURL.appendingPathComponent("retained", isDirectory: true)
    try FileManager.default.moveItem(at: f.intake.receivingDirectory, to: retained)
    try FileManager.default.createSymbolicLink(at: f.intake.receivingDirectory, withDestinationURL: outside)
    let throughLink = f.intake.receivingDirectory.appendingPathComponent("sentinel.txt")
    #expect(throws: PromisedFileIntakeError.changedRoot) { try f.intake.registerReceivedFile(throughLink) }
    #expect(try Data(contentsOf: sentinel) == Data("outside payload".utf8))
    #expect(f.intake.itemCount == 0)
}

@Test func promisedIntakeRejectsEscapingReceiptNamesAfterRestart() throws {
    let f = try PromiseIntakeFixture(); defer { f.clean() }
    let file = f.intake.receivingDirectory.appendingPathComponent("payload.txt")
    try Data("keep this".utf8).write(to: file)
    try f.intake.registerReceivedFile(file)
    let records = f.intake.directoryURL.appendingPathComponent("Receipts", isDirectory: true)
    let record = try #require(FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil).first)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
    object["name"] = "../escape.txt"
    try JSONSerialization.data(withJSONObject: object).write(to: record)
    #expect(throws: PromisedFileIntakeError.invalidManifest) { try PromisedFileIntake(recovering: f.intake.directoryURL) }
    #expect(try Data(contentsOf: file) == Data("keep this".utf8))
}
