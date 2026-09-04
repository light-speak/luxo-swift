import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Generates typed Swift client from Luxo schema introspection.
///
/// Usage:
///   let codegen = LuxoCodegen(endpoint: "http://localhost:4000/luvia", introspectionKey: "KEY")
///   try await codegen.generate(outputDir: "Sources/Generated", packageName: "LuxoGenerated")
///
/// Generates:
///   - Models.swift — Codable structs for all models
///   - Client.swift — Typed API methods with async/await
///   - SelectHints.swift — Pre-computed field hints (if analyze was run)
public final class LuxoCodegen {
    private let endpoint: URL
    private let key: String
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    public init(endpoint: String, introspectionKey: String) throws {
        self.endpoint = try validatedCodegenURL(endpoint)
        self.key = introspectionKey
        self.fetch = { request in try await URLSession.shared.data(for: request) }
    }

    init(
        endpoint: String,
        introspectionKey: String,
        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) throws {
        self.endpoint = try validatedCodegenURL(endpoint)
        self.key = introspectionKey
        self.fetch = fetch
    }

    /// Fetch schema and generate Swift files.
    public func generate(outputDir: String, packageName: String = "LuxoGenerated") async throws {
        // Fetch schema
        let schema = try await fetchSchema()

        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Generate Models.swift
        let modelsCode = generateModels(schema)
        try modelsCode.write(toFile: "\(outputDir)/Models.swift", atomically: true, encoding: .utf8)

        // Generate Decoders.swift
        let decodersCode = generateDecoders(schema)
        try decodersCode.write(toFile: "\(outputDir)/Decoders.swift", atomically: true, encoding: .utf8)

        // Generate Schema.swift
        let schemaCode = generateSchema(schema)
        try schemaCode.write(toFile: "\(outputDir)/Schema.swift", atomically: true, encoding: .utf8)

        // Generate Client.swift
        let clientCode = generateClient(schema)
        try clientCode.write(toFile: "\(outputDir)/Client.swift", atomically: true, encoding: .utf8)

        print("[luxo] Generated Swift client → \(outputDir)/")
    }

    private func fetchSchema() async throws -> LuxoSchema {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LuxoError(code: 0, message: "invalid introspection URL", name: "ConfigError")
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "$schema", value: nil))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw LuxoError(code: 0, message: "invalid introspection URL", name: "ConfigError")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-Introspection-Key")

        let (data, response) = try await fetch(request)
        if let response = response as? HTTPURLResponse,
            !(200..<300).contains(response.statusCode)
        {
            throw LuxoError(
                code: response.statusCode,
                message: "schema introspection failed with HTTP \(response.statusCode)",
                name: "IntrospectionError"
            )
        }
        return try JSONDecoder().decode(LuxoSchema.self, from: data)
    }

    private func resolveFieldType(
        _ field: LuxoField,
        schema: LuxoSchema,
        usages: [String: TypeUsage],
        input: Bool = false
    ) -> String {
        let tn = field.typeName ?? field.type
        let isList = field.isList ?? false

        // Check enum
        if schema.enums?[tn] != nil { return isList ? "[\(tn)]" : tn }
        // Check model
        if schema.models[tn] != nil {
            let name = input ? inputTypeName(tn, usages: usages) : tn
            return isList ? "[\(name)]" : name
        }
        // Check type decl
        if schema.types?[tn] != nil {
            let name = input ? inputTypeName(tn, usages: usages) : tn
            return isList ? "[\(name)]" : name
        }

        let base = mapType(field.type, nullable: false, list: false)
        return isList ? "[\(base)]" : base
    }

    private func resolveParamType(
        _ param: LuxoParam,
        schema: LuxoSchema,
        usages: [String: TypeUsage],
        nullable: Bool
    ) -> String {
        let typeName = param.typeName ?? param.type
        let structured = schema.models[typeName] != nil || schema.types?[typeName] != nil
        let resolved =
            structured
            ? inputTypeName(typeName, usages: usages)
            : schema.enums?[typeName] != nil ? typeName : param.type
        return mapType(resolved, nullable: nullable, list: param.isList ?? false)
    }

    private func hasInputUsage(_ usage: TypeUsage) -> Bool {
        usage == .input || usage == .inputOutput
    }

    private func hasOutputUsage(_ usage: TypeUsage) -> Bool {
        usage == .output || usage == .inputOutput
    }

    private func inputTypeName(_ name: String, usages: [String: TypeUsage]) -> String {
        usages[name] == .inputOutput ? "\(name)Input" : name
    }

    private func mergeUsage(_ current: TypeUsage, _ next: TypeUsage) -> TypeUsage {
        if current == .unused { return next }
        if current == next || current == .inputOutput { return current }
        return .inputOutput
    }

    /// Supports older schema snapshots that do not carry explicit usage metadata.
    private func inferTypeUsages(_ schema: LuxoSchema) -> [String: TypeUsage] {
        var fields: [String: [LuxoField]] = [:]
        var declared: [String: TypeUsage?] = [:]
        for model in schema.models.values {
            fields[model.name] = model.fields
            declared[model.name] = model.usage
        }
        if let types = schema.types {
            for type in types.values {
                fields[type.name] = type.fields
                declared[type.name] = type.usage
            }
        }

        var usages = Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, TypeUsage.unused) })
        var visited: Set<String> = []
        func mark(_ name: String?, _ usage: TypeUsage) {
            guard let name, let nestedFields = fields[name] else { return }
            let visit = "\(usage.rawValue):\(name)"
            guard visited.insert(visit).inserted else { return }
            usages[name] = mergeUsage(usages[name] ?? .unused, usage)
            for field in nestedFields {
                mark(field.typeName ?? field.type, usage)
            }
        }

        for api in schema.apis.values {
            mark(api.returnType, .output)
            for param in api.params ?? [] { mark(param.typeName ?? param.type, .input) }
        }
        for (name, usage) in declared {
            if usage == .input || usage == .inputOutput { mark(name, .input) }
            if usage == .output || usage == .inputOutput { mark(name, .output) }
            if usage == nil, usages[name] == .unused { mark(name, .output) }
        }
        return usages
    }

    private func isStructuredParam(_ param: LuxoParam, schema: LuxoSchema) -> Bool {
        let typeName = param.typeName ?? param.type
        return schema.models[typeName] != nil || schema.types?[typeName] != nil
    }

    func generateModels(_ schema: LuxoSchema) -> String {
        let usages = inferTypeUsages(schema)
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"

        // Enums — String-based enum
        if let enums = schema.enums {
            for (_, e) in enums.sorted(by: { $0.key < $1.key }) {
                out += "public enum \(e.name): String, Codable, Sendable, CaseIterable {\n"
                for v in e.values {
                    out += "    case \(v.lowercased()) = \"\(v)\"\n"
                }
                out += "}\n\n"
            }
        }

        // Type declarations (non-DB)
        if let types = schema.types {
            for (_, t) in types.sorted(by: { $0.key < $1.key }) {
                let usage = usages[t.name] ?? .unused
                if hasOutputUsage(usage) {
                    out += generateModelDeclaration(
                        name: t.name,
                        fields: t.fields,
                        schema: schema,
                        usages: usages,
                        output: true
                    )
                }
                if hasInputUsage(usage) {
                    out += generateModelDeclaration(
                        name: inputTypeName(t.name, usages: usages),
                        fields: t.fields,
                        schema: schema,
                        usages: usages,
                        output: false
                    )
                }
            }
        }

        // Models
        for (_, model) in schema.models.sorted(by: { $0.key < $1.key }) {
            let usage = usages[model.name] ?? .unused
            if hasOutputUsage(usage) {
                out += generateModelDeclaration(
                    name: model.name,
                    fields: model.fields,
                    schema: schema,
                    usages: usages,
                    output: true
                )
            }
            if hasInputUsage(usage) {
                out += generateModelDeclaration(
                    name: inputTypeName(model.name, usages: usages),
                    fields: model.fields,
                    schema: schema,
                    usages: usages,
                    output: false
                )
            }
        }
        return out
    }

    private func generateModelDeclaration(
        name: String,
        fields: [LuxoField],
        schema: LuxoSchema,
        usages: [String: TypeUsage],
        output: Bool
    ) -> String {
        var out = "public struct \(name): Codable, Sendable {\n"
        for field in fields {
            let base = resolveFieldType(field, schema: schema, usages: usages, input: !output)
            let value = field.nullable ?? false ? "\(base)?" : base
            out += "    public let \(field.name): \(output ? "Selected<\(value)>" : value)\n"
        }
        if !fields.isEmpty { out += "\n" }
        let parameters = fields.map { field -> String in
            let base = resolveFieldType(field, schema: schema, usages: usages, input: !output)
            let value = field.nullable ?? false ? "\(base)?" : base
            if output { return "\(field.name): Selected<\(value)> = .unselected" }
            return "\(field.name): \(value)\((field.nullable ?? false) ? " = nil" : "")"
        }.joined(separator: ", ")
        out += "    public init(\(parameters)) {\n"
        for field in fields { out += "        self.\(field.name) = \(field.name)\n" }
        out += "    }\n"
        out += "}\n\n"
        return out
    }

    func generateClient(_ schema: LuxoSchema) -> String {
        let usages = inferTypeUsages(schema)
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"
        out += "public final class LuxoGeneratedClient {\n"
        out += "    private let transport: Transport\n"
        out += "    private var useBinary: Bool = false\n\n"
        out += "    private func jsonValue<T: Encodable>(_ value: T) throws -> Any {\n"
        out += "        let data = try JSONEncoder().encode(value)\n"
        out += "        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])\n"
        out += "    }\n\n"
        out += "    public init(transport: Transport) {\n"
        out += "        self.transport = transport\n"
        out += "    }\n\n"
        out += "    /// Enable binary mode with schema registration.\n"
        out += "    public func enableBinary() {\n"
        out += "        useBinary = true\n"
        out += "        transport.setMode(.binary)\n"
        out += "        transport.setSchema(LUXO_SCHEMA)\n"
        out += "    }\n\n"

        for (_, api) in schema.apis.sorted(by: { $0.key < $1.key }) {
            let returnType = api.returnType ?? "Void"
            let baseReturn = mapType(returnType, nullable: false, list: api.returnList ?? false)
            let swiftReturn =
                api.paginated ?? false ? "Page<\(mapType(returnType, nullable: false, list: false))>" : baseReturn
            let hasStructuredReturn = schema.models[returnType] != nil || schema.types?[returnType] != nil

            // Build params — page/pageSize always optional for list APIs
            let isPaginated = api.paginated ?? false
            let paginationNames: Set<String> = ["page", "pageSize"]
            var paramList = ""
            var paramSetup = ""
            if let params = api.params {
                let parts = params.map { p in
                    let forceOptional = isPaginated && paginationNames.contains(p.name)
                    let nullable = p.nullable ?? false
                    let hasDefault = p.hasDefault ?? false
                    let type = resolveParamType(p, schema: schema, usages: usages, nullable: false)
                    if nullable && hasDefault {
                        return "\(p.name): LuxoOptional<\(type)> = .absent"
                    }
                    if forceOptional || hasDefault {
                        return "\(p.name): \(type)? = nil"
                    }
                    return "\(p.name): \(type)\(nullable ? "?" : "")"
                }
                paramList = parts.joined(separator: ", ")
                paramSetup = "        var callParams: [String: Any] = [:]\n"
                for p in params {
                    let forceOptional = isPaginated && paginationNames.contains(p.name)
                    let nullable = p.nullable ?? false
                    let hasDefault = p.hasDefault ?? false
                    let structured = isStructuredParam(p, schema: schema)
                    if nullable && hasDefault {
                        paramSetup += "        switch \(p.name) {\n"
                        paramSetup += "        case .absent: break\n"
                        if structured {
                            paramSetup += "        case .present(let value):\n"
                            paramSetup +=
                                "            if let value { callParams[\"\(p.name)\"] = try jsonValue(value) } else { callParams[\"\(p.name)\"] = NSNull() }\n"
                        } else {
                            paramSetup +=
                                "        case .present(let value): callParams[\"\(p.name)\"] = value.map { $0 as Any } ?? NSNull()\n"
                        }
                        paramSetup += "        }\n"
                    } else if forceOptional || hasDefault {
                        let value = structured ? "try jsonValue(\(p.name))" : p.name
                        paramSetup += "        if let \(p.name) { callParams[\"\(p.name)\"] = \(value) }\n"
                    } else if nullable {
                        if structured {
                            paramSetup +=
                                "        if let \(p.name) { callParams[\"\(p.name)\"] = try jsonValue(\(p.name)) } else { callParams[\"\(p.name)\"] = NSNull() }\n"
                        } else {
                            paramSetup +=
                                "        callParams[\"\(p.name)\"] = \(p.name).map { $0 as Any } ?? NSNull()\n"
                        }
                    } else {
                        let value = structured ? "try jsonValue(\(p.name))" : p.name
                        paramSetup += "        callParams[\"\(p.name)\"] = \(value)\n"
                    }
                }
            }
            if hasStructuredReturn {
                if !paramList.isEmpty { paramList += ", " }
                paramList += "select: String? = nil"
                if paramSetup.isEmpty {
                    paramSetup = "        var callParams: [String: Any] = [:]\n"
                }
                paramSetup += "        if let select { callParams[\"$select\"] = select }\n"
            }
            if isPaginated {
                let existingNames = Set(api.params?.map(\.name) ?? [])
                for name in ["page", "pageSize"] where !existingNames.contains(name) {
                    if !paramList.isEmpty { paramList += ", " }
                    paramList += "\(name): Int? = nil"
                    if paramSetup.isEmpty {
                        paramSetup = "        var callParams: [String: Any] = [:]\n"
                    }
                    paramSetup += "        if let \(name) { callParams[\"\(name)\"] = \(name) }\n"
                }
                if !paramList.isEmpty { paramList += ", " }
                paramList += "filters: [LuxoFilter]? = nil, sorters: [LuxoSorter]? = nil"
                if paramSetup.isEmpty {
                    paramSetup = "        var callParams: [String: Any] = [:]\n"
                }
                paramSetup += "        if let filters { callParams[\"$filters\"] = filters.map(\\.jsonObject) }\n"
                paramSetup += "        if let sorters { callParams[\"$sorters\"] = sorters.map(\\.jsonObject) }\n"
            }

            if api.stream ?? false {
                let methodName = "subscribe" + api.name.prefix(1).uppercased() + api.name.dropFirst()
                if !paramList.isEmpty { paramList += ", " }
                paramList += "handler: @escaping (\(swiftReturn)) -> Void"
                out += "    public func \(methodName)(\(paramList)) async throws -> () -> Void {\n"
                out += paramSetup
                let params = paramSetup.isEmpty ? "nil" : "callParams"
                out +=
                    "        return try await transport.subscribe(\"\(api.name)\", params: \(params)) { [weak self] value in\n"
                out += "            guard let self else { return }\n"
                out += "            if self.useBinary, let rawData = value as? Data {\n"
                if hasStructuredReturn {
                    if api.returnList ?? false {
                        out +=
                            "                guard let decoded = try? decodeColumnar\(returnType)(rawData) else { return }\n"
                        out += "                handler(decoded)\n"
                    } else {
                        out += "                var decoder = Decoder(rawData)\n"
                        out +=
                            "                guard let decoded = try? decode\(returnType)(&decoder) else { return }\n"
                        out += "                handler(decoded)\n"
                    }
                } else if returnType == "JSON" && !(api.returnList ?? false) {
                    out += "                var decoder = Decoder(rawData)\n"
                    out +=
                        "                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: decoder.readBytes()) else { return }\n"
                    out += "                handler(decoded)\n"
                } else {
                    out += "                var decoder = Decoder(rawData)\n"
                    out +=
                        "                handler(\(scalarDecodeExpression(returnType, list: api.returnList ?? false)))\n"
                }
                out += "                return\n"
                out += "            }\n"
                out +=
                    "            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),\n"
                out +=
                    "                  let decoded = try? JSONDecoder().decode(\(swiftReturn).self, from: data) else { return }\n"
                out += "            handler(decoded)\n"
                out += "        }\n"
                out += "    }\n\n"
                continue
            }

            out += "    public func \(api.name)(\(paramList)) async throws -> \(swiftReturn) {\n"
            if paramSetup.isEmpty {
                out += "        let result = try await transport.call(\"\(api.name)\")\n"
            } else {
                out += paramSetup
                out += "        let result = try await transport.call(\"\(api.name)\", params: callParams)\n"
            }

            if returnType == "Void" {
                out += "        return ()\n"
            } else if hasStructuredReturn {
                out += "        if useBinary, let rawData = result as? Data {\n"
                if api.paginated ?? false {
                    out += "            return try decodePaginated\(returnType)(rawData)\n"
                } else if api.returnList ?? false {
                    out += "            return try decodeColumnar\(returnType)(rawData)\n"
                } else {
                    out += "            var decoder = Decoder(rawData)\n"
                    out += "            return try decode\(returnType)(&decoder)\n"
                }
                out += "        }\n"
            } else {
                out += "        if useBinary, let rawData = result as? Data {\n"
                out += "            var decoder = Decoder(rawData)\n"
                out += "            return \(scalarDecodeExpression(returnType, list: api.returnList ?? false))\n"
                out += "        }\n"
            }

            if returnType != "Void" {
                out +=
                    "        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])\n"
                out += "        return try JSONDecoder().decode(\(swiftReturn).self, from: data)\n"
            }
            out += "    }\n\n"
        }

        out += "}\n"
        return out
    }

    // MARK: - Binary Decoders

    func generateDecoders(_ schema: LuxoSchema) -> String {
        let usages = inferTypeUsages(schema)
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"
        out +=
            "private func decodeEnum<T: RawRepresentable>(_ type: T.Type, raw: String, field: String) throws -> T where T.RawValue == String {\n"
        out += "    guard let value = T(rawValue: raw) else {\n"
        out +=
            "        throw LuxoError(code: 0, message: \"invalid enum value \\(raw) for \\(field)\", name: \"DecodeError\")\n"
        out += "    }\n"
        out += "    return value\n"
        out += "}\n\n"

        if let types = schema.types {
            for (_, type) in types.sorted(by: { $0.key < $1.key }) where hasOutputUsage(usages[type.name] ?? .unused) {
                out += generateDecoder(name: type.name, fields: type.fields, schema: schema, usages: usages)
            }
        }
        for (_, model) in schema.models.sorted(by: { $0.key < $1.key })
        where hasOutputUsage(usages[model.name] ?? .unused) {
            out += generateDecoder(name: model.name, fields: model.fields, schema: schema, usages: usages)
        }

        return out
    }

    private func generateDecoder(
        name: String,
        fields: [LuxoField],
        schema: LuxoSchema,
        usages: [String: TypeUsage]
    ) -> String {
        var out = "public func decode\(name)(_ decoder: inout Decoder) throws -> \(name) {\n"
        for field in fields {
            let base = resolveFieldType(field, schema: schema, usages: usages)
            let value = field.nullable ?? false ? "\(base)?" : base
            out += "    var _\(field.name): Selected<\(value)> = .unselected\n"
        }
        out += "    decoder.skipArenaHeader()\n"
        out += "    while true {\n"
        out += "        let fieldID = decoder.nextField()\n"
        out += "        if fieldID == 0 { break }\n"
        out += "        switch fieldID {\n"
        for field in fields {
            out += "        case \(field.id): _\(field.name) = .value(\(rowRead(field, schema: schema)))\n"
        }
        out +=
            "        default: throw LuxoError(code: 0, message: \"unknown \(name) field ID \\(fieldID)\", name: \"DecodeError\")\n"
        out += "        }\n"
        out += "    }\n"
        out += "    if let error = decoder.error { throw LuxoError(code: 0, message: error, name: \"DecodeError\") }\n"
        out += "    return \(name)(\n"
        out += fields.map { "        \($0.name): _\($0.name)" }.joined(separator: ",\n")
        out += "\n    )\n"
        out += "}\n\n"
        out += generateColumnarDecoder(name: name, fields: fields, schema: schema, usages: usages, paginated: false)
        out += generateColumnarDecoder(name: name, fields: fields, schema: schema, usages: usages, paginated: true)
        return out
    }

    private func rowRead(_ field: LuxoField, schema: LuxoSchema) -> String {
        let typeName = field.typeName ?? field.type
        let nested = isNested(field, schema: schema)
        let nullable = field.nullable ?? false
        if field.isList ?? false {
            if nested { return "try decoder.readArray { d in try decode\(typeName)(&d) }" }
            if field.type == "Enum" {
                return
                    "try decoder.readArray { d in try decodeEnum(\(typeName).self, raw: d.readString(), field: \"\(field.name)\") }"
            }
            let item = scalarRead(field.type, decoder: "d")
            let prefix = field.type == "JSON" ? "try " : ""
            return "\(prefix)decoder.readArray { d in \(item) }"
        }
        if nested {
            return nullable
                ? "try decoder.readNullable { d in try decode\(typeName)(&d) }"
                : "try decode\(typeName)(&decoder)"
        }
        if nullable {
            switch field.type {
            case "Int": return "decoder.readIntPtr().map(Int.init)"
            case "Float": return "decoder.readFloatPtr()"
            case "String", "Decimal": return "decoder.readStringPtr()"
            case "Boolean": return "decoder.readBoolPtr()"
            case "UUID": return "decoder.readUUIDPtr()"
            case "Bytes": return "decoder.readNullable { $0.readBytes() }"
            case "JSON":
                return "try decoder.readNullable { d in try JSONDecoder().decode(JSONValue.self, from: d.readBytes()) }"
            case "DateTime": return "decoder.readDateTimePtr()"
            case "Duration": return "decoder.readIntPtr()"
            case "Enum":
                return
                    "try decoder.readStringPtr().map { try decodeEnum(\(typeName).self, raw: $0, field: \"\(field.name)\") }"
            default: return "decoder.readStringPtr()"
            }
        }
        if field.type == "Enum" {
            return "try decodeEnum(\(typeName).self, raw: decoder.readString(), field: \"\(field.name)\")"
        }
        return scalarRead(field.type, decoder: "decoder")
    }

    private func scalarRead(_ type: String, decoder: String) -> String {
        switch type {
        case "Int": return "Int(\(decoder).readSvarint())"
        case "Float": return "\(decoder).readFixed64()"
        case "Boolean": return "\(decoder).readBool()"
        case "UUID": return "\(decoder).readUUID()"
        case "Bytes": return "\(decoder).readBytes()"
        case "JSON": return "try JSONDecoder().decode(JSONValue.self, from: \(decoder).readBytes())"
        case "DateTime": return "\(decoder).readDateTime()"
        case "Duration": return "\(decoder).readSvarint()"
        default: return "\(decoder).readString()"
        }
    }

    private func generateColumnarDecoder(
        name: String,
        fields: [LuxoField],
        schema: LuxoSchema,
        usages: [String: TypeUsage],
        paginated: Bool
    ) -> String {
        let function = paginated ? "decodePaginated\(name)" : "decodeColumnar\(name)"
        let result = paginated ? "Page<\(name)>" : "[\(name)]"
        var out = "public func \(function)(_ data: Data) throws -> \(result) {\n"
        out += "    var decoder = ColumnarDecoder(data: data)\n"
        for field in fields {
            out += "    var _\(field.name): \(columnType(field, schema: schema, usages: usages))?\n"
        }
        out += "    while decoder.nextColumn() {\n"
        out += "        switch decoder.fieldID {\n"
        for field in fields {
            out += "        case \(field.id): _\(field.name) = \(columnRead(field, schema: schema))\n"
        }
        out +=
            "        default: throw LuxoError(code: 0, message: \"unknown \(name) column ID \\(decoder.fieldID)\", name: \"DecodeError\")\n"
        out += "        }\n"
        out += "    }\n"
        out += "    if let error = decoder.error { throw LuxoError(code: 0, message: error, name: \"DecodeError\") }\n"
        out += "    var items: [\(name)] = []\n"
        out += "    items.reserveCapacity(decoder.count)\n"
        out += "    for i in 0..<decoder.count {\n"
        for field in fields {
            let base = resolveFieldType(field, schema: schema, usages: usages)
            let value = field.nullable ?? false ? "\(base)?" : base
            out += "        let \(field.name): Selected<\(value)> = \(columnValue(field, schema: schema))\n"
        }
        out += "        items.append(\(name)(\n"
        out += fields.map { "            \($0.name): \($0.name)" }.joined(separator: ",\n")
        out += "\n        ))\n"
        out += "    }\n"
        if paginated {
            out +=
                "    let page = Page<\(name)>(items: items, total: Int(decoder.readSvarint()), page: Int(decoder.readSvarint()), pageSize: Int(decoder.readSvarint()))\n"
            out +=
                "    if let error = decoder.error { throw LuxoError(code: 0, message: error, name: \"DecodeError\") }\n"
            out += "    return page\n"
        } else {
            out += "    return items\n"
        }
        out += "}\n\n"
        return out
    }

    private func isNested(_ field: LuxoField, schema: LuxoSchema) -> Bool {
        let name = field.typeName ?? field.type
        return (field.relation ?? false) || schema.models[name] != nil || schema.types?[name] != nil
    }

    private func columnType(
        _ field: LuxoField,
        schema: LuxoSchema,
        usages: [String: TypeUsage]
    ) -> String {
        if isNested(field, schema: schema) || (field.isList ?? false) || field.type == "Bytes" || field.type == "JSON" {
            return (field.nullable ?? false) && !(field.isList ?? false) ? "[Data?]" : "[Data]"
        }
        let base = resolveFieldType(field, schema: schema, usages: usages)
        return field.nullable ?? false ? "[\(base)?]" : "[\(base)]"
    }

    private func columnRead(_ field: LuxoField, schema: LuxoSchema) -> String {
        if isNested(field, schema: schema) || (field.isList ?? false) || field.type == "Bytes" || field.type == "JSON" {
            return (field.nullable ?? false) && !(field.isList ?? false)
                ? "decoder.readColumnBytesPtr()"
                : "decoder.readColumnBytes()"
        }
        switch field.type {
        case "Int":
            return field.nullable ?? false
                ? "decoder.readColumnIntPtr().map { $0.map(Int.init) }"
                : "decoder.readColumnInt().map(Int.init)"
        case "Duration": return field.nullable ?? false ? "decoder.readColumnIntPtr()" : "decoder.readColumnInt()"
        case "Float": return field.nullable ?? false ? "decoder.readColumnFloatPtr()" : "decoder.readColumnFloat()"
        case "Boolean": return field.nullable ?? false ? "decoder.readColumnBoolPtr()" : "decoder.readColumnBool()"
        case "DateTime":
            return field.nullable ?? false ? "decoder.readColumnDateTimePtr()" : "decoder.readColumnDateTime()"
        case "UUID": return field.nullable ?? false ? "decoder.readColumnUUIDPtr()" : "decoder.readColumnUUID()"
        case "Enum":
            let name = field.typeName ?? field.type
            return field.nullable ?? false
                ? "try decoder.readColumnStringPtr().map { try $0.map { try decodeEnum(\(name).self, raw: $0, field: \"\(field.name)\") } }"
                : "try decoder.readColumnString().map { try decodeEnum(\(name).self, raw: $0, field: \"\(field.name)\") }"
        default: return field.nullable ?? false ? "decoder.readColumnStringPtr()" : "decoder.readColumnString()"
        }
    }

    private func columnValue(_ field: LuxoField, schema: LuxoSchema) -> String {
        let column = "_\(field.name)"
        let typeName = field.typeName ?? field.type
        if isNested(field, schema: schema) {
            if field.isList ?? false {
                return "try \(column).map { .value(try decodeColumnar\(typeName)($0[i])) } ?? .unselected"
            }
            if field.nullable ?? false {
                return
                    "try \(column).map { values in .value(try values[i].map { data in var d = Decoder(data); return try decode\(typeName)(&d) }) } ?? .unselected"
            }
            return
                "try \(column).map { values in var d = Decoder(values[i]); return .value(try decode\(typeName)(&d)) } ?? .unselected"
        }
        if field.isList ?? false {
            let item =
                field.type == "Enum"
                ? "try decodeEnum(\(typeName).self, raw: item.readString(), field: \"\(field.name)\")"
                : scalarRead(field.type, decoder: "item")
            let throwing = field.type == "Enum" || field.type == "JSON"
            return
                "\(throwing ? "try " : "")\(column).map { data in var d = Decoder(data[i]); return .value(\(throwing ? "try " : "")d.readArray { item in \(item) }) } ?? .unselected"
        }
        if field.type == "JSON" {
            let decode = "try JSONDecoder().decode(JSONValue.self, from: data)"
            if field.nullable ?? false {
                return "try \(column).map { values in .value(try values[i].map { data in \(decode) }) } ?? .unselected"
            }
            return
                "try \(column).map { values in .value(try JSONDecoder().decode(JSONValue.self, from: values[i])) } ?? .unselected"
        }
        return "\(column).map { .value($0[i]) } ?? .unselected"
    }

    // MARK: - Schema Map

    func generateSchema(_ schema: LuxoSchema) -> String {
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"
        let selectionTypes =
            (schema.types?.values.map { ($0.name, $0.fields) } ?? [])
            + schema.models.values.map { ($0.name, $0.fields) }
        for (name, fields) in selectionTypes.sorted(by: { $0.0 < $1.0 }) {
            let values = fields.map { field in
                let typeName = field.typeName ?? field.type
                let nested = isNested(field, schema: schema) ? ", typeName: \"\(typeName)\"" : ""
                return "\"\(field.name)\": .init(fieldID: \(field.id)\(nested))"
            }.joined(separator: ", ")
            out += "private let \(selectionFieldsName(name)): [String: APISchema.SelectionFieldSchema] = [\(values)]\n"
        }
        if !selectionTypes.isEmpty { out += "\n" }
        out += "private let LUXO_SELECTION_TYPES: [String: [String: APISchema.SelectionFieldSchema]] = [\n"
        for (name, _) in selectionTypes.sorted(by: { $0.0 < $1.0 }) {
            out += "    \"\(name)\": \(selectionFieldsName(name)),\n"
        }
        out += "]\n\n"
        out += "public let LUXO_SCHEMA: [String: APISchema] = [\n"

        for (_, api) in schema.apis.sorted(by: { $0.key < $1.key }) {
            var paramsStr = "nil"
            if let params = api.params, !params.isEmpty {
                let paramItems = params.map { p in
                    let isList = p.isList ?? false
                    return
                        "APISchema.ParamSchema(fieldID: \(p.id), name: \"\(p.name)\", type: \"\(p.type)\", isList: \(isList), nullable: \(p.nullable ?? false))"
                }
                paramsStr = "[\(paramItems.joined(separator: ", "))]"
            }
            let returnType = api.returnType
            let structuredTypeName = returnType.flatMap { name in
                schema.models[name] != nil || schema.types?[name] != nil ? name : nil
            }
            let fieldsStr = structuredTypeName.map(selectionFieldsName) ?? "[:]"
            let typesStr = structuredTypeName == nil ? "[:]" : "LUXO_SELECTION_TYPES"
            out +=
                "    \"\(api.name)\": APISchema(id: \(api.id), params: \(paramsStr), fields: \(fieldsStr), types: \(typesStr)),\n"
        }

        out += "]\n"
        return out
    }

    private func selectionFieldsName(_ typeName: String) -> String {
        "LUXO_SELECTION_FIELDS_\(typeName)"
    }

    private func mapType(_ type: String, nullable: Bool, list: Bool) -> String {
        let base: String
        switch type {
        case "Int": base = "Int"
        case "Float": base = "Double"
        case "String": base = "String"
        case "Boolean": base = "Bool"
        // DateTime surfaces as an RFC3339/ISO-8601 String in both JSON and binary
        // modes (Go emits an RFC3339 string in JSON, svarint(unix seconds) in binary
        // which the decoder converts to the same string). Matches TS/Dart/Kotlin SDKs.
        case "DateTime": base = "String"
        // Duration surfaces as raw nanoseconds (Int64) in both modes (Go emits a
        // nanosecond number in JSON, svarint(nanos) in binary). Matches other SDKs.
        case "Duration": base = "Int64"
        case "UUID": base = "UUID"
        case "Decimal": base = "String"
        case "Bytes": base = "Data"
        case "JSON": base = "JSONValue"
        default: base = type
        }

        let result = list ? "[\(base)]" : base
        return nullable ? "\(result)?" : result
    }

    private func scalarDecodeExpression(_ type: String, list: Bool) -> String {
        let value: String
        switch type {
        case "Int": value = "Int(decoder.readSvarint())"
        case "Float": value = "decoder.readFixed64()"
        case "Boolean": value = "decoder.readBool()"
        case "DateTime": value = "decoder.readDateTime()"
        case "Duration": value = "decoder.readSvarint()"
        case "UUID": value = "decoder.readUUID()"
        case "Bytes": value = "decoder.readBytes()"
        case "JSON": value = "try JSONDecoder().decode(JSONValue.self, from: decoder.readBytes())"
        default: value = "decoder.readString()"
        }
        if list {
            return "try decoder.readArray { decoder in \(value) }"
        }
        return value
    }
}

private func validatedCodegenURL(_ value: String) throws -> URL {
    guard let url = URL(string: value),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        url.host != nil
    else {
        throw LuxoError(code: 0, message: "invalid introspection URL: \(value)", name: "ConfigError")
    }
    return url
}
