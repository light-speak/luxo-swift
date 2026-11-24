import Foundation
import XCTest
@testable import LuxoCompiler

final class EncoderTypeBoundaryTests: XCTestCase {
    func testLegacyDynamicFieldEntryPointsAreUnavailable() throws {
        try assertRejected(
            """
            var encoder = Encoder()
            try encoder.writeField(1, value: 7, type: "Int")
            try encoder.writeFieldList(1, values: [7], type: "Int")
            """, lines: 4...5,
            diagnostics: ["has no member 'writeField'", "has no member 'writeFieldList'"])
    }

    func testTypedWritersRejectFoundationNumberCoercion() throws {
        let cases: [(String, String)] = [
            ("writeSvarint", "NSNumber(value: true)"),
            ("writeSvarint", "NSNumber(value: false)"),
            ("writeFixed64", "NSNumber(value: true)"),
            ("writeBool", "NSNumber(value: Int64(1))"),
            ("writeBool", "NSNumber(value: 1.0)"),
            ("writeSvarint", "NSNumber(value: 1.0)"),
            ("writeSvarint", "NSNumber(value: -0.0)"),
        ]
        let scalar = cases.map { "try encoder.\($0.0)(\($0.1))" }
        let lists = cases.map { "for value in [\($0.1)] { try encoder.\($0.0)(value) }" }
        try assertRejected(
            (["var encoder = Encoder()"] + scalar + lists).joined(separator: "\n"),
            lines: 4...17, diagnostics: ["cannot convert value of type 'NSNumber'"])
    }

    func testTypedWritersRejectWrongValueKinds() throws {
        let invalid = [
            "encoder.writeSvarint(\"not-an-int\")",
            "try encoder.writeFixed64(\"not-a-float\")",
            "encoder.writeBool(0)",
            "encoder.writeUUID(\"not-a-uuid\")",
            "encoder.writeString(0)",
            "try encoder.writeDateTime(Int64(120))",
            "encoder.writeBytes(\"not-data\")",
            "try encoder.writeJSON(Date())",
            "try encoder.writeJSON([\"ok\": true])",
            "let values: [Int64] = [1, \"bad\"]",
        ]
        try assertRejected(
            (["var encoder = Encoder()"] + invalid).joined(separator: "\n"),
            lines: 4...13, diagnostics: [])
    }

    private func assertRejected(
        _ body: String, lines: ClosedRange<Int>, diagnostics: [String]
    ) throws {
        try withCompiler { process, modules, source in
            try source.write("var encoder = Encoder(); encoder.writeBool(true)")
            _ = try process.run("swiftc", source.arguments(modules))
            try source.write(body)
            do {
                _ = try process.run("swiftc", source.arguments(modules))
                XCTFail("invalid encoder input must not compile")
            } catch SelectionCompilerProcess.Failure.failed(_, _, let diagnostic) {
                for line in lines {
                    XCTAssertTrue(
                        diagnostic.components(separatedBy: "\n").contains {
                            $0.contains("Boundary.swift:\(line):") && $0.contains(": error:")
                        }, diagnostic)
                }
                for message in diagnostics {
                    XCTAssertTrue(diagnostic.contains(message), diagnostic)
                }
            }
        }
    }

    private struct Source {
        let file: URL

        func write(_ body: String) throws {
            try ("import Foundation\nimport LuxoClient\n" + body).write(
                to: file, atomically: true, encoding: .utf8)
        }

        func arguments(_ modules: URL) -> [String] {
            ["-typecheck", "-swift-version", "6", "-I", modules.path, file.path]
        }
    }

    private func withCompiler(
        _ body: (SelectionCompilerProcess, URL, Source) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temporary = root.appendingPathComponent(".tmp").resolvingSymlinksInPath()
        let scratch = temporary.appendingPathComponent("encoder-boundary-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            if scratch.resolvingSymlinksInPath().path.hasPrefix(temporary.path + "/") {
                try? manager.removeItem(at: scratch)
            }
        }
        let modules = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Modules")
        XCTAssertTrue(manager.fileExists(atPath: modules.appendingPathComponent("LuxoClient.swiftmodule").path))
        let process = SelectionCompilerProcess(workspace: root, scratch: scratch)
        try body(process, modules, Source(file: scratch.appendingPathComponent("Boundary.swift")))
    }
}
