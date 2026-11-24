import Foundation
import XCTest
@testable import LuxoCompiler

final class SelectionBuildTests: XCTestCase {
    func testUnderscoredPublicFieldsUseCompilerSymbolsWithoutAdmittingPrivateFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/selection-public-fields-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = [
            "items", "i", "_items", "decoder", "initial", "total", "page", "pageSize", "depth", "depth_", "_i",
            "normal",
        ]
        let fields = names.map { "public let \($0): Int" }.joined(separator: "\n")
        let reads = names.map { "print(row.\($0))" }.joined(separator: "\n")
        let source = """
            public struct Record {
                \(fields)
                var internalSecret: Int { 0 }
                private var secret: Int { 0 }
            }
            public struct Client { public func rows(select: String? = nil) -> [Record] { fatalError() } }
            public func read(_ client: Client) {
                let rows = client.rows()
                for row in rows { \(reads) }
            }
            """
        let file = directory.appendingPathComponent("Read.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let manifest = directory.appendingPathComponent("LuxoSelection.json")
        func declaration(_ fields: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "module": "Probe", "client": "Client", "apis": ["rows": [:]],
                "fields": ["Record": Dictionary(uniqueKeysWithValues: fields.map { ($0, false) })],
            ])
        }
        try declaration(names).write(to: manifest)
        let scratch = directory.appendingPathComponent(".tmp/public")
        let arguments = [
            "-module-name", "Probe", "-parse-as-library", "-module-cache-path",
            directory.appendingPathComponent("cache").path, file.path,
        ]
        _ = try SelectionBuild.prepareOverlay(
            workspace: directory, manifest: manifest, scratch: scratch, arguments: arguments)
        let rewritten = try String(contentsOf: scratch.appendingPathComponent("source-0/Read.swift"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains("select: \"\(names.sorted().joined(separator: ","))\""), rewritten)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        for field in ["internalSecret", "secret"] {
            try declaration(names + [field]).write(to: manifest)
            XCTAssertThrowsError(
                try SelectionBuild.prepareOverlay(
                    workspace: directory, manifest: manifest,
                    scratch: directory.appendingPathComponent(".tmp/" + field),
                    arguments: arguments)
            ) { error in
                guard case SelectionCatalog.Failure.missingSymbol(let name) = error else {
                    return XCTFail("Expected a missing non-public field, got \(error)")
                }
                XCTAssertEqual(name, "Record." + field)
            }
        }
    }

    func testPreparedOverlaySurvivesUntilExternalCompilerFinishes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/selection-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("App.swift")
        let source = """
            public struct User { public let id: Int; public let name: String }
            public struct Client {
                public func user(select: String? = nil) -> User {
                    print(select ?? "MISSING")
                    return User(id: 7, name: "Ada")
                }
            }
            @main struct App {
                static func main() {
                    let client = Client()
                    let first = client.user()
                    #if LUXO_NAME
                    print(first.name)
                    #else
                    print(first.id)
                    #endif
                    let second = client.user()
                    print(second.name)
                }
            }
            """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let manifest = directory.appendingPathComponent("LuxoSelection.json")
        let declaration =
            #"{"version":1,"module":"Probe","client":"Client","apis":{"user":{}},"fields":{"User":{"id":false,"name":false}}}"#
        try Data(declaration.utf8).write(to: manifest)
        let scratch = directory.appendingPathComponent(".tmp/overlay")
        let executable = directory.appendingPathComponent("app")
        let arguments = ["-module-name", "Probe", "-parse-as-library", file.path, "-o", executable.path]
        let overlay = try SelectionBuild.prepareOverlay(
            workspace: directory, manifest: manifest, scratch: scratch, arguments: arguments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlay.path))
        XCTAssertThrowsError(
            try SelectionBuild.prepareOverlay(
                workspace: directory, manifest: manifest, scratch: scratch, arguments: arguments))
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlay.path))
        let process = SelectionCompilerProcess(workspace: directory, scratch: scratch)
        _ = try process.run("swiftc", arguments + ["-vfsoverlay", overlay.path])
        XCTAssertEqual(String(decoding: try process.run(executable.path, []), as: UTF8.self), "id\n7\nname\nAda\n")
        if ProcessInfo.processInfo.environment["LUXO_XCODE_BUILD"] == "1" {
            try verifyXcodeApplication(directory: directory, overlay: overlay, process: process)
            try verifyXcodeIncrementalBuild(
                directory: directory, source: source, manifest: manifest, arguments: arguments, process: process)
            let conditional = try SelectionBuild.prepareOverlay(
                workspace: directory, manifest: manifest,
                scratch: directory.appendingPathComponent(".tmp/conditional"),
                arguments: arguments + ["-D", "LUXO_NAME"])
            try verifyXcodeApplication(
                directory: directory, overlay: conditional, process: process,
                expected: "name\nAda\nname\nAda\n", flags: "-D LUXO_NAME")
            try verifyIOSApplication(directory: directory, manifest: manifest, file: file, process: process)
            try verifyAutomaticXcodeArguments(directory: directory, manifest: manifest, process: process)
            let product = directory.appendingPathComponent(".tmp/exported/Probe.app")
            let builtOutput = try process.run(
                root.appendingPathComponent(".build/debug/LuxoAnalyze").path,
                [
                    "xcode-build", "--workspace", directory.path, "--manifest", manifest.path,
                    "--project", directory.appendingPathComponent("Probe.xcodeproj").path,
                    "--scheme", "Probe", "--module", "Probe", "--target", "arm64-apple-macos13.0",
                    "--destination", "platform=macOS,arch=arm64", "--output", product.path,
                    "--swift-flags", "-D LUXO_NAME",
                ])
            let built = URL(
                fileURLWithPath: String(decoding: builtOutput, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines))
            XCTAssertEqual(built.path, product.path)
            XCTAssertEqual(
                String(
                    decoding: try process.run(built.appendingPathComponent("Contents/MacOS/Probe").path, []),
                    as: UTF8.self),
                "name\nAda\nname\nAda\n")
            XCTAssertThrowsError(
                try SelectionXcodeBuild.run(
                    workspace: directory, manifest: manifest,
                    project: directory.appendingPathComponent("Probe.xcodeproj"),
                    scheme: "Probe", module: "Probe", target: "arm64-apple-macos13.0",
                    destination: "platform=macOS,arch=arm64", output: product))
            let failedProduct = directory.appendingPathComponent(".tmp/failed-export.app")
            XCTAssertThrowsError(
                try SelectionXcodeBuild.run(
                    workspace: directory, manifest: manifest,
                    project: directory.appendingPathComponent("Probe.xcodeproj"),
                    scheme: "Probe", module: "MissingModule", target: "arm64-apple-macos13.0",
                    destination: "platform=macOS,arch=arm64", output: failedProduct))
            XCTAssertFalse(FileManager.default.fileExists(atPath: failedProduct.path))
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(".tmp").path)
                    .contains { $0.hasPrefix("luxo-xcode-") })
            try verifyIOSXcodePipeline(directory: directory, manifest: manifest, process: process)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        let failed = directory.appendingPathComponent(".tmp/failed")
        XCTAssertThrowsError(
            try SelectionBuild.prepareOverlay(
                workspace: directory, manifest: manifest, scratch: failed, arguments: ["--invalid"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        XCTAssertThrowsError(
            try SelectionBuild.prepareOverlay(
                workspace: directory, manifest: manifest,
                scratch: directory.appendingPathComponent("outside"), arguments: arguments))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside").path))
    }

    private func verifyXcodeApplication(
        directory: URL, overlay: URL, process: SelectionCompilerProcess,
        expected: String = "id\n7\nname\nAda\n", flags: String = ""
    ) throws {
        let project = directory.appendingPathComponent("Probe.xcodeproj")
        let newProject = !FileManager.default.fileExists(atPath: project.path)
        if newProject { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false) }
        let contents = """
            // !$*UTF8*$!
            {
              archiveVersion = 1; classes = {}; objectVersion = 56;
              objects = {
                A = {isa = PBXProject; buildConfigurationList = B; compatibilityVersion = "Xcode 14.0";
                  developmentRegion = en; mainGroup = C; projectDirPath = ""; targets = (D); };
                B = {isa = XCConfigurationList; buildConfigurations = (E); defaultConfigurationName = Debug; };
                C = {isa = PBXGroup; children = (F, G); sourceTree = "<group>"; };
                D = {isa = PBXNativeTarget; buildConfigurationList = H; buildPhases = (I); buildRules = ();
                  dependencies = (); name = Probe; productName = Probe; productReference = G;
                  productType = "com.apple.product-type.application"; };
                E = {isa = XCBuildConfiguration; name = Debug; buildSettings = {}; };
                F = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift;
                  sourceTree = "<group>"; };
                G = {isa = PBXFileReference; explicitFileType = wrapper.application; path = Probe.app;
                  sourceTree = BUILT_PRODUCTS_DIR; };
                H = {isa = XCConfigurationList; buildConfigurations = (J); defaultConfigurationName = Debug; };
                I = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (K);
                  runOnlyForDeploymentPostprocessing = 0; };
                J = {isa = XCBuildConfiguration; name = Debug; buildSettings = {
                  PRODUCT_NAME = Probe; PRODUCT_BUNDLE_IDENTIFIER = org.luxo.selection.probe;
                  SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SDKROOT = macosx;
                  MACOSX_DEPLOYMENT_TARGET = 13.0; GENERATE_INFOPLIST_FILE = YES; CODE_SIGNING_ALLOWED = NO;
                }; };
                K = {isa = PBXBuildFile; fileRef = F; };
              };
              rootObject = A;
            }
            """
        if newProject {
            try contents.write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        }
        let derived = directory.appendingPathComponent(".tmp/DerivedData")
        _ = try process.run(
            "/usr/bin/xcodebuild",
            [
                "-project", project.path, "-scheme", "Probe", "-configuration", "Debug",
                "-derivedDataPath", derived.path, "-destination", "platform=macOS",
                "OTHER_SWIFT_FLAGS=\(flags) -vfsoverlay \(overlay.path)", "build",
            ])
        let binary = derived.appendingPathComponent("Build/Products/Debug/Probe.app/Contents/MacOS/Probe")
        XCTAssertEqual(String(decoding: try process.run(binary.path, []), as: UTF8.self), expected)
    }

    private func verifyXcodeIncrementalBuild(
        directory: URL, source: String, manifest: URL, arguments: [String], process: SelectionCompilerProcess
    ) throws {
        let file = directory.appendingPathComponent("App.swift")
        defer { try? source.write(to: file, atomically: true, encoding: .utf8) }
        let changed = source.replacingOccurrences(of: "print(first.id)", with: "print(first.name)")
        try changed.write(to: file, atomically: true, encoding: .utf8)
        let overlay = try SelectionBuild.prepareOverlay(
            workspace: directory, manifest: manifest, scratch: directory.appendingPathComponent(".tmp/incremental"),
            arguments: arguments)
        // Reuse the project and DerivedData: a clean build cannot prove incremental correctness.
        try verifyXcodeApplication(
            directory: directory, overlay: overlay, process: process, expected: "name\nAda\nname\nAda\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), changed)
        // A no-change build must retain the same call-site projection as the preceding rebuild.
        try verifyXcodeApplication(
            directory: directory, overlay: overlay, process: process, expected: "name\nAda\nname\nAda\n")
    }

    private func verifyAutomaticXcodeArguments(
        directory: URL, manifest: URL, process: SelectionCompilerProcess
    ) throws {
        let log = try process.run(
            "/usr/bin/xcodebuild",
            [
                "-project", directory.appendingPathComponent("Probe.xcodeproj").path,
                "-scheme", "Probe", "-configuration", "Debug",
                "-derivedDataPath", directory.appendingPathComponent(".tmp/AutomaticDerivedData").path,
                "-destination", "platform=macOS,arch=arm64", "OTHER_SWIFT_FLAGS=-D LUXO_NAME", "build",
            ])
        let logFile = directory.appendingPathComponent(".tmp/xcode.log")
        try log.write(to: logFile)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let prepared = try process.run(
            root.appendingPathComponent(".build/debug/LuxoAnalyze").path,
            [
                "prepare-xcode", "--workspace", directory.path, "--manifest", manifest.path,
                "--scratch", directory.appendingPathComponent(".tmp/automatic").path,
                "--log", logFile.path, "--module", "Probe", "--target", "arm64-apple-macos13.0",
            ])
        let overlay = URL(
            fileURLWithPath: String(decoding: prepared, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        try verifyXcodeApplication(
            directory: directory, overlay: overlay, process: process,
            expected: "name\nAda\nname\nAda\n", flags: "-D LUXO_NAME")
    }

    private func verifyIOSApplication(
        directory: URL, manifest: URL, file: URL, process: SelectionCompilerProcess
    ) throws {
        for (sdk, target) in [
            ("iphonesimulator", "arm64-apple-ios15.0-simulator"),
            ("iphoneos", "arm64-apple-ios15.0"),
        ] {
            let sdkPath = String(
                decoding: try process.run("/usr/bin/xcrun", ["--sdk", sdk, "--show-sdk-path"]), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let overlay = try SelectionBuild.prepareOverlay(
                workspace: directory, manifest: manifest, scratch: directory.appendingPathComponent(".tmp/" + sdk),
                arguments: [
                    "-module-name", "Probe", "-parse-as-library", "-sdk", sdkPath, "-target", target, file.path,
                ])
            let derived = directory.appendingPathComponent(".tmp/DerivedData-" + sdk)
            _ = try process.run(
                "/usr/bin/xcodebuild",
                [
                    "-project", directory.appendingPathComponent("Probe.xcodeproj").path,
                    "-target", "Probe", "-configuration", "Debug", "-sdk", sdk, "-quiet",
                    "SYMROOT=\(derived.path)/products", "OBJROOT=\(derived.path)/objects",
                    "CONFIGURATION_BUILD_DIR=\(derived.path)/app", "SUPPORTED_PLATFORMS=" + sdk,
                    "IPHONEOS_DEPLOYMENT_TARGET=15.0", "ARCHS=arm64",
                    "OTHER_SWIFT_FLAGS=-vfsoverlay \(overlay.path)", "build",
                ])
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: derived.appendingPathComponent("app/Probe.app/Probe").path))
        }
    }

    private func verifyIOSXcodePipeline(
        directory: URL, manifest: URL, process: SelectionCompilerProcess
    ) throws {
        let project = directory.appendingPathComponent("Probe.xcodeproj")
        let settings = project.appendingPathComponent("project.pbxproj")
        let original = try String(contentsOf: settings, encoding: .utf8)
        defer { try? original.write(to: settings, atomically: true, encoding: .utf8) }
        for (sdk, target, destination, platform) in [
            ("iphonesimulator", "arm64-apple-ios15.0-simulator", "generic/platform=iOS Simulator", "IOSSIMULATOR"),
            ("iphoneos", "arm64-apple-ios15.0", "generic/platform=iOS", "IOS"),
        ] {
            let configured = original.replacingOccurrences(
                of: "SDKROOT = macosx;",
                with: "SDKROOT = \(sdk); SUPPORTED_PLATFORMS = \(sdk); "
                    + "IPHONEOS_DEPLOYMENT_TARGET = 15.0; ARCHS = arm64;")
            try configured.write(to: settings, atomically: true, encoding: .utf8)
            let output = directory.appendingPathComponent(".tmp/exported-\(sdk)/Probe.app")
            let built = try SelectionXcodeBuild.run(
                workspace: directory, manifest: manifest, project: project, scheme: "Probe", module: "Probe",
                target: target, destination: destination, output: output)
            XCTAssertEqual(built, output)
            let binary = built.appendingPathComponent("Probe")
            let metadata = String(
                decoding: try process.run("/usr/bin/xcrun", ["vtool", "-show-build", binary.path]), as: UTF8.self)
            XCTAssertTrue(metadata.contains("platform \(platform)\n"), metadata)
            XCTAssertTrue(metadata.contains("minos 15.0"), metadata)
            XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), configured)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(".tmp").path)
                    .contains { $0.hasPrefix("luxo-xcode-") })
        }
    }

    func testReleaseOptionsStayInBuildButNotSemanticAnalysis() throws {
        let workspace = URL(fileURLWithPath: "/workspace")
        let arguments = [
            "-O", "-whole-module-optimization", "-num-threads", "4", "-module-name", "App",
            "/workspace/main.swift",
        ]
        let invocation = try SelectionCompilerInvocation(
            arguments: arguments, workspace: workspace, defaultModule: "App")
        XCTAssertEqual(invocation.original, arguments)
        XCTAssertEqual(invocation.semantic, ["-module-name", "App"])
        XCTAssertTrue(invocation.graph.isEmpty)
    }

    func testBuildInfersDistinctCallsAndLeavesOriginalUntouched() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/selection-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("App.swift")
        let source = """
            public struct User { public let id: Int; public let name: String }
            public struct Client {
                public func user(select: String? = nil) -> User {
                    print(select ?? "MISSING")
                    return User(id: 7, name: "Ada")
                }
                public func watch(select: String? = nil, handler: (User) -> Void) {
                    print(select ?? "MISSING")
                    handler(User(id: 8, name: "Bee"))
                }
                public func users(select: String? = nil) -> [User] {
                    print(select ?? "MISSING")
                    return [User(id: 9, name: "Cat")]
                }
            }
            @main struct App {
                static func main() {
                    let client = Client()
                    let first = client.user()
                    let alias = first
                    print(alias.id)
                    var computedName: String { alias.name }
                    print(computedName)
                    do { let first = client.user(); print(first.name) }
                    client.watch { row in print(row.name) }
                    let rows = client.users()
                    print(rows[0].id)
                    print(rows.map { $0.name }.joined())
                    for row in rows { print(row.name) }
                }
            }
            """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let manifest =
            #"{"version":1,"module":"Probe","client":"Client","apis":{"user":{},"users":{},"watch":{"handler":"handler"}},"fields":{"User":{"id":false,"name":false}}}"#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("LuxoSelection.json"))
        try SelectionBuild.run(
            workspace: directory, manifest: directory.appendingPathComponent("LuxoSelection.json"),
            arguments: [
                "-g", "-module-name", "Probe", "-parse-as-library", file.path, "-o",
                directory.appendingPathComponent("app").path,
            ])
        let process = Process()
        let pipe = Pipe()
        process.executableURL = directory.appendingPathComponent("app")
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            String(decoding: output, as: UTF8.self), "id,name\n7\nAda\nname\nAda\nname\nBee\nid,name\n9\nCat\nCat\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        let line =
            try XCTUnwrap(
                source.components(separatedBy: "\n").firstIndex {
                    $0.contains("let first = client.user()")
                }) + 1
        let compiler = SelectionCompilerProcess(workspace: directory, scratch: directory)
        var commands = [
            "lldb", "--batch", "--file", directory.appendingPathComponent("app").path,
            "-o", "breakpoint set --file App.swift --line \(line)",
        ]
        // Live debugging additionally requires host debugserver permission; symbol validation does not.
        let live = ProcessInfo.processInfo.environment["LUXO_LLDB_RUNTIME"] == "1"
        if live { commands += ["-o", "run", "-o", "frame info", "-o", "process kill"] }
        let debug = try compiler.run("/usr/bin/xcrun", commands)
        let debugger = String(decoding: debug, as: UTF8.self)
        if live { XCTAssertTrue(debugger.contains("stop reason = breakpoint"), debugger) }
        XCTAssertTrue(debugger.contains("Breakpoint 1: where ="), debugger)
        XCTAssertTrue(debugger.contains("App.swift:\(line)"), debugger)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }
}
