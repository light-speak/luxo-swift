import Foundation
import XCTest
@testable import LuxoCompiler

final class SemanticCallIndexTests: XCTestCase {
    func testUnsupportedReferencesAndMalformedArgumentsAreRejected() throws {
        let reference = #"{"_kind":"declref_expr","decl":{"decl_usr":"sdk.getUser"}}"#
        let expressions = [
            reference,
            #"{"_kind":"call_expr","fn":{"_kind":"unknown_wrapper","sub_expr":\#(reference)}}"#,
            #"{"_kind":"call_expr","range":{"start":0,"end":10},"fn":\#(reference)}"#,
            #"{"_kind":"call_expr","range":{"start":0,"end":10},"fn":\#(reference),"args":{"args":[{"label":"select"}]}}"#,
        ]
        for expression in expressions {
            let source =
                #"{"_kind":"source_file","filename":"Probe.swift","compiler_version":{"full":"test-swift"},"items":[\#(expression)]}"#
            XCTAssertThrowsError(
                try SemanticCallIndex(
                    data: Data(source.utf8), compilerVersion: "test-swift", apiSymbols: ["sdk.getUser"]),
                expression)
        }
    }

    func testRealCompilerCallOffsetsAndSameNamedMethodIsolation() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/semantic-index-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Probe.swift")
        let source = """
            // Verify UTF-8 byte offsets after non-ASCII text: 中文.
            struct User { let id: Int64; let name: String }
            struct LuxoClient {
                func getUser(select: String? = nil) -> User { User(id: 1, name: "Ada") }
            }
            struct Other { func getUser() -> User { User(id: 2, name: "Other") } }
            func load(client: LuxoClient) {
                let first = client.getUser()
                print(first.id)
                let second = client.getUser(select: "name")
                print(second.name)
                print(Other().getUser().name)
            }
            """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let versionData = try compiler(["--version"], directory: directory)
        let version = try XCTUnwrap(String(decoding: versionData, as: UTF8.self).split(separator: "\n").first)
        let data = try compiler(
            ["-dump-ast", "-dump-ast-format", "json", "-dump-usr", "-module-name", "Probe", file.path],
            directory: directory)
        let symbol = "s:5Probe10LuxoClientV7getUser6selectAA0E0VSSSg_tF"
        let index = try SemanticCallIndex(
            data: data, compilerVersion: String(version), apiSymbols: [symbol], source: source)
        XCTAssertEqual(index.calls.count, 2)
        XCTAssertEqual(index.calls.map(\.hasExplicitSelection), [false, true])
        let selections = try ProjectionInference.infer(
            data: data, apis: [symbol: .init()],
            fields: [
                "s:5Probe4UserV2ids5Int64Vvp": .init(name: "id"),
                "s:5Probe4UserV4nameSSvp": .init(name: "name"),
            ])
        XCTAssertEqual(selections[index.calls[0].startOffset], [["id"]])
        let rewritten = try SelectionSourceRewriter.rewrite(
            source: source, index: index, selections: selections)
        XCTAssertTrue(rewritten.contains("let first = client.getUser(select: \"id\")"))
        XCTAssertTrue(rewritten.contains("let second = client.getUser(select: \"name\")"))
        XCTAssertTrue(rewritten.contains("Other().getUser()"))
        let rewrittenFile = directory.appendingPathComponent("Rewritten.swift")
        try rewritten.write(to: rewrittenFile, atomically: true, encoding: .utf8)
        _ = try compiler(["-typecheck", rewrittenFile.path], directory: directory)
        for call in index.calls {
            let bytes = Array(source.utf8)[call.startOffset...call.endOffset]
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasPrefix("client.getUser("))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    private func compiler(_ arguments: [String], directory: URL) throws -> Data {
        let output = directory.appendingPathComponent("compiler-output")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        let finished = expectation(description: "swiftc completed")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        wait(for: [finished], timeout: 30)
        guard !process.isRunning else {
            throw NSError(
                domain: "SemanticCallIndexTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "swiftc timed out"])
        }
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
    }

    func testResolvedSymbolsSeparateSameNamedMethodsAndDeduplicateInitializers() throws {
        let call =
            #"{"_kind":"call_expr","range":{"start":10,"end":28},"fn":{"_kind":"dot_syntax_call_expr","fn":{"_kind":"declref_expr","decl":{"decl_usr":"sdk.getUser"}}},"args":{"args":[{"label":"select","expr":{"_kind":"default_argument_expr"}}]}}"#
        let other = call.replacingOccurrences(of: "sdk.getUser", with: "other.getUser")
        let source = """
            {"_kind":"source_file","filename":"Probe.swift","compiler_version":{"full":"test-swift"},
             "items":[{"original_init":\(call),"processed_init":\(call)},\(other)]}
            """
        let index = try SemanticCallIndex(
            data: Data(source.utf8), compilerVersion: "test-swift", apiSymbols: ["sdk.getUser"])
        XCTAssertEqual(index.calls.count, 1)
        XCTAssertEqual(index.calls.first?.startOffset, 10)
        XCTAssertEqual(index.calls.first?.endOffset, 28)
        XCTAssertEqual(index.calls.first?.hasExplicitSelection, false)
    }

    func testExplicitSelectionAndVersionMismatch() throws {
        let source =
            #"{"_kind":"source_file","filename":"Probe.swift","compiler_version":{"full":"test-swift"},"items":[{"_kind":"call_expr","range":{"start":0,"end":9},"fn":{"_kind":"declref_expr","decl":{"decl_usr":"sdk.getUser"}},"args":{"args":[{"label":"select","expr":{"_kind":"string_literal_expr"}}]}}]}"#
        let data = Data(source.utf8)
        XCTAssertTrue(
            try XCTUnwrap(
                SemanticCallIndex(data: data, compilerVersion: "test-swift", apiSymbols: ["sdk.getUser"]).calls.first
            ).hasExplicitSelection)
        XCTAssertThrowsError(
            try SemanticCallIndex(data: data, compilerVersion: "other-swift", apiSymbols: ["sdk.getUser"]))
        XCTAssertThrowsError(
            try SemanticCallIndex(data: Data("{}".utf8), compilerVersion: "test-swift", apiSymbols: []))
    }
}
