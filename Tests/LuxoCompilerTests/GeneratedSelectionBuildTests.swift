import Foundation
import XCTest
@testable import LuxoClient
@testable import LuxoCompiler

final class GeneratedSelectionBuildTests: XCTestCase {
    func testGeneratedEmptySchemaDirectoriesCompile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/empty-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = SelectionCompilerProcess(workspace: root, scratch: directory)
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        let cases = [
            #"{"models":{},"apis":{}}"#,
            #"{"models":{},"apis":{"echo":{"id":1,"name":"echo","module":"test","returnType":"Bytes"}}}"#,
            #"{"models":{},"apis":{"hidden":{"id":1,"name":"hidden","module":"test","returnType":"Bytes","isInternal":true}}}"#,
            #"{"models":{"Empty":{"name":"Empty","usage":"output","fields":[]}},"apis":{}}"#,
        ]
        for raw in cases {
            let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(raw.utf8))
            let file = directory.appendingPathComponent("Schema.swift")
            try generator.generateSchema(schema).write(to: file, atomically: true, encoding: .utf8)
            _ = try process.run(
                "swiftc",
                [
                    "-typecheck", "-swift-version", "6", "-warnings-as-errors", "-I",
                    root.appendingPathComponent(".build/debug/Modules").path, file.path,
                ])
        }
    }

    func testActualGeneratedRequestsUseInferredSelections() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/generated-selection-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let process = SelectionCompilerProcess(workspace: root, scratch: directory)
        let objectDirectory = root.appendingPathComponent(".build/debug/LuxoClient.build")
        let objects = try fm.contentsOfDirectory(at: objectDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".swift.o") }.map(\.path)
        XCTAssertFalse(objects.isEmpty)
        _ = try process.run(
            "swiftc",
            ["-emit-library", "-profile-generate"] + objects
                + ["-o", directory.appendingPathComponent("libLuxoClient.dylib").path])
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(Self.schema.utf8))
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        let sources = [
            "Models.swift": generator.generateModels(schema), "Decoders.swift": generator.generateDecoders(schema),
            "Schema.swift": generator.generateSchema(schema), "Client.swift": generator.generateClient(schema),
            "App.swift": Self.application,
        ]
        for (name, source) in sources {
            try source.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let manifest = directory.appendingPathComponent("LuxoSelection.json")
        try generator.generateSelectionManifest(schema, module: "App").write(to: manifest)
        let output = directory.appendingPathComponent("app")
        try SelectionBuild.run(
            workspace: directory, manifest: manifest,
            arguments: [
                "-swift-version", "6", "-parse-as-library", "-I",
                root.appendingPathComponent(".build/debug/Modules").path,
                "-L", directory.path, "-l", "LuxoClient", "-o", output.path,
            ] + sources.keys.sorted().map { directory.appendingPathComponent($0).path })
        let result = try process.run(output.path, [])
        XCTAssertEqual(
            String(decoding: result, as: UTF8.self), "id\nprofile{name}\nid\n7\nprofile{name}\nAda\nname\nBee\n")
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("App.swift"), encoding: .utf8), Self.application)
        try verifyImportedClient(
            directory: directory, root: root, process: process, generator: generator, schema: schema)
        if ProcessInfo.processInfo.environment["LUXO_IOS_TYPECHECK"] == "1" {
            try verifyIOSGeneratedClient(
                directory: directory, root: root, process: process, sources: sources.keys.sorted())
        }
    }

    private func verifyIOSGeneratedClient(
        directory: URL, root: URL, process: SelectionCompilerProcess, sources: [String]
    ) throws {
        let runtime = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/LuxoClient"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.map(\.path).sorted()
        for (sdk, target) in [
            ("iphoneos", "arm64-apple-ios15.0"), ("iphonesimulator", "arm64-apple-ios15.0-simulator"),
        ] {
            let modules = directory.appendingPathComponent(sdk)
            try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: false)
            let sdkPath = String(
                decoding: try process.run("/usr/bin/xcrun", ["--sdk", sdk, "--show-sdk-path"]), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let options = [
                "-sdk", sdkPath, "-target", target, "-swift-version", "6", "-strict-concurrency=complete",
                "-warnings-as-errors", "-parse-as-library",
            ]
            _ = try process.run(
                "swiftc",
                options + [
                    "-emit-module", "-module-name", "LuxoClient", "-emit-module-path",
                    modules.appendingPathComponent("LuxoClient.swiftmodule").path,
                ] + runtime)
            _ = try process.run(
                "swiftc",
                options + ["-typecheck", "-I", modules.path, "-module-name", "App"]
                    + sources.map { directory.appendingPathComponent($0).path })
        }
    }

    private func verifyImportedClient(
        directory: URL, root: URL, process: SelectionCompilerProcess, generator: LuxoCodegen, schema: LuxoSchema
    ) throws {
        let modules = root.appendingPathComponent(".build/debug/Modules").path
        let generated = ["Models.swift", "Decoders.swift", "Schema.swift", "Client.swift"].map {
            directory.appendingPathComponent($0).path
        }
        _ = try process.run(
            "swiftc",
            [
                "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", "FixtureSDK", "-I", modules,
                "-L", directory.path, "-l", "LuxoClient", "-emit-module-path",
                directory.appendingPathComponent("FixtureSDK.swiftmodule").path,
                "-o", directory.appendingPathComponent("libFixtureSDK.dylib").path,
            ] + generated)
        let manifest = directory.appendingPathComponent("ImportedSelection.json")
        try generator.generateSelectionManifest(schema, module: "FixtureSDK").write(to: manifest)
        let source = directory.appendingPathComponent("Consumer.swift")
        let original = "import FixtureSDK\n" + Self.application
        try original.write(to: source, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("consumer")
        try SelectionBuild.run(
            workspace: directory, manifest: manifest,
            arguments: [
                "-swift-version", "6", "-module-name", "Consumer", "-parse-as-library", "-I", modules, "-I",
                directory.path,
                "-L", directory.path, "-l", "LuxoClient", "-l", "FixtureSDK", "-o", output.path, source.path,
            ])
        XCTAssertEqual(
            String(decoding: try process.run(output.path, []), as: UTF8.self),
            "id\nprofile{name}\nid\n7\nprofile{name}\nAda\nname\nBee\n")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
    }

    private static let schema =
        #"{"models":{"User":{"name":"User","fields":[{"id":1,"name":"id","type":"Int"},{"id":2,"name":"profile","type":"Model","typeName":"Profile"}]},"Profile":{"name":"Profile","fields":[{"id":1,"name":"name","type":"String"}]}},"apis":{"getUser":{"id":1,"name":"getUser","module":"test","returnType":"User"},"watch":{"id":2,"name":"watch","module":"test","returnType":"Profile","stream":true}}}"#

    private static let application = #"""
        import Foundation
        import LuxoClient
        struct Mock: Transport {
            func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload { throw LuxoError(code: 1, message: "dynamic path") }
            func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
                precondition(request.selectionPlan != nil, "missing prepared call-site selection")
                print(request.selection ?? "MISSING")
                if let plan = request.selectionPlan {
                    let json = try request.toJSONParameters()
                    guard case .string(let text) = json["$select"], text == request.selection,
                        json["selectionPlan"] == nil, !plan.text.isEmpty else {
                        throw LuxoError(code: 1, message: "plan JSON mismatch")
                    }
                }
                var encoder = LuxoClient.Encoder()
                try request.writeParameters(to: &encoder)
                return TransportPayload(data: Data((request.selection == "id" ? "{\"id\":7}" : "{\"profile\":{\"name\":\"Ada\"}}").utf8), mode: .json)
            }
            func subscribe<Value: Sendable>(_ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
                request: any GeneratedRequest, observer: StreamObserver?, handler: @escaping @Sendable (Value) -> Void) async throws -> (@Sendable () -> Void) {
                precondition(request.selectionPlan != nil, "missing prepared call-site selection")
                print(request.selection ?? "MISSING")
                if let plan = request.selectionPlan {
                    let json = try request.toJSONParameters()
                    guard case .string(let text) = json["$select"], text == request.selection,
                        json["selectionPlan"] == nil, !plan.text.isEmpty else {
                        throw LuxoError(code: 1, message: "plan JSON mismatch")
                    }
                }
                handler(try decoder(TransportPayload(data: Data("{\"name\":\"Bee\"}".utf8), mode: .json)))
                return {}
            }
            func setToken(_ token: String) {}
            func setMode(_ mode: TransportMode) {}
            func setSchema(_ schema: [String: APISchema]) throws {}
        }
        @main struct App {
            static func main() async throws {
                let client = try LuxoGeneratedClient(transport: Mock())
                guard let userSchema = LUXO_SCHEMA["getUser"] else {
                    throw LuxoError(code: 1, message: "missing schema")
                }
                let plan = try PreparedSelection("id", schema: userSchema)
                let planned = try await client.getUser(selectionPlan: plan)
                let plannedID = try planned.id.requireValue()
                precondition(plannedID == 7)
                let overridden = try await client.getUser(select: "profile{name}", selectionPlan: plan)
                let selectedProfile = try overridden.profile.requireValue()
                let selectedName = try selectedProfile.name.requireValue()
                precondition(selectedName == "Ada")
                let first = try await client.getUser()
                print(try first.id.requireValue())
                let second = try await client.getUser()
                let profile = try second.profile.requireValue()
                print(try profile.name.requireValue())
                _ = try await client.subscribeWatch { value in
                    print(try! value.name.requireValue())
                }
            }
        }
        """#
}
