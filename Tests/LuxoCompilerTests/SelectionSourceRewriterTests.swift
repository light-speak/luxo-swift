import Foundation
import XCTest
@testable import LuxoCompiler

final class SelectionSourceRewriterTests: XCTestCase {
    func testPerCallSelectionAndArgumentOrder() throws {
        let source = "let a = client.users(limit: 10); let b = client.users(limit: 20)"
        let first = source.utf8.distance(from: source.utf8.startIndex, to: source.range(of: "client")!.lowerBound)
        let second = source.utf8.distance(
            from: source.utf8.startIndex, to: source.range(of: "client", options: .backwards)!.lowerBound)
        let index = try makeIndex(source: source, starts: [first, second], following: ["limit"])
        let output = try SelectionSourceRewriter.rewrite(
            source: source, index: index,
            selections: [first: [["id"]], second: [["owner", "name"], ["name"]]])
        XCTAssertEqual(
            output,
            "let a = client.users(select: \"id\", limit: 10); let b = client.users(select: \"name,owner{name}\", limit: 20)"
        )
    }

    func testHoistsSeparatePlansAndPreservesConditionalScope() throws {
        let source = "#if os(macOS)\nlet _luxoSelection40 = 0\nclient.users()\n#else\nclient.users()\n#endif\n// tail"
        let starts = source.ranges(of: "client.users").map {
            source.utf8.distance(from: source.startIndex, to: $0.lowerBound)
        }
        let index = try makeIndex(source: source, starts: starts, following: ["selectionPlan"])
        let output = try SelectionSourceRewriter.rewrite(
            source: source, index: index, selections: Dictionary(uniqueKeysWithValues: starts.map { ($0, [["id"]]) }),
            planFactories: ["api": "SDK.Client.prepareSelection_users"])
        XCTAssertEqual(
            output.components(separatedBy: "Swift.Result { try SDK.Client.prepareSelection_users").count - 1, 2)
        XCTAssertTrue(output.contains("selectionPlan: try _luxoSelection"))
        XCTAssertTrue(output.contains("\n#if os(macOS)\nprivate let"))
        XCTAssertTrue(output.contains("\n#if os(macOS)\n#else\nprivate let"))
        XCTAssertFalse(output.contains("try!"))
    }

    func testPlanNameAvoidsSourceCollisionAndTrailingComment() throws {
        let source = "client.users() // _luxoSelection0"
        let index = try makeIndex(source: source, starts: [0], following: ["selectionPlan"])
        let output = try SelectionSourceRewriter.rewrite(
            source: source, index: index, selections: [0: [["id"]]],
            planFactories: ["api": "SDK.Client.prepareSelection_users"])
        XCTAssertTrue(output.contains("selectionPlan: try _luxoSelection0_.get()"))
        XCTAssertTrue(output.contains("// _luxoSelection0\nprivate let _luxoSelection0_ = Swift.Result"))
    }

    func testRejectsMissingOrUnsafeSelection() throws {
        let source = "client.users()"
        let index = try makeIndex(source: source, starts: [0], following: [])
        for selections: [Int: [[String]]] in [[:], [0: []], [0: [["name\"bad"]]], [0: [[]]]] {
            XCTAssertThrowsError(
                try SelectionSourceRewriter.rewrite(source: source, index: index, selections: selections))
        }
        XCTAssertThrowsError(
            try SelectionSourceRewriter.rewrite(source: "other()", index: index, selections: [0: [["id"]]]))
        XCTAssertThrowsError(
            try SelectionSourceRewriter.rewrite(source: "otherx.users()", index: index, selections: [0: [["id"]]]))
    }

    func testPreservesCommentsAndExistingArgument() throws {
        let source = "client.users(id: 1 /* keep */)"
        let index = try makeIndex(source: source, starts: [0], following: [])
        XCTAssertEqual(
            try SelectionSourceRewriter.rewrite(source: source, index: index, selections: [0: [["id"]]]),
            "client.users(id: 1 /* keep */, select: \"id\")")
    }

    private func makeIndex(source: String, starts: [Int], following: [String]) throws -> SemanticCallIndex {
        let bytes = Array(source.utf8)
        let calls = starts.map { start in
            let end = bytes[start...].firstIndex(of: 41)!
            let arguments =
                ([#"{"label":"select","expr":{"_kind":"default_argument_expr"}}"#]
                + following.map {
                    #"{"label":"\#($0)","expr":{"_kind":"\#($0 == "selectionPlan" ? "default_argument_expr" : "integer_literal_expr")"}}"#
                }).joined(
                    separator: ",")
            return
                #"{"_kind":"call_expr","range":{"start":\#(start),"end":\#(end)},"fn":{"_kind":"declref_expr","decl":{"decl_usr":"api"}},"args":{"args":[\#(arguments)]}}"#
        }.joined(separator: ",")
        let json =
            #"{"_kind":"source_file","filename":"Test.swift","compiler_version":{"full":"test"},"items":[\#(calls)]}"#
        return try SemanticCallIndex(
            data: Data(json.utf8), compilerVersion: "test", apiSymbols: ["api"], source: source)
    }
}
