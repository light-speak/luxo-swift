import Foundation

enum SwiftRequestCodegen {
    static func selectionFactory(api: String, method: String) -> String {
        """
            public static func prepareSelection_\(method)(_ text: String) throws -> PreparedSelection {
                guard let schema = LUXO_SCHEMA["\(api)"] else {
                    throw LuxoError(code: 0, message: "Missing generated selection schema", name: "ConfigError")
                }
                return try PreparedSelection(text, schema: schema)
            }

        """
    }

    private static let pagination = ["page", "pageSize"]
    private static func optional(_ api: LuxoAPI, _ param: LuxoParam) -> Bool {
        param.hasDefault == true || (api.paginated == true && pagination.contains(param.name))
    }
    private static func fields(_ api: LuxoAPI, selection: Bool, type: (LuxoParam) -> String) -> [(String, String)] {
        var result = (api.params ?? []).map { param in
            let base = type(param)
            let value =
                param.nullable == true && param.hasDefault == true
                ? "LuxoOptional<\(base)>"
                : base + (param.nullable == true || optional(api, param) ? "?" : "")
            return (param.name, value)
        }
        if selection { result += [("select", "String?"), ("selectionPlan", "PreparedSelection?")] }
        if api.paginated == true {
            result += [("filters", "[LuxoFilter]?"), ("sorters", "[LuxoSorter]?")]
        }
        return result
    }

    static func invocation(_ api: LuxoAPI, selection: Bool) -> String {
        let args = fields(api, selection: selection, type: { _ in "" }).map { "\($0.0): \($0.0)" }.joined(
            separator: ", ")
        return "_\(api.name)Request(values: .init(\(args)))"
    }

    static func generate(
        _ api: LuxoAPI, selection: Bool, type: (LuxoParam) -> String, jsonSetup: String,
        scalar: (LuxoField, String) -> String
    ) -> String {
        let stored = fields(api, selection: selection, type: type)
        var out = "\nprivate struct _\(api.name)Request: GeneratedRequest {\n    struct Values: Sendable {\n"
        for (name, type) in stored { out += "        let \(name): \(type)\n" }
        out += "    }\n    let values: Values\n    var apiID: Int { \(api.id) }\n"
        if selection {
            out += "    var selection: String? { values.select ?? values.selectionPlan?.text }\n"
            out += "    var selectionPlan: PreparedSelection? { values.selectionPlan }\n"
        }
        if api.paginated == true {
            out +=
                "    var filters: [LuxoFilter]? { values.filters }\n    var sorters: [LuxoSorter]? { values.sorters }\n"
        }
        out += "    func toJSONParameters() throws -> [String: LuxoValue] {\n"
        for (name, type) in stored where name != "selectionPlan" {
            let value = selection && name == "select" ? "selection" : "values.\(name)"
            let annotation =
                api.params?.contains(where: { $0.name == name && $0.type == "Sealed" }) == true
                ? ": " + type : ""
            out += "        let \(name)\(annotation) = \(value)\n"
        }
        out += jsonSetup
        out += "        return \(jsonSetup.isEmpty ? "[:]" : "callParams")\n    }\n"
        out += "    func writeParameters(to encoder: inout Encoder) throws {\n"
        for param in api.params ?? [] {
            let explicitType = param.type == "Sealed" ? stored.first(where: { $0.0 == param.name })?.1 : nil
            out += writeParameter(api, param, explicitType: explicitType, scalar: scalar)
        }
        return out + "    }\n}\n"
    }

    private static func writeParameter(
        _ api: LuxoAPI, _ param: LuxoParam, explicitType: String?,
        scalar: (LuxoField, String) -> String
    ) -> String {
        let tri = param.nullable == true && param.hasDefault == true
        var out = "        do {\n"
        if tri {
            out += "        if case .present(let value) = values.\(param.name) {\n"
        } else if optional(api, param) {
            out += "        if let value = values.\(param.name) {\n"
        } else {
            out += "        let value\(explicitType.map { ": " + $0 } ?? "") = values.\(param.name)\n"
        }
        out += "        encoder.writeVarint(\(param.id))\n"
        let unwrap = param.nullable == true && (tri || !optional(api, param))
        if unwrap {
            let nonNull = param.type == "JSON" && param.isList != true ? ", value != .null" : ""
            out += "        if let value\(nonNull) {\n"
        }
        if param.nullable == true { out += "        encoder.writeBool(true)\n" }
        let field = LuxoField(
            id: param.id, name: param.name, type: param.type, typeName: param.typeName,
            nullable: false, isList: false, relation: false)
        if param.isList == true {
            out += "        try encoder.writeArrayHeader(value.count)\n        for item in value {\n"
        }
        let value = param.isList == true ? "item" : "value"
        out +=
            param.type == "Model"
            ? "        try encoder.writeDelimited { encoder in try \(value).writeLuxo(to: &encoder) }\n"
            : scalar(field, value)
        if param.isList == true { out += "        }\n" }
        if unwrap { out += "        } else { encoder.writeBool(false) }\n" }
        if optional(api, param) { out += "        }\n" }
        return out + "        }\n"
    }
}
