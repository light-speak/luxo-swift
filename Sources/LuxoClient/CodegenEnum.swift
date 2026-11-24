import Foundation

/// Enum metadata is validated once before writing generated files.
enum SwiftEnumCodegen {
    static func validate(_ schema: LuxoSchema) throws {
        for (key, value) in schema.enums ?? [:] {
            try validateName(key, value.name)
            guard Set(value.values.map { Data($0.utf8) }).count == value.values.count
            else { throw invalid("enum \(key) requires a matching name and distinct members") }
        }
        for (key, model) in schema.models {
            try validateName(key, model.name)
            guard schema.types?[key] == nil && schema.enums?[key] == nil else {
                throw invalid("duplicate type \(key)")
            }
            try validateFields(model.fields, schema: schema)
        }
        for (key, type) in schema.types ?? [:] {
            try validateName(key, type.name)
            guard schema.enums?[key] == nil else { throw invalid("duplicate type \(key)") }
            try validateFields(type.fields, schema: schema)
        }
        for (key, sealed) in schema.sealeds ?? [:] {
            try validateName(key, sealed.name)
            guard isLuxoDSLIdentifier(key),
                schema.models[key] == nil, schema.types?[key] == nil, schema.enums?[key] == nil
            else {
                throw invalid("invalid or duplicate sealed type \(key)")
            }
            var cases = Set<String>()
            for variant in sealed.variants {
                try validateMemberName(variant.name, names: &cases)
                guard isLuxoDSLIdentifier(variant.name) else { throw invalid("invalid case \(variant.name)") }
                var fields = Set<String>()
                for field in variant.fields {
                    guard isLuxoDSLIdentifier(field.name) else { throw invalid("invalid sealed field \(field.name)") }
                    try validateMemberName(field.name, names: &fields)
                    try validateReference(field.type, name: field.typeName, schema: schema)
                }
            }
        }
        for (key, api) in schema.apis {
            try validateName(key, api.name)
            guard api.returnType != "Enum" else { throw invalid("API \(api.name) requires a named enum return") }
            try validateReturnType(api, schema: schema)
            var names = Set<String>()
            for param in api.params ?? [] {
                try validateMemberName(param.name, names: &names)
                try validateReference(param.type, name: param.typeName, schema: schema)
            }
        }
    }

    private static func validateName(_ key: String, _ name: String) throws {
        guard !name.isEmpty else { throw invalid("Declaration name must not be empty") }
        guard key.utf8.elementsEqual(name.utf8) else {
            throw invalid("Declaration name \(name) does not match key \(key)")
        }
    }

    private static func validateMemberName(_ name: String, names: inout Set<String>) throws {
        guard !name.isEmpty else { throw invalid("Member name must not be empty") }
        // Generated Swift members and selection dictionaries use canonical String equality.
        guard names.insert(name).inserted else { throw invalid("duplicate name \(name)") }
    }

    private static func validateFields(_ fields: [LuxoField], schema: LuxoSchema) throws {
        var names = Set<String>()
        for field in fields {
            try validateMemberName(field.name, names: &names)
            try validateReference(field.type, name: field.typeName, schema: schema)
        }
    }

    private static func validateReturnType(_ api: LuxoAPI, schema: LuxoSchema) throws {
        guard let type = api.returnType else {
            throw invalid("API \(api.name) must declare a return type")
        }
        guard isDeclaredType(type, schema: schema) else {
            throw invalid("API \(api.name) has an undeclared return type \(type)")
        }
    }

    private static func isDeclaredType(_ type: String, schema: LuxoSchema) -> Bool {
        switch type {
        case "Int", "Float", "String", "Boolean", "DateTime", "Duration", "UUID", "Decimal", "Bytes", "JSON":
            return true
        default:
            return schema.models[type] != nil || schema.types?[type] != nil || schema.enums?[type] != nil
                || schema.sealeds?[type] != nil
        }
    }

    private static func validateReference(_ type: String, name: String?, schema: LuxoSchema) throws {
        switch type {
        case "Enum":
            guard let name, schema.enums?[name] != nil else { throw invalid("Enum requires a declared typeName") }
        case "Sealed":
            guard let name, schema.sealeds?[name] != nil else {
                throw invalid("Sealed requires a declared typeName")
            }
        case "Model":
            guard let name, schema.models[name] != nil || schema.types?[name] != nil else {
                throw invalid("Model requires a declared typeName")
            }
        default:
            guard isDeclaredType(type, schema: schema) else { throw invalid("undeclared type \(type)") }
        }
    }

    private static func invalid(_ message: String) -> LuxoError {
        LuxoError(code: 0, message: message, name: "SchemaError")
    }

    static func generate(_ declaration: LuxoEnum) -> String {
        let entries = zip(declaration.values, caseNames(declaration.values)).map { (raw: $0.0, name: $0.1) }
        var out = "public enum \(declaration.name): RawRepresentable, Codable, Sendable, Hashable {\n"
        for entry in entries { out += "    case \(entry.name)\n" }
        out += "    case unknown(String)\n\n"
        out +=
            "    public static var knownCases: [Self] { [\(entries.map { ".\($0.name)" }.joined(separator: ", "))] }\n"
        out += initializer(entries)
        out += rawValue(entries)
        out += equality(entries)
        out += hashing(entries)
        out += """

                public init(from decoder: Swift.Decoder) throws {
                    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
                }
                public func encode(to encoder: Swift.Encoder) throws {
                    var container = encoder.singleValueContainer()
                    try container.encode(rawValue)
                }
            }


            """
        return out
    }

    private static func initializer(_ entries: [(raw: String, name: String)]) -> String {
        var out = "    public init(rawValue: String) {\n        switch rawValue {\n"
        for entry in entries {
            let text = literal(entry.raw)
            out += "        case \(text) where rawValue.utf8.elementsEqual(\(text).utf8): self = .\(entry.name)\n"
        }
        out += "        default: self = .unknown(rawValue)\n        }\n    }\n"
        return out
    }

    private static func rawValue(_ entries: [(raw: String, name: String)]) -> String {
        var out = "    public var rawValue: String {\n        switch self {\n"
        for entry in entries { out += "        case .\(entry.name): return \(literal(entry.raw))\n" }
        return out + "        case .unknown(let raw): return raw\n        }\n    }\n"
    }

    private static func equality(_ entries: [(raw: String, name: String)]) -> String {
        if entries.isEmpty {
            return """
                    public static func == (lhs: Self, rhs: Self) -> Bool {
                        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
                    }

                """
        }
        let known = entries.map { "(.\($0.name), .\($0.name))" }.joined(separator: ", ")
        return """
                public static func == (lhs: Self, rhs: Self) -> Bool {
                    switch (lhs, rhs) {
                    case \(known): return true
                    case (.unknown(let left), .unknown(let right)): return left.utf8.elementsEqual(right.utf8)
                    default: return false
                    }
                }

            """
    }

    private static func hashing(_ entries: [(raw: String, name: String)]) -> String {
        var out = "    public func hash(into hasher: inout Hasher) {\n        switch self {\n"
        for (index, entry) in entries.enumerated() {
            out += "        case .\(entry.name): hasher.combine(\(index + 1))\n"
        }
        out += "        case .unknown(let raw):\n            hasher.combine(0)\n"
        return out + "            for byte in raw.utf8 { hasher.combine(byte) }\n        }\n    }\n"
    }

    static func caseNames(_ values: [String]) -> [String] {
        let preferred = values.map { $0.lowercased() }
        let counts = Dictionary(grouping: preferred, by: { $0 }).mapValues(\.count)
        let reserved: Set<String> = ["unknown", "init", "self"]
        var occupied = Set(preferred).union(reserved)
        return zip(values, preferred).map { raw, name in
            if counts[name] == 1 && !reserved.contains(name) && validIdentifier(name) { return "`\(name)`" }
            var escaped = "luxo_" + raw.utf8.map { String($0, radix: 16) }.joined(separator: "_")
            while occupied.contains(escaped) { escaped = "_" + escaped }
            occupied.insert(escaped)
            return "`\(escaped)`"
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first, first == 95 || (97...122).contains(first), value != "_" else {
            return false
        }
        return value.utf8.allSatisfy { $0 == 95 || (97...122).contains($0) || (48...57).contains($0) }
    }

    static func literal(_ value: String) -> String {
        if !value.utf8.contains(where: { $0 < 32 || $0 == 127 || $0 == 34 || $0 == 92 }) {
            return "\"\(value)\""
        }
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 0...31, 127: out += "\\u{\(String(scalar.value, radix: 16))}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
