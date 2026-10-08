import Foundation

/// Build-time data flow over the type-checked Swift AST. Unknown object uses fail closed.
public enum ProjectionInference {
    public struct API: Codable, Sendable {
        public var handler: String?
        public init(handler: String? = nil) { self.handler = handler }
    }
    public struct Field: Codable, Sendable {
        public var name: String
        public var structured: Bool
        public init(name: String, structured: Bool = false) {
            self.name = name
            self.structured = structured
        }
    }
    public enum Failure: Error, Equatable {
        case objectEscapes(Int, String)
        case emptySelection(Int)
        case unsupportedBinding
        case invalidAST
    }

    public static func infer(
        data: Data, apis: [String: API], fields: [String: Field], transparent: Set<String> = []
    ) throws -> [Int: [[String]]] {
        let root = try JSONDecoder().decode(CompilerASTValue.self, from: data)
        return try infer(root: root, apis: apis, fields: fields, transparent: transparent)
    }

    static func infer(
        root: CompilerASTValue, apis: [String: API], fields: [String: Field], transparent: Set<String>
    ) throws -> [Int: [[String]]] {
        let flow = ProjectionFlow(apis: apis, fields: fields, transparent: transparent)
        try flow.consume(root)
        for offset in flow.required where flow.paths[offset, default: []].isEmpty {
            throw Failure.emptySelection(offset)
        }
        return flow.paths.mapValues { Array($0).sorted { $0.lexicographicallyPrecedes($1) } }
    }
}

private final class ProjectionFlow {
    typealias Failure = ProjectionInference.Failure
    struct Origin { let call: Int; var path: [String] = [] }
    struct Binding { var origin: Origin? }
    let apis: [String: ProjectionInference.API]
    let fields: [String: ProjectionInference.Field]
    let transparent: Set<String>
    var scope: [String: Binding] = [:]
    var paths: [Int: Set<[String]>] = [:]
    var required: Set<Int> = []

    init(apis: [String: ProjectionInference.API], fields: [String: ProjectionInference.Field], transparent: Set<String>)
    {
        self.apis = apis
        self.fields = fields
        self.transparent = transparent
    }

    func consume(_ node: CompilerASTValue) throws {
        if let origin = try evaluate(node) { throw Failure.objectEscapes(origin.call, node.kind) }
    }

    func evaluate(_ node: CompilerASTValue) throws -> Origin? {
        switch node.kind {
        case "brace_stmt":
            let previous = scope
            defer { scope = previous }
            for element in node["elements"]?.array ?? [] { try consume(element) }
        case "func_decl", "closure_expr": try closure(node, origin: nil)
        case "pattern_binding_decl": try bind(node)
        case "pattern_named":
            if let name = node.declaredName, scope[name]?.origin != nil { throw Failure.unsupportedBinding }
        case "for_each_stmt": try loop(node)
        case "var_decl":
            if let name = node.declaredName, let origin = scope[name]?.origin, node["let"]?.flag != true {
                throw Failure.objectEscapes(origin.call, "mutable binding")
            }
            for child in node.children { try consume(child) }
        case "declref_expr":
            if node["decl"]?["decl_usr"]?.text == "", let name = node["decl"]?["base_name"]?.text {
                return scope[name]?.origin
            }
        case "member_ref_expr": return try member(node)
        case "subscript_expr":
            guard node["decl"]?["decl_usr"]?.text == "s:SayxSicip" else {
                for child in node.children { try consume(child) }
                return nil
            }
            if let arguments = node["args"] { try consume(arguments) }
            return try node["base"].flatMap { try evaluate($0) }
        case "call_expr": return try call(node)
        case "await_expr", "try_expr", "force_try_expr", "optional_try_expr", "load_expr",
            "force_value_expr", "bind_optional_expr", "optional_evaluation_expr", "inject_into_optional":
            guard let child = node["sub_expr"] else { throw Failure.invalidAST }
            return try evaluate(child)
        default:
            for (key, child) in node.members where key != "original_init" { try consume(child) }
            if case .array(let children) = node { for child in children { try consume(child) } }
        }
        return nil
    }

    private func bind(_ node: CompilerASTValue) throws {
        for entry in node["pattern_entries"]?.array ?? [] {
            guard let value = entry["processed_init"] else { continue }
            let origin = try evaluate(value)
            guard entry["pattern"]?.kind == "pattern_named", let name = entry["pattern"]?.declaredName else {
                if origin != nil { throw Failure.unsupportedBinding }
                continue
            }
            scope[name] = Binding(origin: origin)
        }
    }

    private func member(_ node: CompilerASTValue) throws -> Origin? {
        guard let base = node["base"], var origin = try evaluate(base) else { return nil }
        guard let symbol = node["decl"]?["decl_usr"]?.text else { throw Failure.invalidAST }
        if transparent.contains(symbol) { return origin }
        guard let field = fields[symbol] else { throw Failure.objectEscapes(origin.call, "unrecognized member") }
        origin.path.append(field.name)
        if field.structured { return origin }
        paths[origin.call, default: []].insert(origin.path)
        return nil
    }

    private func loop(_ node: CompilerASTValue) throws {
        guard let sequence = node["parsed_sequence"] else { throw Failure.invalidAST }
        let origin = try evaluate(sequence)
        let previous = scope
        defer { scope = previous }
        guard node["pattern"]?.kind == "pattern_named", let name = node["pattern"]?.declaredName else {
            throw Failure.unsupportedBinding
        }
        scope[name] = Binding(origin: origin)
        if let condition = node["where"] { try consume(condition) }
        if let body = node["body"] { try consume(body) }
    }

    private func call(_ node: CompilerASTValue) throws -> Origin? {
        let symbol = Self.symbol(node["fn"])
        let arguments = node["args"]?["args"]?.array ?? []
        if let symbol, let api = apis[symbol] { return try apiCall(node, arguments: arguments, api: api) }
        if let symbol, transparent.contains(symbol) {
            for argument in arguments { try consume(argument) }
            return try receiver(node)
        }
        let collectionMethods: Set<String> = [
            "s:STsE7forEachyyy7ElementQzKXEKF",
            "s:SlsE3mapySayqd__Gqd__7ElementQzqd_0_YKXEqd_0_YKs5ErrorRd_0_r0_lF",
        ]
        if let symbol, collectionMethods.contains(symbol), let origin = try receiver(node) {
            guard arguments.count == 1, let callback = arguments[0]["expr"], callback.kind == "closure_expr" else {
                throw Failure.objectEscapes(origin.call, "non-inline collection callback")
            }
            try closure(callback, origin: origin)
            return nil
        }
        if let function = node["fn"] { try consume(function) }
        for argument in arguments { try consume(argument) }
        return nil
    }

    private func apiCall(
        _ node: CompilerASTValue, arguments: [CompilerASTValue], api: ProjectionInference.API
    ) throws -> Origin? {
        if let function = node["fn"] { try consume(function) }
        let explicit = arguments.contains {
            $0["label"]?.text == "select" && $0["expr"]?.kind != "default_argument_expr"
        }
        guard let offset = node["range"]?["start"]?.integer else { throw Failure.invalidAST }
        let origin = explicit ? nil : Origin(call: offset)
        if !explicit { required.insert(offset) }
        for argument in arguments {
            if let handler = api.handler, argument["label"]?.text == handler, !explicit {
                guard let callback = argument["expr"], callback.kind == "closure_expr" else {
                    throw Failure.objectEscapes(offset, "non-inline subscription callback")
                }
                try closure(callback, origin: origin)
            } else {
                try consume(argument)
            }
        }
        return api.handler == nil ? origin : nil
    }

    private func closure(_ node: CompilerASTValue, origin: Origin?) throws {
        let previous = scope
        defer { scope = previous }
        let parameters = node["params"]?["params"]?.array ?? []
        for parameter in parameters {
            if let name = parameter.declaredName { scope[name] = Binding(origin: nil) }
        }
        if let origin {
            guard parameters.count == 1, let name = parameters[0].declaredName else {
                throw Failure.unsupportedBinding
            }
            scope[name] = Binding(origin: origin)
        }
        if let body = node["body"] { try consume(body) }
    }

    private func receiver(_ node: CompilerASTValue) throws -> Origin? {
        guard let receiver = node["fn"]?["args"]?["args"]?.array.first?["expr"] else { return nil }
        return try evaluate(receiver)
    }

    private static func symbol(_ node: CompilerASTValue?) -> String? {
        guard let node else { return nil }
        switch node.kind {
        case "declref_expr": return node["decl"]?["decl_usr"]?.text
        case "dot_syntax_call_expr": return symbol(node["fn"])
        case "function_conversion_expr", "load_expr": return symbol(node["sub_expr"])
        default: return nil
        }
    }
}
