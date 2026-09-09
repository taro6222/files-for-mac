// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FilesMac",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FilesCore", targets: ["FilesCore"]), .executable(name: "FilesMac", targets: ["FilesMac"])],
    targets: [
        .target(name: "FilesCore"),
        .executableTarget(name: "FilesMac", dependencies: ["FilesCore"]),
        .testTarget(name: "FilesCoreTests", dependencies: ["FilesCore"])
    ]
)
