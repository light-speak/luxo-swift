import Foundation
import XCTest
@testable import LuxoClient

final class JSONCodableTests: XCTestCase {
    private final class InitializerCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        func reset() { lock.withLock { count = 0 } }
        var value: Int { lock.withLock { count } }
    }

    private final class WeakContext {
        weak var decoder: JSONCodableDecoder?
        weak var document: JSONCodableDocument?
        init(_ decoder: JSONCodableDecoder) { self.decoder = decoder; document = decoder.document }
    }

    private final class LifetimeTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var contexts: [WeakContext] = []
        func record(_ decoder: JSONCodableDecoder) { lock.withLock { contexts.append(WeakContext(decoder)) } }
        func reset() { lock.withLock { contexts.removeAll() } }
        var count: Int { lock.withLock { contexts.count } }
        var alive: Int {
            lock.withLock { contexts.filter { $0.decoder != nil || $0.document != nil }.count }
        }
    }

    private struct LifetimeProbe: Decodable {
        final class Node: Decodable { let child: Node? }
        enum Key: String, CodingKey { case number, node, metadata }
        enum Failure: Error { case rejected, missingContext }
        static let trace = LifetimeTrace()
        let number: Int
        let node: Node?
        let metadata: JSONValue?
        init(from decoder: any Swift.Decoder) throws {
            guard let context = decoder as? JSONCodableDecoder else { throw Failure.missingContext }
            Self.trace.record(context)
            let values = try decoder.container(keyedBy: Key.self)
            number = try values.decode(Int.self, forKey: .number)
            node = try values.decodeIfPresent(Node.self, forKey: .node)
            metadata = try values.decodeIfPresent(JSONValue.self, forKey: .metadata)
            if number < 0 { throw Failure.rejected }
        }
    }

    func testContextualDecoderAndDocumentReleaseAfterSuccessfulAndFailedReads() throws {
        struct Root: Decodable { let metadata: JSONValue; let value: LifetimeProbe }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let node62 = String(repeating: "{\"child\":", count: 62) + "null" + String(repeating: "}", count: 62)
        let cases = [
            ("{\"number\":7}", true), ("{\"number\":-1}", false), ("{\"number\":\"bad\"}", false),
            ("{\"number\":7,\"metadata\":[\(json)]}", false),
            ("{\"number\":7,\"node\":{\"child\":\(node62)}}", false),
            ("{\"number\":7,\"node\":\(node62)}", true),
        ]
        let decoder = LuxoJSONDecoder()
        defer { LifetimeProbe.trace.reset() }
        for _ in 0..<2 {
            for (probe, valid) in cases {
                LifetimeProbe.trace.reset()
                let input = Data("{\"metadata\":\(json),\"value\":\(probe)}".utf8)
                if valid {
                    let value = try decoder.decode(Root.self, from: input)
                    XCTAssertEqual(value.value.number, 7)
                    XCTAssertEqual(LifetimeProbe.trace.alive, 0)
                } else {
                    XCTAssertThrowsError(try decoder.decode(Root.self, from: input))
                }
                XCTAssertEqual(LifetimeProbe.trace.count, 1)
                XCTAssertEqual(LifetimeProbe.trace.alive, 0)
            }
        }
    }

    func testEarlyReturningArrayInitializerStillChecksEveryUnreadJSONValue() throws {
        struct Unread: Decodable {
            init(from decoder: any Swift.Decoder) throws { _ = try decoder.unkeyedContainer() }
        }
        struct Root: Decodable { let metadata: JSONValue; let value: Unread }
        let decoder = LuxoJSONDecoder()
        let metadata = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        for value in ["[]", "[null]", "[\(json)]", "[0,\(json)]"] {
            let input = Data("{\"metadata\":\(metadata),\"value\":\(value)}".utf8)
            XCTAssertNoThrow(try decoder.decode(Root.self, from: input))
        }
        for value in ["[[\(json)]]", "[0,[\(json)]]"] {
            let input = Data("{\"metadata\":\(metadata),\"value\":\(value)}".utf8)
            XCTAssertThrowsError(try decoder.decode(Root.self, from: input)) { error in
                XCTAssertEqual((error as? LuxoError)?.name, "ParseError")
            }
        }
        XCTAssertNoThrow(
            try decoder.decode(Root.self, from: Data("{\"metadata\":\(metadata),\"value\":[]}".utf8)))
    }

    func testContextualSuperDecoderKeepsMissingNullValueAndErrorPaths() throws {
        struct Probe: Decodable {
            enum Key: String, CodingKey { case known }
            let value: Int?
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                XCTAssertTrue(root.allKeys.isEmpty)
                let parent = try root.superDecoder()
                XCTAssertEqual(parent.codingPath.map(\.stringValue), ["value", "super"])
                value = try Int?(from: parent)
            }
        }
        struct Root: Decodable { let metadata: JSONValue; let value: Probe }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        for (text, expected) in [("{}", nil), ("{\"super\":null}", nil), ("{\"super\":7}", 7)] {
            let input = Data("{\"metadata\":\(json),\"value\":\(text)}".utf8)
            XCTAssertEqual(try LuxoJSONDecoder().decode(Root.self, from: input).value.value, expected)
        }
        let invalid = Data("{\"metadata\":\(json),\"value\":{\"super\":\"bad\"}}".utf8)
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: invalid)) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else {
                return XCTFail("lost superclass type mismatch")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["value", "super"])
        }
    }

    func testSharedDecoderKeepsConcurrentDepthFailuresAndRecoveryIsolated() async throws {
        final class Node: Decodable { let child: Node? }
        struct Root: Decodable { let marker: Int; let value: Node; let metadata: JSONValue }
        enum Failure: Error { case acceptedInvalidValue, wrongValue, wrongError }
        let decoder = LuxoJSONDecoder()
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let node = String(repeating: "{\"child\":", count: 63) + "null" + String(repeating: "}", count: 63)
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for marker in 0..<24 {
                group.addTask {
                    func input(_ value: String, _ metadata: String, _ number: String) -> Data {
                        Data("{\"marker\":\(number),\"value\":\(value),\"metadata\":\(metadata)}".utf8)
                    }
                    let valid = input(node, json, String(marker))
                    let invalid = [
                        input("{\"child\":\(node)}", json, String(marker)),
                        input(node, "[\(json)]", String(marker)),
                        input(node, json, "\"invalid\""),
                    ]
                    for _ in 0..<2 {
                        for (index, data) in invalid.enumerated() {
                            do {
                                _ = try decoder.decode(Root.self, from: data)
                                throw Failure.acceptedInvalidValue
                            } catch let error as LuxoError {
                                let expectedName = index == 0 ? "DecodingError" : "ParseError"
                                guard index < 2, error.name == expectedName else { throw Failure.wrongError }
                            } catch DecodingError.typeMismatch(_, let context) {
                                guard index == 2, context.codingPath.map(\.stringValue) == ["marker"] else {
                                    throw Failure.wrongError
                                }
                            }
                            let value = try decoder.decode(Root.self, from: valid)
                            guard value.marker == marker else { throw Failure.wrongValue }
                        }
                    }
                    return 12
                }
            }
            var count = 0
            for try await countPerTask in group { count += countPerTask }
            return count
        }
        XCTAssertEqual(completed, 288)
    }

    func testOverwrittenCustomInitializersDoNotTurnOldBusinessFailuresIntoResponseFailures() throws {
        enum BusinessFailure: Error { case rejected }
        struct Model: Decodable {
            enum Key: String, CodingKey { case number }
            let number: Int
            init(from decoder: any Swift.Decoder) throws {
                number = try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .number)
                if number == 0 { throw BusinessFailure.rejected }
                if number == -1 { throw LuxoError(code: 409, message: "old value rejected", name: "BusinessRule") }
            }
        }
        struct Root: Decodable { let metadata: JSONValue; let value: Model? }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for number in [0, -1] {
            for last in ["null", "{\"number\":7}"] {
                let input = Data("{\"metadata\":\(json),\"value\":{\"number\":\(number)},\"value\":\(last)}".utf8)
                XCTAssertNoThrow(try LuxoJSONDecoder().decode(Root.self, from: input))
            }
            let final = Data("{\"metadata\":\(json),\"value\":{\"number\":7},\"value\":{\"number\":\(number)}}".utf8)
            XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: final)) { error in
                if number == 0 {
                    guard case BusinessFailure.rejected = error else { return XCTFail("lost business error") }
                } else {
                    XCTAssertEqual((error as? LuxoError)?.name, "BusinessRule")
                }
            }
        }
    }

    func testOverwrittenCustomInitializersExecuteOnlyForReturnedValues() throws {
        struct Model: Decodable {
            static let counter = InitializerCounter()
            enum Key: String, CodingKey { case number }
            let number: Int
            init(from decoder: any Swift.Decoder) throws {
                Self.counter.increment()
                number = try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .number)
            }
        }
        struct Root: Decodable { let metadata: JSONValue; let value: Model? }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for (last, expected) in [("null", 0), ("{\"number\":8}", 1)] {
            Model.counter.reset()
            let input = Data("{\"metadata\":\(json),\"value\":{\"number\":7},\"value\":\(last)}".utf8)
            _ = try LuxoJSONDecoder().decode(Root.self, from: input)
            XCTAssertEqual(Model.counter.value, expected)
        }
    }

    func testOverwrittenCollectionAndBorrowedArrayValuesDoNotExecuteBusinessInitializers() throws {
        struct Model: Decodable {
            static let counter = InitializerCounter()
            enum Key: String, CodingKey { case number }
            let number: Int
            init(from decoder: any Swift.Decoder) throws {
                Self.counter.increment()
                number = try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .number)
                if number == 0 { throw LuxoError(code: 409, message: "old value", name: "BusinessRule") }
            }
        }
        struct Borrowed: Decodable {
            let model: Model
            init(from decoder: any Swift.Decoder) throws {
                var array = try decoder.unkeyedContainer()
                model = try array.decode(Model.self)
            }
        }
        struct Root<Value: Decodable>: Decodable { let metadata: JSONValue; let value: Value }
        let metadata = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        func check<Value: Decodable>(_ type: Value.Type, old: String, last: String, calls: Int) throws {
            Model.counter.reset()
            let input = Data("{\"metadata\":\(metadata),\"value\":\(old),\"value\":\(last)}".utf8)
            _ = try LuxoJSONDecoder().decode(Root<Value>.self, from: input)
            XCTAssertEqual(Model.counter.value, calls)
        }
        try check([Model].self, old: "[{\"number\":0}]", last: "[]", calls: 0)
        try check([Model].self, old: "[{\"number\":0}]", last: "[{\"number\":7}]", calls: 1)
        try check([String: Model].self, old: "{\"old\":{\"number\":0}}", last: "{}", calls: 0)
        try check([String: Model].self, old: "{\"old\":{\"number\":0}}", last: "{\"new\":{\"number\":7}}", calls: 1)
        try check(Borrowed.self, old: "[{\"number\":0}]", last: "[{\"number\":7}]", calls: 1)
    }

    func testOverwrittenUnobservedModelsUseRawJSONDepthWithoutInitializers() throws {
        final class Node: Decodable { let child: Node? }
        struct JSONHolder: Decodable {
            static let counter = InitializerCounter()
            let child: JSONValue
            enum Key: String, CodingKey { case child }
            init(from decoder: any Swift.Decoder) throws {
                Self.counter.increment()
                child = try decoder.container(keyedBy: Key.self).decode(JSONValue.self, forKey: .child)
            }
        }
        struct ModelHolder: Decodable {
            static let counter = InitializerCounter()
            let child: Node
            enum Key: String, CodingKey { case child }
            init(from decoder: any Swift.Decoder) throws {
                Self.counter.increment()
                child = try decoder.container(keyedBy: Key.self).decode(Node.self, forKey: .child)
            }
        }
        struct Root<Value: Decodable>: Decodable { let metadata: JSONValue; let value: Value? }
        let metadata = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for depth in [64, 127, 128] {
            let json = String(repeating: "{\"child\":", count: depth) + "null" + String(repeating: "}", count: depth)
            let input = Data("{\"metadata\":\(metadata),\"value\":{\"child\":\(json)},\"value\":null}".utf8)
            // The discarded value includes its own outer object, independently of the final model's type.
            if depth < 128 {
                XCTAssertNil(try LuxoJSONDecoder().decode(Root<JSONHolder>.self, from: input).value)
                XCTAssertNil(try LuxoJSONDecoder().decode(Root<ModelHolder>.self, from: input).value)
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root<JSONHolder>.self, from: input))
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root<ModelHolder>.self, from: input))
            }
            XCTAssertEqual(JSONHolder.counter.value, 0)
            XCTAssertEqual(ModelHolder.counter.value, 0)
        }
    }

    func testDiscardedDelegatedModelsValidateRawJSONWithoutReadingMissingMembers() throws {
        struct Model: Decodable { let number: Int; let metadata: JSONValue }
        struct Wrapped: Decodable {
            let value: Model
            init(from decoder: any Swift.Decoder) throws {
                value = try decoder.singleValueContainer().decode(Model.self)
            }
        }
        struct Root: Decodable { let metadata: JSONValue; let value: Wrapped? }
        let prefix = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for depth in [127, 128, 129] {
            let json = String(repeating: "[", count: depth) + "7" + String(repeating: "]", count: depth)
            let input = Data("{\"metadata\":\(prefix),\"value\":{\"metadata\":\(json)},\"value\":null}".utf8)
            // No model is initialized: its outer object is part of the discarded JSON budget.
            if depth == 127 {
                XCTAssertNil(try LuxoJSONDecoder().decode(Root.self, from: input).value)
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: input))
            }
        }
        let last = Data("{\"metadata\":\(prefix),\"value\":{}}".utf8)
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: last)) { error in
            guard case DecodingError.keyNotFound = error else { return XCTFail("lost last-member failure") }
        }
    }

    func testNestedSchemaObservationsValidateEveryDuplicateFieldGroup() throws {
        struct Model: Decodable { let metadata: JSONValue }
        struct Root: Decodable { let value: Model }
        let last = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for depth in [128, 129] {
            let json = String(repeating: "[", count: depth) + "7" + String(repeating: "]", count: depth)
            let old = "{\"metadata\":\(json),\"metadata\":7}"
            let input = Data("{\"value\":\(old),\"value\":{\"metadata\":\(last)}}".utf8)
            if depth == 128 {
                XCTAssertEqual(
                    try LuxoJSONDecoder().decode(Root.self, from: input).value.metadata,
                    try JSONValue.parse(Data(last.utf8)))
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: input))
            }
        }
    }

    func testContextualIndexChecksMillionElementArrayBoundary() throws {
        struct Root: Decodable { let metadata: JSONValue }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let million = String(repeating: "0,", count: 999_999) + "0"
        let valid = Data("{\"metadata\":\(json),\"unknown\":[\(million)]}".utf8)
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(Root.self, from: valid))
        let invalid = Data("{\"metadata\":\(json),\"unknown\":[0,\(million)]}".utf8)
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: invalid))
    }

    func testContextualDelegationStopsRecursiveConstructorsAndRecovers() throws {
        struct Loop: Decodable {
            init(from decoder: any Swift.Decoder) throws {
                _ = try decoder.singleValueContainer().decode(Loop.self)
            }
        }
        struct Root<Value: Decodable>: Decodable { let metadata: JSONValue; let value: Value }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let input = Data("{\"metadata\":\(json),\"value\":7}".utf8)
        let decoder = LuxoJSONDecoder()
        XCTAssertThrowsError(try decoder.decode(Root<Loop>.self, from: input)) { error in
            XCTAssertEqual((error as? LuxoError)?.message, "Codable wrapper nesting exceeds 128 levels")
        }
        XCTAssertEqual(try decoder.decode(Root<Int>.self, from: input).value, 7)
    }

    func testContextualTypedArrayAndDictionaryDepthBoundaries() throws {
        final class ArrayValue: Decodable {
            let children: [ArrayValue]
            init(from decoder: any Swift.Decoder) throws {
                children = try decoder.singleValueContainer().decode([ArrayValue].self)
            }
        }
        final class DictionaryValue: Decodable {
            let children: [String: DictionaryValue]
            init(from decoder: any Swift.Decoder) throws {
                children = try decoder.singleValueContainer().decode([String: DictionaryValue].self)
            }
        }
        struct Root<Value: Decodable>: Decodable { let metadata: JSONValue; let value: Value }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for depth in [128, 129] {
            let array = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            let object =
                String(repeating: "{\"v\":", count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
            let a = Data("{\"metadata\":\(json),\"value\":\(array)}".utf8)
            let d = Data("{\"metadata\":\(json),\"value\":\(object)}".utf8)
            if depth == 128 {
                XCTAssertNoThrow(try LuxoJSONDecoder().decode(Root<ArrayValue>.self, from: a))
                XCTAssertNoThrow(try LuxoJSONDecoder().decode(Root<DictionaryValue>.self, from: d))
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root<ArrayValue>.self, from: a))
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root<DictionaryValue>.self, from: d))
            }
        }
    }

    func testRepeatedBorrowedFieldsKeepScalarOptionalMapAndCodingPathSemantics() throws {
        struct Probe: Decodable {
            enum Key: String, CodingKey { case value, child, number, optional, map }
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                let value = try root.nestedContainer(keyedBy: Key.self, forKey: .value)
                let child = try value.nestedContainer(keyedBy: Key.self, forKey: .child)
                XCTAssertEqual(child.allKeys.count, 3)
                XCTAssertEqual(try child.decode(Int.self, forKey: .number), 7)
                XCTAssertEqual(try child.decodeIfPresent(Int.self, forKey: .optional), 4)
                XCTAssertEqual(try child.decode([String: Int].self, forKey: .map), ["k": 5])
                let scalar = try child.superDecoder(forKey: .number).singleValueContainer()
                XCTAssertEqual(scalar.codingPath.map(\.stringValue), ["value", "child", "number"])
            }
        }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let old =
            "{\"child\":{\"number\":1,\"number\":2,\"optional\":null,\"optional\":3,\"map\":{},\"map\":{\"k\":1,\"k\":2}}}"
        let last = "{\"child\":{\"number\":7,\"optional\":4,\"map\":{\"k\":5}}}"
        let input = Data("{\"metadata\":\(json),\"value\":\(old),\"value\":\(old),\"value\":\(last)}".utf8)
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(Probe.self, from: input))
    }

    func testNestedDuplicateReplayChecksUnmaterializedJSONForEveryEarlierGroup() throws {
        final class Node: Decodable { let child: Node? }
        struct Inner: Decodable { let node: Node? }
        struct Outer: Decodable { let inner: Inner }
        struct Root: Decodable { let metadata: JSONValue; let value: Outer }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for layers in [61, 62, 128, 129] {
            var node = "{}"
            for _ in 1..<layers { node = "{\"child\":\(node)}" }
            for last in ["{\"node\":null}", "{}"] {
                let old = "{\"inner\":{\"node\":\(node)},\"inner\":\(last)}"
                let input = Data("{\"metadata\":\(json),\"value\":\(old),\"value\":{\"inner\":{\"node\":null}}}".utf8)
                if layers <= 128 {
                    XCTAssertNil(try LuxoJSONDecoder().decode(Root.self, from: input).value.inner.node)
                } else {
                    XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: input))
                }
            }
        }
    }

    func testRequiredJSONAndDataFieldsValidateOwnDiscardedOccurrences() throws {
        struct JSONRoot: Decodable { let metadata: JSONValue }
        struct DataRoot: Decodable {
            static let counter = InitializerCounter()
            enum Key: String, CodingKey { case metadata, data }
            let metadata: JSONValue
            let data: Data
            init(from decoder: any Swift.Decoder) throws {
                Self.counter.increment()
                let values = try decoder.container(keyedBy: Key.self)
                metadata = try values.decode(JSONValue.self, forKey: .metadata)
                data = try values.decode(Data.self, forKey: .data)
            }
        }
        for depth in [128, 129] {
            let json = String(repeating: "[", count: depth) + "7" + String(repeating: "]", count: depth)
            let metadata = Data("{\"metadata\":\(json),\"metadata\":7}".utf8)
            let bytes = Data("{\"metadata\":7,\"data\":\(json),\"data\":\"AQ==\"}".utf8)
            if depth == 128 {
                XCTAssertEqual(try LuxoJSONDecoder().decode(JSONRoot.self, from: metadata).metadata, .integer(7))
                XCTAssertEqual(try LuxoJSONDecoder().decode(DataRoot.self, from: bytes).data, Data([1]))
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(JSONRoot.self, from: metadata))
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(DataRoot.self, from: bytes))
            }
        }
        struct Nested: Decodable { let metadata: JSONValue; let value: DataRoot }
        let context = String(repeating: "{\"v\":", count: 65) + "0" + String(repeating: "}", count: 65)
        for depth in [128, 129] {
            DataRoot.counter.reset()
            let json = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
            let old = "{\"data\":\(json),\"data\":\"AA==\"}"
            let input = Data(
                "{\"metadata\":\(context),\"value\":\(old),\"value\":{\"metadata\":0,\"data\":\"AQ==\"}}".utf8)
            if depth == 128 {
                XCTAssertEqual(try LuxoJSONDecoder().decode(Nested.self, from: input).value.data, Data([1]))
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Nested.self, from: input))
            }
            XCTAssertEqual(DataRoot.counter.value, 1)
        }
    }

    func testDiscardedGenericOptionalAndSingleValueWrappersCheckRawJSON128() throws {
        final class Node: Decodable { let number: Int; let child: Node? }
        struct Root<Value: Decodable>: Decodable { let metadata: JSONValue; let value: Value }
        struct Wrapped<Value: Decodable>: Decodable {
            let value: Value
            init(from decoder: any Swift.Decoder) throws {
                value = try decoder.singleValueContainer().decode(Value.self)
            }
        }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for layers in [63, 64, 128, 129] {
            var node = "{\"number\":7}"
            for _ in 1..<layers { node = "{\"number\":7,\"child\":\(node)}" }
            let text = Data("{\"metadata\":\(json),\"value\":\(node),\"value\":null}".utf8)
            if layers <= 128 {
                XCTAssertNil(try LuxoJSONDecoder().decode(Root<Node?>.self, from: text).value)
                XCTAssertNil(try LuxoJSONDecoder().decode(Root<Wrapped<Node?>>.self, from: text).value.value)
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root<Node?>.self, from: text))
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root<Wrapped<Node?>>.self, from: text))
            }
        }
    }

    func testDiscardedPartialModelsCheckRawDepthWithoutExecutingMemberReads() throws {
        struct Item: Decodable { let number: Int; let metadata: JSONValue }
        struct Partial: Decodable { let nested: [Item]; let number: Int }
        struct Root: Decodable { let metadata: JSONValue; let value: Partial? }
        let prefix = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for depth in [125, 126, 128, 129] {
            let json = String(repeating: "[", count: depth) + "7" + String(repeating: "]", count: depth)
            let text = "{\"metadata\":\(prefix),\"value\":{\"nested\":[{\"metadata\":\(json)}]},\"value\":null}"
            // Partial object, array and item contribute three containers before the JSON field.
            if depth == 125 {
                XCTAssertNil(try LuxoJSONDecoder().decode(Root.self, from: Data(text.utf8)).value)
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: Data(text.utf8)))
            }
        }
    }

    func testDiscardedCollectionsValidateRawElementsWithoutRequiringModelMembers() throws {
        final class Node: Decodable { let number: Int; let child: Node? }
        struct Root: Decodable { let metadata: JSONValue; let value: [Node] }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for layers in [63, 64, 128, 129] {
            var node = "{\"number\":7}"
            for _ in 1..<layers { node = "{\"number\":7,\"child\":\(node)}" }
            let text = "{\"metadata\":\(json),\"value\":[{},\(node)],\"value\":[]}"
            if layers <= 128 {
                XCTAssertTrue(try LuxoJSONDecoder().decode(Root.self, from: Data(text.utf8)).value.isEmpty)
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: Data(text.utf8)))
            }
        }
    }

    func testDiscardedUUIDAndIntegerDictionariesValidateValuesWithoutRequiringMembers() throws {
        struct Model: Decodable { let number: Int; let metadata: JSONValue }
        struct UUIDRoot: Decodable { let metadata: JSONValue; let value: [UUID: Model] }
        struct IntRoot: Decodable { let metadata: JSONValue; let value: [Int: Model] }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let key = "00112233-4455-6677-8899-aabbccddeeff"
        let item = "{\"number\":7,\"metadata\":\(json)}"
        let array = "{\"metadata\":\(json),\"value\":[\"\(key)\",{}],\"value\":[\"\(key)\",\(item)]}"
        XCTAssertEqual(
            try LuxoJSONDecoder().decode(UUIDRoot.self, from: Data(array.utf8)).value.values.first?.number, 7)
        let keyed = "{\"metadata\":\(json),\"value\":{\"7\":{}},\"value\":{\"7\":\(item)}}"
        XCTAssertEqual(try LuxoJSONDecoder().decode(IntRoot.self, from: Data(keyed.utf8)).value[7]?.number, 7)
    }

    func testLastCollectionAndOptionalMembersStillRequireBusinessFields() throws {
        struct Model: Decodable { let number: Int }
        struct Root: Decodable { let metadata: JSONValue; let value: Model? }
        struct List: Decodable { let metadata: JSONValue; let value: [Model] }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let optional = "{\"metadata\":\(json),\"value\":{\"number\":7},\"value\":{}}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: Data(optional.utf8)))
        let list = "{\"metadata\":\(json),\"value\":[],\"value\":[{}]}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(List.self, from: Data(list.utf8)))
    }

    func testOverwrittenCollectionMembersDoNotRequireMissingFields() throws {
        struct Model: Decodable { let number: Int; let metadata: JSONValue }
        struct List: Decodable { let metadata: JSONValue; let value: [Model] }
        struct DictionaryRoot: Decodable { let metadata: JSONValue; let value: [String: Model] }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        let item = "{\"number\":7,\"metadata\":\(json)}"
        for previous in ["[{}]", "[{},{}]", "null", "7"] {
            let text = "{\"metadata\":\(json),\"value\":\(previous),\"value\":[\(item)]}"
            let value = try LuxoJSONDecoder().decode(List.self, from: Data(text.utf8))
            XCTAssertEqual(value.value.count, 1)
            XCTAssertEqual(value.value[0].number, 7)
        }
        for previous in ["{\"x\":{}}", "{\"x\":{},\"y\":{}}", "null", "7"] {
            let text = "{\"metadata\":\(json),\"value\":\(previous),\"value\":{\"x\":\(item)}}"
            let value = try LuxoJSONDecoder().decode(DictionaryRoot.self, from: Data(text.utf8))
            XCTAssertEqual(value.value.count, 1)
            XCTAssertEqual(value.value["x"]?.number, 7)
        }
    }

    func testOverwrittenOptionalModelsPreservePresentAndNullLastValues() throws {
        struct Model: Decodable { let number: Int; let metadata: JSONValue }
        struct Root: Decodable { let metadata: JSONValue; let value: Model? }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for previous in ["{}", "null", "7", "[]"] {
            for last in ["null", "{\"number\":7,\"metadata\":\(json)}"] {
                let text = "{\"metadata\":\(json),\"value\":\(previous),\"value\":\(last)}"
                let value = try LuxoJSONDecoder().decode(Root.self, from: Data(text.utf8))
                XCTAssertEqual(value.value?.number, last == "null" ? nil : 7)
            }
        }
    }

    func testDiscardedDuplicateModelsDoNotRequireMissingMembers() throws {
        struct Model: Decodable { let number: Int; let metadata: JSONValue }
        struct Synthesized: Decodable { let nested: Model }
        struct Borrowed: Decodable {
            enum Key: String, CodingKey { case nested, metadata, number }
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                let nested = try root.nestedContainer(keyedBy: Key.self, forKey: .nested)
                _ = try nested.decode(Int.self, forKey: .number)
                _ = try nested.decode(JSONValue.self, forKey: .metadata)
            }
        }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        for previous in ["{}", "null", "7", "[]"] {
            let input = Data("{\"nested\":\(previous),\"nested\":{\"number\":7,\"metadata\":\(json)}}".utf8)
            XCTAssertNoThrow(try LuxoJSONDecoder().decode(Synthesized.self, from: input))
            XCTAssertNoThrow(try LuxoJSONDecoder().decode(Borrowed.self, from: input))
        }
    }

    func testDiscardedTypedCollectionsCheckRawJSONWhenLastIsEmpty() throws {
        struct Root: Decodable {
            let metadata: JSONValue
            let items: [HandwrittenNode]?
            let named: [String: HandwrittenNode]?
        }
        let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
        struct Required: Decodable { let metadata: JSONValue; let items: [HandwrittenNode] }
        for layers in [65, 128, 129] {
            let model = handwrittenJSON(layers, lists: false, json: 0)
            for members in ["\"items\":[\(model)],\"items\":[]", "\"named\":{\"x\":\(model)},\"named\":{}"] {
                let input = Data("{\"metadata\":\(json),\(members)}".utf8)
                if layers <= 128 {
                    XCTAssertNoThrow(try LuxoJSONDecoder().decode(Root.self, from: input))
                } else {
                    XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: input))
                }
            }
            let input = Data("{\"metadata\":\(json),\"items\":[\(model)],\"items\":[]}".utf8)
            if layers <= 128 {
                XCTAssertTrue(try LuxoJSONDecoder().decode(Required.self, from: input).items.isEmpty)
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Required.self, from: input))
            }
        }
    }

    func testNestedDuplicateArraysUseElementTypesAndCheckEarlierValues() throws {
        struct Nested: Decodable {
            enum Key: String, CodingKey { case items, metadata }
            let value: JSONValue
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                var items = try root.nestedUnkeyedContainer(forKey: .items)
                let item = try items.nestedContainer(keyedBy: Key.self)
                value = try item.decode(JSONValue.self, forKey: .metadata)
            }
        }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let valid = "{\"items\":[{\"metadata\":\(json)}],\"items\":[{\"metadata\":\(json)}]}"
        XCTAssertEqual(
            try LuxoJSONDecoder().decode(Nested.self, from: Data(valid.utf8)).value,
            try JSONValue.parse(Data(json.utf8)))
        let invalid = "{\"items\":[{\"metadata\":[\(json)]}],\"items\":[{\"metadata\":\(json)}]}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Nested.self, from: Data(invalid.utf8)))
    }

    func testNestedDuplicateAbsentOptionalFieldsCheckEarlierRawJSON() throws {
        struct Nested: Decodable {
            enum Key: String, CodingKey { case nested, child }
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                let nested = try root.nestedContainer(keyedBy: Key.self, forKey: .nested)
                _ = try nested.decodeIfPresent(HandwrittenNode.self, forKey: .child)
            }
        }
        for depth in [62, 63, 128, 129] {
            let node = handwrittenJSON(depth, lists: false, json: 0)
            let text = "{\"nested\":{\"child\":\(node)},\"nested\":{}}"
            if depth <= 128 {
                XCTAssertNoThrow(try LuxoJSONDecoder().decode(Nested.self, from: Data(text.utf8)))
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Nested.self, from: Data(text.utf8)))
            }
        }
    }

    func testDuplicateBorrowedArraysKeepIndependentCursorsAndTailValidation() throws {
        struct Nested: Decodable {
            enum Key: String, CodingKey { case items, metadata }
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                for _ in 0..<2 {
                    var array = try root.nestedUnkeyedContainer(forKey: .items)
                    XCTAssertTrue(try array.decodeNil())
                    var nested = try array.nestedUnkeyedContainer()
                    _ = try nested.decode(JSONValue.self)
                    let object = try array.nestedContainer(keyedBy: Key.self)
                    _ = try object.decode(JSONValue.self, forKey: .metadata)
                    XCTAssertEqual(try Int(from: array.superDecoder()), 7)
                }
            }
        }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let array = "[null,[\(json)],{\"metadata\":\(json)},7]"
        for earlier in ["[]", array, String(array.dropLast()) + ",\(json)]"] {
            let text = "{\"items\":\(earlier),\"items\":\(array)}"
            XCTAssertNoThrow(try LuxoJSONDecoder().decode(Nested.self, from: Data(text.utf8)))
        }
        let invalid = String(array.dropLast()) + ",[\(json)]]"
        let text = "{\"items\":\(invalid),\"items\":\(array)}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Nested.self, from: Data(text.utf8)))
    }

    func testDuplicateSuperDecodersKeepJSONAndSingleValueTypes() throws {
        struct Wrapped: Decodable {
            let value: [JSONValue]
            init(from decoder: any Swift.Decoder) throws {
                value = try decoder.singleValueContainer().decode([JSONValue].self)
            }
        }
        struct Nested: Decodable {
            enum Key: String, CodingKey { case metadata, number, wrapped }
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                _ = try JSONValue(from: root.superDecoder(forKey: .metadata))
                XCTAssertEqual(try Int(from: root.superDecoder(forKey: .number)), 7)
                _ = try Wrapped(from: root.superDecoder(forKey: .wrapped))
            }
        }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let fields = "\"metadata\":\(json),\"number\":7,\"wrapped\":[\(json)]"
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(Nested.self, from: Data("{\(fields),\(fields)}".utf8)))
        let invalid = "{\"metadata\":[\(json)],\(fields)}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Nested.self, from: Data(invalid.utf8)))
    }

    func testNestedContainerDuplicatesUseTheObservedJSONFieldType() throws {
        struct Nested: Decodable {
            enum Key: String, CodingKey { case nested, metadata }
            let value: JSONValue
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                let nested = try root.nestedContainer(keyedBy: Key.self, forKey: .nested)
                value = try nested.decode(JSONValue.self, forKey: .metadata)
            }
        }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let text = "{\"nested\":{\"metadata\":\(json)},\"nested\":{\"metadata\":\(json)}}"
        XCTAssertEqual(
            try LuxoJSONDecoder().decode(Nested.self, from: Data(text.utf8)).value,
            try JSONValue.parse(Data(json.utf8)))
        let invalid = "{\"nested\":{\"metadata\":[\(json)]},\"nested\":{\"metadata\":\(json)}}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Nested.self, from: Data(invalid.utf8)))
    }

    func testContextualCodableKeepsPrimitiveAndBorrowedContainerSemantics() throws {
        struct DeepPrimitives: Codable, Equatable { let metadata: JSONValue; let values: Primitives }
        struct DeepContainers: Codable, Equatable { let metadata: JSONValue; let values: Containers }
        var json = JSONValue.integer(7)
        for _ in 0..<128 { json = .array([json]) }
        try roundTrip(DeepPrimitives(metadata: json, values: Primitives()))
        try roundTrip(DeepContainers(metadata: json, values: Containers()))
    }

    func testContextualEmptyProjectionKeepsArrayAndDictionaryIdentity() throws {
        struct ArrayRoot: Decodable { let metadata: JSONValue; let values: [EmptyProjection] }
        struct DictionaryRoot: Decodable { let metadata: JSONValue; let values: [String: EmptyProjection] }
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        XCTAssertThrowsError(
            try LuxoJSONDecoder().decode(ArrayRoot.self, from: Data("{\"metadata\":\(json),\"values\":[{}]}".utf8))
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("lost projection error") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["values", "0"])
        }
        XCTAssertNoThrow(
            try LuxoJSONDecoder().decode(
                DictionaryRoot.self, from: Data("{\"metadata\":\(json),\"values\":{\"0\":{}}}".utf8)))
    }

    func testNoSchemaHTTPReturnsModelBytesForTypedCodableValidation() async throws {
        let text = handwrittenJSON(64, lists: true, json: 128)
        let transport = HTTPTransport(backend: HandwrittenBackend(response: Data("{\"data\":\(text)}".utf8)))
        let response = try await transport.call("read")
        XCTAssertEqual(response.data, Data(text.utf8))
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(HandwrittenNode.self, from: response.data))
        let json129 = String(repeating: "[", count: 129) + "null" + String(repeating: "]", count: 129)
        let raw = HTTPTransport(backend: HandwrittenBackend(response: Data("{\"data\":\(json129)}".utf8)))
        let untyped = try await raw.call("read")
        XCTAssertThrowsError(try JSONValue.parse(untyped.data))
        try raw.setSchema(["read": .init(id: 7, response: .json)])
        do { _ = try await raw.call("read"); XCTFail("declared JSON129 accepted") } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ParseError")
        }
        let late = "{\"data\":\(json129),\"data\":null,\"error\":\"Rejected\",\"code\":400,\"message\":\"no\"}"
        let failed = HTTPTransport(backend: HandwrittenBackend(response: Data(late.utf8)))
        do { _ = try await failed.call("read"); XCTFail("discarded error JSON129 accepted") } catch let error
            as LuxoError
        { XCTAssertEqual(error.name, "ParseError") }
    }

    private struct HandwrittenBackend: HTTPBackend {
        let response: Data
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            HTTPBackendResponse(status: 200, body: response)
        }
    }

    func testFailedScalarProbeCannotHideThe65thEmptyModel() {
        struct Probe: Decodable {
            init(from decoder: any Swift.Decoder) throws {
                _ = try? decoder.singleValueContainer().decode(Bool.self)
            }
        }
        final class Node: Decodable {
            let child: Node?
            let tail: Probe?
        }
        var text = "{\"tail\":{}}"
        for _ in 0..<63 { text = "{\"child\":\(text)}" }
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Node.self, from: Data(text.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("64"))
        }
    }

    func testHandwrittenCodableReads64ModelsAndIndependentJSON128WithoutSchema() throws {
        for lists in [false, true] {
            for layers in [63, 64] {
                let text = handwrittenJSON(layers, lists: lists, json: 128)
                let decoder = LuxoJSONDecoder()
                let values = [
                    try decoder.decode(HandwrittenNode.self, from: Data(text.utf8)),
                    try decoder.decode([HandwrittenNode].self, from: Data("[\(text)]".utf8))[0],
                    try XCTUnwrap(
                        decoder.decode([String: HandwrittenNode].self, from: Data("{\"root\":\(text)}".utf8))["root"]),
                ]
                for value in values {
                    var node = value
                    for _ in 1..<layers {
                        node = try XCTUnwrap(lists ? node.children?.first : node.child)
                    }
                    var expected = JSONValue.integer(9_007_199_254_740_993)
                    for _ in 0..<128 { expected = .array([expected]) }
                    XCTAssertEqual(node.metadata, expected)
                }
            }
        }
    }

    func testHandwrittenCodableRejects65ModelsAndRecoversWithoutSchema() throws {
        let decoder = LuxoJSONDecoder()
        for lists in [false, true] {
            let invalid = handwrittenJSON(65, lists: lists, json: 0)
            XCTAssertThrowsError(try decoder.decode(HandwrittenNode.self, from: Data(invalid.utf8))) { error in
                XCTAssertTrue(String(describing: error).contains("64"))
            }
            XCTAssertNoThrow(try decoder.decode(HandwrittenNode.self, from: Data("{}".utf8)))
        }
    }

    func testHandwrittenCodableChecksDiscardedAndUnknownJSONDepth() throws {
        let valid = handwrittenJSON(1, lists: false, json: 128)
        let invalid = handwrittenJSON(1, lists: false, json: 129)
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(HandwrittenNode.self, from: Data(valid.utf8)))
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(HandwrittenNode.self, from: Data(invalid.utf8)))
        for key in ["metadata", "unknown"] {
            let value = String(repeating: "[", count: 129) + "null" + String(repeating: "]", count: 129)
            let text = "{\"\(key)\":\(value),\"\(key)\":null}"
            XCTAssertThrowsError(try LuxoJSONDecoder().decode(HandwrittenNode.self, from: Data(text.utf8)))
        }
        let model65 = handwrittenJSON(65, lists: false, json: 0)
        let duplicate = "{\"child\":\(model65),\"child\":null}"
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(HandwrittenNode.self, from: Data(duplicate.utf8)))
        let raw129 = handwrittenJSON(129, lists: false, json: 0)
        let tooDeep = "{\"child\":\(raw129),\"child\":null}"
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(HandwrittenNode.self, from: Data(tooDeep.utf8)))
    }

    private func handwrittenJSON(_ layers: Int, lists: Bool, json: Int) -> String {
        var text =
            "{\"metadata\":" + String(repeating: "[", count: json) + "9007199254740993"
            + String(repeating: "]", count: json) + "}"
        for _ in 1..<layers { text = lists ? "{\"children\":[\(text)]}" : "{\"child\":\(text)}" }
        return text
    }

    func testNoSchemaPartialArraysValidateUnconsumedValuesAndSyntax() throws {
        struct First: Decodable {
            let value: Int
            init(from decoder: any Swift.Decoder) throws {
                var items = try decoder.unkeyedContainer()
                value = try items.decode(Int.self)
            }
        }
        let valid = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        XCTAssertEqual(try LuxoJSONDecoder().decode(First.self, from: Data("[7,\(valid)]".utf8)).value, 7)
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(First.self, from: Data("[7,[\(valid)]]".utf8)))
        for invalid in ["[7,]", "[7,1e]", "[7,\"\\ud800\"]", "[7] false", "{\"x\":1,}"] {
            XCTAssertThrowsError(try LuxoJSONDecoder().decode(First.self, from: Data(invalid.utf8)))
        }
        let million = "[7," + String(repeating: "0,", count: 999_998) + "0]"
        XCTAssertEqual(try LuxoJSONDecoder().decode(First.self, from: Data(million.utf8)).value, 7)
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(First.self, from: Data(("[0," + million.dropFirst()).utf8)))
    }

    func testNoSchemaRepeatedProjectionKeepsEarlierSuccessfulValidation() throws {
        struct Empty: Decodable {}
        struct Twice: Decodable {
            let node: HandwrittenNode
            init(from decoder: any Swift.Decoder) throws {
                let value = try decoder.singleValueContainer()
                node = try value.decode(HandwrittenNode.self)
                XCTAssertNil(try? value.decode(Empty.self))
            }
        }
        let text = handwrittenJSON(64, lists: false, json: 128)
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(Twice.self, from: Data(text.utf8)))
    }

    func testNoSchemaDirectJSONValueAndKnownSchemaKeepInheritedModelDepth() throws {
        struct Direct: Decodable {
            enum Key: String, CodingKey { case metadata }
            let value: JSONValue
            init(from decoder: any Swift.Decoder) throws {
                value = try JSONValue(from: decoder.container(keyedBy: Key.self).superDecoder(forKey: .metadata))
            }
        }
        let json = String(repeating: "[", count: 128) + "9223372036854775808" + String(repeating: "]", count: 128)
        let direct = try LuxoJSONDecoder().decode(Direct.self, from: Data("{\"metadata\":\(json)}".utf8))
        XCTAssertEqual(direct.value, try JSONValue.parse(Data(json.utf8)))
        struct Known: Codable, Sendable, LuxoJSONSchemaProviding {
            let metadata: JSONValue
            static var luxoJSONSchema: LuxoJSONReadSchema {
                .model("Known", types: ["Known": ["metadata": .init(fieldID: 1, type: "JSON")]])
            }
        }
        final class Node: Decodable { let child: Node?; let known: Known? }
        for layers in [63, 64] {
            var text = "{\"known\":{\"metadata\":\(json)}}"
            for _ in 1..<layers { text = "{\"child\":\(text)}" }
            if layers == 63 {
                XCTAssertNoThrow(try LuxoJSONDecoder().decode(Node.self, from: Data(text.utf8)))
            } else {
                XCTAssertThrowsError(try LuxoJSONDecoder().decode(Node.self, from: Data(text.utf8))) { error in
                    XCTAssertTrue(String(describing: error).contains("64"))
                }
            }
        }
    }

    func testStructuredWriterKeepsModelAndJSONBudgetsIndependent() throws {
        struct Projection: LuxoBinaryEncodable {
            let value: LuxoValue
            func encode(to encoder: any Swift.Encoder) throws { XCTFail("must use the typed projection") }
            func writeLuxo(to encoder: inout LuxoClient.Encoder) throws { XCTFail("not a Binary fixture") }
            func luxoJSONValue() throws -> LuxoValue { value }
        }
        var json = JSONValue.integer(7)
        for _ in 0..<128 { json = .array([json]) }
        for lists in [false, true] {
            for layers in [63, 64, 65] {
                var value: LuxoValue = .object(["metadata": .json(json)])
                for _ in 1..<layers { value = .object(["next": lists ? .array([value]) : value]) }
                let projected = LuxoValue.structured(Projection(value: value))
                if layers <= 64 {
                    let data = try JSONWriter.encode(projected)
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("7"))
                } else {
                    XCTAssertThrowsError(try JSONWriter.encode(projected)) { error in
                        XCTAssertEqual((error as? LuxoError)?.message, "model nesting exceeds 64 levels")
                    }
                }
            }
        }
        var arrays: LuxoValue = .int(1)
        for _ in 0..<128 { arrays = .array([arrays]) }
        XCTAssertNoThrow(try JSONWriter.encode(.structured(Projection(value: arrays))))
        XCTAssertThrowsError(try JSONWriter.encode(.structured(Projection(value: .array([arrays])))))
        XCTAssertNoThrow(try JSONWriter.encode(.structured(Projection(value: .object([:])))))
        struct RecursiveProjection: LuxoBinaryEncodable {
            func encode(to encoder: any Swift.Encoder) throws { XCTFail("must use the typed projection") }
            func writeLuxo(to encoder: inout LuxoClient.Encoder) throws { XCTFail("not a Binary fixture") }
            func luxoJSONValue() throws -> LuxoValue { .structured(self) }
        }
        XCTAssertThrowsError(try JSONWriter.encode(.structured(RecursiveProjection()))) { error in
            XCTAssertEqual((error as? LuxoError)?.message, "model nesting exceeds 64 levels")
        }
        XCTAssertEqual(
            try JSONWriter.encode(LuxoValue.encode(["values": [7, 8]])), Data("{\"values\":[7,8]}".utf8))
    }

    func testEmpty65thModelIsRejectedByBothCodableProjectionAndWriter() {
        final class Node: Encodable, Sendable {
            let children: [Node]?
            init(_ children: [Node]? = nil) { self.children = children }
        }
        var value = Node()
        for _ in 1..<65 { value = Node([value]) }
        for operation in [
            { _ = try LuxoValue.encode(value) },
            { _ = try LuxoJSONEncoder().encode(value) },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual((error as? LuxoError)?.message, "model nesting exceeds 64 levels")
            }
        }
    }

    func testHandwrittenCodableWritesModel64WithoutSchema() throws {
        let encoder = LuxoJSONEncoder()
        for lists in [false, true] {
            let value = handwrittenNode(64, lists: lists)
            XCTAssertNoThrow(try encoder.encode(value))
            XCTAssertNoThrow(try encoder.encode([value]))
            XCTAssertNoThrow(try encoder.encode(["root": value]))
            XCTAssertNoThrow(try encoder.encode(Optional.some(value)))
        }
    }

    func testHandwrittenCodableRejectsModel65AndRecovers() throws {
        let encoder = LuxoJSONEncoder()
        for lists in [false, true] {
            XCTAssertThrowsError(try encoder.encode(handwrittenNode(65, lists: lists))) { error in
                XCTAssertEqual((error as? LuxoError)?.name, "EncodingError")
                XCTAssertTrue((error as? LuxoError)?.message.contains("64") == true)
            }
            XCTAssertNoThrow(try encoder.encode(handwrittenNode(1, lists: lists)))
        }
    }

    func testDictionaryWithNonStringKeysRetainsItsUnkeyedRepresentation() throws {
        let key = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        for value in [[UUID: Int](), [key: 7]] {
            let data = try LuxoJSONEncoder().encode(value)
            XCTAssertEqual(data.first, 91)
            XCTAssertEqual(try LuxoJSONDecoder().decode([UUID: Int].self, from: data), value)
        }
    }

    private func handwrittenNode(_ layers: Int, lists: Bool) -> HandwrittenNode {
        var json = JSONValue.string("leaf")
        for _ in 0..<128 { json = .array([json]) }
        var node = HandwrittenNode(metadata: json, children: [])
        for _ in 1..<layers {
            node = lists ? HandwrittenNode(children: [node]) : HandwrittenNode(child: node)
        }
        return node
    }

    private final class HandwrittenNode: Codable {
        let metadata: JSONValue?
        let child: HandwrittenNode?
        let children: [HandwrittenNode]?
        init(metadata: JSONValue? = nil, child: HandwrittenNode? = nil, children: [HandwrittenNode]? = nil) {
            self.metadata = metadata
            self.child = child
            self.children = children
        }
    }

    func testCustomDictionaryDelegationKeeps128ContainersBounded() throws {
        struct DictionaryProjection: Encodable {
            let layers: Int
            func encode(to encoder: any Swift.Encoder) throws {
                var container = encoder.singleValueContainer()
                if layers == 0 {
                    try container.encode("leaf")
                } else {
                    try container.encode(["next": DictionaryProjection(layers: layers - 1)])
                }
            }
        }
        for layers in [127, 128] {
            XCTAssertNoThrow(try LuxoJSONEncoder().encode(DictionaryProjection(layers: layers)))
        }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(DictionaryProjection(layers: 129))) { error in
            XCTAssertTrue((error as? LuxoError)?.message.contains("128") == true)
        }
    }

    func testMixedCollectionDelegationCannotSplitIts128Budget() throws {
        struct Mixed: Encodable {
            let layers: Int
            func encode(to encoder: any Swift.Encoder) throws {
                var container = encoder.singleValueContainer()
                if layers == 0 {
                    try container.encode([Int]())
                } else if layers.isMultiple(of: 2) {
                    try container.encode(["next": Mixed(layers: layers - 1)])
                } else {
                    try container.encode([Mixed(layers: layers - 1)])
                }
            }
        }
        XCTAssertNoThrow(try LuxoJSONEncoder().encode(Mixed(layers: 127)))
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Mixed(layers: 128))) { error in
            XCTAssertTrue((error as? LuxoError)?.message.contains("128") == true)
        }
    }

    private struct EmptyProjection: Decodable {
        init(from decoder: Swift.Decoder) throws {
            try LuxoJSONDecoder.validateEmptyModelProjection(from: decoder)
        }
    }

    func testEmptyProjectionUsesLuxoArrayIdentityNotNumericObjectKeys() throws {
        let decoder = LuxoJSONDecoder()
        XCTAssertNoThrow(try decoder.decode(EmptyProjection.self, from: Data("{}".utf8)))
        XCTAssertNoThrow(try decoder.decode([String: EmptyProjection].self, from: Data(#"{"0":{}}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode([EmptyProjection].self, from: Data("[{}]".utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("missing projection error")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["0"])
        }
        // The generated Codable conformance is also usable outside the Luxo wire decoder.
        XCTAssertNoThrow(try JSONDecoder().decode(EmptyProjection.self, from: Data("{}".utf8)))
        XCTAssertNoThrow(
            try LuxoJSONDecoder.validateEmptyModelProjection(
                from: JSONTreeDecoder(value: .object([:]), key: JSONCodingKey(stringValue: "0"))))
    }

    func testSelectedPresenceAccumulatesWithoutTreatingNullAsMissing() throws {
        enum Key: String, CodingKey { case missing, null, value, invalid }
        let decoder = JSONTreeDecoder(value: .object(["null": .null, "value": 7, "invalid": "wrong"]))
        let container = try decoder.container(keyedBy: Key.self)
        var selected = false
        _ = try container.decode(Selected<Int>.self, forKey: .missing, selected: &selected)
        XCTAssertFalse(selected)
        XCTAssertThrowsError(try container.decode(Selected<Int>.self, forKey: .invalid, selected: &selected))
        XCTAssertFalse(selected)
        XCTAssertNil(try container.decode(Selected<Int?>.self, forKey: .null, selected: &selected).requireValue())
        XCTAssertTrue(selected)
        _ = try container.decode(Selected<Int>.self, forKey: .missing, selected: &selected)
        XCTAssertTrue(selected)
        selected = false
        XCTAssertEqual(try container.decode(Selected<Int>.self, forKey: .value, selected: &selected).requireValue(), 7)
        XCTAssertTrue(selected)
    }

    func testTypedJSONListsHaveIndependentContainerBudgets() throws {
        let decoder = LuxoJSONDecoder()
        for (open, close) in [("[", "]"), ("{\"v\":", "}")] {
            let valid = String(repeating: open, count: 128) + "null" + String(repeating: close, count: 128)
            let invalid = open + valid + close
            XCTAssertNoThrow(try decoder.decode([JSONValue].self, from: Data("[\(valid)]".utf8)))
            XCTAssertNoThrow(try decoder.decode([[JSONValue?]].self, from: Data("[[\(valid),null]]".utf8)))
            XCTAssertNoThrow(try decoder.decode([String: JSONValue].self, from: Data("{\"0\":\(valid)}".utf8)))
            XCTAssertThrowsError(try decoder.decode([JSONValue].self, from: Data("[\(invalid)]".utf8)))
            XCTAssertThrowsError(try decoder.decode(JSONValue.self, from: Data("[\(valid)]".utf8)))
            for pair in ["\"v\":\(invalid),\"v\":null", "\"v\":null,\"v\":\(invalid)"] {
                XCTAssertThrowsError(try decoder.decode([String: JSONValue].self, from: Data("{\(pair)}".utf8)))
            }
        }
    }

    private var nodeSchema: LuxoJSONReadSchema {
        .model(
            "Node",
            types: [
                "Node": [
                    "child": .init(fieldID: 1, typeName: "Node", type: "Model"),
                    "children": .init(fieldID: 2, typeName: "Node", type: "Model", isList: true),
                    "json": .init(fieldID: 3, type: "JSON"),
                    "documents": .init(fieldID: 4, type: "JSON", isList: true),
                ]
            ])
    }

    func testSchemaReaderChecksAllSourceValuesAndObjectBudgets() throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let leaf = "{\"json\":\(json),\"documents\":[\(json)]}"
        for (open, close) in [("{\"child\":", "}"), ("{\"children\":[", "]}")] {
            let valid = String(repeating: open, count: 63) + leaf + String(repeating: close, count: 63)
            XCTAssertNoThrow(try JSONReader.decode(Data(valid.utf8), schema: nodeSchema))
            XCTAssertThrowsError(try JSONReader.decode(Data((open + valid + close).utf8), schema: nodeSchema))
            for pair in ["\"child\":\(valid),\"child\":null", "\"child\":null,\"child\":\(valid)"] {
                XCTAssertThrowsError(try JSONReader.decode(Data("{\(pair)}".utf8), schema: nodeSchema))
            }
        }
        for text in ["{}", "null", "1", "[]", "{\"child\":null,\"children\":[],\"unknown\":{}}"] {
            XCTAssertNoThrow(try JSONReader.decode(Data(text.utf8), schema: nodeSchema))
        }
        for text in ["{", "{\"child\" 1}", "{\"child\":null 1}", "{\"children\":[1 2]}", "{\"children\":[}"] {
            XCTAssertThrowsError(try JSONReader.decode(Data(text.utf8), schema: nodeSchema))
        }
        XCTAssertThrowsError(try JSONReader.decode(Data("{}".utf8), schema: .model("Missing", types: [:]))) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
        }
        for field in ["json", "unknown"] {
            for pair in ["\"\(field)\":[\(json)],\"\(field)\":null", "\"\(field)\":null,\"\(field)\":[\(json)]"] {
                XCTAssertThrowsError(try JSONReader.decode(Data("{\(pair)}".utf8), schema: nodeSchema))
            }
        }
    }

    func testSchemaReaderTypedWrappersKeepJSONRootsAndNormalTypeErrors() throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let decoder = LuxoJSONDecoder()
        XCTAssertNoThrow(try decoder.decode(Selected<JSONValue>.self, from: Data(json.utf8)))
        XCTAssertNoThrow(
            try decoder.decode(
                Page<JSONValue>.self, from: Data("{\"items\":[\(json)],\"total\":1,\"page\":1,\"pageSize\":1}".utf8)))
        XCTAssertNoThrow(
            try decoder.decode(Cursor<JSONValue>.self, from: Data("{\"items\":[\(json)],\"hasMore\":false}".utf8)))
        XCTAssertThrowsError(try decoder.decode([JSONValue].self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try decoder.decode([String: JSONValue].self, from: Data("[]".utf8)))
        XCTAssertThrowsError(try decoder.decode(Page<JSONValue>.self, from: Data("[]".utf8)))
        XCTAssertThrowsError(
            try decoder.decode(Cursor<JSONValue>.self, from: Data("{\"items\":false,\"hasMore\":false}".utf8)))
        XCTAssertNoThrow(try JSONReader.decode(Data("{\"v\":\(json)}".utf8), schema: .dictionary(.json)))
        XCTAssertNoThrow(try JSONReader.decode(Data("{\"items\":[\(json)]}".utf8), schema: .page(.json)))
        let limit = "[" + String(repeating: "null,", count: 999_999) + "null]"
        XCTAssertNoThrow(try JSONReader.decode(Data(limit.utf8), schema: .list(.json)))
        let overflow = "[null," + limit.dropFirst()
        XCTAssertThrowsError(try JSONReader.decode(Data(overflow.utf8), schema: .list(.json)))
    }

    private struct Primitives: Codable, Equatable {
        var boolean = true
        var string = "text"
        var double: Double = 1.25
        var float: Float = 1.25
        var int = Int.min
        var int8 = Int8.min
        var int16 = Int16.min
        var int32 = Int32.min
        var int64 = Int64.min
        var uint = UInt.max
        var uint8 = UInt8.max
        var uint16 = UInt16.max
        var uint32 = UInt32.max
        var uint64 = UInt64.max
    }

    private struct ContextualValue<Value: Codable & Equatable>: Codable, Equatable {
        let metadata: JSONValue
        let value: Value
    }

    func testContextualSingleValuePrimitivesPreserveExactValues() throws {
        var metadata = JSONValue.integer(7)
        for _ in 0..<128 { metadata = .array([metadata]) }
        func check<Value: Codable & Equatable>(_ value: Value) throws {
            try roundTrip(ContextualValue(metadata: metadata, value: value))
        }
        try check(true); try check("東京"); try check(Float(1.25)); try check(Double(1.25))
        try check(Int.min); try check(Int8.min); try check(Int16.min); try check(Int32.min); try check(Int64.min)
        try check(UInt.max); try check(UInt8.max); try check(UInt16.max); try check(UInt32.max); try check(UInt64.max)
        try check(Data([0, 255])); try check(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        try check(Date(timeIntervalSinceReferenceDate: 100.25))
    }

    func testContextualOptionalPrimitivesDistinguishValuesMissingAndNull() throws {
        struct Values: Codable, Equatable {
            var boolean: Bool? = true
            var string: String? = "text"
            var double: Double? = 1.25
            var float: Float? = 1.25
            var int: Int? = .min
            var int8: Int8? = .min
            var int16: Int16? = .min
            var int32: Int32? = .min
            var int64: Int64? = .min
            var uint: UInt? = .max
            var uint8: UInt8? = .max
            var uint16: UInt16? = .max
            var uint32: UInt32? = .max
            var uint64: UInt64? = .max
        }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let metadata = try JSONValue.parse(Data(json.utf8))
        try roundTrip(ContextualValue(metadata: metadata, value: Values()))
        for text in ["{}", "{\"boolean\":null,\"int\":null}"] {
            let input = "{\"metadata\":\(json),\"value\":\(text)}"
            let value = try LuxoJSONDecoder().decode(ContextualValue<Values>.self, from: Data(input.utf8)).value
            XCTAssertNil(value.boolean); XCTAssertNil(value.string); XCTAssertNil(value.double)
            XCTAssertNil(value.float); XCTAssertNil(value.int); XCTAssertNil(value.int8)
            XCTAssertNil(value.int16); XCTAssertNil(value.int32); XCTAssertNil(value.int64)
            XCTAssertNil(value.uint); XCTAssertNil(value.uint8); XCTAssertNil(value.uint16)
            XCTAssertNil(value.uint32); XCTAssertNil(value.uint64)
        }
    }

    func testContextualIndexRejectsMalformedSuffixesAndKeepsBorrowedDataSlices() throws {
        struct Root: Decodable { let metadata: JSONValue }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let prefix = "{\"metadata\":\(json)"
        for suffix in [",\"v\" 1}", ",1:0}", ",\"v\":1 \"w\":2}", ",\"v\":[0 1]}", ",\"v\":[0,]}"] {
            XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: Data((prefix + suffix).utf8)))
        }
        var bytes = Data("prefix".utf8)
        bytes.append(contentsOf: [0xef, 0xbb, 0xbf])
        bytes.append(Data((prefix + "}").utf8))
        let slice = bytes.dropFirst(6)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(
            try LuxoJSONDecoder().decode(Root.self, from: slice).metadata,
            try JSONValue.parse(Data(json.utf8)))
        let tooDeep = Data((String(repeating: "[", count: 321) + "0" + String(repeating: "]", count: 321)).utf8)
        XCTAssertThrowsError(try LuxoJSONDecoder().decode(Root.self, from: tooDeep))
    }

    func testContextualTypeErrorsRetainKeyedAndArrayPaths() throws {
        struct Required: Codable, Equatable { let number: Int8 }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let prefix = "{\"metadata\":\(json),\"value\":"
        let decoder = LuxoJSONDecoder()
        XCTAssertThrowsError(
            try decoder.decode(
                ContextualValue<Required>.self,
                from: Data((prefix + "{\"number\":128}}").utf8))
        ) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else {
                return XCTFail("lost keyed type mismatch")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["value", "number"])
        }
        XCTAssertThrowsError(
            try decoder.decode(
                ContextualValue<Required>.self,
                from: Data((prefix + "{}}").utf8))
        ) { error in
            guard case DecodingError.keyNotFound(let key, let context) = error else {
                return XCTFail("lost missing field")
            }
            XCTAssertEqual(key.stringValue, "number")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["value"])
        }
        for value in ["false", "[]"] {
            XCTAssertThrowsError(
                try decoder.decode(
                    ContextualValue<Required>.self,
                    from: Data((prefix + value + "}").utf8)))
        }
        XCTAssertThrowsError(
            try decoder.decode(
                ContextualValue<[Required]>.self,
                from: Data((prefix + "{}}").utf8)))
        let duplicate = Data((prefix + "{\"number\":7,\"number\":8}}").utf8)
        XCTAssertEqual(try decoder.decode(ContextualValue<Required>.self, from: duplicate).value.number, 8)
    }

    func testContextualDuplicateProjectionTraversesMultipleBorrowedLevels() throws {
        struct Nested: Decodable {
            enum Key: String, CodingKey { case nested, metadata }
            let value: JSONValue
            init(from decoder: any Swift.Decoder) throws {
                let root = try decoder.container(keyedBy: Key.self)
                let first = try root.nestedContainer(keyedBy: Key.self, forKey: .nested)
                let second = try first.nestedContainer(keyedBy: Key.self, forKey: .nested)
                XCTAssertEqual(second.codingPath.map(\.stringValue), ["nested", "nested"])
                value = try second.decode(JSONValue.self, forKey: .metadata)
            }
        }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let valid = "{\"nested\":{\"metadata\":\(json)}}"
        let input = Data("{\"nested\":\(valid),\"nested\":\(valid)}".utf8)
        XCTAssertEqual(
            try LuxoJSONDecoder().decode(Nested.self, from: input).value,
            try JSONValue.parse(Data(json.utf8)))
        let invalid = "{\"nested\":{\"metadata\":[\(json)]}}"
        XCTAssertThrowsError(
            try LuxoJSONDecoder().decode(
                Nested.self,
                from: Data("{\"nested\":\(invalid),\"nested\":\(valid)}".utf8)))
    }

    func testSpecializedPrimitiveContainers() throws {
        try roundTrip(Primitives())
        let data = Data(#"[true,"text",1.25,1.25,-1,-1,-1,-1,-1,1,1,1,1,1]"#.utf8)
        _ = try PrimitiveArray(from: JSONTreeDecoder(value: JSONReader.decode(data)))
        struct Root: Decodable { let metadata: JSONValue; let values: PrimitiveArray }
        let json = String(repeating: "[", count: 128) + "7" + String(repeating: "]", count: 128)
        let input = Data("{\"metadata\":\(json),\"values\":\(String(decoding: data, as: UTF8.self))}".utf8)
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(Root.self, from: input))
    }

    private struct PrimitiveArray: Decodable {
        init(from decoder: any Swift.Decoder) throws {
            var array = try decoder.unkeyedContainer()
            XCTAssertEqual(try array.decode(Bool.self), true)
            XCTAssertEqual(try array.decode(String.self), "text")
            XCTAssertEqual(try array.decode(Double.self), 1.25)
            XCTAssertEqual(try array.decode(Float.self), 1.25)
            XCTAssertEqual(try array.decode(Int.self), -1)
            XCTAssertEqual(try array.decode(Int8.self), -1)
            XCTAssertEqual(try array.decode(Int16.self), -1)
            XCTAssertEqual(try array.decode(Int32.self), -1)
            XCTAssertEqual(try array.decode(Int64.self), -1)
            XCTAssertEqual(try array.decode(UInt.self), 1)
            XCTAssertEqual(try array.decode(UInt8.self), 1)
            XCTAssertEqual(try array.decode(UInt16.self), 1)
            XCTAssertEqual(try array.decode(UInt32.self), 1)
            XCTAssertEqual(try array.decode(UInt64.self), 1)
            XCTAssertTrue(array.isAtEnd)
        }
    }

    func testContainerPathsAndSelectedValues() throws {
        let decoder = JSONTreeDecoder(value: .int(42), parentPath: [JSONCodingKey(stringValue: "root")])
        XCTAssertEqual(try decoder.singleValueContainer().codingPath.map(\.stringValue), ["root"])
        let encoder = JSONTreeEncoder(node: JSONEncodingNode(), codingPath: [JSONCodingKey(stringValue: "root")])
        XCTAssertEqual(encoder.singleValueContainer().codingPath.map(\.stringValue), ["root"])
        var container = encoder.unkeyedContainer()
        XCTAssertEqual(container.codingPath.map(\.stringValue), ["root"])
        let objectEncoder = JSONTreeEncoder(
            node: JSONEncodingNode(), codingPath: [JSONCodingKey(stringValue: "object")])
        let object = objectEncoder.container(keyedBy: JSONCodingKey.self)
        XCTAssertEqual(object.codingPath.map(\.stringValue), ["object"])
        try container.encode(Selected.value(42))
        XCTAssertEqual(try LuxoJSONDecoder().decode(Selected<Int>.self, from: Data("42".utf8)).requireValue(), 42)
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Selected<Int>.unselected))
        XCTAssertEqual(try JSONTreeDecoder(value: .float(1.25)).decode(Double.self), 1.25)
        let empty = try JSONTreeDecoder(value: .object([:])).container(keyedBy: JSONCodingKey.self)
        XCTAssertNil(try Int?(from: empty.superDecoder()))
    }
    func testEveryPrimitiveAndCollection() throws {
        try roundTrip(true); try roundTrip(false); try roundTrip("東京\u{feff}\n")
        try roundTrip(Int.min); try roundTrip(Int8.min); try roundTrip(Int16.min)
        try roundTrip(Int32.min); try roundTrip(Int64.min)
        try roundTrip(UInt.max); try roundTrip(UInt8.max); try roundTrip(UInt16.max)
        try roundTrip(UInt32.max); try roundTrip(UInt64.max)
        try roundTrip(Float(1.25)); try roundTrip(Double(1.25))
        try roundTrip(Int?.none); try roundTrip(Int?.some(42))
        try roundTrip([1, 2, 3]); try roundTrip([Int]()); try roundTrip([1, nil, 2] as [Int?])
        try roundTrip(["a": [1, 2], "b": [3]]); try roundTrip([String: Int]())
        try roundTrip(Data([0, 255])); try roundTrip(Data())
        try roundTrip(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        try roundTrip(Date(timeIntervalSinceReferenceDate: 100.25))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let data = try LuxoJSONEncoder().encode(value)
        XCTAssertEqual(try LuxoJSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func testTypedRejectionsAndCodingPaths() throws {
        for text in ["null", "true", "\"42\"", "[]", "{}", "1.0", "9223372036854775808"] {
            XCTAssertThrowsError(try decode(Int64.self, text), text)
        }
        XCTAssertEqual(try decode(Int64.self, "-0"), 0)
        XCTAssertThrowsError(try decode(Int8.self, "128"))
        XCTAssertThrowsError(try decode(UInt8.self, "-1"))
        XCTAssertThrowsError(try decode(UInt64.self, "18446744073709551616"))
        XCTAssertThrowsError(try decode(Bool.self, "1"))
        XCTAssertThrowsError(try decode(String.self, "false"))
        XCTAssertThrowsError(try decode([Int].self, "{}"))
        XCTAssertThrowsError(try decode([String: Int].self, "[]"))
        XCTAssertThrowsError(try decode(Data.self, "[]"))
        XCTAssertThrowsError(try decode(Data.self, "\"bad%\""))
        XCTAssertThrowsError(try decode(Double.self, "null"))
        XCTAssertThrowsError(try decode(Float.self, "1e39"))
        XCTAssertThrowsError(try decode(Float.self, "1e-50"))
        XCTAssertEqual(try decode(Double.self, "1"), 1)
        for value in [Double.infinity, -.infinity, .nan] { XCTAssertThrowsError(try LuxoJSONEncoder().encode(value)) }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Float.infinity))
        struct Nested: Decodable { let numbers: [Int8] }
        XCTAssertThrowsError(try decode(Nested.self, #"{"numbers":[128]}"#)) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("missing path") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["numbers", "0"])
        }
        XCTAssertThrowsError(try decode(Nested.self, "{}")) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return XCTFail("missing key error") }
            XCTAssertEqual(key.stringValue, "numbers")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try LuxoJSONDecoder().decode(type, from: Data(text.utf8))
    }

    func testLazyContainerPathsRemainComplete() throws {
        struct Item: Decodable { let value: Int8 }
        struct Group: Decodable { let items: [Item] }
        struct Root: Decodable { let groups: [Group] }
        let valid = #"{"groups":[{"items":[{"value":1}]}]}"#
        XCTAssertEqual(try decode(Root.self, valid).groups[0].items[0].value, 1)
        let invalid = #"{"groups":[{"items":[{"value":128}]}]}"#
        XCTAssertThrowsError(try decode(Root.self, invalid)) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("missing path") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["groups", "0", "items", "0", "value"])
        }
        XCTAssertThrowsError(try decode(Root.self, #"{"groups":[{"items":[{}]}]}"#)) { error in
            guard case DecodingError.keyNotFound(let key, let context) = error else {
                return XCTFail("missing key error")
            }
            XCTAssertEqual(key.stringValue, "value")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["groups", "0", "items", "0"])
        }
        let decoder = JSONTreeDecoder(value: try JSONReader.decode(Data(valid.utf8)))
        let root = try decoder.container(keyedBy: JSONCodingKey.self)
        var groups = try root.nestedUnkeyedContainer(forKey: .init(stringValue: "groups"))
        let group = try groups.nestedContainer(keyedBy: JSONCodingKey.self)
        var items = try group.nestedUnkeyedContainer(forKey: .init(stringValue: "items"))
        let item = try items.nestedContainer(keyedBy: JSONCodingKey.self)
        XCTAssertEqual(group.codingPath.map(\.stringValue), ["groups", "0"])
        XCTAssertEqual(items.codingPath.map(\.stringValue), ["groups", "0", "items"])
        XCTAssertEqual(item.codingPath.map(\.stringValue), ["groups", "0", "items", "0"])
    }

    func testNestedAndSuperContainers() throws { try roundTrip(Containers()) }

    private struct Containers: Codable, Equatable {
        enum Key: String, CodingKey { case nested, array, child, value, missing, explicitNull }
        init() {}

        func encode(to encoder: Swift.Encoder) throws {
            XCTAssertTrue(encoder.userInfo.isEmpty)
            var root = encoder.container(keyedBy: Key.self)
            try root.encodeNil(forKey: .explicitNull)
            var nested = root.nestedContainer(keyedBy: Key.self, forKey: .nested)
            try nested.encode(7, forKey: .value)
            try JSONValue.rawNumber(JSONNumber("1.5")).encode(to: root.superEncoder(forKey: .child))
            try "parent".encode(to: root.superEncoder())
            var array = root.nestedUnkeyedContainer(forKey: .array)
            try array.encodeNil()
            try array.encode(1)
            var list = array.nestedUnkeyedContainer()
            try list.encode(true)
            var object = array.nestedContainer(keyedBy: Key.self)
            try object.encode("nested", forKey: .value)
            try "last".encode(to: array.superEncoder())
            XCTAssertEqual(array.count, 5)
        }

        init(from decoder: Swift.Decoder) throws {
            XCTAssertTrue(decoder.userInfo.isEmpty)
            let root = try decoder.container(keyedBy: Key.self)
            XCTAssertTrue(root.allKeys.contains(.array))
            XCTAssertFalse(root.contains(.missing))
            XCTAssertTrue(try root.decodeNil(forKey: .explicitNull))
            XCTAssertFalse(try root.decodeNil(forKey: .nested))
            let nested = try root.nestedContainer(keyedBy: Key.self, forKey: .nested)
            XCTAssertEqual(try nested.decode(Int.self, forKey: .value), 7)
            XCTAssertEqual(try Double(from: root.superDecoder(forKey: .child)), 1.5)
            XCTAssertEqual(try String(from: root.superDecoder()), "parent")
            var array = try root.nestedUnkeyedContainer(forKey: .array)
            XCTAssertEqual(array.count, 5)
            XCTAssertTrue(try array.decodeNil())
            XCTAssertFalse(try array.decodeNil())
            XCTAssertEqual(try array.decode(Int.self), 1)
            var list = try array.nestedUnkeyedContainer()
            XCTAssertTrue(try list.decode(Bool.self))
            let object = try array.nestedContainer(keyedBy: Key.self)
            XCTAssertEqual(try object.decode(String.self, forKey: .value), "nested")
            XCTAssertEqual(try String(from: array.superDecoder()), "last")
            XCTAssertTrue(array.isAtEnd)
            XCTAssertThrowsError(try array.decode(Int.self))
            XCTAssertThrowsError(try array.decodeNil())
        }
    }

    func testRecursiveCustomEncodableAndStructuredInputsFailAtDepthLimit() {
        struct Recursive: Encodable {
            func encode(to encoder: Swift.Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(self)
            }
        }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Recursive()))
        struct NestedContainers: Encodable {
            func encode(to encoder: Swift.Encoder) throws {
                var array = encoder.unkeyedContainer()
                for _ in 0..<129 { array = array.nestedUnkeyedContainer() }
            }
        }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(NestedContainers()))
        var value: JSONValue = .null
        for _ in 0..<129 { value = .array([value]) }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(value))
    }
}
