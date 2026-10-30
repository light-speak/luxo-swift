// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "LuxoClient",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "LuxoClient", targets: ["LuxoClient"]),
        .library(name: "LuxoNIO", targets: ["LuxoNIO"]),
        .library(name: "LuxoCompiler", targets: ["LuxoCompiler"]),
        .executable(name: "LuxoAnalyze", targets: ["LuxoAnalyze"]),
        .plugin(name: "LuxoBuild", targets: ["LuxoBuild"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "603.0.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.46.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
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
            name: "LuxoNIO",
            dependencies: [
                "LuxoClient",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        .testTarget(
            name: "LuxoNIOTests",
            dependencies: [
                "LuxoNIO", .product(name: "NIOEmbedded", package: "swift-nio"),
            ]),
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
