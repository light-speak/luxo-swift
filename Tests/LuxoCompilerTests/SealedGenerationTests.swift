import Foundation
import XCTest
@testable import LuxoClient
@testable import LuxoCompiler

final class SealedGenerationTests: XCTestCase {
    func testGeneratedSealedCodecsCompileAndRun() throws {
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(Self.fixture.utf8))
        try schema.validateIDs()
        try SwiftEnumCodegen.validate(schema)
        try withFixture(
            schema, application: Self.application, file: "main.swift",
            artifact: ProcessInfo.processInfo.environment["LUXO_SEALED_OUTPUT"]
        ) { fixture in
            XCTAssertEqual(try fixture.compileAndRun(), "sealed codecs passed\n")
        }
    }

    func testGeneratedSealedCaseSelectionsUseCompilerIdentity() throws {
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(Self.fixture.utf8))
        try withFixture(schema, application: Self.selectionApplication) { fixture in
            XCTAssertEqual(
                try fixture.selectAndRun(),
                "Failure,Nested{child{Success{value}}},Pending,Success{value}\n7\nSuccess{value}\n7\nFailure,Nested,Pending,Success\nSuccess{value}\n7\nSuccess{value}\n7\n"
            )
            for source in [
                Self.selectionApplication.replacingOccurrences(
                    of: "switch value {", with: "escape(value); switch value {")
                    + "\nfunc escape(_ value: Outcome) {}\n",
                Self.selectionApplication.replacingOccurrences(
                    of: "print(try payload.value.requireValue())",
                    with: "escapePayload(payload); print(try payload.value.requireValue())")
                    + "\nfunc escapePayload(_ value: LuxoSealed_7_Outcome_1Payload) {}\n",
            ] {
                try source.write(
                    to: fixture.directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try fixture.selectAndRun())
            }
        }
    }

    func testActualMonomorphicGenericSchemaPreservesInputLayout() throws {
        try withFixture(genericSchema(), application: Self.genericApplication, file: "main.swift") { fixture in
            XCTAssertEqual(try fixture.compileAndRun(), "monomorphic generic passed\n")
        }
    }

    func testActualMonomorphicGenericSchemaInfersAllFourAPIs() throws {
        try withFixture(genericSchema(), application: Self.genericSelectionApplication) { fixture in
            XCTAssertEqual(
                try fixture.selectAndRun(),
                "items{value{value}},page,pageSize,total\n7\n1\n1\n10\nhasMore,items{value{value}},nextCursor\n8\nafter\nfalse\nvalue{items{value},page,pageSize,total}\n9\n1\n1\n10\nvalue\n7\nnil\n"
            )
        }
    }

    func testActualGoSealedProducerVectorsCompileAndDecode() throws {
        let schemaData = try Data(
            contentsOf: Self.root.appendingPathComponent("Tests/LuxoClientTests/Fixtures/GoSealedSchema.json"))
        let wire = try String(
            contentsOf: Self.root.appendingPathComponent("Tests/LuxoClientTests/Fixtures/GoSealedWire.json"),
            encoding: .utf8)
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: schemaData)
        let source = Self.goProducerApplication.replacingOccurrences(
            of: "GO_WIRE_LITERAL", with: SwiftEnumCodegen.literal(wire))
        try withFixture(schema, application: source, file: "main.swift") { fixture in
            XCTAssertEqual(try fixture.compileAndRun(), "Go sealed vectors 5 passed\n")
        }
    }

    func testActualGoEmptySumAPIsDoNotRequireFakeSelections() throws {
        let schema = try JSONDecoder().decode(
            LuxoSchema.self,
            from:
                Data(contentsOf: Self.root.appendingPathComponent("Tests/LuxoClientTests/Fixtures/GoSealedSchema.json"))
        )
        try withFixture(schema, application: Self.emptyApplication) { fixture in
            XCTAssertEqual(try fixture.selectAndRun(), "empty APIs passed\n")
        }
    }

    private static let goProducerApplication = #"""
        import Foundation
        import LuxoClient
        struct Vector: Decodable { let name: String; let json: JSONValue; let raw: [UInt8] }
        struct Vectors: Decodable { let vectors: [Vector] }
        let vectors = try LuxoJSONDecoder().decode(Vectors.self, from: Data(GO_WIRE_LITERAL.utf8)).vectors
        precondition(vectors.count == 5)
        for vector in vectors {
            let json = try LuxoJSONEncoder().encode(vector.json)
            let fromBinary = try decodeLuxoResponse(Data(vector.raw), read: decodeOutcome)
            let fromJSON = try LuxoJSONDecoder().decode(Outcome.self, from: json)
            let fromFoundation = try JSONDecoder().decode(Outcome.self, from: json)
            for value in [fromBinary, fromJSON, fromFoundation] {
                let encoded = try JSONValue.parse(LuxoJSONEncoder().encode(value))
                precondition(encoded == vector.json, vector.name)
            }
            let input = try LuxoJSONDecoder().decode(OutcomeInput.self, from: json)
            var bytes = Encoder()
            try input.writeLuxo(to: &bytes)
            precondition(bytes.data == Data(vector.raw), vector.name)
        }
        print("Go sealed vectors 5 passed")
        """#

    private static let emptyApplication = #"""
        import Foundation
        import LuxoClient
        struct Mock: Transport {
            func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload { fatalError("dynamic path") }
            func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
                precondition(request.selection == nil && request.selectionPlan == nil)
                var bytes = Encoder()
                try request.writeParameters(to: &bytes)
                precondition(bytes.data == Data([1,0]))
                return TransportPayload(data: Data([0]), mode: .binary)
            }
            func setToken(_ token: String) {}
            func setMode(_ mode: TransportMode) {}
            func setSchema(_ schema: [String: APISchema]) throws {}
        }
        @main struct App {
            static func main() async throws {
                let client = try LuxoGeneratedClient(transport: Mock())
                let value: EmptyOutcome? = try await client.echoEmpty(value: nil)
                guard case nil = value else { fatalError("empty present") }
                let values: [EmptyOutcome] = try await client.echoEmptyList(values: [])
                precondition(values.isEmpty)
                print("empty APIs passed")
            }
        }
        """#

    func testGeneratedSealedArrayMetadataSelectsOnlyRealCaseLeaves() throws {
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(Self.fixture.utf8))
        try withFixture(schema, application: Self.metadataApplication) { fixture in
            XCTAssertEqual(try fixture.selectAndRun(), "sealed metadata passed\n")
            let escaped =
                Self.metadataApplication.replacingOccurrences(
                    of: "precondition(history?.count == 2 && history?.isEmpty == false)",
                    with: "_ = opaque(history).isEmpty")
                + "\nfunc opaque(_ values: [Outcome]?) -> AnyCollection<Outcome> { AnyCollection(values ?? []) }\n"
            try escaped.write(
                to: fixture.directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try fixture.selectAndRun())
        }
    }

    private static let metadataApplication = #"""
        import Foundation
        import LuxoClient
        struct Mock: Transport {
            func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload { fatalError("dynamic path") }
            func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
                precondition(request.selection == "Nested{child{Failure,Nested,Pending,Success},history{Failure,Nested,Pending,Success}}")
                return TransportPayload(data: Data(#"{"Nested":{"child":null,"history":[{"Pending":{}},{"Success":{}}]}}"#.utf8), mode: .json)
            }
            func setToken(_ token: String) {}
            func setMode(_ mode: TransportMode) {}
            func setSchema(_ schema: [String: APISchema]) throws {}
        }
        @main struct App {
            static func main() async throws {
                let client = try LuxoGeneratedClient(transport: Mock())
                let value = try await client.echo(value: .nested(.init()))
                guard case .nested(let payload) = value else { fatalError("wrong case") }
                guard case nil = try payload.child.requireValue() else { fatalError("wrong null") }
                let history = try payload.history.requireValue()
                precondition(history?.count == 2 && history?.isEmpty == false)
                print("sealed metadata passed")
            }
        }
        """#

    func testSealedSourceAliasesPreserveWireNamesAndFreshPayloadTypes() throws {
        let body = #"""
            {"models":{"LuxoSealed_7_Outcome_1Payload":{"name":"LuxoSealed_7_Outcome_1Payload","usage":"output","fields":[{"id":1,"name":"value","type":"Int"}]}},
             "sealeds":{"Outcome":{"name":"Outcome","usage":"inputOutput","variants":[{"id":1,"name":"Success","fields":[{"id":1,"name":"class","type":"Int"},{"id":2,"name":"luxoField1","type":"String","hasDefault":true}]}]}},
             "apis":{"echo":{"id":1,"name":"echo","module":"test","returnType":"Outcome","params":[{"id":1,"name":"value","type":"Sealed","typeName":"Outcome"}]}}}
            """#
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(body.utf8))
        try withFixture(schema, application: Self.aliasApplication) { fixture in
            XCTAssertEqual(try fixture.selectAndRun(), "sealed aliases passed\n")
        }
        let empty = LuxoSchema(models: [:], apis: [:])
        XCTAssertTrue(SwiftSealedPlan(empty, aliases: [:]).owners.isEmpty)
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        XCTAssertTrue(generator.sealedSelectionTypes(empty).isEmpty)
        // This controls the internal defensive fallback, not a valid public schema/inference result.
        let noUsage = LuxoCodegen.TypeUsages(states: [:], inputAliases: [:])
        XCTAssertEqual(generator.generateSealedModels(schema, usages: noUsage), "")
    }

    private static let aliasApplication = #"""
        import Foundation
        import LuxoClient
        struct Mock: Transport {
            func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload { fatalError("dynamic path") }
            func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
                precondition(request.selection == "Success{class}")
                var encoder = Encoder()
                try request.writeParameters(to: &encoder)
                precondition(encoder.data == Data([1,6,1,4,0,1,14,0]))
                return TransportPayload(data: Data(#"{"Success":{"class":7}}"#.utf8), mode: .json)
            }
            func setToken(_ token: String) {}
            func setMode(_ mode: TransportMode) {}
            func setSchema(_ schema: [String: APISchema]) throws {}
        }
        @main struct App {
            static func main() async throws {
                let client = try LuxoGeneratedClient(transport: Mock())
                let value = try await client.echo(value: .success(.init(luxoField1_: 7)))
                guard case .success(let payload) = value else { fatalError("wrong case") }
                let number = try payload.luxoField1_.requireValue()
                precondition(number == 7)
                print("sealed aliases passed")
            }
        }
        """#

    private func genericSchema() throws -> LuxoSchema {
        try JSONDecoder().decode(
            LuxoSchema.self,
            from: Data(
                contentsOf:
                    Self.root.appendingPathComponent("Tests/LuxoClientTests/Fixtures/GenericMonomorphic.json")))
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Fixture {
        let directory: URL
        let process: SelectionCompilerProcess
        let sources: [String]
        let objects: [String]
        var modules: String { SealedGenerationTests.root.appendingPathComponent(".build/debug/Modules").path }

        func compileAndRun() throws -> String {
            let executable = directory.appendingPathComponent("check")
            _ = try process.run(
                "swiftc",
                [
                    "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                    "-profile-generate", "-I", modules, "-o", executable.path,
                ] + sources + objects)
            return String(decoding: try process.run(executable.path, []), as: UTF8.self)
        }

        func selectAndRun() throws -> String {
            let library = directory.appendingPathComponent("libLuxoClient.dylib")
            if !FileManager.default.fileExists(atPath: library.path) {
                _ = try process.run("swiftc", ["-emit-library", "-profile-generate"] + objects + ["-o", library.path])
            }
            let executable = directory.appendingPathComponent("app")
            try SelectionBuild.run(
                workspace: directory, manifest: directory.appendingPathComponent("LuxoSelection.json"),
                arguments: [
                    "-swift-version", "6", "-parse-as-library", "-I", modules,
                    "-L", directory.path, "-l", "LuxoClient", "-o", executable.path,
                ] + sources)
            return String(decoding: try process.run(executable.path, []), as: UTF8.self)
        }
    }

    private func withFixture(
        _ schema: LuxoSchema, application: String, file: String = "App.swift", artifact: String? = nil,
        body: (Fixture) throws -> Void
    ) throws {
        let directory =
            artifact.map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent(".tmp/sealed-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if artifact == nil { try? fm.removeItem(at: directory) } }
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        let sources = [
            "Models.swift": generator.generateModels(schema), "Decoders.swift": generator.generateDecoders(schema),
            "Schema.swift": generator.generateSchema(schema), "Client.swift": generator.generateClient(schema),
            file: application,
        ]
        for (name, source) in sources {
            try source.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try generator.generateSelectionManifest(schema, module: "App").write(
            to: directory.appendingPathComponent("LuxoSelection.json"))
        let objects = try fm.contentsOfDirectory(
            at: Self.root.appendingPathComponent(".build/debug/LuxoClient.build"),
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".swift.o") }.map(\.path).sorted()
        XCTAssertFalse(objects.isEmpty)
        try body(
            Fixture(
                directory: directory, process: SelectionCompilerProcess(workspace: Self.root, scratch: directory),
                sources: sources.keys.sorted().map { directory.appendingPathComponent($0).path }, objects: objects))
    }

    private static let genericApplication = #"""
        import Foundation
        import LuxoClient
        let input = LuxoBox_d1dc0a950b2f5e29Input(value:
            LuxoPage_5411031e24da9aefInput(items: [CounterInput(value: 9)], total: 1, page: 1, pageSize: 10))
        var encoder = Encoder()
        try input.writeLuxo(to: &encoder)
        precondition(encoder.data == Data([0,1,0,1,1,0,1,18,0,2,2,3,2,4,20,0,0]))
        let output = try LuxoJSONDecoder().decode(LuxoBox_d1dc0a950b2f5e29.self, from:
            Data(#"{"value":{"items":[{"value":9}],"total":1,"page":1,"pageSize":10}}"#.utf8))
        let page = try output.value.requireValue()
        let items = try page.items.requireValue()
        let number = try items[0].value.requireValue()
        precondition(number == 9)
        print("monomorphic generic passed")
        """#

    private static let genericSelectionApplication = #"""
        import Foundation
        import LuxoClient
        struct Mock: Transport {
            func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload { fatalError("dynamic path") }
            func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
                guard let plan = request.selectionPlan else { throw LuxoError(code: 1, message: "missing automatic plan") }
                print(plan.text)
                var encoder = Encoder()
                try request.writeParameters(to: &encoder)
                let json: String
                switch api {
                case "readPage": json = #"{"items":[{"value":{"value":7}}],"total":1,"page":1,"pageSize":10}"#
                case "readCursor": json = #"{"items":[{"value":{"value":8}}],"nextCursor":"after","hasMore":false}"#
                case "echoNested":
                    precondition(encoder.data == Data([1,17,0,1,0,1,1,0,1,18,0,2,2,3,2,4,20,0,0]))
                    json = #"{"value":{"items":[{"value":9}],"total":1,"page":1,"pageSize":10}}"#
                case "echoLists":
                    precondition(encoder.data == Data([1,2,5,0,1,1,14,0,4,0,1,0,0]))
                    json = #"[{"value":7},{"value":null}]"#
                default: throw LuxoError(code: 1, message: "unknown API")
                }
                return TransportPayload(data: Data(json.utf8), mode: .json)
            }
            func setToken(_ token: String) {}
            func setMode(_ mode: TransportMode) {}
            func setSchema(_ schema: [String: APISchema]) throws {}
        }
        @main struct App {
            static func main() async throws {
                let client = try LuxoGeneratedClient(transport: Mock())
                let page = try await client.readPage()
                for box in try page.items.requireValue() {
                    let counter = try box.value.requireValue()
                    print(try counter.value.requireValue())
                }
                print(try page.total.requireValue()); print(try page.page.requireValue()); print(try page.pageSize.requireValue())
                let cursor = try await client.readCursor()
                for box in try cursor.items.requireValue() {
                    let counter = try box.value.requireValue()
                    print(try counter.value.requireValue())
                }
                print(try cursor.nextCursor.requireValue() ?? "null"); print(try cursor.hasMore.requireValue())
                let nested = try await client.echoNested(value: .init(value:
                    .init(items: [.init(value: 9)], total: 1, page: 1, pageSize: 10)))
                let nestedPage = try nested.value.requireValue()
                for counter in try nestedPage.items.requireValue() { print(try counter.value.requireValue()) }
                print(try nestedPage.total.requireValue()); print(try nestedPage.page.requireValue()); print(try nestedPage.pageSize.requireValue())
                let rows = try await client.echoLists(value: [.init(value: 7), .init(value: nil)])
                for row in rows {
                    if let value = try row.value.requireValue() { print(value) } else { print("nil") }
                }
            }
        }
        """#

    private static let selectionApplication = #"""
        import Foundation
        import LuxoClient
        struct Mock: Transport {
            func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload { fatalError("dynamic path") }
            func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
                guard let plan = request.selectionPlan else { throw LuxoError(code: 1, message: "missing automatic plan") }
                print(plan.text)
                var bytes = Encoder()
                try request.writeParameters(to: &bytes)
                if api == "echoMany" {
                    precondition(bytes.data == Data([1,1,6,1,4,0,1,14,0]))
                    return TransportPayload(data: Data(#"[{"Success":{"value":7}}]"#.utf8), mode: .json)
                }
                precondition(bytes.data == Data([1,6,1,4,0,1,14,0]))
                return TransportPayload(data: Data(#"{"Success":{"value":7}}"#.utf8), mode: .json)
            }
            func setToken(_ token: String) {}
            func setMode(_ mode: TransportMode) {}
            func setSchema(_ schema: [String: APISchema]) throws {}
        }
        @main struct App {
            static func main() async throws {
                let client = try LuxoGeneratedClient(transport: Mock())
                let value = try await client.echo(value: .success(.init(value: 7)))
                switch value {
                case .success(let payload): print(try payload.value.requireValue())
                case .nested(let nested):
                    if case .success(let child)? = try nested.child.requireValue() {
                        print(try child.value.requireValue())
                    }
                case .failure, .pending: break
                }
                if case .success(let payload) = try await client.echo(value: .success(.init(value: 7))) {
                    print(try payload.value.requireValue())
                }
                let tag = try await client.echo(value: .success(.init(value: 7)))
                switch tag { default: break }
                for case .success(let row) in try await client.echoMany(values: [.success(.init(value: 7))]) {
                    print(try row.value.requireValue())
                }
                try await guarded(client)
            }
            static func guarded(_ client: LuxoGeneratedClient) async throws {
                guard case .success(let payload) = try await client.echo(value: .success(.init(value: 7))) else { return }
                print(try payload.value.requireValue())
            }
        }
        """#

    private static let fixture = #"""
        {
          "models": {
            "Envelope": {
              "name": "Envelope",
              "fields": [
                {
                  "id": 1,
                  "name": "outcome",
                  "type": "Sealed",
                  "typeName": "Outcome"
                },
                {
                  "id": 2,
                  "name": "history",
                  "type": "Sealed",
                  "typeName": "Outcome",
                  "nullable": true,
                  "isList": true
                }
              ]
            }
          },
          "apis": {
            "echo": {
              "id": 1,
              "name": "echo",
              "module": "test",
              "returnType": "Outcome",
              "params": [
                {
                  "id": 1,
                  "name": "value",
                  "type": "Sealed",
                  "typeName": "Outcome"
                }
              ]
            },
            "echoEmpty": {
              "id": 2,
              "name": "echoEmpty",
              "module": "test",
              "returnType": "EmptyOutcome",
              "returnNullable": true,
              "params": [
                {
                  "id": 1,
                  "name": "value",
                  "type": "Sealed",
                  "typeName": "EmptyOutcome",
                  "nullable": true
                }
              ]
            },
            "echoEmptyList": {
              "id": 3,
              "name": "echoEmptyList",
              "module": "test",
              "returnType": "EmptyOutcome",
              "returnList": true,
              "params": [
                {
                  "id": 1,
                  "name": "values",
                  "type": "Sealed",
                  "typeName": "EmptyOutcome",
                  "isList": true
                }
              ]
            },
            "rows": {
              "id": 4,
              "name": "rows",
              "module": "test",
              "returnType": "Envelope",
              "returnList": true
            },
            "echoMany": {
              "id": 5,
              "name": "echoMany",
              "module": "test",
              "returnType": "Outcome",
              "returnList": true,
              "params": [
                {
                  "id": 1,
                  "name": "values",
                  "type": "Sealed",
                  "typeName": "Outcome",
                  "isList": true
                }
              ]
            }
          },
          "sealeds": {
            "Outcome": {
              "name": "Outcome",
              "usage": "inputOutput",
              "variants": [
                {
                  "id": 1,
                  "name": "Success",
                  "fields": [
                    {
                      "id": 1,
                      "name": "value",
                      "type": "Int"
                    }
                  ]
                },
                {
                  "id": 2,
                  "name": "Failure",
                  "fields": [
                    {
                      "id": 1,
                      "name": "reason",
                      "type": "String",
                      "hasDefault": true
                    }
                  ]
                },
                {
                  "id": 3,
                  "name": "Pending",
                  "fields": []
                },
                {
                  "id": 4,
                  "name": "Nested",
                  "fields": [
                    {
                      "id": 1,
                      "name": "child",
                      "type": "Sealed",
                      "typeName": "Outcome",
                      "nullable": true,
                      "hasDefault": true
                    },
                    {
                      "id": 2,
                      "name": "history",
                      "type": "Sealed",
                      "typeName": "Outcome",
                      "nullable": true,
                      "hasDefault": true,
                      "isList": true
                    }
                  ]
                }
              ]
            },
            "EmptyOutcome": {
              "name": "EmptyOutcome",
              "usage": "inputOutput",
              "variants": []
            },
            "RequiredOutcome": {
              "name": "RequiredOutcome",
              "usage": "inputOutput",
              "variants": [
                {
                  "id": 1,
                  "name": "Value",
                  "fields": [
                    {
                      "id": 1,
                      "name": "child",
                      "type": "Sealed",
                      "typeName": "Outcome",
                      "nullable": true
                    }
                  ]
                }
              ]
            }
          }
        }
        """#

    private static let application = #"""
        import Foundation
        import LuxoClient

        func rejects(_ label: String = "sealed input", _ operation: () throws -> Void) {
            do { try operation(); fatalError("accepted invalid \(label)") } catch {}
        }
        let success = OutcomeInput.success(.init(value: 7))
        var encoder = Encoder()
        try success.writeLuxo(to: &encoder)
        precondition(encoder.data == Data([1,4,0,1,14,0]))
        guard case .success(let payload) = try decodeLuxoResponse(encoder.data, read: decodeOutcome) else {
            fatalError("wrong binary case")
        }
        let number = try payload.value.requireValue()
        precondition(number == 7)
        for data in [Data([1,4,0,1,14,0]), Data([1,2,0,0]), Data([3,2,0,0])] {
            let value = try decodeLuxoResponse(data, read: decodeOutcome)
            let json = try LuxoJSONEncoder().encode(value)
            _ = try LuxoJSONDecoder().decode(Outcome.self, from: json)
        }
        guard case .success(let empty) = try decodeLuxoResponse(Data([1,2,0,0]), read: decodeOutcome),
              case .unselected = empty.value else { fatalError("output default fabricated") }
        for data in [Data(), Data([0,2,0,0]), Data([99,2,0,0]), Data([1,4,0,1,14]),
                     Data([3,2,0,0,3,2,0,0]), Data([1,3,0,0,0])] {
            rejects { _ = try decodeLuxoResponse(data, read: decodeOutcome) }
        }
        for json in [#"{}"#, #"{"Unknown":{}}"#, #"{"Pending":{},"Success":{}}"#,
                     #"{"Pending":{},"Pending":{}}"#, #"{"Pending":null}"#] {
            rejects { _ = try LuxoJSONDecoder().decode(Outcome.self, from: Data(json.utf8)) }
        }
        rejects { _ = try LuxoJSONDecoder().decode(OutcomeInput.self, from: Data(#"{"Success":{}}"#.utf8)) }
        rejects { _ = try LuxoJSONDecoder().decode(OutcomeInput.self, from: Data(#"{"Failure":{"reason":null}}"#.utf8)) }
        let omitted = try LuxoJSONDecoder().decode(OutcomeInput.self, from: Data(#"{"Failure":{}}"#.utf8))
        var omittedBytes = Encoder()
        try omitted.writeLuxo(to: &omittedBytes)
        precondition(omittedBytes.data == Data([2,2,0,0]))
        let nilChild = OutcomeInput.nested(.init(child: .present(nil), history: .present([success])))
        var nestedBytes = Encoder()
        try nilChild.writeLuxo(to: &nestedBytes)
        guard case .nested(let nested) = try decodeLuxoResponse(nestedBytes.data, read: decodeOutcome),
              case .value(nil) = nested.child, let history = try nested.history.requireValue(), history.count == 1 else {
            fatalError("nullable/list frame mismatch")
        }
        var deep = OutcomeInput.pending(.init())
        for _ in 0..<31 { deep = .nested(.init(child: .present(deep))) }
        var boundary = Encoder()
        try deep.writeLuxo(to: &boundary)
        _ = try decodeLuxoResponse(boundary.data, read: decodeOutcome)
        _ = try LuxoJSONDecoder().decode(Outcome.self, from: LuxoJSONEncoder().encode(deep))
        deep = .nested(.init(child: .present(deep)))
        rejects { var bytes = Encoder(); try deep.writeLuxo(to: &bytes) }
        rejects { _ = try LuxoJSONEncoder().encode(deep) }
        for json in [#"{"Pending":{},"Unknown":{}}"#, #"{"Pending":{"typo":7}}"#] {
            rejects("Foundation output \(json)") { _ = try JSONDecoder().decode(Outcome.self, from: Data(json.utf8)) }
            rejects("Foundation input \(json)") { _ = try JSONDecoder().decode(OutcomeInput.self, from: Data(json.utf8)) }
        }
        let plan = try LuxoGeneratedClient.prepareSelection_echo("Success{value},Pending")
        precondition(plan.text == "Success{value},Pending")
        let listBytes = Data([2,6,1,4,0,1,14,0,4,3,2,0,0])
        var row = Encoder()
        row.writeVarint(0)
        row.writeVarint(1)
        row.writeBytes(Data([1,4,0,1,14,0]))
        row.writeVarint(2)
        row.writeBool(true)
        row.writeRawBytes(listBytes)
        row.writeEnd()
        let envelope = try decodeLuxoResponse(row.data, read: decodeEnvelope)
        let rowHistory = try envelope.history.requireValue()
        precondition(rowHistory?.count == 2)
        var columns = Encoder()
        columns.writeVarint(1)
        columns.writeVarint(0)
        columns.writeVarint(1)
        columns.writeBytes(Data([1,4,0,1,14,0]))
        columns.writeVarint(2)
        columns.writeBool(true)
        columns.writeBytes(listBytes)
        columns.writeEnd()
        let rows = try decodeColumnarEnvelope(columns.data)
        precondition(rows.count == 1)
        let columnHistory = try rows[0].history.requireValue()
        precondition(columnHistory?.count == 2)
        let emptyInput: EmptyOutcomeInput? = nil
        guard case nil = emptyInput else { fatalError("empty input") }
        let emptyOutput: EmptyOutcome? = try LuxoJSONDecoder().decode(EmptyOutcome?.self, from: Data("null".utf8))
        guard case nil = emptyOutput else { fatalError("empty output") }
        let emptyList = try LuxoJSONDecoder().decode([EmptyOutcome].self, from: Data("[]".utf8))
        precondition(emptyList.isEmpty)
        rejects { _ = try LuxoJSONDecoder().decode(EmptyOutcome.self, from: Data(#"{"Future":{}}"#.utf8)) }
        rejects { _ = try decodeLuxoResponse(Data([1,2,0,0]), read: decodeEmptyOutcome) }
        rejects { _ = try LuxoJSONDecoder().decode(RequiredOutcomeInput.self, from: Data(#"{"Value":{}}"#.utf8)) }
        let requiredNull = try LuxoJSONDecoder().decode(RequiredOutcomeInput.self, from: Data(#"{"Value":{"child":null}}"#.utf8))
        var requiredBytes = Encoder()
        try requiredNull.writeLuxo(to: &requiredBytes)
        precondition(requiredBytes.data == Data([1,4,0,1,0,0]))
        var deepJSON = #"{"Pending":{}}"#
        for _ in 0..<31 { deepJSON = "{\"Nested\":{\"child\":" + deepJSON + "}}" }
        _ = try LuxoJSONDecoder().decode(Outcome.self, from: Data(deepJSON.utf8))
        deepJSON = "{\"Nested\":{\"child\":" + deepJSON + "}}"
        rejects { _ = try LuxoJSONDecoder().decode(Outcome.self, from: Data(deepJSON.utf8)) }
        print("sealed codecs passed")
        """#
}
