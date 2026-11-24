import Foundation

/// Concrete generated values write Binary directly; JSON materialization is explicit.
public protocol GeneratedRequest: Sendable {
    var apiID: Int { get }
    var selection: String? { get }
    var selectionPlan: PreparedSelection? { get }
    var filters: [LuxoFilter]? { get }
    var sorters: [LuxoSorter]? { get }
    func writeParameters(to encoder: inout Encoder) throws
    func toJSONParameters() throws -> [String: LuxoValue]
}

public extension GeneratedRequest {
    var selection: String? { nil }
    var selectionPlan: PreparedSelection? { nil }
    var filters: [LuxoFilter]? { nil }
    var sorters: [LuxoSorter]? { nil }
}

enum RequestParameters: Sendable {
    case dynamic([String: LuxoValue]?)
    case generated(any GeneratedRequest)

    func json() throws -> [String: LuxoValue]? {
        switch self {
        case .dynamic(let values): return values
        case .generated(let request): return try request.toJSONParameters()
        }
    }

    func binary(schema: APISchema) throws -> Data {
        switch self {
        case .dynamic(let values): return try LuxoBinaryProtocol.encodeRequest(schema: schema, params: values)
        case .generated(let request): return try LuxoBinaryProtocol.encodeRequest(schema: schema, request: request)
        }
    }
}
