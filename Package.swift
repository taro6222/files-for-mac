// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilesMac",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FilesCore", targets: ["FilesCore"]), .executable(name: "FilesMac", targets: ["FilesMac"]), .executable(name: "FilesSplitProbe", targets: ["FilesSplitProbe"])],
    targets: [
        .systemLibrary(name: "CLibArchive"),
        .systemLibrary(name: "CZlib"),
        .target(name: "FilesCore", dependencies: ["CLibArchive", "CZlib"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "FilesMac", dependencies: ["FilesCore"]),
        .executableTarget(name: "FilesSplitProbe", dependencies: ["FilesCore"], path: "Tools/SplitCreationProbe"),
        .testTarget(name: "FilesCoreTests", dependencies: ["FilesCore"], resources: [.copy("Fixtures")])
    ]
)
