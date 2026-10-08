import SwiftParser
import SwiftSyntax

/// Applies per-call projections to an in-memory source snapshot, never the user's file.
public enum SelectionSourceRewriter {
    public enum Failure: Error, Equatable {
        case invalidSource
        case sourceMismatch
        case unmatchedCall(Int)
        case unsupportedCall(Int)
        case missingSelection(Int)
        case invalidFieldPath
    }

    public static func rewrite(
        source: String, index: SemanticCallIndex, selections: [Int: [[String]]]
    ) throws -> String {
        guard index.source == source else { throw Failure.sourceMismatch }
        let tree = Parser.parse(source: source)
        guard !tree.hasError else { throw Failure.invalidSource }
        let visitor = CallVisitor(index: index, selections: selections)
        visitor.walk(tree)
        if let failure = visitor.failure { throw failure }
        for call in index.calls where !visitor.seen.contains(call.startOffset) {
            throw Failure.unmatchedCall(call.startOffset)
        }
        var bytes = Array(source.utf8)
        for edit in visitor.edits.sorted(by: { $0.offset > $1.offset }) {
            bytes.insert(contentsOf: edit.text.utf8, at: edit.offset)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    fileprivate static func render(_ paths: [[String]]) throws -> String {
        let root = FieldNode.root()
        for path in paths {
            guard !path.isEmpty, path.count <= 64 else { throw Failure.invalidFieldPath }
            var node = root
            for name in path {
                let bytes = Array(name.utf8)
                guard let first = bytes.first, isLetter(first),
                    bytes.allSatisfy({ isLetter($0) || (48...57).contains($0) })
                else { throw Failure.invalidFieldPath }
                node = node.addChild(name)
            }
        }
        return root.toSelectString()
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

private final class CallVisitor: SyntaxVisitor {
    typealias Failure = SelectionSourceRewriter.Failure
    let calls: [Int: SemanticCallIndex.Call]
    let selections: [Int: [[String]]]
    var seen: Set<Int> = []
    var edits: [(offset: Int, text: String)] = []
    var failure: Failure?

    init(index: SemanticCallIndex, selections: [Int: [[String]]]) {
        calls = Dictionary(uniqueKeysWithValues: index.calls.map { ($0.startOffset, $0) })
        self.selections = selections
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard let call = calls[start], failure == nil,
            node.lastToken(viewMode: .sourceAccurate)?.positionAfterSkippingLeadingTrivia.utf8Offset == call.endOffset
        else { return .visitChildren }
        do {
            seen.insert(start)
            if call.hasExplicitSelection { return .visitChildren }
            guard !node.arguments.contains(where: { $0.label?.text == "select" }),
                node.rightParen != nil || (node.arguments.isEmpty && node.trailingClosure != nil)
            else { throw Failure.unsupportedCall(start) }
            guard let paths = selections[start], !paths.isEmpty else { throw Failure.missingSelection(start) }
            let selection = try SelectionSourceRewriter.render(paths)
            edits.append(insertion(node, call: call, selection: selection))
        } catch let error as Failure {
            failure = error
        } catch {
            failure = .unsupportedCall(start)
        }
        return .visitChildren
    }

    private func insertion(
        _ node: FunctionCallExprSyntax, call: SemanticCallIndex.Call, selection: String
    ) -> (offset: Int, text: String) {
        let value = "select: \"\(selection)\""
        guard let rightParen = node.rightParen else {
            return (node.calledExpression.endPositionBeforeTrailingTrivia.utf8Offset, "(" + value + ")")
        }
        if let next = node.arguments.first(where: { argument in
            argument.label.map { call.labelsAfterSelection.contains($0.text) } ?? false
        }) {
            return (next.positionAfterSkippingLeadingTrivia.utf8Offset, value + ", ")
        }
        let prefix = node.arguments.isEmpty || node.arguments.last?.trailingComma != nil ? "" : ", "
        return (rightParen.positionAfterSkippingLeadingTrivia.utf8Offset, prefix + value)
    }
}
