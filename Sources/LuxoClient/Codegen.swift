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
///   - Models.swift — Codable models with immutable recursive references
///   - Client.swift — Typed API methods with async/await
///   - LuxoSelection.json — Build-time symbol catalog for call-site selection
public final class LuxoCodegen {
    private let endpoint: URL
    private let key: String
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    public init(endpoint: String, introspectionKey: String) throws {
        self.endpoint = try validatedCodegenURL(endpoint)
        self.key = introspectionKey
        self.fetch = { request in
            try await URLSession.shared.data(for: request, delegate: IntrospectionRedirectPolicy.shared)
        }
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
        try schema.validateIDs()
        try SwiftEnumCodegen.validate(schema)
        let queries = try SwiftQueryCodegen.generate(schema)

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
        try queries.write(toFile: "\(outputDir)/Queries.swift", atomically: true, encoding: .utf8)
        try generateSelectionManifest(schema, module: packageName)
            .write(to: URL(fileURLWithPath: "\(outputDir)/LuxoSelection.json"))

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

    func resolveFieldType(
        _ field: LuxoField,
        schema: LuxoSchema,
        usages: TypeUsages,
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
        if schema.types?[tn] != nil || schema.sealeds?[tn] != nil {
            let name = input ? inputTypeName(tn, usages: usages) : tn
            return isList ? "[\(name)]" : name
        }

        let base = mapType(field.type, schema: schema, nullable: false, list: false)
        return isList ? "[\(base)]" : base
    }

    private func resolveParamType(
        _ param: LuxoParam,
        schema: LuxoSchema,
        usages: TypeUsages,
        nullable: Bool
    ) -> String {
        let typeName = param.typeName ?? param.type
        let structured =
            schema.models[typeName] != nil || schema.types?[typeName] != nil || schema.sealeds?[typeName] != nil
        let resolved =
            structured
            ? inputTypeName(typeName, usages: usages)
            : schema.enums?[typeName] != nil ? typeName : param.type
        return mapType(resolved, schema: schema, nullable: nullable, list: param.isList ?? false)
    }

    private func hasInputUsage(_ usage: TypeUsage) -> Bool {
        usage == .input || usage == .inputOutput
    }

    private func hasOutputUsage(_ usage: TypeUsage) -> Bool {
        usage == .output || usage == .inputOutput
    }

    struct TypeUsages {
        let states: [String: TypeUsage]
        let inputAliases: [String: String]
        subscript(_ name: String) -> TypeUsage? { states[name] }
    }

    // Reserve actual declarations and all preferred input helper names first.
    private func planInputAliases(_ schema: LuxoSchema, states: [String: TypeUsage]) -> [String: String] {
        var collisions: [String] = []
        for (name, usage) in states where usage == .inputOutput {
            let preferred = "\(name)Input"
            if (states[preferred] ?? .unused) != .unused || schema.enums?[preferred] != nil {
                collisions.append(name)
            }
        }
        if collisions.isEmpty { return [:] }
        var reserved: Set<String> = []
        if let enums = schema.enums { reserved.formUnion(enums.keys) }
        for (name, usage) in states {
            if usage != .unused { reserved.insert(name) }
            if usage == .inputOutput { reserved.insert("\(name)Input") }
        }
        var aliases: [String: String] = [:]
        for name in collisions.sorted() {
            let fields = schema.models[name]?.fields ?? schema.types?[name]?.fields ?? []
            let members = Set(fields.map(\.name))
            let base = "Luxo\(name)Input"
            var candidate = base
            var ordinal = 2
            while reserved.contains(candidate) || members.contains(candidate) {
                candidate = "\(base)\(ordinal)"
                ordinal += 1
            }
            reserved.insert(candidate)
            aliases[name] = candidate
        }
        return aliases
    }

    func inputTypeName(_ name: String, usages: TypeUsages) -> String {
        usages.inputAliases[name] ?? (usages[name] == .inputOutput ? "\(name)Input" : name)
    }

    private func mergeUsage(_ current: TypeUsage, _ next: TypeUsage) -> TypeUsage {
        if current == .unused { return next }
        if current == next || current == .inputOutput { return current }
        return .inputOutput
    }

    /// Supports older schema snapshots that do not carry explicit usage metadata.
    func inferTypeUsages(_ schema: LuxoSchema) -> TypeUsages {
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

        for sealed in (schema.sealeds ?? [:]).values {
            fields[sealed.name] = sealed.variants.flatMap { $0.fields.map(\.sealedField) }
            declared[sealed.name] = sealed.usage
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
        return TypeUsages(states: usages, inputAliases: planInputAliases(schema, states: usages))
    }

    func generateSelectionManifest(_ schema: LuxoSchema, module: String) throws -> Data {
        struct APIEntry: Encodable { let handler: String? }
        struct SealedField: Encodable { let name: String; let structured: Bool }
        struct SealedCase: Encodable { let name: String; let payload: String; let fields: [String: SealedField] }
        struct Manifest: Encodable {
            let version = 1
            let module: String
            let client = "LuxoGeneratedClient"
            let runtimeModule = "LuxoClient"
            let selectionPlans = true
            let apis: [String: APIEntry]
            let fields: [String: [String: Bool]]
            let sealeds: [String: [String: SealedCase]]?
        }
        let usages = inferTypeUsages(schema)
        var fields: [String: [String: Bool]] = [:]
        let models =
            schema.models.values.map { ($0.name, $0.fields) }
            + (schema.types?.values.map { ($0.name, $0.fields) } ?? [])
        for (name, members) in models where hasOutputUsage(usages[name] ?? .unused) {
            fields[name] = Dictionary(
                uniqueKeysWithValues: members.map {
                    (
                        $0.name,
                        schema.models[$0.typeName ?? $0.type] != nil || schema.types?[$0.typeName ?? $0.type] != nil
                            || schema.sealeds?[$0.typeName ?? $0.type]?.variants.isEmpty == false
                    )
                })
        }
        var sealeds: [String: [String: SealedCase]] = [:]
        if schema.sealeds?.isEmpty == false {
            let plan = SwiftSealedPlan(schema, aliases: usages.inputAliases)
            for (owner, variants) in plan.owners where hasOutputUsage(usages[owner] ?? .unused) {
                sealeds[owner] = Dictionary(
                    uniqueKeysWithValues: variants.map { variant in
                        let members = Dictionary(
                            uniqueKeysWithValues: zip(variant.fields, variant.declaration.fields).map { field, param in
                                let name = field.typeName ?? field.type
                                return (
                                    field.name,
                                    SealedField(
                                        name: param.name,
                                        structured:
                                            schema.models[name] != nil || schema.types?[name] != nil
                                            || schema.sealeds?[name]?.variants.isEmpty == false)
                                )
                            })
                        return (
                            String(variant.sourceCase.dropFirst().dropLast()),
                            SealedCase(name: variant.declaration.name, payload: variant.output, fields: members)
                        )
                    })
            }
        }
        var apis: [String: APIEntry] = [:]
        for api in schema.apis.values where api.isInternal != true {
            guard let type = api.returnType, schema.sealeds?[type]?.variants.isEmpty != true,
                fields[type] != nil || sealeds[type] != nil
            else { continue }
            let stream = api.stream == true
            let name = stream ? "subscribe" + api.name.prefix(1).uppercased() + api.name.dropFirst() : api.name
            apis[name] = APIEntry(handler: stream ? "handler" : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(
            Manifest(module: module, apis: apis, fields: fields, sealeds: sealeds.isEmpty ? nil : sealeds))
    }

    private func inlineTypeReferences(_ schema: LuxoSchema) -> [String: [String]] {
        var graph: [String: [String]] = [:]
        func register(_ name: String, fields: [LuxoField]) {
            let edges = fields.compactMap { field -> String? in
                guard !(field.isList ?? false) else { return nil }
                let target = field.typeName ?? field.type
                guard schema.models[target] != nil || schema.types?[target] != nil else { return nil }
                return target
            }
            if !edges.isEmpty { graph[name] = edges }
        }
        for model in schema.models.values { register(model.name, fields: model.fields) }
        if let types = schema.types {
            for type in types.values { register(type.name, fields: type.fields) }
        }
        return graph
    }

    /// Arrays already provide indirection; only inline cycles need reference storage.
    private func recursiveValueTypes(_ schema: LuxoSchema) -> Set<String> {
        let graph = inlineTypeReferences(schema)
        var indices: [String: Int] = [:]
        var low: [String: Int] = [:]
        var stack: [String] = []
        var active: Set<String> = []
        var recursive: Set<String> = []
        func visit(_ name: String) {
            let index = indices.count
            indices[name] = index
            low[name] = index
            stack.append(name)
            active.insert(name)
            for next in graph[name] ?? [] where graph[next] != nil {
                if indices[next] == nil {
                    visit(next)
                    low[name] = min(low[name]!, low[next]!)
                } else if active.contains(next) {
                    low[name] = min(low[name]!, indices[next]!)
                }
            }
            guard low[name] == index else { return }
            var component: [String] = []
            while let member = stack.popLast() {
                active.remove(member)
                component.append(member)
                if member == name { break }
            }
            if component.count > 1 || (graph[name]?.contains(name) ?? false) {
                recursive.formUnion(component)
            }
        }
        for name in graph.keys where indices[name] == nil { visit(name) }
        return recursive
    }

    func generateModels(_ schema: LuxoSchema) -> String {
        let usages = inferTypeUsages(schema)
        let recursive = recursiveValueTypes(schema)
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"

        // Known cases and explicit unknown values retain the string wire format.
        if let enums = schema.enums {
            for (_, e) in enums.sorted(by: { $0.key < $1.key }) {
                out += SwiftEnumCodegen.generate(e)
            }
        }

        // Type declarations (non-DB)
        if let types = schema.types {
            for (_, t) in types.sorted(by: { $0.key < $1.key }) {
                let usage = usages[t.name] ?? .unused
                if hasOutputUsage(usage) {
                    out += generateModelDeclaration(
                        name: t.name,
                        wireName: t.name,
                        fields: t.fields,
                        reference: recursive.contains(t.name),
                        schema: schema,
                        usages: usages,
                        output: true
                    )
                }
                if hasInputUsage(usage) {
                    out += generateModelDeclaration(
                        name: inputTypeName(t.name, usages: usages),
                        wireName: t.name,
                        fields: t.fields,
                        reference: recursive.contains(t.name),
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
                    wireName: model.name,
                    fields: model.fields,
                    reference: recursive.contains(model.name),
                    schema: schema,
                    usages: usages,
                    output: true
                )
            }
            if hasInputUsage(usage) {
                out += generateModelDeclaration(
                    name: inputTypeName(model.name, usages: usages),
                    wireName: model.name,
                    fields: model.fields,
                    reference: recursive.contains(model.name),
                    schema: schema,
                    usages: usages,
                    output: false
                )
            }
        }
        out += generateSealedModels(schema, usages: usages)
        return out
    }

    func generateModelDeclaration(
        name: String,
        wireName: String,
        fields: [LuxoField],
        reference: Bool,
        schema: LuxoSchema,
        usages: TypeUsages,
        output: Bool, codingKeys: String = "", closedJSONFields: [String]? = nil
    ) -> String {
        let binaryConformance = output ? "" : ", LuxoBinaryEncodable"
        let declaration = reference ? "final class" : "struct"
        var out =
            "public \(declaration) \(name): Codable, Sendable\(binaryConformance), LuxoClient.LuxoJSONSchemaProviding {\n"
        out +=
            "    public static let luxoJSONSchema = LuxoClient.LuxoJSONReadSchema.model(\"\(wireName)\", types: LUXO_SELECTION_TYPES)\n\n"
        out += codingKeys
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
        if output {
            out += generateOutputJSONDecoder(
                fields: fields, schema: schema, usages: usages, closedJSONFields: closedJSONFields)
            if closedJSONFields != nil { out += sealedOutputJSONEncoder(fields) }
        } else {
            out += generateInputBinaryEncoder(fields: fields, schema: schema)
            out += generateInputJSONProjection(fields: fields, schema: schema)
        }
        out += "}\n\n"
        return out
    }

    private func generateOutputJSONDecoder(
        fields: [LuxoField], schema: LuxoSchema, usages: TypeUsages, closedJSONFields: [String]? = nil
    ) -> String {
        var out = ""
        if fields.isEmpty && closedJSONFields == nil { out += "\n    private enum CodingKeys: CodingKey {}\n" }
        out += "\n    public init(from decoder: Swift.Decoder) throws {\n"
        let binding = fields.isEmpty && closedJSONFields == nil ? "_" : "let container"
        out += "        \(binding) = try decoder.container(keyedBy: CodingKeys.self)\n"
        if let closedJSONFields { out += sealedJSONKeyValidation(closedJSONFields) }
        if !fields.isEmpty { out += "        var hasSelectedField = false\n" }
        for field in fields {
            let base = resolveFieldType(field, schema: schema, usages: usages, input: false)
            let value = field.nullable ?? false ? "\(base)?" : base
            out +=
                "        self.\(field.name) = try container.decode(Selected<\(value)>.self, forKey: .\(field.name), selected: &hasSelectedField)\n"
            if field.type == "DateTime" {
                out += "        if case .value(let date) = self.\(field.name) { try validateDateTime(date) }\n"
            }
        }
        if !fields.isEmpty { out += "        if hasSelectedField { return }\n" }
        // Only the Luxo decoder can distinguish array positions from numeric object keys.
        out += "        try LuxoClient.LuxoJSONDecoder.validateEmptyModelProjection(from: decoder)\n"
        out += "    }\n"
        return out
    }

    private func generateInputBinaryEncoder(fields: [LuxoField], schema: LuxoSchema) -> String {
        let arenaTerms = fields.compactMap(arenaLengthExpression)
        let arenaLength = arenaTerms.isEmpty ? "0" : arenaTerms.joined(separator: " + ")
        var out = "\n    public func writeLuxo(to encoder: inout Encoder) throws {\n"
        out += "        try writeLuxo(to: &encoder, depth: 0)\n    }\n"
        out += "\n    fileprivate func writeLuxo(to encoder: inout Encoder, depth: Swift.Int) throws {\n"
        out += "        guard depth < 64 else {\n"
        out +=
            "            throw LuxoClient.LuxoError(code: 0, message: \"model nesting exceeds 64 levels\", name: \"EncodingError\")\n"
        out += "        }\n"
        out += "        encoder.writeVarint(UInt64(\(arenaLength)))\n"
        for field in fields {
            out += generateInputBinaryField(field, schema: schema)
        }
        out += "        encoder.writeEnd()\n"
        out += "    }\n"
        return out
    }

    private func generateInputJSONProjection(fields: [LuxoField], schema: LuxoSchema) -> String {
        var out = "\n    public func luxoJSONValue() throws -> LuxoValue {\n"
        if fields.isEmpty { return out + "        return .object([:])\n    }\n" }
        out += "        var values = Dictionary<String, LuxoValue>(minimumCapacity: \(fields.count))\n"
        for field in fields {
            let optional = field.nullable ?? false
            let expression = typedTransportExpression(
                type: field.type, typeName: field.typeName, list: field.isList ?? false,
                value: optional ? "value" : "self.\(field.name)", schema: schema)
            let assignment = "values[\"\(field.name)\"] = \(expression.source)"
            out +=
                optional
                ? "        if let value = self.\(field.name) { \(assignment) }\n"
                : "        \(assignment)\n"
        }
        return out + "        return .object(values)\n    }\n"
    }

    private func arenaLengthExpression(_ field: LuxoField) -> String? {
        guard !(field.isList ?? false), field.type == "String" || field.type == "Enum" else { return nil }
        let reference = inputBinaryFieldReference(field)
        let value = field.type == "Enum" ? "\(reference).rawValue" : reference
        if field.nullable ?? false {
            let mapped = field.type == "Enum" ? "$0.rawValue.utf8.count" : "$0.utf8.count"
            return "(\(reference).map { \(mapped) } ?? 0)"
        }
        return "\(value).utf8.count"
    }

    private func inputBinaryFieldReference(_ field: LuxoField) -> String {
        field.name == "encoder" || field.name == "depth" ? "self.\(field.name)" : field.name
    }

    private func generateInputBinaryField(_ field: LuxoField, schema: LuxoSchema) -> String {
        let reference = inputBinaryFieldReference(field)
        var out = "        encoder.writeVarint(UInt64(\(field.id)))\n"
        guard field.nullable ?? false else {
            return out + generateInputBinaryValue(field, value: reference, schema: schema, indent: "        ")
        }
        let nonNull = field.type == "JSON" && field.isList != true ? ", value != .null" : ""
        out += "        if let value = \(reference)\(nonNull) {\n"
        out += "            encoder.writeBool(true)\n"
        out += generateInputBinaryValue(field, value: "value", schema: schema, indent: "            ")
        out += "        } else {\n"
        out += "            encoder.writeBool(false)\n"
        out += "        }\n"
        return out
    }

    private func generateInputBinaryValue(
        _ field: LuxoField,
        value: String,
        schema: LuxoSchema,
        indent: String
    ) -> String {
        guard field.isList ?? false else {
            return generateInputBinaryScalar(field, value: value, schema: schema, indent: indent)
        }
        var out = "\(indent)try encoder.writeArrayHeader(\(value).count)\n"
        out += "\(indent)for item in \(value) {\n"
        out += generateInputBinaryScalar(field, value: "item", schema: schema, indent: indent + "    ")
        out += "\(indent)}\n"
        return out
    }

    func generateInputBinaryScalar(
        _ field: LuxoField,
        value: String,
        schema: LuxoSchema,
        indent: String, depth: String = "depth + 1"
    ) -> String {
        if field.type == "Sealed" {
            let argument = depth == "0" ? "" : ", depth: " + depth
            return
                "\(indent)try encoder.writeDelimited { encoder in try \(value).writeLuxo(to: &encoder\(argument)) }\n"
        }
        if isNested(field, schema: schema) {
            return "\(indent)try \(value).writeLuxo(to: &encoder, depth: depth + 1)\n"
        }
        let statement: String
        switch field.type {
        case "Int", "Duration":
            statement = "encoder.writeSvarint(\(Self.builtinType("Int64", schema: schema))(\(value)))"
        case "Float": statement = "try encoder.writeFixed64(\(value))"
        case "String", "Decimal": statement = "encoder.writeString(\(value))"
        case "Enum": statement = "encoder.writeString(\(value).rawValue)"
        case "Boolean": statement = "encoder.writeBool(\(value))"
        case "DateTime": statement = "try encoder.writeDateTime(\(value))"
        case "UUID": statement = "encoder.writeUUID(\(value))"
        case "Bytes": statement = "encoder.writeBytes(\(value))"
        case "JSON": statement = "try encoder.writeJSON(\(value))"
        default:
            statement =
                "throw LuxoError(code: 0, message: \"unsupported binary field type: \(field.type)\", name: \"ConfigError\")"
        }
        return "\(indent)\(statement)\n"
    }

    func generateClient(_ schema: LuxoSchema) -> String {
        let usages = inferTypeUsages(schema)
        var requests = ""
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"
        out += "public final class LuxoGeneratedClient: Sendable {\n"
        out += "    private let transport: Transport\n\n"
        out += "    public init(transport: Transport) throws {\n"
        out += "        self.transport = transport\n"
        out += "        try transport.setSchema(LUXO_SCHEMA)\n"
        out += "    }\n\n"
        out += "    /// Enable binary mode using the schema registered at initialization.\n"
        out += "    public func enableBinary() {\n"
        out += "        transport.setMode(.binary)\n"
        out += "    }\n\n"

        for (_, api) in schema.apis.sorted(by: { $0.key < $1.key }) {
            if api.isInternal == true { continue }
            let returnType = api.returnType ?? "Void"
            let baseReturn = mapType(returnType, schema: schema, nullable: false, list: api.returnList ?? false)
            let swiftReturn =
                (api.paginated ?? false
                    ? "Page<\(mapType(returnType, schema: schema, nullable: false, list: false))>" : baseReturn)
                + (api.returnNullable == true ? "?" : "")
            let hasStructuredReturn =
                schema.models[returnType] != nil || schema.types?[returnType] != nil
                || schema.sealeds?[returnType]?.variants.isEmpty == false

            // Build params — page/pageSize always optional for list APIs
            let isPaginated = api.paginated ?? false
            let paginationNames: Set<String> = ["page", "pageSize"]
            var paramList = ""
            var paramSetup = ""
            if let params = api.params, !params.isEmpty {
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
                paramSetup = "        var callParams: [String: LuxoValue] = [:]\n"
                for p in params {
                    let forceOptional = isPaginated && paginationNames.contains(p.name)
                    let nullable = p.nullable ?? false
                    let hasDefault = p.hasDefault ?? false
                    if nullable && hasDefault {
                        paramSetup += "        switch \(p.name) {\n"
                        paramSetup += "        case .absent: break\n"
                        paramSetup += "        case .present(let value):\n"
                        let value = transportValueExpression(p, value: "value", schema: schema)
                        paramSetup +=
                            "            if let value { callParams[\"\(p.name)\"] = \(value) } else { callParams[\"\(p.name)\"] = .null }\n"
                        paramSetup += "        }\n"
                    } else if forceOptional || hasDefault {
                        let value = transportValueExpression(p, value: p.name, schema: schema)
                        paramSetup +=
                            "        if let \(p.name) { callParams[\"\(p.name)\"] = \(value) }\n"
                    } else if nullable {
                        let value = transportValueExpression(p, value: p.name, schema: schema)
                        paramSetup +=
                            "        if let \(p.name) { callParams[\"\(p.name)\"] = \(value) } else { callParams[\"\(p.name)\"] = .null }\n"
                    } else {
                        let value = transportValueExpression(p, value: p.name, schema: schema)
                        paramSetup +=
                            "        callParams[\"\(p.name)\"] = \(value)\n"
                    }
                }
            }
            if hasStructuredReturn {
                if !paramList.isEmpty { paramList += ", " }
                paramList += "select: String? = nil, selectionPlan: PreparedSelection? = nil"
                if paramSetup.isEmpty {
                    paramSetup = "        var callParams: [String: LuxoValue] = [:]\n"
                }
                paramSetup += "        if let select { callParams[\"$select\"] = .string(select) }\n"
            }
            if isPaginated {
                if !paramList.isEmpty { paramList += ", " }
                paramList += "filters: [LuxoFilter]? = nil, sorters: [LuxoSorter]? = nil"
                if paramSetup.isEmpty {
                    paramSetup = "        var callParams: [String: LuxoValue] = [:]\n"
                }
                paramSetup +=
                    "        if let filters { callParams[\"$filters\"] = .array(filters.map(\\.transportValue)) }\n"
                paramSetup +=
                    "        if let sorters { callParams[\"$sorters\"] = .array(sorters.map(\\.transportValue)) }\n"
            }

            if hasStructuredReturn {
                let method =
                    api.stream == true
                    ? "subscribe" + api.name.prefix(1).uppercased() + api.name.dropFirst() : api.name
                out += SwiftRequestCodegen.selectionFactory(api: api.name, method: method)
            }
            let request = SwiftRequestCodegen.invocation(api, selection: hasStructuredReturn)
            requests += SwiftRequestCodegen.generate(
                api, selection: hasStructuredReturn,
                type: { self.resolveParamType($0, schema: schema, usages: usages, nullable: false) },
                jsonSetup: paramSetup,
                scalar: {
                    self.generateInputBinaryScalar($0, value: $1, schema: schema, indent: "        ", depth: "0")
                })
            if api.stream ?? false {
                let methodName = "subscribe" + api.name.prefix(1).uppercased() + api.name.dropFirst()
                if !paramList.isEmpty { paramList += ", " }
                paramList +=
                    "observer: StreamObserver? = nil, handler: @escaping LuxoClient.SubscriptionHandler<\(swiftReturn)>"
                out += "    public func \(methodName)(\(paramList)) async throws -> (@Sendable () -> Swift.Void) {\n"
                out +=
                    "        return try await transport.subscribe(\"\(api.name)\", decoder: Self.decode_\(api.name), request: \(request), observer: observer, handler: handler)\n"
                out += "    }\n\n"
                out += responseDecoder(
                    api, returnType: returnType, swiftReturn: swiftReturn, structured: hasStructuredReturn,
                    schema: schema)
                continue
            }

            out += "    public func \(api.name)(\(paramList)) async throws -> \(swiftReturn) {\n"
            out += "        let result = try await transport.call(\"\(api.name)\", request: \(request))\n"

            out += "        return try Self.decode_\(api.name)(result)\n"
            out += "    }\n\n"
            out += responseDecoder(
                api, returnType: returnType, swiftReturn: swiftReturn, structured: hasStructuredReturn, schema: schema)
        }

        out += "}\n" + requests
        return out
    }

    private func responseDecoder(
        _ api: LuxoAPI, returnType: String, swiftReturn: String, structured: Bool, schema: LuxoSchema
    ) -> String {
        var out = "    private static func decode_\(api.name)(_ result: TransportPayload) throws -> \(swiftReturn) {\n"
        out += "        if result.mode == .binary {\n"
        let nullable = api.returnNullable == true
        if nullable { out += "            if try isNullRoot(result.data) { return nil }\n" }
        let scalarData = nullable ? "try Decoder(result.data, offset: 1)" : "result.data"
        let columnData = nullable ? "try ColumnarDecoder(data: result.data, offset: 1)" : "result.data"
        if schema.sealeds?[returnType]?.variants.isEmpty == true {
            if api.returnList == true {
                out += "            return try decodeLuxoResponse(\(scalarData)) { decoder in\n"
                out +=
                    "                guard decoder.readVarint() == 0 else { throw LuxoError(code: 0, message: \"empty sealed list must be empty\", name: \"DecodeError\") }\n"
                out += "                return []\n            }\n"
            } else {
                out +=
                    "            throw LuxoError(code: 0, message: \"empty sealed type has no values\", name: \"DecodeError\")\n"
            }
        } else if schema.sealeds?[returnType] != nil {
            let read =
                api.returnList == true
                ? "try decoder.readArray { decoder in try decodeLuxoResponse(decoder.readBytes()) { try decode\(returnType)(&$0) } }"
                : "try decode\(returnType)(&decoder)"
            out += "            return try decodeLuxoResponse(\(scalarData)) { decoder in \(read) }\n"
        } else if structured {
            if api.paginated ?? false {
                out += "            return try decodePaginated\(returnType)(\(columnData))\n"
            } else if api.returnList ?? false {
                out += "            return try decodeColumnar\(returnType)(\(columnData))\n"
            } else {
                out += "            return \(modelPayloadRead(returnType, data: scalarData))\n"
            }
        } else {
            let read =
                returnType == "JSON" && nullable && api.returnList != true
                ? "try decodeLuxoNullableBinaryJSON(decoder.readBytes())"
                : scalarDecodeExpression(returnType, list: api.returnList ?? false, schema: schema)
            out += "            return try decodeLuxoResponse(\(scalarData)) { decoder in \(read) }\n"
        }
        out += "        }\n"
        if returnType == "DateTime" {
            out += "        let value = try decodeLuxoJSONResponse(\(swiftReturn).self, from: result.data)\n"
            out += "        try validateDateTime(value)\n        return value\n"
        } else {
            out += "        return try decodeLuxoJSONResponse(\(swiftReturn).self, from: result.data)\n"
        }
        return out + "    }\n\n"
    }

    struct TransportExpression {
        let value: String
        var throwing = false
        var source: String { (throwing ? "try " : "") + value }
    }

    private func transportValueExpression(_ param: LuxoParam, value: String, schema: LuxoSchema) -> String {
        typedTransportExpression(
            type: param.type, typeName: param.typeName, list: param.isList ?? false,
            value: value, schema: schema
        ).source
    }

    func typedTransportExpression(
        type: String, typeName: String?, list: Bool, value: String, schema: LuxoSchema
    ) -> TransportExpression {
        if list, schema.sealeds?[typeName ?? type]?.variants.isEmpty == true {
            return TransportExpression(
                value:
                    "{ guard \(value).isEmpty else { throw LuxoError(code: 0, message: \"empty sealed list must be empty\", name: \"ConfigError\") }; return LuxoValue.array([]) }()",
                throwing: true)
        }
        let scalar = scalarTransportExpression(
            type: type, typeName: typeName, value: list ? "$0" : value, schema: schema)
        guard list else { return scalar }
        return TransportExpression(
            value: ".array(\(value).map { \(scalar.source) })", throwing: scalar.throwing)
    }

    private func scalarTransportExpression(
        type: String, typeName: String?, value: String, schema: LuxoSchema
    ) -> TransportExpression {
        let name = typeName ?? type
        if type == "Enum" || schema.enums?[name] != nil {
            return TransportExpression(value: ".string(\(value).rawValue)")
        }
        if type == "Model" || type == "Sealed" || schema.models[name] != nil || schema.types?[name] != nil
            || schema.sealeds?[name] != nil
        {
            return TransportExpression(value: ".structured(\(value))")
        }
        switch type {
        case "Float":
            return TransportExpression(value: "LuxoValue(finiteFloat: \(value))", throwing: true)
        case "JSON":
            return TransportExpression(value: "LuxoValue.checkedJSON(\(value))", throwing: true)
        case "Int", "Duration", "String", "Boolean", "DateTime", "UUID", "Decimal", "Bytes":
            return TransportExpression(value: "LuxoValue(\(value))")
        default:
            return TransportExpression(value: "LuxoValue.encode(\(value))", throwing: true)
        }
    }

    // MARK: - Binary Decoders

    func generateDecoders(_ schema: LuxoSchema) -> String {
        let usages = inferTypeUsages(schema)
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"
        out += generateResponseDecoder()

        if let types = schema.types {
            for (_, type) in types.sorted(by: { $0.key < $1.key }) where hasOutputUsage(usages[type.name] ?? .unused) {
                out += generateDecoder(name: type.name, fields: type.fields, schema: schema, usages: usages)
            }
        }
        for (_, model) in schema.models.sorted(by: { $0.key < $1.key })
        where hasOutputUsage(usages[model.name] ?? .unused) {
            out += generateDecoder(name: model.name, fields: model.fields, schema: schema, usages: usages)
        }

        out += generateSealedDecoders(schema, usages: usages)
        return out
    }

    private func generateResponseDecoder() -> String {
        """
        // Only complete response payloads use this boundary, never inline row fields.
        @inline(__always)
        func decodeLuxoResponse<Value>(_ data: Data, read: (inout Decoder) throws -> Value) throws -> Value {
            try decodeLuxoResponse(Decoder(data), read: read)
        }

        @inline(__always)
        func decodeLuxoResponse<Value>(_ initial: Decoder, read: (inout Decoder) throws -> Value) throws -> Value {
            var decoder = initial
            let value: Value
            do {
                value = try read(&decoder)
            } catch let error as LuxoError {
                if error.name == "DecodeError" { throw error }
                throw LuxoError(code: 0, message: decoder.error ?? error.message, name: "DecodeError")
            } catch {
                throw LuxoError(code: 0, message: decoder.error ?? "invalid response payload", name: "DecodeError")
            }
            if let error = decoder.error { throw LuxoError(code: 0, message: error, name: "DecodeError") }
            guard decoder.isAtEnd else {
                throw LuxoError(code: 0, message: "trailing response bytes", name: "DecodeError")
            }
            return value
        }

        // Keep transport-level decode failures distinct from business errors.
        @inline(__always)
        func decodeLuxoJSONResponse<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
            do {
                return try LuxoJSONDecoder().decode(type, from: data)
            } catch let error as LuxoError {
                if error.name == "DecodeError" { throw error }
                throw LuxoError(code: 0, message: error.message, name: "DecodeError")
            } catch {
                throw LuxoError(code: 0, message: "invalid JSON response payload", name: "DecodeError")
            }
        }

        @inline(__always)
        func decodeLuxoBinaryJSON(_ data: Data) throws -> JSONValue {
            do {
                return try JSONValue.parseBinary(data)
            } catch let error as LuxoError {
                throw LuxoError(code: 0, message: error.message, name: "DecodeError")
            }
        }

        @inline(__always)
        func decodeLuxoNullableBinaryJSON(_ data: Data) throws -> JSONValue? {
            let value = try decodeLuxoBinaryJSON(data)
            return value == .null ? nil : value
        }


        """
    }

    func generateDecoder(
        name: String,
        fields: [LuxoField],
        schema: LuxoSchema,
        usages: TypeUsages, columnar: Bool = true
    ) -> String {
        let depth = decoderDepthName(fields)
        var out = "public func decode\(name)(_ decoder: inout Decoder) throws -> \(name) {\n"
        out += "    try decode\(name)(&decoder, depth: 0)\n}\n\n"
        out +=
            "private func decode\(name)(_ decoder: inout Decoder, \(decoderDepthParameter(depth))) throws -> \(name) {\n"
        out += modelDepthCheck(depth, allowEmpty: false)
        for field in fields {
            let value = selectedFieldType(field, schema: schema, usages: usages)
            out += "    var _\(field.name): Selected<\(value)> = .unselected\n"
        }
        out += "    decoder.skipArenaHeader()\n"
        out += "    while true {\n"
        out += "        let fieldID = decoder.nextField()\n"
        out += "        if fieldID == 0 { break }\n"
        out += "        switch fieldID {\n"
        for field in fields {
            out +=
                "        case \(field.id): _\(field.name) = .value(\(rowRead(field, schema: schema, depth: depth)))\n"
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
        if !columnar { return out }
        out += generateColumnarDecoder(name: name, fields: fields, schema: schema, usages: usages, paginated: false)
        out += generateColumnarDecoder(name: name, fields: fields, schema: schema, usages: usages, paginated: true)
        return out
    }

    private func decoderDepthName(_ fields: [LuxoField]) -> String {
        var name = "depth"
        while fields.contains(where: { $0.name == name }) { name.append("_") }
        return name
    }

    private func selectedFieldType(_ field: LuxoField, schema: LuxoSchema, usages: TypeUsages) -> String {
        let base = resolveFieldType(field, schema: schema, usages: usages)
        return field.nullable ?? false ? "\(base)?" : base
    }

    private func decoderDepthParameter(_ depth: String) -> String {
        depth == "depth" ? "depth: Swift.Int" : "depth \(depth): Swift.Int"
    }

    private func modelDepthCheck(_ depth: String, allowEmpty: Bool) -> String {
        let condition = allowEmpty ? "decoder.count == 0 || \(depth) < 64" : "\(depth) < 64"
        return "    guard \(condition) else {\n"
            + "        throw LuxoError(code: 0, message: \"model nesting exceeds 64 levels\", name: \"DecodeError\")\n"
            + "    }\n"
    }

    func rowRead(_ field: LuxoField, schema: LuxoSchema, depth: String) -> String {
        let typeName = field.typeName ?? field.type
        let nested = isNested(field, schema: schema)
        let nullable = field.nullable ?? false
        if field.isList ?? false {
            let read = arrayRead(field, schema: schema, depth: "\(depth) + 1")
            return nullable ? "decoder.readBool() ? \(read) : nil" : read
        }
        if field.type == "Sealed" {
            let read = modelPayloadRead(typeName, data: "decoder.readBytes()", depth: "\(depth) + 1")
            return nullable ? "decoder.readBool() ? \(read) : nil" : read
        }
        if nested {
            return nullable
                ? "try decoder.readNullable { d in \(modelPayloadRead(typeName, data: "d.readBytes()", depth: "\(depth) + 1")) }"
                : modelPayloadRead(typeName, data: "decoder.readBytes()", depth: "\(depth) + 1")
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
                return "decoder.readBool() ? try decodeLuxoNullableBinaryJSON(decoder.readBytes()) : nil"
            case "DateTime": return "decoder.readDateTimePtr()"
            case "Duration": return "decoder.readIntPtr()"
            case "Enum":
                return
                    "decoder.readStringPtr().map { \(typeName)(rawValue: $0) }"
            default: return "decoder.readStringPtr()"
            }
        }
        if field.type == "Enum" {
            return "\(typeName)(rawValue: decoder.readString())"
        }
        return scalarRead(field.type, decoder: "decoder")
    }

    // The nullable marker belongs to the outer field/cell, not its array payload.
    private func arrayRead(_ field: LuxoField, schema: LuxoSchema, depth: String = "0") -> String {
        let typeName = field.typeName ?? field.type
        if field.type == "Sealed" {
            return "try decoder.readArray { d in \(modelPayloadRead(typeName, data: "d.readBytes()", depth: depth)) }"
        }
        if isNested(field, schema: schema) {
            return "try decodeColumnar\(typeName)(decoder.readBytes(), depth: \(depth))"
        }
        if field.type == "DateTime" { return "decoder.readDateTimeArray()" }
        if field.type == "Enum" {
            return
                "decoder.readArray { d in \(typeName)(rawValue: d.readString()) }"
        }
        let item = scalarRead(field.type, decoder: "d")
        let prefix = field.type == "JSON" ? "try " : ""
        return "\(prefix)decoder.readArray { d in \(item) }"
    }

    private func modelPayloadRead(_ type: String, data: String, depth: String? = nil) -> String {
        let argument = depth.map { ", depth: \($0)" } ?? ""
        let read = "{ decoder in try decode\(type)(&decoder\(argument)) }"
        return "try decodeLuxoResponse(\(data)) \(read)"
    }

    private func scalarRead(_ type: String, decoder: String) -> String {
        switch type {
        case "Int": return "Int(\(decoder).readSvarint())"
        case "Float": return "\(decoder).readFixed64()"
        case "Boolean": return "\(decoder).readBool()"
        case "UUID": return "\(decoder).readUUID()"
        case "Bytes": return "\(decoder).readBytes()"
        case "JSON": return "try decodeLuxoBinaryJSON(\(decoder).readBytes())"
        case "DateTime": return "\(decoder).readDateTime()"
        case "Duration": return "\(decoder).readSvarint()"
        default: return "\(decoder).readString()"
        }
    }

    private func generateColumnarDecoder(
        name: String,
        fields: [LuxoField],
        schema: LuxoSchema,
        usages: TypeUsages,
        paginated: Bool
    ) -> String {
        let function = paginated ? "decodePaginated\(name)" : "decodeColumnar\(name)"
        let result = paginated ? "Page<\(name)>" : "[\(name)]"
        let depth = decoderDepthName(fields)
        var out = columnarDecoderHeader(function, result: result, depth: depth, paginated: paginated)
        for field in fields {
            out += "    var _\(field.name): \(columnType(field, schema: schema, usages: usages))?\n"
        }
        out += "    while decoder.nextColumn() {\n"
        out += "        switch decoder.fieldID {\n"
        for field in fields {
            out += "        case \(field.id):\n"
            out += previousColumnCheck(field, schema: schema, usages: usages, depth: depth)
            out += "            _\(field.name) = \(columnRead(field, schema: schema))\n"
        }
        out +=
            "        default: throw LuxoError(code: 0, message: \"unknown \(name) column ID \\(decoder.fieldID)\", name: \"DecodeError\")\n"
        out += "        }\n"
        out += "    }\n"
        out += "    if let error = decoder.error { throw LuxoError(code: 0, message: error, name: \"DecodeError\") }\n"
        out += columnarCompletion(paginated: paginated)
        out += "    var items: [\(name)] = []\n"
        out += "    items.reserveCapacity(decoder.count)\n"
        out += "    for \(fields.isEmpty ? "_" : "i") in 0..<decoder.count {\n"
        out += "        items.append(\(name)(\n"
        out += fields.map {
            "            \($0.name): \(columnValue($0, schema: schema, depth: depth))"
        }.joined(separator: ",\n")
        out += "\n        ))\n"
        out += "    }\n"
        if paginated {
            out +=
                "    return Page<\(name)>(items: items, total: total, page: page, pageSize: pageSize)\n"
        } else {
            out += "    return items\n"
        }
        out += "}\n\n"
        return out
    }

    private func previousColumnCheck(
        _ field: LuxoField, schema: LuxoSchema, usages: TypeUsages, depth: String
    ) -> String {
        guard isNested(field, schema: schema) || (field.isList ?? false) || field.type == "JSON" else { return "" }
        let value = selectedFieldType(field, schema: schema, usages: usages)
        return "            if _\(field.name) != nil {\n"
            + "                for i in 0..<decoder.count {\n"
            + "                    let _: Selected<\(value)> = \(columnValue(field, schema: schema, depth: depth))\n"
            + "                }\n            }\n"
    }

    private func columnarDecoderHeader(_ function: String, result: String, depth: String, paginated: Bool) -> String {
        var out = "public func \(function)(_ data: Data) throws -> \(result) {\n"
        out += "    try \(function)(ColumnarDecoder(data: data), depth: 0)\n}\n\n"
        out += "public func \(function)(_ initial: ColumnarDecoder) throws -> \(result) {\n"
        out += "    try \(function)(initial, depth: 0)\n}\n\n"
        if !paginated {
            out += "private func \(function)(_ data: Data, \(decoderDepthParameter(depth))) throws -> \(result) {\n"
            out += "    try \(function)(ColumnarDecoder(data: data), depth: \(depth))\n}\n\n"
        }
        out +=
            "private func \(function)(_ initial: ColumnarDecoder, \(decoderDepthParameter(depth))) throws -> \(result) {\n"
        out += "    var decoder = initial\n"
        out += modelDepthCheck(depth, allowEmpty: true)
        return out
    }

    private func columnarCompletion(paginated: Bool) -> String {
        var out = ""
        if paginated {
            for name in ["total", "page", "pageSize"] {
                out += "    let \(name) = Int(decoder.readSvarint())\n"
            }
            out +=
                "    if let error = decoder.error { throw LuxoError(code: 0, message: error, name: \"DecodeError\") }\n"
        }
        out += "    guard decoder.isAtEnd else {\n"
        out +=
            "        throw LuxoError(code: 0, message: \"trailing columnar response bytes\", name: \"DecodeError\")\n"
        out += "    }\n"
        return out
    }

    private func isNested(_ field: LuxoField, schema: LuxoSchema) -> Bool {
        let name = field.typeName ?? field.type
        return (field.relation ?? false) || schema.models[name] != nil || schema.types?[name] != nil
    }

    private func columnType(
        _ field: LuxoField,
        schema: LuxoSchema,
        usages: TypeUsages
    ) -> String {
        if isNested(field, schema: schema) || field.type == "Sealed" || (field.isList ?? false) || field.type == "Bytes"
            || field.type == "JSON"
        {
            return field.nullable ?? false ? "[Data?]" : "[Data]"
        }
        let base = resolveFieldType(field, schema: schema, usages: usages)
        return field.nullable ?? false ? "[\(base)?]" : "[\(base)]"
    }

    private func columnRead(_ field: LuxoField, schema: LuxoSchema) -> String {
        if isNested(field, schema: schema) || field.type == "Sealed" || (field.isList ?? false) || field.type == "Bytes"
            || field.type == "JSON"
        {
            return field.nullable ?? false
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
                ? "decoder.readColumnStringPtr().map { $0.map { \(name)(rawValue: $0) } }"
                : "decoder.readColumnString().map { \(name)(rawValue: $0) }"
        default: return field.nullable ?? false ? "decoder.readColumnStringPtr()" : "decoder.readColumnString()"
        }
    }

    private func columnValue(_ field: LuxoField, schema: LuxoSchema, depth: String) -> String {
        let column = "_\(field.name)"
        let typeName = field.typeName ?? field.type
        if field.type == "Sealed" {
            let read =
                field.isList == true
                ? "try decodeLuxoResponse(data) { decoder in \(arrayRead(field, schema: schema, depth: "\(depth) + 1")) }"
                : modelPayloadRead(typeName, data: "data", depth: "\(depth) + 1")
            let value =
                field.nullable == true
                ? "try values[i].map { data in \(read) }" : "try { let data = values[i]; return \(read) }()"
            return "try \(column).map { values in .value(\(value)) } ?? .unselected"
        }
        if isNested(field, schema: schema) {
            if field.isList ?? false {
                if field.nullable ?? false {
                    return
                        "try \(column).map { values in .value(try values[i].map { try decodeColumnar\(typeName)($0, depth: \(depth) + 1) }) } ?? .unselected"
                }
                return
                    "try \(column).map { .value(try decodeColumnar\(typeName)($0[i], depth: \(depth) + 1)) } ?? .unselected"
            }
            if field.nullable ?? false {
                return
                    "try \(column).map { values in .value(try values[i].map { data in \(modelPayloadRead(typeName, data: "data", depth: "\(depth) + 1")) }) } ?? .unselected"
            }
            return
                "try \(column).map { values in .value(\(modelPayloadRead(typeName, data: "values[i]", depth: "\(depth) + 1"))) } ?? .unselected"
        }
        if field.isList ?? false {
            let read = arrayRead(field, schema: schema)
            if field.nullable ?? false {
                return
                    "try \(column).map { values in .value(try values[i].map { data in try decodeLuxoResponse(data) { decoder in \(read) } }) } ?? .unselected"
            }
            return
                "try \(column).map { data in .value(try decodeLuxoResponse(data[i]) { decoder in \(read) }) } ?? .unselected"
        }
        if field.type == "JSON" {
            if field.nullable ?? false {
                return
                    "try \(column).map { values in .value(try values[i].flatMap { data in try decodeLuxoNullableBinaryJSON(data) }) } ?? .unselected"
            }
            return
                "try \(column).map { values in .value(try decodeLuxoBinaryJSON(values[i])) } ?? .unselected"
        }
        return "\(column).map { .value($0[i]) } ?? .unselected"
    }

    // MARK: - Schema Map

    func generateSchema(_ schema: LuxoSchema) -> String {
        var out = "// GENERATED BY LuxoCodegen. DO NOT EDIT.\n\n"
        out += "import Foundation\nimport LuxoClient\n\n"
        var selectionTypes =
            (schema.types?.values.map { ($0.name, $0.fields) } ?? [])
            + schema.models.values.map { ($0.name, $0.fields) }
        if schema.sealeds?.isEmpty == false { selectionTypes += sealedSelectionTypes(schema) }
        for (name, fields) in selectionTypes.sorted(by: { $0.0 < $1.0 }) {
            let values = fields.map { field in
                let typeName = field.typeName ?? field.type
                let nested =
                    isNested(field, schema: schema) || field.type == "Sealed" || field.typeName?.contains(".") == true
                    ? ", typeName: \(SwiftEnumCodegen.literal(typeName))" : ""
                return
                    "\"\(field.name)\": .init(fieldID: \(field.id)\(nested), type: \"\(field.type)\", isList: \(field.isList ?? false), nullable: \(field.nullable ?? false))"
            }.joined(separator: ", ")
            let literal = fields.isEmpty ? "[:]" : "[\(values)]"
            out += "private let \(selectionFieldsName(name)): [String: APISchema.SelectionFieldSchema] = \(literal)\n"
        }
        if !selectionTypes.isEmpty { out += "\n" }
        out += "let LUXO_SELECTION_TYPES: [String: [String: APISchema.SelectionFieldSchema]] = [\n"
        if selectionTypes.isEmpty { out += "    :\n" }
        for (name, _) in selectionTypes.sorted(by: { $0.0 < $1.0 }) {
            out += "    \"\(name)\": \(selectionFieldsName(name)),\n"
        }
        out += "]\n\n"
        out += "public let LUXO_SCHEMA: [String: APISchema] = [\n"
        if !schema.apis.values.contains(where: { $0.isInternal != true }) { out += "    :\n" }

        for (_, api) in schema.apis.sorted(by: { $0.key < $1.key }) {
            if api.isInternal == true { continue }
            var paramsStr = "nil"
            if let params = api.params, !params.isEmpty {
                let paramItems = params.map { p in
                    let isList = p.isList ?? false
                    let typeName = p.typeName.map { ", typeName: \(SwiftEnumCodegen.literal($0))" } ?? ""
                    return
                        "APISchema.ParamSchema(fieldID: \(p.id), name: \"\(p.name)\", type: \"\(p.type)\"\(typeName), isList: \(isList), nullable: \(p.nullable ?? false))"
                }
                paramsStr = "[\(paramItems.joined(separator: ", "))]"
            }
            let returnType = api.returnType
            let structuredTypeName = returnType.flatMap { name in
                schema.models[name] != nil || schema.types?[name] != nil || schema.sealeds?[name] != nil ? name : nil
            }
            let needsTypes =
                structuredTypeName != nil || (api.params ?? []).contains { $0.type == "Model" || $0.type == "Sealed" }
            let fieldsStr = structuredTypeName.map(selectionFieldsName) ?? "[:]"
            let typesStr = needsTypes ? "LUXO_SELECTION_TYPES" : "[:]"
            var response =
                structuredTypeName.map {
                    ".model(\"\(schema.sealeds?[$0] != nil ? "@sealed:" + $0 : $0)\", types: LUXO_SELECTION_TYPES)"
                } ?? ".json"
            if api.paginated ?? false {
                response = ".page(\(response))"
            } else if api.returnList ?? false {
                response = ".list(\(response))"
            }
            out +=
                "    \"\(api.name)\": APISchema(id: \(api.id), params: \(paramsStr), fields: \(fieldsStr), types: \(typesStr), response: \(response)),\n"
        }

        out += "]\n"
        return out
    }

    private func selectionFieldsName(_ typeName: String) -> String {
        if isLuxoDSLIdentifier(typeName) { return "LUXO_SELECTION_FIELDS_" + typeName }
        return "LUXO_SEALED_SELECTION_FIELDS_" + typeName.utf8.map { String($0, radix: 16) }.joined(separator: "_")
    }

    static func builtinType(_ name: String, schema: LuxoSchema) -> String {
        guard
            schema.models[name] != nil || schema.types?[name] != nil || schema.enums?[name] != nil
                || schema.sealeds?[name] != nil
        else {
            return name
        }
        let module = name == "Data" || name == "UUID" ? "Foundation" : name == "JSONValue" ? "LuxoClient" : "Swift"
        return "\(module).\(name)"
    }

    private func mapType(_ type: String, schema: LuxoSchema, nullable: Bool, list: Bool) -> String {
        let base: String
        switch type {
        case "Int": base = "Int"
        case "Float": base = "Double"
        case "String": base = "String"
        case "Boolean": base = "Bool"
        // DateTime surfaces as RFC3339 text; binary seconds plus nanoseconds
        // retain the same precision as JSON and the other SDKs.
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

        let resolved = base == type ? base : Self.builtinType(base, schema: schema)
        let result = list ? "[\(resolved)]" : resolved
        return nullable ? "\(result)?" : result
    }

    private func scalarDecodeExpression(_ type: String, list: Bool, schema: LuxoSchema) -> String {
        if list && type == "DateTime" { return "decoder.readDateTimeArray()" }
        let isEnum = schema.enums?[type] != nil
        let value =
            isEnum
            ? "\(type)(rawValue: decoder.readString())"
            : scalarRead(type, decoder: "decoder")
        if list {
            return "\(type == "JSON" ? "try " : "")decoder.readArray { decoder in \(value) }"
        }
        return value
    }
}

// Introspection credentials must never follow a server-selected destination.
final class IntrospectionRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = IntrospectionRedirectPolicy()

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
