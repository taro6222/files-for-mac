import Foundation
import Testing
@testable import FilesCore

@Test func archiveCapabilityMatrixAdvertisesOnlyVerifiedProviderFeatures() {
    #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/tmp/a.ZIP")) == .zip)
    #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/tmp/a.7z")) == .sevenZip)
    #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/tmp/a.rar")) == .rar)
    #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/tmp/a.tar")) == nil)
    let zip = ArchiveCapabilityMatrix.capabilities(for: .zip)
    #expect(zip.browse && zip.extract && zip.create)
    #expect(!zip.update && !zip.password && !zip.splitVolumes)
    for format in [ArchiveFormat.sevenZip, .rar] {
        let capabilities = ArchiveCapabilityMatrix.capabilities(for: format)
        #expect(!capabilities.browse && !capabilities.extract && !capabilities.create)
        #expect(!capabilities.update && !capabilities.password && !capabilities.splitVolumes)
    }
}
