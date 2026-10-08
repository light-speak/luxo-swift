// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "LuxoClient",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "LuxoClient", targets: ["LuxoClient"]),
        .library(name: "LuxoCompiler", targets: ["LuxoCompiler"]),
        .executable(name: "LuxoAnalyze", targets: ["LuxoAnalyze"]),
        .plugin(name: "LuxoBuild", targets: ["LuxoBuild"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "603.0.2")
    ],
    targets: [
        .plugin(
            name: "LuxoBuild",
            capability: .command(
                intent: .custom(verb: "luxo-build", description: "Build with compiler-resolved call-site selections"),
                permissions: [
                    .writeToPackageDirectory(reason: "Create isolated source snapshots and the requested build output")
                ]
            ),
            dependencies: ["LuxoAnalyze"]
        ),
        .target(name: "LuxoClient"),
        .target(
            name: "LuxoCompiler",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "LuxoAnalyze",
            dependencies: ["LuxoCompiler"]
        ),
        .testTarget(
            name: "LuxoClientTests",
            dependencies: ["LuxoClient"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "LuxoCompilerTests", dependencies: ["LuxoCompiler", "LuxoClient"]),
    ]
)
