import Foundation

/// Static wire metadata used before Codable materializes a model or discards duplicate keys.
public protocol LuxoJSONSchemaProviding: Decodable, SendableMetatype {
    static var luxoJSONSchema: LuxoJSONReadSchema { get }
}

/// Keeps generic JSON container depth independent of typed collections and model depth.
public struct LuxoJSONReadSchema: Sendable {
    enum Collection: Sendable { case list, dictionary, page }

    enum Shape: Sendable {
        case json
        case model(String, [String: [String: APISchema.SelectionFieldSchema]])
        case sealed(String, [String: [String: APISchema.SelectionFieldSchema]])
        case sealedPayload(String, [String: [String: APISchema.SelectionFieldSchema]])
        indirect case collection(Collection, LuxoJSONReadSchema)
        case typedCollection(Collection, any LuxoJSONSchemaProviding.Type)
    }

    let shape: Shape

    public static let json = LuxoJSONReadSchema(shape: .json)

    public static func model(
        _ name: String, types: [String: [String: APISchema.SelectionFieldSchema]]
    ) -> Self {
        if name.hasPrefix("@sealed:") { return Self(shape: .sealed(name, types)) }
        if name.contains(".") { return Self(shape: .sealedPayload(name, types)) }
        return Self(shape: .model(name, types))
    }

    public static func list(_ element: Self) -> Self { Self(shape: .collection(.list, element)) }
    public static func dictionary(_ value: Self) -> Self { Self(shape: .collection(.dictionary, value)) }
    public static func page(_ item: Self) -> Self { Self(shape: .collection(.page, item)) }
}

extension JSONValue: LuxoJSONSchemaProviding {
    public static var luxoJSONSchema: LuxoJSONReadSchema { .json }
}

extension Array: LuxoJSONSchemaProviding where Element: LuxoJSONSchemaProviding {
    public static var luxoJSONSchema: LuxoJSONReadSchema { .init(shape: .typedCollection(.list, Element.self)) }
}

extension Optional: LuxoJSONSchemaProviding where Wrapped: LuxoJSONSchemaProviding {
    public static var luxoJSONSchema: LuxoJSONReadSchema { Wrapped.luxoJSONSchema }
}

extension Dictionary: LuxoJSONSchemaProviding where Key == String, Value: LuxoJSONSchemaProviding {
    public static var luxoJSONSchema: LuxoJSONReadSchema { .init(shape: .typedCollection(.dictionary, Value.self)) }
}

extension Selected: LuxoJSONSchemaProviding where Value: LuxoJSONSchemaProviding & Encodable {
    public static var luxoJSONSchema: LuxoJSONReadSchema { Value.luxoJSONSchema }
}

extension Page: LuxoJSONSchemaProviding where T: LuxoJSONSchemaProviding {
    public static var luxoJSONSchema: LuxoJSONReadSchema { .init(shape: .typedCollection(.page, T.self)) }
}

extension Cursor: LuxoJSONSchemaProviding where T: LuxoJSONSchemaProviding {
    public static var luxoJSONSchema: LuxoJSONReadSchema { .init(shape: .typedCollection(.page, T.self)) }
}

struct JSONModelDepthFailure: Error {}

extension JSONReader {
    mutating func skipValue(schema: LuxoJSONReadSchema) throws {
        _ = try value(schema: schema, objectDepth: 0, materialize: false)
    }

    mutating func value(
        schema: LuxoJSONReadSchema, objectDepth: Int, materialize: Bool = true
    ) throws -> LuxoValue {
        whitespace()
        switch schema.shape {
        case .json:
            return try schemaValue(materialize: materialize)
        case .model(let name, let types):
            return try model(name: name, types: types, objectDepth: objectDepth, materialize: materialize)
        case .sealedPayload(let name, let types):
            return try model(
                name: name, types: types, objectDepth: objectDepth,
                materialize: materialize, rejectUnknown: true)
        case .sealed(let name, let types):
            guard let fields = types[name] else {
                throw LuxoError(code: 0, message: "missing JSON sealed schema: \(name)", name: "ConfigError")
            }
            return try sealed(fields: fields, types: types, objectDepth: objectDepth, materialize: materialize)
        case .collection(let kind, let element):
            return try collection(kind, element: element, objectDepth: objectDepth, materialize: materialize)
        case .typedCollection(let kind, let type):
            return try collection(
                kind, element: type.luxoJSONSchema, objectDepth: objectDepth, materialize: materialize)
        }
    }

    private mutating func collection(
        _ kind: LuxoJSONReadSchema.Collection, element: LuxoJSONReadSchema, objectDepth: Int, materialize: Bool
    ) throws -> LuxoValue {
        switch kind {
        case .list:
            return try typedArray(materialize: materialize) {
                try $0.value(schema: element, objectDepth: objectDepth, materialize: materialize)
            }
        case .dictionary:
            return try typedObject(materialize: materialize) { reader, _ in
                try reader.value(schema: element, objectDepth: objectDepth, materialize: materialize)
            }
        case .page:
            return try typedObject(materialize: materialize) { reader, key in
                if key == "items" {
                    return try reader.typedArray(materialize: materialize) {
                        try $0.value(schema: element, objectDepth: objectDepth, materialize: materialize)
                    }
                }
                return try reader.schemaValue(materialize: materialize)
            }
        }
    }

    private mutating func model(
        name: String, types: [String: [String: APISchema.SelectionFieldSchema]], objectDepth: Int, materialize: Bool,
        rejectUnknown: Bool = false
    ) throws -> LuxoValue {
        guard let fields = types[name] else {
            throw LuxoError(code: 0, message: "missing JSON model schema: \(name)", name: "ConfigError")
        }
        if current == 123, objectDepth >= 64 {
            if !materialize { throw JSONModelDepthFailure() }
            throw LuxoError(code: 0, message: "model nesting exceeds 64 levels", name: "DecodingError")
        }
        return try typedObject(materialize: materialize) { reader, key in
            guard let index = fields.index(forKey: key) else {
                if rejectUnknown { throw reader.invalid() }
                return try reader.schemaValue(materialize: materialize)
            }
            let entry = fields[index]
            if rejectUnknown && !entry.key.utf8.elementsEqual(key.utf8) { throw reader.invalid() }
            let field = entry.value
            if field.isList {
                return try reader.typedArray(materialize: materialize) {
                    try $0.modelField(field, types: types, objectDepth: objectDepth + 1, materialize: materialize)
                }
            }
            return try reader.modelField(field, types: types, objectDepth: objectDepth + 1, materialize: materialize)
        }
    }

    private mutating func sealed(
        fields: [String: APISchema.SelectionFieldSchema],
        types: [String: [String: APISchema.SelectionFieldSchema]], objectDepth: Int, materialize: Bool
    ) throws -> LuxoValue {
        // Nullability is owned by the containing field/Optional Codable value.
        if current == 110 { try keyword("null"); return .null }
        guard objectDepth < 64 else {
            if !materialize { throw JSONModelDepthFailure() }
            throw LuxoError(code: 0, message: "model nesting exceeds 64 levels", name: "DecodingError")
        }
        guard take(123) else { throw invalid() }
        whitespace()
        let key = try string()
        guard let field = fields[key], let payload = field.typeName,
            payload.utf8.reversed().prefix(while: { $0 != 46 }).elementsEqual(key.utf8.reversed())
        else {
            throw invalid()
        }
        whitespace()
        guard take(58) else { throw invalid() }
        whitespace()
        guard current == 123 else { throw invalid() }
        let value = try model(
            name: payload, types: types, objectDepth: objectDepth + 1,
            materialize: materialize, rejectUnknown: true)
        whitespace()
        guard take(125) else { throw invalid() }
        return materialize ? .object([key: value]) : .null
    }

    private mutating func modelField(
        _ field: APISchema.SelectionFieldSchema,
        types: [String: [String: APISchema.SelectionFieldSchema]], objectDepth: Int, materialize: Bool
    ) throws -> LuxoValue {
        whitespace()
        if let name = field.typeName {
            if field.type == "Sealed" {
                return try value(
                    schema: .model("@sealed:" + name, types: types),
                    objectDepth: objectDepth, materialize: materialize)
            }
            return try model(name: name, types: types, objectDepth: objectDepth, materialize: materialize)
        }
        return try schemaValue(materialize: materialize)
    }

    private mutating func schemaValue(materialize: Bool) throws -> LuxoValue {
        if materialize { return try value(depth: 0) }
        try skipValue(depth: 0)
        return .null
    }

    mutating func typedArray(
        materialize: Bool, element: (inout JSONReader) throws -> LuxoValue
    ) throws -> LuxoValue {
        whitespace()
        guard take(91) else { return try schemaValue(materialize: materialize) }
        whitespace()
        var values: [LuxoValue] = []
        var count = 0
        if take(93) { return materialize ? .array(values) : .null }
        var complete: Bool
        repeat {
            guard count < 1_000_000 else { throw invalid() }
            count += 1
            let value = try element(&self)
            if materialize { values.append(value) }
            whitespace()
            complete = take(93)
            if !complete, !take(44) { throw invalid() }
        } while !complete
        return materialize ? .array(values) : .null
    }

    mutating func typedObject(
        materialize: Bool, field: (inout JSONReader, String) throws -> LuxoValue
    ) throws -> LuxoValue {
        whitespace()
        guard take(123) else { return try schemaValue(materialize: materialize) }
        whitespace()
        var values: [String: LuxoValue] = [:]
        if take(125) { return materialize ? .object(values) : .null }
        var complete: Bool
        repeat {
            whitespace()
            let key = try string()
            whitespace()
            guard take(58) else { throw invalid() }
            // Validate every source value before duplicate-key replacement.
            let value = try field(&self, key)
            if materialize { values[key] = value }
            whitespace()
            complete = take(125)
            if !complete, !take(44) { throw invalid() }
        } while !complete
        return materialize ? .object(values) : .null
    }
}
