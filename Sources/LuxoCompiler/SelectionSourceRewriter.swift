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
        source: String, index: SemanticCallIndex, selections: [Int: [[String]]],
        planFactories: [String: String] = [:]
    ) throws -> String {
        guard index.source == source else { throw Failure.sourceMismatch }
        let tree = Parser.parse(source: source)
        guard !tree.hasError else { throw Failure.invalidSource }
        let visitor = CallVisitor(index: index, selections: selections, factories: planFactories, source: source)
        visitor.walk(tree)
        if let failure = visitor.failure { throw failure }
        for call in index.calls where !visitor.seen.contains(call.startOffset) {
            throw Failure.unmatchedCall(call.startOffset)
        }
        var bytes = Array(source.utf8)
        for edit in visitor.edits.sorted(by: { $0.offset > $1.offset }) {
            bytes.insert(contentsOf: edit.text.utf8, at: edit.offset)
        }
        return String(decoding: bytes, as: UTF8.self) + visitor.declarations
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
    let factories: [String: String]
    let source: String
    var declarations = ""

    init(index: SemanticCallIndex, selections: [Int: [[String]]], factories: [String: String], source: String) {
        self.factories = factories
        self.source = source
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
            var value = "select: \"\(selection)\""
            if let factory = factories[call.symbol] {
                guard call.labelsAfterSelection.first == "selectionPlan" else {
                    throw Failure.unsupportedCall(start)
                }
                var name = "_luxoSelection\(start)"
                while source.contains(name) { name += "_" }
                let declaration = "private let \(name) = Swift.Result { try \(factory)(\"\(selection)\") }\n"
                declarations += "\n" + scopedDeclaration(declaration, node: Syntax(node))
                value += ", selectionPlan: try \(name).get()"
            }
            edits.append(insertion(node, call: call, value: value))
        } catch let error as Failure {
            failure = error
        } catch {
            failure = .unsupportedCall(start)
        }
        return .visitChildren
    }

    private func scopedDeclaration(_ declaration: String, node: Syntax) -> String {
        var result = declaration
        var ancestor: Syntax? = node
        while let current = ancestor {
            if let clause = current.as(IfConfigClauseSyntax.self),
                let directive = clause.parent?.parent?.as(IfConfigDeclSyntax.self)
            {
                var wrapped = ""
                for branch in directive.clauses {
                    wrapped += branch.poundKeyword.text
                    if let condition = branch.condition { wrapped += " " + condition.trimmedDescription }
                    wrapped += "\n"
                    if branch.id == clause.id { break }
                }
                result = wrapped + result + "#endif\n"
            }
            ancestor = current.parent
        }
        return result
    }

    private func insertion(
        _ node: FunctionCallExprSyntax, call: SemanticCallIndex.Call, value: String
    ) -> (offset: Int, text: String) {
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
