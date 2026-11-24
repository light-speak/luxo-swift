import Foundation
import XCTest
@testable import LuxoCompiler

final class SelectionXcodeInvocationTests: XCTestCase {
    func testLiteralCommandWordsPreserveQuotedPathsWithoutEvaluation() throws {
        XCTAssertEqual(
            try SelectionXcodeInvocation.words(#"swiftc -I '/a b' /c\ d.swift -D NAME "$(touch nope)""#),
            ["swiftc", "-I", "/a b", "/c d.swift", "-D", "NAME", "$(touch nope)"])
        XCTAssertThrowsError(try SelectionXcodeInvocation.words("'unfinished"))
        XCTAssertThrowsError(try SelectionXcodeInvocation.words("unfinished\\"))
    }

    func testAnalysisPreservesSemanticsAndRejectsUnknownFlags() throws {
        let arguments = [
            "-module-name", "App", "-target", "arm64-apple-macos13.0", "-sdk", "/sdk",
            "-D", "FEATURE", "-I", "/modules", "-Xcc", "-I/headers", "-parse-as-library",
            "-c", "-j16", "-incremental", "-output-file-map", "/output.json",
            "-Xfrontend", "-serialize-debugging-options", "/workspace/App.swift",
        ]
        let filtered = try SelectionXcodeInvocation.analysis(arguments, workspace: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(
            filtered,
            [
                "-module-name", "App", "-target", "arm64-apple-macos13.0", "-sdk", "/sdk",
                "-D", "FEATURE", "-I", "/modules", "-Xcc", "-I/headers", "-parse-as-library", "/workspace/App.swift",
            ])
        XCTAssertThrowsError(
            try SelectionXcodeInvocation.analysis(["-unknown"], workspace: URL(fileURLWithPath: "/workspace")))
        XCTAssertThrowsError(
            try SelectionXcodeInvocation.analysis(["-sdk"], workspace: URL(fileURLWithPath: "/workspace")))
        XCTAssertThrowsError(
            try SelectionXcodeInvocation.analysis(
                ["-vfsoverlay", "/old"], workspace: URL(fileURLWithPath: "/workspace")))
    }

    func testCommandSelectionRejectsMissingAmbiguousAndWrongTargets() throws {
        let workspace = URL(fileURLWithPath: "/workspace")
        let command =
            "builtin-SwiftDriver -- /tools/swiftc -module-name App -target arm64-apple-macos13.0 /workspace/App.swift"
        XCTAssertEqual(
            try SelectionXcodeInvocation.extract(
                command, module: "App", target: "arm64-apple-macos13.0", workspace: workspace),
            ["-module-name", "App", "-target", "arm64-apple-macos13.0", "/workspace/App.swift"])
        for log in [
            "", command + "\n" + command, command.replacingOccurrences(of: "App -target", with: "Other -target"),
            command.replacingOccurrences(of: "arm64", with: "x86_64"),
        ] {
            XCTAssertThrowsError(
                try SelectionXcodeInvocation.extract(
                    log, module: "App", target: "arm64-apple-macos13.0", workspace: workspace))
        }
    }

    func testResponseFileExpandsOnlySourcePaths() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = root.appendingPathComponent(".tmp/xcode-arguments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("App.SwiftFileList")
        try "\"\(workspace.path)/App Space.swift\"\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try SelectionXcodeInvocation.analysis(["@" + file.path], workspace: workspace),
            [workspace.appendingPathComponent("App Space.swift").path])
        for content in ["", "@nested", "-sdk /other", "invalid.txt"] {
            try content.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try SelectionXcodeInvocation.analysis(["@" + file.path], workspace: workspace))
        }
        XCTAssertThrowsError(try SelectionXcodeInvocation.analysis(["@/outside.SwiftFileList"], workspace: workspace))
        XCTAssertThrowsError(
            try SelectionXcodeInvocation.analysis(["-working-directory", "/other"], workspace: workspace))
    }
}
