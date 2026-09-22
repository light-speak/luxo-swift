import Foundation

/// Enum metadata is validated once before writing generated files.
enum SwiftEnumCodegen {
    static func validate(_ schema: LuxoSchema) throws {
        for (key, value) in schema.enums ?? [:] {
            guard key.utf8.elementsEqual(value.name.utf8), !value.values.isEmpty,
                Set(value.values.map { Data($0.utf8) }).count == value.values.count
            else { throw invalid("enum \(key) requires a matching name and distinct members") }
        }
        let fields = schema.models.values.flatMap(\.fields) + (schema.types?.values.flatMap(\.fields) ?? [])
        for field in fields { try validateReference(field.type, name: field.typeName, schema: schema) }
        for api in schema.apis.values {
            guard api.returnType != "Enum" else { throw invalid("API \(api.name) requires a named enum return") }
            for param in api.params ?? [] {
                try validateReference(param.type, name: param.typeName, schema: schema)
            }
        }
    }

    private static func validateReference(_ type: String, name: String?, schema: LuxoSchema) throws {
        guard type == "Enum" else { return }
        guard let name, schema.enums?[name] != nil else { throw invalid("Enum requires a declared typeName") }
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

    private static func caseNames(_ values: [String]) -> [String] {
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

    private static func literal(_ value: String) -> String {
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
