// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusStackCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "FocusStackCore", targets: ["FocusStackCore"])],
    targets: [
        .target(name: "FocusStackCore", exclude: ["Models", "Resources"], resources: [.copy("MetalEngine/Kernels")]),
    ],
    swiftLanguageModes: [.v6]
)
