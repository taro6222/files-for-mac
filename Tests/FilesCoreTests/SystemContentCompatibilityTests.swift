import Foundation
import Testing
@testable import FilesCore

@Test func systemContentCompatibilityUsesExplicitCertificatesFontsAndMediaTypes() {
    #expect(SystemContentCompatibility.isCertificate(URL(fileURLWithPath: "/tmp/root.CER")))
    #expect(SystemContentCompatibility.isCertificate(URL(fileURLWithPath: "/tmp/identity.p12")))
    #expect(!SystemContentCompatibility.isCertificate(URL(fileURLWithPath: "/tmp/script.command")))
    #expect(SystemContentCompatibility.isFont(URL(fileURLWithPath: "/tmp/family.ttc")))
    #expect(SystemContentCompatibility.isFont(URL(fileURLWithPath: "/tmp/type.otf")))
    #expect(!SystemContentCompatibility.isFont(URL(fileURLWithPath: "/tmp/type.txt")))
    #expect(SystemContentCompatibility.isMedia(URL(fileURLWithPath: "/tmp/movie.mov")))
    #expect(SystemContentCompatibility.isMedia(URL(fileURLWithPath: "/tmp/audio.m4a")))
    #expect(!SystemContentCompatibility.isMedia(URL(fileURLWithPath: "/tmp/image.png")))
}
