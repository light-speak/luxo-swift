enum WireIDLimits {
    static let selectionField = 65535
    static let api = 2147483647
    static let parameter = api - 2
}

extension LuxoSchema {
    /// Validate the complete directory before writing generated files.
    func validateIDs() throws {
        for model in models.values {
            try validateFieldIDs(model.fields, owner: "model \(model.name)")
        }
        for type in (types ?? [:]).values {
            try validateFieldIDs(type.fields, owner: "type \(type.name)")
        }
        var seen = Set<Int>()
        for api in apis.values {
            try validateID(api.id, maximum: WireIDLimits.api, seen: &seen, path: "API \(api.name)")
            var params = Set<Int>()
            for param in api.params ?? [] {
                try validateID(
                    param.id, maximum: WireIDLimits.parameter, seen: &params, path: "API \(api.name).\(param.name)")
            }
        }
    }
}

/// Validate once before atomically replacing a transport's value-semantic schema.
func validateRuntimeSchemaIDs(_ schema: [String: APISchema]) throws {
    var seen = Set<Int>()
    for (name, api) in schema {
        try validateID(api.id, maximum: WireIDLimits.api, seen: &seen, path: "API \(name)")
        var params = Set<Int>()
        for param in api.params ?? [] {
            try validateID(
                param.fieldID, maximum: WireIDLimits.parameter, seen: &params, path: "API \(name).\(param.name)")
        }
        try validateFieldIDs(api.fields, owner: "API \(name)")
        for (type, fields) in api.types {
            try validateFieldIDs(fields, owner: "API \(name) type \(type)")
        }
    }
}

private func validateFieldIDs(_ fields: [String: APISchema.SelectionFieldSchema], owner: @autoclosure () -> String)
    throws
{
    var seen = Set<Int>()
    for (name, field) in fields {
        try validateID(field.fieldID, maximum: WireIDLimits.selectionField, seen: &seen, path: "\(owner()).\(name)")
    }
}

private func validateFieldIDs(_ fields: [LuxoField], owner: @autoclosure () -> String) throws {
    var seen = Set<Int>()
    for field in fields {
        try validateID(field.id, maximum: WireIDLimits.selectionField, seen: &seen, path: "\(owner()).\(field.name)")
    }
}

private func validateID(_ id: Int, maximum: Int, seen: inout Set<Int>, path: @autoclosure () -> String) throws {
    guard id > 0 && id <= maximum else {
        throw LuxoError(code: 0, message: "\(path()): ID must be from 1 to \(maximum)", name: "ConfigError")
    }
    guard seen.insert(id).inserted else {
        throw LuxoError(code: 0, message: "\(path()): duplicate ID \(id)", name: "ConfigError")
    }
}
