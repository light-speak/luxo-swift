import Foundation

/// An immutable JSON number token. Conversion is explicit and range checked.
public struct JSONNumber: Sendable, Equatable, Hashable {
    public let literal: String

    public init(_ literal: String) throws {
        let data = Data(literal.utf8)
        try data.withUnsafeBytes { raw in
            var reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
            _ = try reader.number()
            guard reader.offset == raw.count else { throw reader.invalid() }
        }
        self.literal = literal
    }

    // Only the validating reader and exact integer writer may bypass validation.
    init(validated literal: String) { self.literal = literal }

    var isInteger: Bool { !literal.utf8.contains { $0 == 46 || $0 == 69 || $0 == 101 } }

    public func toInt64() throws -> Int64 {
        guard isInteger, let value = Int64(literal) else {
            throw LuxoError(code: 0, message: "JSON number is not a signed Int64", name: "DecodingError")
        }
        return value
    }

    public func toDouble() throws -> Double {
        guard let value = Double(literal), value.isFinite, value != 0 || !hasNonzeroSignificand else {
            throw LuxoError(code: 0, message: "JSON number is outside the Float range", name: "DecodingError")
        }
        return value
    }

    private var hasNonzeroSignificand: Bool {
        for byte in literal.utf8 {
            if byte == 69 || byte == 101 { break }
            if byte >= 49 && byte <= 57 { return true }
        }
        return false
    }
}
