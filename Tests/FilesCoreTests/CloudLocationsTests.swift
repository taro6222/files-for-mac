import Foundation
import Testing
@testable import FilesCore

@Test func cloudLocationsDiscoverVisibleDirectoriesAndPreserveUnknownState() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("cloud-locations-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let storage = root.appendingPathComponent("CloudStorage", isDirectory: true), iCloud = root.appendingPathComponent("iCloud Drive", isDirectory: true)
    try fm.createDirectory(at: storage.appendingPathComponent("Dropbox-personal"), withIntermediateDirectories: true)
    try fm.createDirectory(at: storage.appendingPathComponent("OneDrive-work"), withIntermediateDirectories: true)
    try fm.createDirectory(at: storage.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    try Data().write(to: storage.appendingPathComponent("not-a-directory")); try fm.createDirectory(at: iCloud, withIntermediateDirectories: true)
    let locations = CloudLocationProvider(cloudStorageRoot: storage, iCloudDriveRoot: iCloud).locations(fileManager: fm)
    #expect(locations.count == 3); #expect(Set(locations.map(\.providerName)) == ["Dropbox", "OneDrive", "iCloud Drive"])
    #expect(locations.allSatisfy { $0.state == .unknown && !$0.exposesUbiquitousState })
    #expect(locations.map(\.name) == locations.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
}

@Test func cloudLocationsReturnEmptyForUnavailableRoots() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-cloud-\(UUID())", isDirectory: true)
    #expect(CloudLocationProvider(cloudStorageRoot: missing, iCloudDriveRoot: missing.appendingPathComponent("icloud")).locations().isEmpty)
    #expect(CloudLocationProvider(cloudStorageRoot: missing, iCloudDriveRoot: missing).state(of: missing) == .unknown)
}

@Test func cloudActionsStayDisabledForOrdinaryProviderFiles() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("cloud-actions-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("local.txt"); try Data("keep".utf8).write(to: file)
    let provider = CloudLocationProvider(cloudStorageRoot: root, iCloudDriveRoot: root.appendingPathComponent("missing"))
    #expect(provider.capabilities(for: file) == CloudItemCapabilities(downloadNow: false, evictLocalCopy: false, keepDownloaded: false))
    #expect(throws: CloudOperationError.unsupported) { try provider.requestDownload(file, fileManager: fm) }
    #expect(throws: CloudOperationError.unsupported) { try provider.evictLocalCopy(file, fileManager: fm) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
}
