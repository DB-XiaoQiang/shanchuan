// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CopyTool", platforms: [.macOS(.v13)], products: [
    .executable(name: "CopyTool", targets: ["CopyToolApp"]),
    .library(name: "CopyToolCore", targets: ["CopyToolCore"])
], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
], targets: [
    .target(name: "CopyToolCore"),
    .executableTarget(name: "CopyToolApp", dependencies: ["CopyToolCore", .product(name: "Sparkle", package: "Sparkle")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "CopyToolCoreTests", dependencies: ["CopyToolCore"]),
    .testTarget(name: "CopyToolAppTests", dependencies: ["CopyToolApp", "CopyToolCore"])
])
