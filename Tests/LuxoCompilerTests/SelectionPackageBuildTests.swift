import Foundation
import XCTest
@testable import LuxoCompiler

final class SelectionPackageBuildTests: XCTestCase {
    func testSwiftPackageBuildUsesCurrentCallSiteProjection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/selection-package-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("Sources/Probe")
        let fm = FileManager.default
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let package = """
            // swift-tools-version:6.3
            import PackageDescription
            let package = Package(name: "Probe", products: [.executable(name: "probe", targets: ["Probe"])], targets: [
                .executableTarget(name: "Probe", resources: [.copy("data.txt")]), .executableTarget(name: "LuxoAnalyze"),
                .plugin(name: "LuxoBuild", capability: .command(intent: .custom(verb: "luxo-build", description: "Build selections"),
                    permissions: [.writeToPackageDirectory(reason: "Build output")]), dependencies: ["LuxoAnalyze"])
            ])
            """
        try package.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try preparePlugin(root: root, directory: directory)
        try "resource".write(to: sources.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let manifest = directory.appendingPathComponent("LuxoSelection.json")
        try Data(
            #"{"version":1,"module":"Probe","client":"Client","apis":{"user":{}},"fields":{"User":{"id":false,"name":false}}}"#
                .utf8
        ).write(to: manifest)
        let source = """
            import Foundation
            public struct User { public let id: Int; public let name: String }
            public struct Client {
                public func user(select: String? = nil) -> User {
                    print(select ?? "MISSING")
                    return User(id: 7, name: "Ada")
                }
            }
            let user = Client().user()
            print(user.id)
            precondition(try! String(contentsOf: Bundle.module.url(forResource: "data", withExtension: "txt")!, encoding: .utf8) == "resource")
            """
        // A function-local binding has a stable lexical lifetime for automatic inference.
        let local = source.replacingOccurrences(
            of: "let user = Client().user()\nprint(user.id)",
            with: "func run() { let user = Client().user(); print(user.id) }; run()")
        let file = sources.appendingPathComponent("main.swift")
        for (index, field) in ["id", "name"].enumerated() {
            let current = local.replacingOccurrences(of: "print(user.id)", with: "print(user.\(field))")
            try current.write(to: file, atomically: true, encoding: .utf8)
            let output = directory.appendingPathComponent("out-\(index)")
            let process = SelectionCompilerProcess(workspace: directory, scratch: directory)
            let executable: URL
            if index == 0 {
                executable = try SelectionPackageBuild.run(
                    workspace: directory, manifest: manifest, product: "probe", output: output)
            } else {
                _ = try process.run(
                    "swift",
                    [
                        "package", "--package-path", directory.path, "--allow-writing-to-package-directory",
                        "luxo-build", "--manifest", manifest.path, "--product", "probe", "--output", output.path,
                        "--configuration", "release",
                    ])
                executable = output.appendingPathComponent("probe")
            }
            XCTAssertEqual(
                String(decoding: try process.run(executable.path, []), as: UTF8.self),
                field == "id" ? "id\n7\n" : "name\nAda\n")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), current)
        }
    }

    private func preparePlugin(root: URL, directory: URL) throws {
        let fm = FileManager.default
        let plugin = directory.appendingPathComponent("Plugins/LuxoBuild")
        let shim = directory.appendingPathComponent("Sources/LuxoAnalyze")
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        try fm.createDirectory(at: shim, withIntermediateDirectories: true)
        try fm.copyItem(
            at: root.appendingPathComponent("Plugins/LuxoBuild/plugin.swift"),
            to: plugin.appendingPathComponent("plugin.swift"))
        let tool = root.appendingPathComponent(".build/debug/LuxoAnalyze").path
        let source = """
            import Foundation
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "\(tool)")
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
            """
        try source.write(to: shim.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    }
}
