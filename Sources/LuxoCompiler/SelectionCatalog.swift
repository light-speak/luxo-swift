import Foundation

/// Source-level generation metadata resolved against the official compiler symbol graph.
public struct SelectionManifest: Decodable, Sendable {
    public let version: Int
    public let module: String
    public let client: String
    public let runtimeModule: String?
    public let selectionPlans: Bool?
    public let apis: [String: ProjectionInference.API]
    public let fields: [String: [String: Bool]]
    public let sealeds: [String: [String: SealedCase]]?

    public struct SealedCase: Decodable, Sendable {
        public let name: String
        public let payload: String
        public let fields: [String: ProjectionInference.Field]
    }

    func validate() throws {
        guard version == 1 else { throw SelectionCatalog.Failure.unsupportedVersion }
        let names = [module, client] + Array(apis.keys) + Array(fields.keys) + fields.values.flatMap(\.keys)
        for (owner, cases) in sealeds ?? [:] {
            guard Self.validIdentifier(owner) else { throw SelectionCatalog.Failure.invalidManifest }
            for (source, variant) in cases {
                let names =
                    [source, variant.name, variant.payload] + Array(variant.fields.keys)
                    + variant.fields.values.map(\.name)
                guard names.allSatisfy(Self.validIdentifier) else { throw SelectionCatalog.Failure.invalidManifest }
            }
        }
        guard names.allSatisfy(Self.validIdentifier), runtimeModule == nil || runtimeModule == "LuxoClient" else {
            throw SelectionCatalog.Failure.invalidManifest
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        var first = true
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if code == 95 || (65...90).contains(code) || (97...122).contains(code)
                || (!first && (48...57).contains(code))
            {
                first = false; continue
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                first = false
            default: return false
            }
        }
        return !first
    }
}

public struct SelectionCatalog: Sendable {
    public enum Failure: Error {
        case unsupportedVersion, invalidManifest, missingSymbol(String), ambiguousSymbol(String)
    }
    public let apis: [String: ProjectionInference.API]
    public let fields: [String: ProjectionInference.Field]
    public let transparent: Set<String>
    public let metadata: Set<String>
    public let planFactories: [String: String]
    public let sealeds: [String: ProjectionInference.Sealed]

    public init(manifest data: Data, graphs: [Data], currentModule: String? = nil) throws {
        let manifest = try JSONDecoder().decode(SelectionManifest.self, from: data)
        try manifest.validate()
        let graphs = try graphs.map { try JSONDecoder().decode(SymbolGraph.self, from: $0) }
        let symbols = Self.publicSymbols(graphs, module: manifest.module)
        var apis: [String: ProjectionInference.API] = [:]
        var factories: [String: String] = [:]
        for (name, api) in manifest.apis {
            let symbol = try Self.resolve(symbols, owner: manifest.client, member: name, method: true)
            apis[symbol] = api
            if manifest.selectionPlans == true {
                let factory = "prepareSelection_" + name
                _ = try Self.resolve(symbols, owner: manifest.client, member: factory, method: true)
                let prefix = currentModule == manifest.module ? "" : manifest.module + "."
                factories[symbol] = prefix + manifest.client + "." + factory
            }
        }
        var fields: [String: ProjectionInference.Field] = [:]
        for (owner, members) in manifest.fields {
            for (name, structured) in members {
                let symbol = try Self.resolve(symbols, owner: owner, member: name, method: false)
                fields[symbol] = .init(name: name, structured: structured)
            }
        }
        var sealeds: [String: ProjectionInference.Sealed] = [:]
        if let entries = manifest.sealeds, !entries.isEmpty {
            let owners = Self.publicOwners(graphs.filter { $0.module.name == manifest.module })
            for (owner, cases) in entries {
                let ids = owners.filter { !$0.key.isEmpty && $0.value.isPublic && $0.value.name == owner }.map(\.key)
                guard ids.count == 1, let id = ids.first, id.hasPrefix("s:") else {
                    throw Failure.missingSymbol(owner)
                }
                for (source, variant) in cases {
                    _ = try Self.resolve(symbols, owner: owner, member: source, method: true)
                    for (name, field) in variant.fields {
                        let symbol = try Self.resolve(symbols, owner: variant.payload, member: name, method: false)
                        if let previous = fields[symbol],
                            previous.name != field.name || previous.structured != field.structured
                        {
                            throw Failure.ambiguousSymbol(variant.payload + "." + name)
                        }
                        fields[symbol] = field
                    }
                }
                // The pinned compiler emits nominal type references from the graph's precise Swift USR.
                let nominal = "$s" + id.dropFirst(2)
                let entries = cases.mapValues(\.name)
                sealeds[nominal + "D"] = .init(cases: entries)
                sealeds[nominal + "SgD"] = .init(cases: entries, optional: true)
                let array = "$sSay" + id.dropFirst(2) + "G"
                sealeds[array + "D"] = .init(cases: entries, collection: true)
                sealeds[array + "SgD"] = .init(cases: entries, optional: true, collection: true)
            }
        }
        self.sealeds = sealeds
        self.apis = apis
        planFactories = factories
        self.fields = fields
        (transparent, metadata) = Self.runtimeProperties(graphs)
    }

    private static func publicSymbols(_ graphs: [SymbolGraph], module: String) -> [SymbolGraph.Symbol] {
        let graphs = graphs.filter { $0.module.name == module }
        var symbols: [SymbolGraph.Symbol] = []
        symbols.reserveCapacity(graphs.first?.symbols.count ?? 0)
        visitPublicSymbols(graphs, selecting: { _ in true }) { symbol, _ in symbols.append(symbol) }
        return symbols
    }

    private static func visitPublicSymbols<Value>(
        _ graphs: [SymbolGraph], selecting: (SymbolGraph.Symbol) -> Value?,
        _ visit: (SymbolGraph.Symbol, Value) -> Void
    ) {
        let owners = publicOwners(graphs)
        let members = memberOwners(graphs)
        for graph in graphs {
            for symbol in graph.symbols where symbol.isPublic {
                guard let value = selecting(symbol), let ownerID = members[symbol.identifier.precise],
                    !ownerID.isEmpty, let owner = owners[ownerID], owner.isPublic,
                    symbol.pathComponents.first == owner.name
                else { continue }
                visit(symbol, value)
            }
        }
    }

    private struct Owner {
        let name: String
        var isPublic: Bool
    }

    private static func publicOwners(_ graphs: [SymbolGraph]) -> [String: Owner] {
        var owners: [String: Owner] = [:]
        for graph in graphs {
            for symbol in graph.symbols where symbol.pathComponents.count == 1 {
                let id = symbol.identifier.precise
                let name = symbol.pathComponents[0]
                if var owner = owners[id] {
                    owner.isPublic = owner.isPublic && symbol.isPublicType && owner.name == name
                    owners[id] = owner
                } else {
                    owners[id] = Owner(name: name, isPublic: symbol.isPublicType)
                }
            }
        }
        return owners
    }

    private static func memberOwners(_ graphs: [SymbolGraph]) -> [String: String] {
        var members: [String: String] = [:]
        for graph in graphs {
            for relationship in graph.relationships where !relationship.source.isEmpty {
                if let owner = members[relationship.source], owner != relationship.target {
                    // Conflicting ownership must not depend on graph order.
                    members[relationship.source] = ""
                } else if members[relationship.source] == nil {
                    members[relationship.source] = relationship.target
                }
            }
        }
        return members
    }

    private static func runtimeProperties(_ graphs: [SymbolGraph]) -> (Set<String>, Set<String>) {
        var transparent: Set<String> = []
        var metadata: Set<String> = []
        visitPublicSymbols(graphs.filter { $0.module.name == "LuxoClient" }, selecting: runtimeProperty) {
            symbol, property in
            switch property {
            case .transparent:
                transparent.insert(symbol.identifier.precise)
            case .metadata:
                metadata.insert(symbol.identifier.precise)
            }
        }
        return (transparent, metadata)
    }

    private enum RuntimeProperty { case transparent, metadata }

    private static func runtimeProperty(_ symbol: SymbolGraph.Symbol) -> RuntimeProperty? {
        let path = symbol.pathComponents
        guard path.count == 2 else { return nil }
        switch (path[0], path[1]) {
        case ("Selected", "requireValue()"), ("Page", "items"): return .transparent
        case ("Page", "total"), ("Page", "page"), ("Page", "pageSize"): return .metadata
        default: return nil
        }
    }

    private static func resolve(_ symbols: [SymbolGraph.Symbol], owner: String, member: String, method: Bool) throws
        -> String
    {
        let prefix = method ? member + "(" : member
        var candidate: String?
        for symbol in symbols {
            let path = symbol.pathComponents
            guard path.count == 2, path[0] == owner,
                method ? path[1].hasPrefix(prefix) : path[1] == member
            else { continue }
            let id = symbol.identifier.precise
            if let candidate {
                guard candidate == id else { throw Failure.ambiguousSymbol(owner + "." + member) }
            } else {
                candidate = id
            }
        }
        guard let candidate else { throw Failure.missingSymbol(owner + "." + member) }
        return candidate
    }
}

private struct SymbolGraph: Decodable {
    struct Module: Decodable { let name: String }
    struct Symbol: Decodable {
        struct Identifier: Decodable { let precise: String }
        private struct Kind: Decodable { let identifier: String }
        let identifier: Identifier
        let pathComponents: [String]
        let isPublic: Bool
        let isPublicType: Bool

        private enum CodingKeys: String, CodingKey {
            case identifier, pathComponents, accessLevel, kind
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let access = try container.decodeIfPresent(String.self, forKey: .accessLevel)
            isPublic = access == "public" || access == "open"
            identifier = try container.decode(Identifier.self, forKey: .identifier)
            pathComponents = try container.decode([String].self, forKey: .pathComponents)
            if isPublic && pathComponents.count == 1 {
                let kind = try container.decodeIfPresent(Kind.self, forKey: .kind)?.identifier
                switch kind {
                case "swift.class", "swift.struct", "swift.enum", "swift.protocol", "swift.actor":
                    isPublicType = true
                default: isPublicType = false
                }
            } else {
                isPublicType = false
            }
        }
    }
    struct Relationship: Decodable {
        let source: String
        let target: String

        private enum CodingKeys: String, CodingKey { case source, target, kind }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .kind) == "memberOf" {
                source = try container.decode(String.self, forKey: .source)
                target = try container.decode(String.self, forKey: .target)
            } else {
                source = ""
                target = ""
            }
        }
    }
    let module: Module
    let symbols: [Symbol]
    let relationships: [Relationship]

    private enum CodingKeys: String, CodingKey { case module, symbols, relationships }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        module = try container.decode(Module.self, forKey: .module)
        symbols = try container.decode([Symbol].self, forKey: .symbols)
        relationships = try container.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
    }
}
