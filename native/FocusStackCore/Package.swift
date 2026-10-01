// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusStackCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "FocusStackCore", targets: ["FocusStackCore"])],
    targets: [
        .target(name: "CLibTIFF", path: "Vendor/libtiff", exclude: ["LICENSE.md", "PROVENANCE.json"], publicHeadersPath: "include", cSettings: [.headerSearchPath(".")], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CTIFFBridge", dependencies: ["CLibTIFF"]),
        .target(name: "FocusStackCore", dependencies: ["CTIFFBridge"], exclude: ["Resources"], resources: [.copy("MetalEngine/Kernels"), .copy("Models")]),
    ],
    swiftLanguageModes: [.v6]
)
