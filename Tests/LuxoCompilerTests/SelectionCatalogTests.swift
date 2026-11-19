import Foundation
import XCTest

@testable import LuxoCompiler

final class SelectionCatalogTests: XCTestCase {
    func testSealedPayloadSymbolConflictsRejectBothWireAndShapeMismatch() throws {
        let graph = #"""
            {"module":{"name":"T"},"symbols":[
             {"identifier":{"precise":"s:1T7OutcomeO"},"pathComponents":["Outcome"],"accessLevel":"public","kind":{"identifier":"swift.enum"}},
             {"identifier":{"precise":"s:1T7PayloadV"},"pathComponents":["Payload"],"accessLevel":"public","kind":{"identifier":"swift.struct"}},
             {"identifier":{"precise":"success"},"pathComponents":["Outcome","success(_:)"],"accessLevel":"public"},
             {"identifier":{"precise":"failure"},"pathComponents":["Outcome","failure(_:)"],"accessLevel":"public"},
             {"identifier":{"precise":"value"},"pathComponents":["Payload","value"],"accessLevel":"public"}],
             "relationships":[{"kind":"memberOf","source":"success","target":"s:1T7OutcomeO"},
              {"kind":"memberOf","source":"failure","target":"s:1T7OutcomeO"},
              {"kind":"memberOf","source":"value","target":"s:1T7PayloadV"}]}
            """#
        func manifest(name: String, structured: Bool) -> Data {
            Data(
                #"""
                {"version":1,"module":"T","client":"Client","apis":{},"fields":{},"sealeds":{"Outcome":{
                 "success":{"name":"Success","payload":"Payload","fields":{"value":{"name":"one","structured":false}}},
                 "failure":{"name":"Failure","payload":"Payload","fields":{"value":{"name":"\#(name)","structured":\#(structured)}}}}}}
                """#.utf8)
        }
        for (name, structured) in [("two", false), ("one", true)] {
            XCTAssertThrowsError(
                try SelectionCatalog(manifest: manifest(name: name, structured: structured), graphs: [Data(graph.utf8)])
            ) {
                guard case SelectionCatalog.Failure.ambiguousSymbol = $0 else { return XCTFail("unexpected \($0)") }
            }
        }
        XCTAssertNoThrow(
            try SelectionCatalog(manifest: manifest(name: "one", structured: false), graphs: [Data(graph.utf8)]))
        let valid = manifest(name: "one", structured: false)
        let privateOwner = graph.replacingOccurrences(
            of: "\"accessLevel\":\"public\",\"kind\":{\"identifier\":\"swift.enum\"}",
            with: "\"accessLevel\":\"private\",\"kind\":{\"identifier\":\"swift.enum\"}")
        XCTAssertThrowsError(try SelectionCatalog(manifest: valid, graphs: [Data(privateOwner.utf8)])) {
            guard case SelectionCatalog.Failure.missingSymbol = $0 else { return XCTFail("unexpected \($0)") }
        }
        let invalid = Data(
            String(decoding: valid, as: UTF8.self).replacingOccurrences(
                of: "\"module\":\"T\"", with: "\"module\":\"bad-name\""
            ).utf8)
        XCTAssertThrowsError(try SelectionCatalog(manifest: invalid, graphs: [Data(graph.utf8)])) {
            guard case SelectionCatalog.Failure.invalidManifest = $0 else { return XCTFail("unexpected \($0)") }
        }
    }

    func testManifestPreservesUnicodeDSLLetterNames() throws {
        let source =
            #"{"version":1,"module":"SDK","client":"Client","apis":{"café":{}},"fields":{"Café":{"中文2":false,"𐐀_name":false}}}"#
        let manifest = try JSONDecoder().decode(SelectionManifest.self, from: Data(source.utf8))
        XCTAssertNoThrow(try manifest.validate())
        for name in ["café", "中文2", "𐐀_name", "_id2"] { XCTAssertTrue(SelectionManifest.validIdentifier(name)) }
        for name in ["2café", "café²", "e\u{0301}", "😀", "字\u{200d}", "bad-name"] {
            XCTAssertFalse(SelectionManifest.validIdentifier(name))
        }
    }
    func testEmptyOwnerCannotAuthorizeConflictingMembership() throws {
        let manifest = #"{"version":1,"module":"SDK","client":"Client","apis":{},"fields":{"Record":{"id":false}}}"#
        for targets in [["", ""], ["first", "second"], ["second", "first", "second"]] {
            let graph: [String: Any] = [
                "module": ["name": "SDK"],
                "symbols": [
                    [
                        "identifier": ["precise": ""], "pathComponents": ["Record"], "accessLevel": "public",
                        "kind": ["identifier": "swift.struct"],
                    ],
                    ["identifier": ["precise": "field"], "pathComponents": ["Record", "id"], "accessLevel": "public"],
                ],
                "relationships": targets.map { ["kind": "memberOf", "source": "field", "target": $0] },
            ]
            XCTAssertThrowsError(
                try SelectionCatalog(
                    manifest: Data(manifest.utf8), graphs: [JSONSerialization.data(withJSONObject: graph)])
            ) { error in
                guard case SelectionCatalog.Failure.missingSymbol("Record.id") = error else {
                    return XCTFail("empty owner authorized a member: \(error)")
                }
            }
        }
    }

    func testResolverPreservesDuplicateMethodFactoryAndFieldIdentities() throws {
        let manifest =
            #"{"version":1,"module":"SDK","client":"Client","selectionPlans":true,"apis":{"user":{}},"fields":{"User":{"id":false}}}"#
        let graph = try resolverGraph()
        let duplicate = try SelectionCatalog(manifest: Data(manifest.utf8), graphs: [graph, graph])
        XCTAssertEqual(Set(duplicate.apis.keys), ["api"])
        XCTAssertEqual(Set(duplicate.fields.keys), ["field"])
        XCTAssertEqual(duplicate.planFactories, ["api": "SDK.Client.prepareSelection_user"])
        for (path, member) in [
            (["User", "id"], "User.id"), (["Client", "user(extra:)"], "Client.user"),
            (["Client", "prepareSelection_user(extra:)"], "Client.prepareSelection_user"),
        ] {
            let additional = try graphData(
                String(
                    decoding: JSONSerialization.data(withJSONObject: [
                        "module": ["name": "SDK"],
                        "symbols": [["identifier": ["precise": "different"], "pathComponents": path]],
                    ]), as: UTF8.self))
            XCTAssertThrowsError(try SelectionCatalog(manifest: Data(manifest.utf8), graphs: [graph, additional])) {
                error in
                guard case SelectionCatalog.Failure.ambiguousSymbol(let symbol) = error, symbol == member else {
                    return XCTFail("distinct USRs lost their ambiguity: \(error)")
                }
            }
        }
        let empty = try resolverGraph(field: "")
        XCTAssertThrowsError(try SelectionCatalog(manifest: Data(manifest.utf8), graphs: [empty])) { error in
            guard case SelectionCatalog.Failure.missingSymbol("User.id") = error else {
                return XCTFail("empty member identity became a valid symbol: \(error)")
            }
        }
    }

    func testRuntimeCandidatesKeepAllOwnerAndMembershipConflictEvidence() throws {
        let manifest = #"{"version":1,"module":"SDK","client":"Client","apis":{},"fields":{}}"#
        let source =
            #"{"module":{"name":"LuxoClient"},"symbols":[{"identifier":{"precise":"total"},"pathComponents":["Page","total"]},{"identifier":{"precise":"value"},"pathComponents":["Selected","requireValue()"]}]}"#
        let graph = try graphData(source)
        let ownerConflict = try JSONSerialization.data(withJSONObject: [
            "module": ["name": "LuxoClient"],
            "symbols": [
                [
                    "identifier": ["precise": "fixture-owner:Page"], "pathComponents": ["Unrelated"],
                    "accessLevel": "public", "kind": ["identifier": "swift.struct"],
                ]
            ],
        ])
        let relationshipConflict = try JSONSerialization.data(withJSONObject: [
            "module": ["name": "LuxoClient"], "symbols": [],
            "relationships": [["kind": "memberOf", "source": "total", "target": "fixture-owner:Selected"]],
        ])
        for conflict in [ownerConflict, relationshipConflict] {
            for graphs in [[graph, conflict, graph], [conflict, graph]] {
                let catalog = try SelectionCatalog(manifest: Data(manifest.utf8), graphs: graphs)
                XCTAssertEqual(catalog.transparent, ["value"])
                XCTAssertTrue(catalog.metadata.isEmpty)
            }
        }
    }

    private func resolverGraph(field: String = "field") throws -> Data {
        try graphData(
            """
            {"module":{"name":"SDK"},"symbols":[
            {"identifier":{"precise":"api"},"pathComponents":["Client","user(select:)"]},
            {"identifier":{"precise":"factory"},"pathComponents":["Client","prepareSelection_user(_:)"]},
            {"identifier":{"precise":"\(field)"},"pathComponents":["User","id"]}]}
            """)
    }

    func testRealCompilerRequiresPublicOwnersForSDKAndRuntimeMembers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/selection-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sdk = try ownerGraph(
            "OwnerProbe", directory: directory, label: "sdk",
            source: """
                public protocol Provider {}
                public extension Provider { var filters: [Int]? { nil }; var sorters: [Int]? { nil } }
                public struct PublicRecord: Provider { public let id: Int }
                struct InternalRecord: Provider { public let id: Int }
                private struct PrivateRecord: Provider { public let id: Int }
                public struct PublicClient { public func user(select: String? = nil) -> PublicRecord { fatalError() } }
                struct InternalClient { public func user(select: String? = nil) -> PublicRecord { fatalError() } }
                private struct PrivateClient { public func user(select: String? = nil) -> PublicRecord { fatalError() } }
                """)
        func manifest(_ client: String, fields: [String: [String: Bool]], api: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "module": "OwnerProbe", "client": client,
                "apis": api ? ["user": [:]] : [:], "fields": fields,
            ])
        }
        let visible = try SelectionCatalog(
            manifest: manifest("PublicClient", fields: ["PublicRecord": ["id": false]], api: true),
            graphs: [sdk])
        XCTAssertEqual(visible.apis.count, 1)
        XCTAssertEqual(visible.fields.values.map(\.name), ["id"])
        for owner in ["InternalRecord", "PrivateRecord"] {
            for field in ["id", "filters", "sorters"] {
                XCTAssertThrowsError(
                    try SelectionCatalog(
                        manifest: manifest("PublicClient", fields: [owner: [field: false]], api: false),
                        graphs: [sdk]))
            }
        }
        for client in ["InternalClient", "PrivateClient"] {
            XCTAssertThrowsError(
                try SelectionCatalog(manifest: manifest(client, fields: [:], api: true), graphs: [sdk]))
        }
        try verifyOwnerRelationships(
            sdk, manifest: manifest("PublicClient", fields: ["PublicRecord": ["id": false]], api: true))
        let empty = try manifest("PublicClient", fields: [:], api: false)
        for access in ["internal", "private", "public"] {
            let runtime = try ownerGraph(
                "LuxoClient", directory: directory, label: access,
                source: """
                    \(access) struct Page {
                        public let items: [Int]; public let total: Int; public let page: Int; public let pageSize: Int
                    }
                    \(access) enum Selected<Value> {
                        case value(Value)
                        public func requireValue() -> Value { fatalError() }
                    }
                    """)
            let catalog = try SelectionCatalog(manifest: empty, graphs: [runtime])
            XCTAssertEqual(catalog.transparent.count, access == "public" ? 2 : 0)
            XCTAssertEqual(catalog.metadata.count, access == "public" ? 3 : 0)
        }
    }

    func testNonPublicSymbolsCannotEnterTheManifestOrRuntimeProperties() throws {
        let manifest = #"""
            {"version":1,"module":"SDK","client":"Client","apis":{"user":{}},"fields":{"User":{"id":false}}}
            """#
        for access in ["internal", "private", "fileprivate", "package"] {
            for hiddenAPI in [false, true] {
                let apiAccess = hiddenAPI ? access : "public"
                let fieldAccess = hiddenAPI ? "public" : access
                let graph = """
                    {"module":{"name":"SDK"},"symbols":[
                    {"identifier":{"precise":"api"},"pathComponents":["Client","user(select:)"],"accessLevel":"\(apiAccess)"},
                    {"identifier":{"precise":"field"},"pathComponents":["User","id"],"accessLevel":"\(fieldAccess)"}]}
                    """
                XCTAssertThrowsError(
                    try SelectionCatalog(manifest: Data(manifest.utf8), graphs: [try graphData(graph)]))
            }
        }
        let noAccess = #"""
            {"module":{"name":"SDK"},"symbols":[
            {"identifier":{"precise":"api"},"pathComponents":["Client","user(select:)"]},
            {"identifier":{"precise":"field"},"pathComponents":["User","id"]}]}
            """#
        XCTAssertThrowsError(
            try SelectionCatalog(
                manifest: Data(manifest.utf8), graphs: [try graphData(noAccess, publicMembers: false)]))
        let publicAPI = #"""
            {"module":{"name":"SDK"},"symbols":[
            {"identifier":{"precise":"api"},"pathComponents":["Client","user(select:)"],"accessLevel":"public"}]}
            """#
        let openField = #"""
            {"module":{"name":"SDK"},"symbols":[
            {"identifier":{"precise":"field"},"pathComponents":["User","id"],"accessLevel":"open"}]}
            """#
        let visible = try SelectionCatalog(
            manifest: Data(manifest.utf8), graphs: [try graphData(publicAPI), try graphData(openField)])
        XCTAssertEqual(Set(visible.apis.keys), ["api"])
        XCTAssertEqual(visible.fields["field"]?.name, "id")
        let runtime = """
            {"module":{"name":"LuxoClient"},"symbols":[
            {"identifier":{"precise":"hidden"},"pathComponents":["Page","total"],"accessLevel":"internal"},
            {"identifier":{"precise":"legacy"},"pathComponents":["Page","pageSize"]},
            {"identifier":{"precise":"public"},"pathComponents":["Page","page"],"accessLevel":"public"},
            {"identifier":{"precise":"open"},"pathComponents":["Page","items"],"accessLevel":"open"}]}
            """
        let empty = #"{"version":1,"module":"SDK","client":"Client","apis":{},"fields":{}}"#
        let catalog = try SelectionCatalog(
            manifest: Data(empty.utf8), graphs: [try graphData(runtime, publicMembers: false)])
        XCTAssertEqual(catalog.metadata, ["public"])
        XCTAssertEqual(catalog.transparent, ["open"])
    }

    func testPageMetadataUsesOnlyRuntimePropertySymbols() throws {
        let manifest = #"{"version":1,"module":"SDK","client":"Client","apis":{},"fields":{}}"#
        let runtime = #"""
            {"module":{"name":"LuxoClient"},"symbols":[
            {"identifier":{"precise":"runtime.items"},"pathComponents":["Page","items"]},
            {"identifier":{"precise":"runtime.total"},"pathComponents":["Page","total"]},
            {"identifier":{"precise":"runtime.page"},"pathComponents":["Page","page"]},
            {"identifier":{"precise":"runtime.pageSize"},"pathComponents":["Page","pageSize"]},
            {"identifier":{"precise":"other.total"},"pathComponents":["Other","total"]}]}
            """#
        let business = #"""
            {"module":{"name":"Business"},"symbols":[
            {"identifier":{"precise":"business.total"},"pathComponents":["Page","total"]}]}
            """#
        let otherRuntime = #"""
            {"module":{"name":"LuxoClient"},"symbols":[
            {"identifier":{"precise":"short"},"pathComponents":["Page"]},
            {"identifier":{"precise":"nested"},"pathComponents":["Page","total","nested"]},
            {"identifier":{"precise":"method"},"pathComponents":["Page","total()"]},
            {"identifier":{"precise":"runtime.value"},"pathComponents":["Selected","requireValue()"]}]}
            """#
        let catalog = try SelectionCatalog(
            manifest: Data(manifest.utf8),
            graphs: [try graphData(runtime), try graphData(business), try graphData(otherRuntime)])
        XCTAssertEqual(catalog.transparent, ["runtime.items", "runtime.value"])
        XCTAssertEqual(catalog.metadata, ["runtime.total", "runtime.page", "runtime.pageSize"])
    }

    func testResolvesOnlyManifestSymbolsAndRejectsMissingEntries() throws {
        let manifest =
            #"{"version":1,"module":"SDK","client":"Client","apis":{"user":{}},"fields":{"User":{"id":false}}}"#
        let graph =
            #"{"module":{"name":"SDK"},"symbols":[{"identifier":{"precise":"exact.api"},"pathComponents":["Client","user(select:)"]},{"identifier":{"precise":"other.api"},"pathComponents":["Other","user(select:)"]},{"identifier":{"precise":"exact.field"},"pathComponents":["User","id"]}]}"#
        let catalog = try SelectionCatalog(
            manifest: Data(manifest.utf8), graphs: [try graphData(graph)])
        XCTAssertEqual(Set(catalog.apis.keys), ["exact.api"])
        XCTAssertEqual(catalog.fields["exact.field"]?.name, "id")
        XCTAssertThrowsError(try SelectionCatalog(manifest: Data(manifest.utf8), graphs: []))
        XCTAssertThrowsError(
            try SelectionCatalog(
                manifest: Data(
                    manifest.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8),
                graphs: [try graphData(graph)]))
    }

    private func graphData(_ source: String, publicMembers: Bool = true) throws -> Data {
        var graph = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        var symbols = try XCTUnwrap(graph["symbols"] as? [[String: Any]])
        symbols = symbols.map { symbol in
            var symbol = symbol
            if publicMembers && symbol["accessLevel"] == nil { symbol["accessLevel"] = "public" }
            return symbol
        }
        // Legacy fixtures declare public owners explicitly here; production never guesses them from names.
        var relationships = graph["relationships"] as? [[String: Any]] ?? []
        let members = symbols
        for member in members {
            guard let path = member["pathComponents"] as? [String], let name = path.first,
                let identifier = member["identifier"] as? [String: String], let id = identifier["precise"]
            else { continue }
            let ownerID = "fixture-owner:" + name
            if !symbols.contains(where: { ($0["identifier"] as? [String: String])?["precise"] == ownerID }
            ) {
                symbols.append([
                    "identifier": ["precise": ownerID], "pathComponents": [name], "accessLevel": "public",
                    "kind": ["identifier": "swift.struct"],
                ])
            }
            relationships.append(["kind": "memberOf", "source": id, "target": ownerID])
        }
        graph["symbols"] = symbols
        graph["relationships"] = relationships
        return try JSONSerialization.data(withJSONObject: graph)
    }

    private func verifyOwnerRelationships(_ data: Data, manifest: Data) throws {
        let graph = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let symbols = try XCTUnwrap(graph["symbols"] as? [[String: Any]])
        let relationships = try XCTUnwrap(graph["relationships"] as? [[String: Any]])
        let ownerIndex = try XCTUnwrap(
            symbols.firstIndex { ($0["pathComponents"] as? [String]) == ["PublicRecord"] })
        let field = try XCTUnwrap(
            symbols.first { ($0["pathComponents"] as? [String]) == ["PublicRecord", "id"] })
        let id = try XCTUnwrap((field["identifier"] as? [String: String])?["precise"])
        let client = try XCTUnwrap(
            symbols.first { ($0["pathComponents"] as? [String]) == ["PublicClient"] })
        let target = try XCTUnwrap((client["identifier"] as? [String: String])?["precise"])
        let duplicate = try SelectionCatalog(manifest: manifest, graphs: [data, data])
        XCTAssertEqual(duplicate.fields.count, 1)
        for key in ["accessLevel", "kind"] {
            var changed = graph
            var values = symbols
            values[ownerIndex].removeValue(forKey: key)
            changed["symbols"] = values
            let missing = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try SelectionCatalog(manifest: manifest, graphs: [missing]))
            XCTAssertThrowsError(try SelectionCatalog(manifest: manifest, graphs: [data, missing]))
        }
        let conflict: [String: Any] = ["kind": "memberOf", "source": id, "target": target]
        let same = try XCTUnwrap(
            relationships.first {
                ($0["source"] as? String) == id && ($0["kind"] as? String) == "memberOf"
            })
        for values in [relationships + [conflict, same], [conflict] + relationships] {
            var changed = graph
            changed["relationships"] = values
            XCTAssertThrowsError(
                try SelectionCatalog(
                    manifest: manifest, graphs: [JSONSerialization.data(withJSONObject: changed)]))
        }
        var missing = graph
        missing.removeValue(forKey: "relationships")
        XCTAssertThrowsError(
            try SelectionCatalog(
                manifest: manifest, graphs: [JSONSerialization.data(withJSONObject: missing)]))
    }

    private func ownerGraph(_ module: String, directory: URL, label: String, source: String) throws
        -> Data
    {
        let output = directory.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let file = output.appendingPathComponent("Owners.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let process = SelectionCompilerProcess(workspace: directory, scratch: output)
        let sdk = String(
            decoding: try process.run("/usr/bin/xcrun", ["--show-sdk-path"]), as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = [
            "-sdk", sdk, "-target", "arm64-apple-macos13.0", "-swift-version", "6",
            "-module-cache-path", directory.appendingPathComponent("cache").path,
        ]
        _ = try process.run(
            "swiftc",
            options + [
                "-emit-module", "-module-name", module, file.path, "-emit-module-path",
                output.appendingPathComponent(module + ".swiftmodule").path,
            ])
        let tool = String(
            decoding: try process.run("/usr/bin/xcrun", ["--find", "swift-symbolgraph-extract"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try process.run(
            tool,
            options + [
                "-minimum-access-level", "private", "-module-name", module, "-I", output.path,
                "-output-dir", output.path,
            ])
        return try Data(contentsOf: output.appendingPathComponent(module + ".symbols.json"))
    }
}
