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
        guard offset < input.count, isIdentifierStart(input[offset]) else { return "" }
        offset += 1
        while offset < input.count, isIdentifierPart(input[offset]) { offset += 1 }
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

private func isIdentifierStart(_ byte: UInt8) -> Bool {
    byte == 95 || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
}

private func isIdentifierPart(_ byte: UInt8) -> Bool {
    isIdentifierStart(byte) || (byte >= 48 && byte <= 57)
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
