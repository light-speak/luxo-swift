// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "LuxoConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LuxoConsumer",
            dependencies: [
                .product(name: "LuxoClient", package: "luxo-swift"),
                .product(name: "LuxoCompiler", package: "luxo-swift"),
            ]
        ),
        .executableTarget(
            name: "LuxoGeneratedConsumer",
            dependencies: [
                .product(name: "LuxoClient", package: "luxo-swift")
            ],
            path: ".tmp/generated-consumer"
        ),
    ]
)
