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

    func validate() throws {
        guard version == 1 else { throw SelectionCatalog.Failure.unsupportedVersion }
        let names = [module, client] + Array(apis.keys) + Array(fields.keys) + fields.values.flatMap(\.keys)
        guard names.allSatisfy(Self.validIdentifier), runtimeModule == nil || runtimeModule == "LuxoClient" else {
            throw SelectionCatalog.Failure.invalidManifest
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func letter(_ byte: UInt8) -> Bool { byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) }
        guard let first = bytes.first, letter(first) else { return false }
        return bytes.allSatisfy { letter($0) || (48...57).contains($0) }
    }
}

public struct SelectionCatalog: Sendable {
    public enum Failure: Error {
        case unsupportedVersion, invalidManifest, missingSymbol(String), ambiguousSymbol(String)
    }
    public let apis: [String: ProjectionInference.API]
    public let fields: [String: ProjectionInference.Field]
    public let transparent: Set<String>
    public let planFactories: [String: String]

    public init(manifest data: Data, graphs: [Data], currentModule: String? = nil) throws {
        let manifest = try JSONDecoder().decode(SelectionManifest.self, from: data)
        try manifest.validate()
        let graphs = try graphs.map { try JSONDecoder().decode(SymbolGraph.self, from: $0) }
        let symbols = graphs.filter { $0.module.name == manifest.module }.flatMap(\.symbols)
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
        self.apis = apis
        planFactories = factories
        self.fields = fields
        transparent = Set(
            graphs.filter { $0.module.name == "LuxoClient" }.flatMap(\.symbols).filter {
                $0.pathComponents == ["Selected", "requireValue()"] || $0.pathComponents == ["Page", "items"]
            }.map(\.identifier.precise))
    }

    private static func resolve(_ symbols: [SymbolGraph.Symbol], owner: String, member: String, method: Bool) throws
        -> String
    {
        let candidates = Set(
            symbols.filter {
                guard $0.pathComponents.count == 2, $0.pathComponents[0] == owner else { return false }
                return method ? $0.pathComponents[1].hasPrefix(member + "(") : $0.pathComponents[1] == member
            }.map(\.identifier.precise))
        guard !candidates.isEmpty else { throw Failure.missingSymbol(owner + "." + member) }
        guard candidates.count == 1, let symbol = candidates.first else {
            throw Failure.ambiguousSymbol(owner + "." + member)
        }
        return symbol
    }
}

private struct SymbolGraph: Decodable {
    struct Module: Decodable { let name: String }
    struct Symbol: Decodable {
        struct Identifier: Decodable { let precise: String }
        let identifier: Identifier
        let pathComponents: [String]
    }
    let module: Module
    let symbols: [Symbol]
}
