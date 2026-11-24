import Foundation

/// Compiler-resolved call identities. This is build tooling, not SDK runtime metadata.
public struct SemanticCallIndex: Sendable {
    public struct Call: Equatable, Sendable {
        public let symbol: String
        public let startOffset: Int
        public let endOffset: Int
        public let hasExplicitSelection: Bool
        public let labelsAfterSelection: [String]
    }

    public enum Failure: Error, Equatable {
        case incompatibleCompiler
        case invalidAST
        case invalidCallRange
        case conflictingCall
        case unsupportedAPIReference
    }

    public let filename: String
    public let calls: [Call]
    public let source: String?

    public init(data: Data, compilerVersion: String, apiSymbols: Set<String>, source: String? = nil) throws {
        let root = try JSONDecoder().decode(CompilerASTValue.self, from: data)
        try self.init(root: root, compilerVersion: compilerVersion, apiSymbols: apiSymbols, source: source)
    }

    init(root: CompilerASTValue, compilerVersion: String, apiSymbols: Set<String>, source: String?) throws {
        guard root["_kind"]?.text == "source_file", let file = root["filename"]?.text else {
            throw Failure.invalidAST
        }
        guard root["compiler_version"]?["full"]?.text == compilerVersion else {
            throw Failure.incompatibleCompiler
        }
        var indexed: [Int: Call] = [:]
        try Self.collect(root, apiSymbols: apiSymbols, into: &indexed)
        filename = file
        calls = indexed.values.sorted { $0.startOffset < $1.startOffset }
        self.source = source
    }

    private static func collect(
        _ node: CompilerASTValue, apiSymbols: Set<String>, into calls: inout [Int: Call]
    ) throws {
        if node["_kind"]?.text == "call_expr",
            let symbol = callee(node["fn"]), apiSymbols.contains(symbol)
        {
            let call = try readCall(node, symbol: symbol)
            if let old = calls[call.startOffset], old != call { throw Failure.conflictingCall }
            calls[call.startOffset] = call
            try collectCallee(node["fn"], apiSymbols: apiSymbols, into: &calls)
            for (key, child) in node.members where key != "fn" {
                try collect(child, apiSymbols: apiSymbols, into: &calls)
            }
            return
        }
        if node["_kind"]?.text == "declref_expr",
            let symbol = node["decl"]?["decl_usr"]?.text, apiSymbols.contains(symbol)
        {
            throw Failure.unsupportedAPIReference
        }
        for child in node.children { try collect(child, apiSymbols: apiSymbols, into: &calls) }
    }

    private static func readCall(_ node: CompilerASTValue, symbol: String) throws -> Call {
        guard let start = node["range"]?["start"]?.integer,
            let end = node["range"]?["end"]?.integer, start >= 0, end >= start
        else { throw Failure.invalidCallRange }
        guard case .array(let arguments) = node["args"]?["args"] else { throw Failure.invalidAST }
        let selections = arguments.filter { $0["label"]?.text == "select" }
        guard selections.count == 1, let kind = selections[0]["expr"]?["_kind"]?.text else {
            throw Failure.invalidAST
        }
        let explicitPlan = arguments.contains {
            $0["label"]?.text == "selectionPlan" && $0["expr"]?["_kind"]?.text != "default_argument_expr"
        }
        let explicit = kind != "default_argument_expr" || explicitPlan
        let following = arguments.drop(while: { $0["label"]?.text != "select" }).dropFirst()
        let labels = try following.map { argument in
            guard let label = argument["label"]?.text else { throw Failure.invalidAST }
            return label
        }
        return Call(
            symbol: symbol, startOffset: start, endOffset: end, hasExplicitSelection: explicit,
            labelsAfterSelection: labels)
    }

    private static func collectCallee(
        _ node: CompilerASTValue?, apiSymbols: Set<String>, into calls: inout [Int: Call]
    ) throws {
        guard let node else { throw Failure.invalidAST }
        if node["_kind"]?.text == "declref_expr" { return }
        let calleeKey = node["_kind"]?.text == "dot_syntax_call_expr" ? "fn" : "sub_expr"
        try collectCallee(node[calleeKey], apiSymbols: apiSymbols, into: &calls)
        // Receiver expressions can contain separate API calls and must still be inspected.
        for (key, child) in node.members where key != calleeKey {
            try collect(child, apiSymbols: apiSymbols, into: &calls)
        }
    }

    private static func callee(_ node: CompilerASTValue?) -> String? {
        guard let node else { return nil }
        switch node["_kind"]?.text {
        case "declref_expr": return node["decl"]?["decl_usr"]?.text
        case "dot_syntax_call_expr": return callee(node["fn"])
        case "function_conversion_expr", "load_expr": return callee(node["sub_expr"])
        default: return nil
        }
    }
}

/// The compiler's JSON format is version-pinned; source offsets stay integral.
indirect enum CompilerASTValue: Decodable {
    case object([String: CompilerASTValue])
    case array([CompilerASTValue])
    case text(String)
    case integer(Int)
    case boolean(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode([CompilerASTValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CompilerASTValue].self))
        }
    }

    subscript(key: String) -> CompilerASTValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }

    var children: [CompilerASTValue] {
        switch self {
        case .object(let values): return Array(values.values)
        case .array(let values): return values
        default: return []
        }
    }

    var members: [String: CompilerASTValue] {
        guard case .object(let values) = self else { return [:] }
        return values
    }

    var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    var integer: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var kind: String { self["_kind"]?.text ?? "" }
    var array: [CompilerASTValue] {
        guard case .array(let values) = self else { return [] }
        return values
    }
    var flag: Bool {
        guard case .boolean(let value) = self else { return false }
        return value
    }
    var declaredName: String? { self["name"]?["base_name"]?["name"]?.text }
}
