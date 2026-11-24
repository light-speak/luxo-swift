import Foundation

/// Compiles checked scalar paths once and validates the lossless JSON value tree.
/// Object indices support recursive schemas without ARC reference cycles.
struct JSONParameterPlan: Sendable {
    private struct Field: Sendable {
        enum Kind: Sendable {
            case integer, dateTime, json, passthrough, object(Int), payload(Int), sealed(Int), missing(String)
        }
        let kind: Kind
        let isList: Bool
        let nullable: Bool
    }

    private let fields: [String: Field]
    private let objects: [[String: Field]]

    init?(params: [APISchema.ParamSchema]?, types: [String: [String: APISchema.SelectionFieldSchema]]) {
        var compiler = Compiler(types: types)
        var fields: [String: Field] = [:]
        for param in params ?? [] {
            fields[param.name] = compiler.field(
                type: param.type, name: param.typeName, list: param.isList, nullable: param.nullable)
        }
        guard !fields.isEmpty else { return nil }
        self.fields = fields
        self.objects = compiler.objects()
    }

    func writeJSON(_ value: LuxoValue, named name: String, to writer: inout JSONWriter) throws {
        do {
            try entry(value, field: fields[name], name: name, depth: 0, to: &writer)
        } catch let error as Failure {
            throw LuxoError(
                code: 0, message: "invalid JSON parameter \(error.path): \(error.reason)", name: "ConfigError")
        }
    }

    private func entry(
        _ value: LuxoValue, field: Field?, name: String, depth: Int, to writer: inout JSONWriter
    ) throws {
        do {
            guard let field else { try writer.value(value, depth: 0); return }
            if case .null = value, field.nullable { try writer.value(.null, depth: 0); return }
            if field.isList {
                guard case .array(let values) = value else { throw Failure(reason: "must be a list") }
                try writer.array(values, depth: 0) { writer, index, item in
                    do { try scalar(item, kind: field.kind, depth: depth, to: &writer) } catch var error as Failure {
                        error.prepend("[\(index)]"); throw error
                    }
                }
                return
            }
            try scalar(value, kind: field.kind, depth: depth, to: &writer)
        } catch var error as Failure {
            error.prepend(name)
            throw error
        }
    }

    private func scalar(
        _ value: LuxoValue, kind: Field.Kind, depth: Int, to writer: inout JSONWriter
    ) throws {
        switch kind {
        case .passthrough:
            try writer.value(value, depth: 0)
        case .json:
            try writer.value(value, depth: 0, genericJSON: true)
        case .dateTime:
            guard case .string(let text) = value else { throw Failure(reason: "must be a DateTime string") }
            do { _ = try dateTimeParts(text) } catch { throw Failure(reason: "invalid DateTime value") }
            try writer.value(value, depth: 0)
        case .integer:
            guard case .int = value else { throw Failure(reason: "must be a signed Int64") }
            try writer.value(value, depth: 0)
        case .missing(let type):
            throw Failure(reason: "missing schema for \(type)")
        case .sealed(let index):
            let values = try projectedObject(value, depth: depth)
            guard values.count == 1, let (name, item) = values.first,
                let fieldIndex = objects[index].index(forKey: name),
                objects[index][fieldIndex].key.utf8.elementsEqual(name.utf8)
            else { throw Failure(reason: "must contain exactly one known case") }
            let field = objects[index][fieldIndex].value
            try writer.object(values, depth: 0) { writer, _, _ in
                try entry(item, field: field, name: name, depth: depth + 1, to: &writer)
            }
        case .object(let index), .payload(let index):
            let values = try projectedObject(value, depth: depth)
            let objectFields = objects[index]
            if case .payload = kind,
                let unknown = values.keys.first(where: { name in
                    guard let index = objectFields.index(forKey: name) else { return true }
                    return !objectFields[index].key.utf8.elementsEqual(name.utf8)
                })
            {
                throw Failure(reason: "unknown sealed payload field \(unknown)")
            }
            try writer.object(values, depth: 0) { writer, name, item in
                try entry(item, field: objectFields[name], name: name, depth: depth + 1, to: &writer)
            }
        }
    }

    private func projectedObject(_ value: LuxoValue, depth: Int) throws -> [String: LuxoValue] {
        guard depth < 64 else { throw Failure(reason: "model nesting exceeds 64 levels") }
        var value = value
        var projections = 0
        while case .structured(let input) = value {
            guard projections < 64 else { throw Failure(reason: "model projection nesting exceeds 64 levels") }
            value = try input.luxoJSONValue()
            projections += 1
        }
        guard case .object(let fields) = value else { throw Failure(reason: "must be an object") }
        return fields
    }

    private struct Failure: Error {
        var path = ""
        let reason: String

        mutating func prepend(_ segment: String) {
            if path.isEmpty { path = segment } else { path = segment + (path.hasPrefix("[") ? "" : ".") + path }
        }
    }

    private struct Compiler {
        let types: [String: [String: APISchema.SelectionFieldSchema]]
        var definitions: [[String: APISchema.SelectionFieldSchema]] = []
        var indices: [String: Int] = [:]
        var payloadIndices: Set<Int> = []

        mutating func field(type: String?, name: String?, list: Bool, nullable: Bool) -> Field? {
            let kind: Field.Kind
            if type == "Int" || type == "Duration" {
                kind = .integer
            } else if type == "JSON" {
                kind = .json
            } else if type == "DateTime" {
                kind = .dateTime
            } else if type == "Sealed" {
                let definition = object("@sealed:" + (name ?? "<unknown>"))
                if case .object(let index) = definition { kind = .sealed(index) } else { kind = definition }
            } else if type == "Model" {
                kind = object(name ?? "<unknown>")
            } else if let modelName = name ?? type, types[modelName] != nil || type == nil {
                kind = object(modelName)
            } else if type == nil {
                kind = .missing("field type metadata")
            } else {
                return nil
            }
            return Field(kind: kind, isList: list, nullable: nullable)
        }

        mutating func object(_ name: String) -> Field.Kind {
            guard let definition = types[name] else { return .missing(name) }
            if let index = indices[name] { return name.contains(".") ? .payload(index) : .object(index) }
            let index = definitions.count
            indices[name] = index
            definitions.append(definition)
            if name.contains(".") { payloadIndices.insert(index); return .payload(index) }
            return .object(index)
        }

        mutating func objects() -> [[String: Field]] {
            var result: [[String: Field]] = []
            while result.count < definitions.count {
                let definition = definitions[result.count]
                let payload = payloadIndices.contains(result.count)
                var fields: [String: Field] = [:]
                for (name, metadata) in definition {
                    fields[name] =
                        field(
                            type: metadata.type, name: metadata.typeName,
                            list: metadata.isList, nullable: metadata.nullable)
                        ?? (payload
                            ? Field(kind: .passthrough, isList: metadata.isList, nullable: metadata.nullable) : nil)
                }
                result.append(fields)
            }
            return result
        }
    }
}

enum LuxoJSONRequest {
    static func encode(
        api: String, params: [String: LuxoValue]?, plan: JSONParameterPlan?,
        sequence: UInt64? = nil, subscription: Bool = false
    ) throws -> Data {
        var body = Dictionary<String, LuxoValue>(minimumCapacity: (params?.count ?? 0) + 2)
        body[subscription ? "$sub" : "$api"] = .string(api)
        if let sequence { body["$id"] = .jsonNumber(JSONNumber(validated: String(sequence))) }
        for (name, value) in params ?? [:] {
            if name.utf8.first == UInt8(ascii: "$") {
                switch name {
                case "$api", "$id", "$sub", "$unsub": continue
                default: break
                }
            }
            body[name] = value
        }
        var writer = JSONWriter()
        try writer.object(body, depth: 0) { writer, name, value in
            if let plan, name != "$api", name != "$id", name != "$sub" {
                try plan.writeJSON(value, named: name, to: &writer)
            } else {
                try writer.value(value, depth: 0)
            }
        }
        return Data(writer.bytes)
    }
}
