// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CopyTool", platforms: [.macOS(.v13)], products: [
    .executable(name: "CopyTool", targets: ["CopyToolApp"]),
    .library(name: "CopyToolCore", targets: ["CopyToolCore"])
], targets: [
    .target(name: "CopyToolCore"),
    .executableTarget(name: "CopyToolApp", dependencies: ["CopyToolCore"]),
    .testTarget(name: "CopyToolCoreTests", dependencies: ["CopyToolCore"]),
    .testTarget(name: "CopyToolAppTests", dependencies: ["CopyToolApp", "CopyToolCore"])
])
