import Foundation
import XCTest
@testable import LuxoClient
@testable import LuxoCompiler

final class GeneratedQueryBuildTests: XCTestCase {
    func testGeneratedQueriesCompileAndPreserveInt64() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/generated-query-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let process = SelectionCompilerProcess(workspace: root, scratch: directory)
        let objects = try fm.contentsOfDirectory(
            at: root.appendingPathComponent(".build/debug/LuxoClient.build"), includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".swift.o") }.map(\.path)
        _ = try process.run(
            "swiftc",
            ["-emit-library", "-profile-generate"] + objects
                + ["-o", directory.appendingPathComponent("libLuxoClient.dylib").path])
        let schema = try JSONDecoder().decode(
            LuxoSchema.self,
            from: Data(
                #"{"models":{},"enums":{"State":{"name":"State","values":["OPEN"]}},"apis":{"listUsers":{"id":1,"name":"listUsers","module":"user","paginated":true,"query":{"filters":[{"field":"id","type":"Int","operators":["eq"]},{"field":"state","type":"State","operators":["eq"]}],"sorters":["id"]}}}}"#
                    .utf8))
        let query = directory.appendingPathComponent("Queries.swift")
        try SwiftQueryCodegen.generate(schema).write(to: query, atomically: true, encoding: .utf8)
        let models = directory.appendingPathComponent("Models.swift")
        let generator = try LuxoCodegen(endpoint: "http://localhost", introspectionKey: "test")
        try generator.generateModels(schema).write(to: models, atomically: true, encoding: .utf8)
        let main = directory.appendingPathComponent("main.swift")
        try """
        import LuxoClient
        let value: Int64 = 9_007_199_254_740_993
        let filter = LuxoQuery_listUsers.id_eq(value)
        guard case .int64(let stored) = filter.value, stored == value else { fatalError("precision") }
        precondition(filter.field == "id" && filter.op == "eq")
        precondition(LuxoQuery_listUsers.id_desc().order == "desc")
        guard case .string(let state) = LuxoQuery_listUsers.state_eq(State(rawValue: "OPEN")).value,
              state == "OPEN" else { fatalError("enum") }
        print(stored)
        """.write(to: main, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("app")
        let args = [
            "-swift-version", "6", "-I", root.appendingPathComponent(".build/debug/Modules").path,
            "-L", directory.path, "-l", "LuxoClient", "-o", output.path, query.path, models.path, main.path,
        ]
        _ = try process.run("swiftc", args)
        XCTAssertEqual(String(decoding: try process.run(output.path, []), as: UTF8.self), "9007199254740993\n")
        try "let value = LuxoQuery_listUsers.id_eq(\"42\")".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try process.run("swiftc", args))
    }
}
