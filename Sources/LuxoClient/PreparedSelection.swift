import Foundation

final class SelectionSchemaIdentity: Sendable {}

/// Immutable syntax and optional schema-bound bytes; request encoding needs no cache lock.
public struct PreparedSelection: Sendable {
    public let text: String
    private let selected: [SelectedField]
    private let identity: SelectionSchemaIdentity?
    private let bytes: Data?

    public init(_ text: String, schema: APISchema? = nil) throws {
        let parsed = try SelectionParser(text).parse()
        guard !parsed.isEmpty else { throw selectionConfigError("selection must not be empty") }
        self.text = text
        selected = parsed
        identity = schema?.selectionIdentity
        if let schema {
            bytes = try LuxoBinaryProtocol.encodeSelectionNode(selected, fields: schema.fields, types: schema.types)
        } else {
            bytes = nil
        }
    }

    fileprivate func mask(for schema: APISchema) throws -> Data {
        if identity === schema.selectionIdentity, let bytes { return bytes }
        return try LuxoBinaryProtocol.encodeSelectionNode(selected, fields: schema.fields, types: schema.types)
    }
}

private func selectionConfigError(_ message: String) -> LuxoError {
    LuxoError(code: 0, message: message, name: "ConfigError")
}

fileprivate struct SelectedField: Sendable {
    let name: String
    let children: [SelectedField]?
}

private final class SelectionParser {
    private let input: [UInt8]
    private var offset = 0

    init(_ selection: String) {
        input = Array(selection.utf8)
    }

    func parse() throws -> [SelectedField] {
        let fields = try parseList(nested: false, depth: 0)
        skipSpaces()
        if offset != input.count { throw error("unexpected character") }
        return fields
    }

    private func parseList(nested: Bool, depth: Int) throws -> [SelectedField] {
        if depth >= 32 { throw error("selection depth exceeds 32") }
        var fields: [SelectedField] = []
        var names = Set<String>()
        while true {
            skipSpaces()
            if offset >= input.count || (nested && input[offset] == 125) { break }
            let name = readIdentifier()
            if name.isEmpty { throw error("expected field name") }
            if !names.insert(name).inserted { throw error("duplicate field '\(name)'") }
            skipSpaces()
            let children = try readChildren(name: name, depth: depth)
            fields.append(SelectedField(name: name, children: children))
            skipSpaces()
            if offset >= input.count || input[offset] != 44 { break }
            offset += 1
            skipSpaces()
            if offset >= input.count || (nested && input[offset] == 125) {
                throw error("expected field after ','")
            }
        }
        return fields
    }

    private func readChildren(name: String, depth: Int) throws -> [SelectedField]? {
        guard offset < input.count, input[offset] == 123 else { return nil }
        offset += 1
        let children = try parseList(nested: true, depth: depth + 1)
        if children.isEmpty { throw error("empty selection for '\(name)'") }
        skipSpaces()
        guard offset < input.count, input[offset] == 125 else {
            throw error("missing '}' for '\(name)'")
        }
        offset += 1
        return children
    }

    private func readIdentifier() -> String {
        let start = offset
        while offset < input.count {
            let width = selectionIdentifierWidth(input, at: offset, first: offset == start)
            if width == 0 { break }
            offset += width
        }
        return String(decoding: input[start..<offset], as: UTF8.self)
    }

    private func skipSpaces() {
        while offset < input.count,
            input[offset] == 32 || input[offset] == 9 || input[offset] == 10 || input[offset] == 13
        {
            offset += 1
        }
    }

    private func error(_ message: String) -> LuxoError {
        LuxoError(code: 0, message: "\(message) at position \(offset)", name: "ConfigError")
    }
}

private func selectionIdentifierWidth(_ input: [UInt8], at offset: Int, first: Bool) -> Int {
    let byte = input[offset]
    if byte < 128 {
        return byte == 95 || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || (!first && byte >= 48 && byte <= 57) ? 1 : 0
    }
    // Input is a Swift String's valid UTF-8; offsets only advance by full scalars.
    let width = byte < 224 ? 2 : byte < 240 ? 3 : 4
    var value = UInt32(byte & (width == 2 ? 31 : width == 3 ? 15 : 7))
    for index in 1..<width { value = (value << 6) | UInt32(input[offset + index] & 63) }
    guard let scalar = Unicode.Scalar(value), isLuxoDSLLetter(scalar) else { return 0 }
    return width
}

private func isLuxoDSLLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
    default: false
    }
}

func isLuxoDSLIdentifier(_ name: String) -> Bool {
    var first = true
    for scalar in name.unicodeScalars {
        let value = scalar.value
        if value != 95 && !(value >= 65 && value <= 90) && !(value >= 97 && value <= 122)
            && !(!first && value >= 48 && value <= 57) && !(value >= 128 && isLuxoDSLLetter(scalar))
        {
            return false
        }
        first = false
    }
    return !first
}

extension LuxoBinaryProtocol {
    static func writeFieldMask(
        _ encoder: inout Encoder,
        schema: APISchema,
        selection: String?,
        plan: PreparedSelection? = nil
    ) throws {
        guard !schema.fields.isEmpty else {
            encoder.writeVarint(0)
            return
        }
        guard let selection else {
            throw selectionConfigError("$select is required for structured responses")
        }
        let mask: Data
        if let plan, plan.text == selection {
            mask = try plan.mask(for: schema)
        } else {
            let selected = try SelectionParser(selection).parse()
            guard !selected.isEmpty else {
                throw selectionConfigError("$select is required for structured responses")
            }
            mask = try encodeSelectionNode(selected, fields: schema.fields, types: schema.types)
        }
        encoder.writeVarint(UInt64(mask.count))
        encoder.writeRawBytes(mask)
    }

    fileprivate static func encodeSelectionNode(
        _ selected: [SelectedField],
        fields: [String: APISchema.SelectionFieldSchema],
        types: [String: [String: APISchema.SelectionFieldSchema]]
    ) throws -> Data {
        var fieldMask: [UInt8] = []
        var children: [(fieldID: Int, data: Data)] = []
        for field in selected {
            guard let metadata = fields[field.name] else {
                throw selectionConfigError("unknown selected field: \(field.name)")
            }
            try fieldMaskSet(&fieldMask, fieldID: metadata.fieldID)
            guard let childSelection = field.children else { continue }
            guard let typeName = metadata.typeName, let nestedFields = types[typeName] else {
                throw selectionConfigError("field \(field.name) does not support nested selection")
            }
            children.append(
                (
                    metadata.fieldID,
                    try encodeSelectionNode(
                        childSelection,
                        fields: nestedFields,
                        types: types
                    )
                ))
        }
        var encoder = Encoder()
        encoder.writeVarint(UInt64(fieldMask.count))
        encoder.writeRawBytes(Data(fieldMask))
        for child in children.sorted(by: { $0.fieldID < $1.fieldID }) {
            encoder.writeVarint(UInt64(child.fieldID))
            encoder.writeVarint(UInt64(child.data.count))
            encoder.writeRawBytes(child.data)
        }
        return encoder.data
    }

}
