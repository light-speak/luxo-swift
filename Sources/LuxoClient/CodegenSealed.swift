import Foundation

extension LuxoParam {
    var sealedField: LuxoField {
        .init(
            id: id, name: name, type: type, typeName: typeName,
            nullable: nullable, isList: isList, relation: false)
    }
}

/// Source aliases are planned from real declarations; wire names and stable IDs stay unchanged.
struct SwiftSealedPlan {
    struct Variant {
        let owner: String
        let declaration: LuxoSealedVariant
        let sourceCase: String
        let output: String
        let input: String
        let fields: [LuxoField]
    }
    let owners: [String: [Variant]]

    init(_ schema: LuxoSchema, aliases: [String: String]) {
        var reserved = Set(schema.models.keys).union(schema.types?.keys ?? [:].keys)
            .union(schema.enums?.keys ?? [:].keys).union(schema.sealeds?.keys ?? [:].keys)
        reserved.formUnion(aliases.values)
        reserved.formUnion(reserved.map { $0 + "Input" })
        func fresh(_ base: String) -> String {
            var name = base
            while !reserved.insert(name).inserted { name += "_" }
            return name
        }
        var owners: [String: [Variant]] = [:]
        for (owner, sealed) in (schema.sealeds ?? [:]).sorted(by: { $0.key < $1.key }) {
            let names = SwiftEnumCodegen.caseNames(sealed.variants.map(\.name))
            owners[owner] = zip(sealed.variants, names).map { variant, name in
                let base = "LuxoSealed_\(owner.utf8.count)_\(owner)_\(variant.id)"
                return Variant(
                    owner: owner, declaration: variant, sourceCase: name,
                    output: fresh(base + "Payload"), input: fresh(base + "Input"),
                    fields: Self.fields(variant.fields))
            }
        }
        self.owners = owners
    }

    private static func fields(_ params: [LuxoParam]) -> [LuxoField] {
        let reserved: Set<String> = [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
            "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static",
            "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else",
            "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "Any",
            "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try", "_",
            "CodingKeys", "luxoJSONSchema", "writeLuxo", "luxoJSONValue",
            "LuxoError", "LuxoValue", "LuxoOptional", "Selected", "Swift", "Foundation", "LuxoClient",
            "stringValue", "intValue", "description", "debugDescription",
        ]
        var occupied = Set(params.map(\.name))
        return params.map { param in
            var name = param.name
            if reserved.contains(name) {
                name = "luxoField\(param.id)"
                while !occupied.insert(name).inserted { name += "_" }
            }
            return .init(
                id: param.id, name: name, type: param.type, typeName: param.typeName,
                nullable: param.nullable, isList: param.isList, relation: false)
        }
    }
}

extension LuxoCodegen {
    func generateSealedModels(_ schema: LuxoSchema, usages: TypeUsages) -> String {
        guard schema.sealeds?.isEmpty == false else { return "" }
        let plan = SwiftSealedPlan(schema, aliases: usages.inputAliases)
        var out = ""
        for (owner, variants) in plan.owners.sorted(by: { $0.key < $1.key }) {
            let usage = usages[owner] ?? .unused
            if usage == .output || usage == .inputOutput {
                for variant in variants {
                    let keys = payloadKeys(variant)
                    out += generateModelDeclaration(
                        name: variant.output, wireName: owner + "." + variant.declaration.name,
                        fields: variant.fields, reference: false, schema: schema,
                        usages: usages, output: true, codingKeys: keys,
                        closedJSONFields: variant.declaration.fields.map(\.name))
                }
                out += sealedDeclaration(owner, owner: owner, variants: variants, input: false)
            }
            if usage == .input || usage == .inputOutput {
                for variant in variants { out += sealedInputPayload(variant, schema: schema, usages: usages) }
                out += sealedDeclaration(
                    inputTypeName(owner, usages: usages), owner: owner, variants: variants, input: true)
            }
        }
        return out
    }

    private func payloadKeys(_ variant: SwiftSealedPlan.Variant) -> String {
        dynamicCodingKeys(zip(variant.fields, variant.declaration.fields).map { ($0.name, $1.name) })
    }

    private func dynamicCodingKeys(_ fields: [(String, String)]) -> String {
        var out = "    private struct CodingKeys: Swift.CodingKey, Swift.Sendable {\n"
        out += "        let stringValue: Swift.String\n        var intValue: Swift.Int? { nil }\n"
        out += "        init(_ value: Swift.String) { stringValue = value }\n"
        out += "        init?(stringValue: Swift.String) { self.init(stringValue) }\n"
        out += "        init?(intValue: Swift.Int) { return nil }\n"
        for (source, wire) in fields {
            out += "        static let \(source) = Self(\(SwiftEnumCodegen.literal(wire)))\n"
        }
        return out + "    }\n"
    }

    func sealedJSONKeyValidation(_ names: [String]) -> String {
        var out = "        for key in container.allKeys {\n            switch key.stringValue {\n"
        for name in names {
            let literal = SwiftEnumCodegen.literal(name)
            out += "            case \(literal) where key.stringValue.utf8.elementsEqual(\(literal).utf8): break\n"
        }
        return out
            + "            default: throw LuxoError(code: 0, message: \"unknown sealed payload field\", name: \"DecodingError\")\n            }\n        }\n"
    }

    func sealedOutputJSONEncoder(_ fields: [LuxoField]) -> String {
        let binding = fields.isEmpty ? "_" : "var container"
        var out =
            "    public func encode(to encoder: Swift.Encoder) throws {\n        \(binding) = encoder.container(keyedBy: CodingKeys.self)\n"
        for field in fields { out += "        try container.encode(self.\(field.name), forKey: .\(field.name))\n" }
        return out + "    }\n"
    }

    private func sealedDeclaration(_ name: String, owner: String, variants: [SwiftSealedPlan.Variant], input: Bool)
        -> String
    {
        var out = "public indirect enum \(name): Codable, Sendable, LuxoClient.LuxoJSONSchemaProviding"
        if input { out += ", LuxoClient.LuxoBinaryEncodable" }
        out += " {\n"
        out +=
            "    public static let luxoJSONSchema = LuxoClient.LuxoJSONReadSchema.model(\(SwiftEnumCodegen.literal("@sealed:" + owner)), types: LUXO_SELECTION_TYPES)\n"
        for variant in variants {
            out += "    case \(variant.sourceCase)(\(input ? variant.input : variant.output))\n"
        }
        if !variants.isEmpty {
            out += dynamicCodingKeys(variants.map { ("tag\($0.declaration.id)", $0.declaration.name) })
        }
        out += sealedJSONDecoder(variants, input: input)
        out += "    public func encode(to encoder: Swift.Encoder) throws {\n"
        if !variants.isEmpty { out += "        var container = encoder.container(keyedBy: CodingKeys.self)\n" }
        out += "        switch self {\n"
        for variant in variants {
            out +=
                "        case .\(variant.sourceCase)(let value): try container.encode(value, forKey: .tag\(variant.declaration.id))\n"
        }
        out += "        }\n    }\n"
        if input { out += sealedInputEncoder(variants) }
        return out + "}\n\n"
    }

    private func sealedJSONDecoder(_ variants: [SwiftSealedPlan.Variant], input: Bool) -> String {
        if variants.isEmpty {
            return
                "    public init(from decoder: Swift.Decoder) throws { throw LuxoError(code: 0, message: \"empty sealed type has no values\", name: \"DecodingError\") }\n"
        }
        var out =
            "    public init(from decoder: Swift.Decoder) throws {\n        let container = try decoder.container(keyedBy: CodingKeys.self)\n"
        out +=
            "        guard container.allKeys.count == 1, let key = container.allKeys.first else {\n            throw LuxoError(code: 0, message: \"sealed value requires exactly one known case\", name: \"DecodingError\")\n        }\n        switch key.stringValue {\n"
        for variant in variants {
            out +=
                "        case \(SwiftEnumCodegen.literal(variant.declaration.name)) where key.stringValue.utf8.elementsEqual(\(SwiftEnumCodegen.literal(variant.declaration.name)).utf8): self = .\(variant.sourceCase)(try container.decode(\(input ? variant.input : variant.output).self, forKey: key))\n"
        }
        return out
            + "        default: throw LuxoError(code: 0, message: \"unknown sealed case\", name: \"DecodingError\")\n        }\n    }\n"
    }

    private func sealedInputEncoder(_ variants: [SwiftSealedPlan.Variant]) -> String {
        var out =
            "    public func writeLuxo(to encoder: inout Encoder) throws { try writeLuxo(to: &encoder, depth: 0) }\n"
        out +=
            "    fileprivate func writeLuxo(to encoder: inout Encoder, depth: Swift.Int) throws {\n        guard depth < 64 else { throw LuxoError(code: 0, message: \"model nesting exceeds 64 levels\", name: \"EncodingError\") }\n        switch self {\n"
        for variant in variants {
            out +=
                "        case .\(variant.sourceCase)(let value):\n            encoder.writeVarint(\(variant.declaration.id))\n            try encoder.writeDelimited { encoder in try value.writeLuxo(to: &encoder, depth: depth + 1) }\n"
        }
        out += "        }\n    }\n    public func luxoJSONValue() throws -> LuxoValue {\n        switch self {\n"
        for variant in variants {
            out +=
                "        case .\(variant.sourceCase)(let value): return .object([\(SwiftEnumCodegen.literal(variant.declaration.name)): .structured(value)])\n"
        }
        return out + "        }\n    }\n"
    }

    private func sealedInputType(_ field: LuxoField, param: LuxoParam, schema: LuxoSchema, usages: TypeUsages) -> String
    {
        let base = resolveFieldType(field, schema: schema, usages: usages, input: true)
        if param.hasDefault == true && param.nullable == true { return "LuxoOptional<\(base)>" }
        return base + (param.nullable == true || param.hasDefault == true ? "?" : "")
    }

    private func sealedInputPayload(_ variant: SwiftSealedPlan.Variant, schema: LuxoSchema, usages: TypeUsages)
        -> String
    {
        var out = "public struct \(variant.input): Codable, Sendable, LuxoBinaryEncodable, LuxoJSONSchemaProviding {\n"
        out +=
            "    public static let luxoJSONSchema = LuxoJSONReadSchema.model(\(SwiftEnumCodegen.literal(variant.owner + "." + variant.declaration.name)), types: LUXO_SELECTION_TYPES)\n"
        let fields = Array(zip(variant.fields, variant.declaration.fields))
        for (field, param) in fields {
            out +=
                "    public let \(field.name): \(sealedInputType(field, param: param, schema: schema, usages: usages))\n"
        }
        let parameters = fields.map { field, param in
            let initial = param.hasDefault == true ? (param.nullable == true ? " = .absent" : " = nil") : ""
            return "\(field.name): \(sealedInputType(field, param: param, schema: schema, usages: usages))\(initial)"
        }.joined(separator: ", ")
        out += "    public init(\(parameters)) {\n"
        for field in variant.fields { out += "        self.\(field.name) = \(field.name)\n" }
        out += "    }\n" + payloadKeys(variant)
        out += sealedInputCodable(variant, schema: schema, usages: usages)
        out += sealedInputRow(variant, schema: schema)
        return out + "}\n\n"
    }

    private func sealedInputCodable(_ variant: SwiftSealedPlan.Variant, schema: LuxoSchema, usages: TypeUsages)
        -> String
    {
        let fields = Array(zip(variant.fields, variant.declaration.fields))
        var out =
            "    public init(from decoder: Swift.Decoder) throws {\n        let container = try decoder.container(keyedBy: CodingKeys.self)\n"
        out += sealedJSONKeyValidation(variant.declaration.fields.map(\.name))
        for (field, param) in fields {
            let base =
                resolveFieldType(field, schema: schema, usages: usages, input: true)
                + (param.nullable == true ? "?" : "")
            let value = "try container.decode(\(base).self, forKey: .\(field.name))"
            if param.hasDefault == true {
                out +=
                    "        self.\(field.name) = container.contains(.\(field.name)) ? \(param.nullable == true ? ".present(\(value))" : value) : \(param.nullable == true ? ".absent" : "nil")\n"
            } else {
                out += "        self.\(field.name) = \(value)\n"
            }
        }
        out +=
            "    }\n    public func encode(to encoder: Swift.Encoder) throws {\n        \(fields.isEmpty ? "_" : "var container") = encoder.container(keyedBy: CodingKeys.self)\n"
        for (field, param) in fields {
            if param.hasDefault == true && param.nullable == true {
                out +=
                    "        if case .present(let value) = self.\(field.name) { try container.encode(value, forKey: .\(field.name)) }\n"
            } else if param.hasDefault == true {
                out +=
                    "        if let value = self.\(field.name) { try container.encode(value, forKey: .\(field.name)) }\n"
            } else {
                out += "        try container.encode(self.\(field.name), forKey: .\(field.name))\n"
            }
        }
        return out + "    }\n"
    }

    /// Omission and explicit null use the same static branch in binary and JSON projections.
    private func sealedVisit(_ variant: SwiftSealedPlan.Variant, body: (LuxoField, LuxoParam, String) -> String)
        -> String
    {
        var out = ""
        for (field, param) in zip(variant.fields, variant.declaration.fields) {
            let reference = "self.\(field.name)"
            let value = param.hasDefault == true ? "value" : reference
            let statement = body(field, param, value)
            if statement.isEmpty { continue }
            if param.hasDefault == true && param.nullable == true {
                out += "        if case .present(let value) = \(reference) {\n" + statement + "        }\n"
            } else if param.hasDefault == true {
                out += "        if let value = \(reference) {\n" + statement + "        }\n"
            } else {
                out += statement
            }
        }
        return out
    }

    private func sealedInputRow(_ variant: SwiftSealedPlan.Variant, schema: LuxoSchema) -> String {
        var out =
            "    public func writeLuxo(to encoder: inout Encoder) throws { try writeLuxo(to: &encoder, depth: 0) }\n"
        out +=
            "    fileprivate func writeLuxo(to encoder: inout Encoder, depth: Swift.Int) throws {\n        guard depth < 64 else { throw LuxoError(code: 0, message: \"model nesting exceeds 64 levels\", name: \"EncodingError\") }\n"
        let strings = variant.fields.contains { $0.isList != true && ($0.type == "String" || $0.type == "Enum") }
        out += strings ? "        var arena = 0\n" : ""
        out += sealedVisit(variant) { field, param, value in
            guard field.isList != true, field.type == "String" || field.type == "Enum" else { return "" }
            let member = field.type == "Enum" ? ".rawValue" : ""
            return param.nullable == true
                ? "        arena += \(value).map { $0\(member).utf8.count } ?? 0\n"
                : "        arena += \(value)\(member).utf8.count\n"
        }
        out += "        encoder.writeVarint(\(strings ? "Swift.UInt64(arena)" : "0"))\n"
        out += sealedVisit(variant) { field, param, value in
            var text = "        encoder.writeVarint(\(field.id))\n"
            if param.nullable == true { text += "        if let value = \(value) {\n        encoder.writeBool(true)\n" }
            text += sealedInputValue(field, value: param.nullable == true ? "value" : value, schema: schema)
            if param.nullable == true { text += "        } else { encoder.writeBool(false) }\n" }
            return text
        }
        out += "        encoder.writeEnd()\n    }\n    public func luxoJSONValue() throws -> LuxoValue {\n"
        if variant.fields.isEmpty { return out + "        return .object([:])\n    }\n" }
        out += "        var values: [String: LuxoValue] = [:]\n"
        out += sealedVisit(variant) { field, param, value in
            let expression = typedTransportExpression(
                type: field.type, typeName: field.typeName, list: field.isList == true,
                value: param.nullable == true ? "value" : value, schema: schema
            ).source
            let key = SwiftEnumCodegen.literal(param.name)
            return param.nullable == true
                ? "        if let value = \(value) { values[\(key)] = \(expression) } else { values[\(key)] = .null }\n"
                : "        values[\(key)] = \(expression)\n"
        }
        return out + "        return .object(values)\n    }\n"
    }

    private func sealedInputValue(_ field: LuxoField, value: String, schema: LuxoSchema) -> String {
        let item = field.isList == true ? "item" : value
        let scalar = generateInputBinaryScalar(field, value: item, schema: schema, indent: "        ")
        if field.isList != true { return scalar }
        return "        try encoder.writeArrayHeader(\(value).count)\n        for item in \(value) {\n" + scalar
            + "        }\n"
    }

    func generateSealedDecoders(_ schema: LuxoSchema, usages: TypeUsages) -> String {
        guard schema.sealeds?.isEmpty == false else { return "" }
        let plan = SwiftSealedPlan(schema, aliases: usages.inputAliases)
        var out = ""
        for (owner, variants) in plan.owners.sorted(by: { $0.key < $1.key })
        where usages[owner] == .output || usages[owner] == .inputOutput {
            for variant in variants {
                out += generateDecoder(
                    name: variant.output, fields: variant.fields, schema: schema, usages: usages, columnar: false)
            }
            out +=
                "public func decode\(owner)(_ decoder: inout Decoder) throws -> \(owner) { try decode\(owner)(&decoder, depth: 0) }\n"
            out +=
                "private func decode\(owner)(_ decoder: inout Decoder, depth: Swift.Int) throws -> \(owner) {\n    guard depth < 64 else { throw LuxoError(code: 0, message: \"model nesting exceeds 64 levels\", name: \"DecodeError\") }\n    let tag = decoder.readVarint()\n    switch tag {\n"
            for variant in variants {
                out +=
                    "    case \(variant.declaration.id): return .\(variant.sourceCase)(try decodeLuxoResponse(decoder.readBytes()) { try decode\(variant.output)(&$0, depth: depth + 1) })\n"
            }
            out +=
                "    default: throw LuxoError(code: 0, message: \"unknown sealed tag \\(tag)\", name: \"DecodeError\")\n    }\n}\n\n"
        }
        return out
    }

    func sealedSelectionTypes(_ schema: LuxoSchema) -> [(String, [LuxoField])] {
        var result: [(String, [LuxoField])] = []
        for (owner, sealed) in schema.sealeds ?? [:] {
            let cases = sealed.variants.map { variant in
                LuxoField(
                    id: variant.id, name: variant.name, type: "Model", typeName: owner + "." + variant.name,
                    nullable: false, isList: false, relation: false)
            }
            result.append((owner, cases))
            result.append(("@sealed:" + owner, cases))
            for variant in sealed.variants {
                result.append((owner + "." + variant.name, variant.fields.map(\.sealedField)))
            }
        }
        return result
    }
}
