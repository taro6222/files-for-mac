import Foundation
import Testing
@testable import FilesCore

@Test func archiveValidationAcceptsBoundedRegularTree() throws {
    let result = try ArchiveExtractionValidator.validate([
        .init(path: "folder/", kind: .directory),
        .init(path: "folder/한글-é.txt", kind: .regularFile, uncompressedSize: 12)
    ], limits: .init(maximumEntries: 2, maximumTotalBytes: 12, maximumSingleFileBytes: 12))
    #expect(result.map(\.relativePath) == ["folder", "folder/한글-é.txt"])
}

@Test func archiveValidationRejectsTraversalAbsoluteLinksAndCanonicalDuplicates() {
    for entry in [
        ArchiveEntryDescriptor(path: "../escape", kind: .regularFile),
        .init(path: "/absolute", kind: .regularFile),
        .init(path: "C:/windows", kind: .regularFile),
        .init(path: "folder\\escape", kind: .regularFile),
        .init(path: "link", kind: .symbolicLink)
    ] {
        #expect(throws: (any Error).self) { try ArchiveExtractionValidator.validate([entry]) }
    }
    #expect(throws: ArchiveValidationError.duplicatePath("é.txt")) {
        try ArchiveExtractionValidator.validate([
            .init(path: "e\u{301}.txt", kind: .regularFile), .init(path: "é.txt", kind: .regularFile)
        ])
    }
}

@Test func archiveValidationEnforcesCountSingleAndTotalLimitsWithoutOverflow() {
    #expect(throws: ArchiveValidationError.tooManyEntries) {
        try ArchiveExtractionValidator.validate([.init(path: "a", kind: .regularFile), .init(path: "b", kind: .regularFile)], limits: .init(maximumEntries: 1))
    }
    #expect(throws: ArchiveValidationError.singleFileLimit("large")) {
        try ArchiveExtractionValidator.validate([.init(path: "large", kind: .regularFile, uncompressedSize: 11)], limits: .init(maximumSingleFileBytes: 10))
    }
    #expect(throws: ArchiveValidationError.totalSizeLimit) {
        try ArchiveExtractionValidator.validate([.init(path: "a", kind: .regularFile, uncompressedSize: 6), .init(path: "b", kind: .regularFile, uncompressedSize: 5)], limits: .init(maximumTotalBytes: 10, maximumSingleFileBytes: 10))
    }
    #expect(throws: ArchiveValidationError.totalSizeLimit) {
        try ArchiveExtractionValidator.validate([.init(path: "a", kind: .regularFile, uncompressedSize: .max), .init(path: "b", kind: .regularFile, uncompressedSize: 1)], limits: .init(maximumTotalBytes: .max, maximumSingleFileBytes: .max))
    }
}

@Test func archiveExtractionPlacementMatchesSmartTopLevelRules() throws {
    let oneTree = [ArchiveEntryDescriptor(path: "root/a.txt", kind: .regularFile)]
    let many = [ArchiveEntryDescriptor(path: "a.txt", kind: .regularFile), ArchiveEntryDescriptor(path: "folder/b.txt", kind: .regularFile)]
    #expect(try !archiveNeedsChildFolder(oneTree, placement: .here))
    #expect(try !archiveNeedsChildFolder(oneTree, placement: .smart))
    #expect(try archiveNeedsChildFolder(many, placement: .smart))
    #expect(try archiveNeedsChildFolder(oneTree, placement: .childFolder))
    #expect(archiveChildFolderBaseName(URL(fileURLWithPath: "/tmp/자료.tar.zip")) == "자료.tar")
}
