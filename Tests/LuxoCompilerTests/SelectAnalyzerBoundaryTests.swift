import Foundation
import XCTest
@testable import LuxoCompiler

final class SelectAnalyzerBoundaryTests: XCTestCase {
    func testAPIMergedHintsAreNotAPublicCompilerEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scratch = root.appendingPathComponent(".tmp/analyzer-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Consumer.swift")
        try "import LuxoCompiler\nlet analyzer = SelectAnalyzer()\n".write(
            to: source, atomically: true, encoding: .utf8)
        let process = SelectionCompilerProcess(workspace: root, scratch: scratch)
        do {
            _ = try process.run(
                "swiftc",
                [
                    "-typecheck", "-I", root.appendingPathComponent(".build/debug/Modules").path,
                    "-I",
                    root.appendingPathComponent(".build/checkouts/swift-syntax/Sources/_SwiftSyntaxCShims/include")
                        .path,
                    source.path,
                ])
            XCTFail("API-wide merged hints must not remain a public compiler entry")
        } catch SelectionCompilerProcess.Failure.failed(_, _, let diagnostic) {
            XCTAssertTrue(diagnostic.contains("cannot find 'SelectAnalyzer' in scope"), diagnostic)
        }
    }
}
