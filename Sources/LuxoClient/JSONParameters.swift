import Foundation

/// Compiles checked scalar paths once and validates the lossless JSON value tree.
/// Object indices support recursive schemas without ARC reference cycles.
struct JSONParameterPlan: Sendable {
    private struct Field: Sendable {
        enum Kind: Sendable {
            case integer, dateTime, object(Int), missing(String)
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

    func jsonValue(_ value: LuxoValue, named name: String) throws -> LuxoValue {
        do {
            return try entry(value, field: fields[name], name: name, depth: 0)
        } catch let error as Failure {
            throw LuxoError(
                code: 0, message: "invalid JSON parameter \(error.path): \(error.reason)", name: "ConfigError")
        }
    }

    private func entry(_ value: LuxoValue, field: Field?, name: String, depth: Int) throws -> LuxoValue {
        do {
            guard let field else { return value }
            if case .null = value, field.nullable { return .null }
            if field.isList {
                guard case .array(let values) = value else { throw Failure(reason: "must be a list") }
                return .array(
                    try values.enumerated().map { index, item in
                        do { return try scalar(item, kind: field.kind, depth: depth + 1) } catch var error as Failure {
                            error.prepend("[\(index)]")
                            throw error
                        }
                    })
            }
            return try scalar(value, kind: field.kind, depth: depth)
        } catch var error as Failure {
            error.prepend(name)
            throw error
        }
    }

    private func scalar(_ value: LuxoValue, kind: Field.Kind, depth: Int) throws -> LuxoValue {
        guard depth <= 128 else { throw Failure(reason: "nesting exceeds 128 levels") }
        switch kind {
        case .dateTime:
            guard case .string(let text) = value else { throw Failure(reason: "must be a DateTime string") }
            do { _ = try dateTimeParts(text) } catch { throw Failure(reason: "invalid DateTime value") }
            return value
        case .integer:
            guard case .int(let number) = value else { throw Failure(reason: "must be a signed Int64") }
            return .int(number)
        case .missing(let type):
            throw Failure(reason: "missing schema for \(type)")
        case .object(let index):
            if case .structured(let input) = value {
                return try scalar(input.luxoJSONValue(), kind: kind, depth: depth + 1)
            }
            guard case .object(let values) = value else { throw Failure(reason: "must be an object") }
            let objectFields = objects[index]
            var result = Dictionary<String, LuxoValue>(minimumCapacity: values.count)
            for (name, item) in values {
                result[name] = try entry(item, field: objectFields[name], name: name, depth: depth + 1)
            }
            return .object(result)
        }
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

        mutating func field(type: String?, name: String?, list: Bool, nullable: Bool) -> Field? {
            let kind: Field.Kind
            if type == "Int" || type == "Duration" {
                kind = .integer
            } else if type == "DateTime" {
                kind = .dateTime
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
            if let index = indices[name] { return .object(index) }
            let index = definitions.count
            indices[name] = index
            definitions.append(definition)
            return .object(index)
        }

        mutating func objects() -> [[String: Field]] {
            var result: [[String: Field]] = []
            while result.count < definitions.count {
                let definition = definitions[result.count]
                var fields: [String: Field] = [:]
                for (name, metadata) in definition {
                    fields[name] = field(
                        type: metadata.type, name: metadata.typeName,
                        list: metadata.isList, nullable: metadata.nullable)
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
        for (name, value) in params ?? [:] where name != "$api" && name != "$id" && name != "$sub" {
            body[name] = try plan?.jsonValue(value, named: name) ?? value
        }
        return try LuxoValue.object(body).jsonData()
    }
}
