import XCTest
@testable import LuxoClient

final class SealedCodegenTests: XCTestCase {
    static let fixture = #"""
        {"models":{},"apis":{"echo":{"id":1,"name":"echo","module":"test","returnType":"Outcome","params":[{"id":1,"name":"value","type":"Sealed","typeName":"Outcome"}]}},
        "sealeds":{"Outcome":{"name":"Outcome","usage":"inputOutput","variants":[
        {"id":1,"name":"Success","fields":[{"id":1,"name":"value","type":"Int"}]},
        {"id":2,"name":"Failure","fields":[{"id":1,"name":"reason","type":"String","hasDefault":true}]},
        {"id":3,"name":"Pending","fields":[]},
        {"id":4,"name":"Nested","fields":[{"id":1,"name":"child","type":"Sealed","typeName":"Outcome","nullable":true,"hasDefault":true},{"id":2,"name":"history","type":"Sealed","typeName":"Outcome","nullable":true,"hasDefault":true,"isList":true}]}]}}}
        """#

    func testSealedSchemaRoundTripAndStaticGeneration() throws {
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(Self.fixture.utf8))
        let encoded = try JSONValue.parse(JSONEncoder().encode(schema))
        guard case .object(let object) = encoded else { return XCTFail("schema object") }
        XCTAssertNotNil(object["sealeds"])
        XCTAssertNoThrow(try schema.validateIDs())
        XCTAssertNoThrow(try SwiftEnumCodegen.validate(schema))
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        let models = generator.generateModels(schema)
        XCTAssertTrue(models.contains("public indirect enum Outcome:"))
        XCTAssertTrue(models.contains("public indirect enum OutcomeInput:"))
        XCTAssertTrue(generator.generateDecoders(schema).contains("public func decodeOutcome("))
        XCTAssertTrue(generator.generateSchema(schema).contains("@sealed:Outcome"))
        XCTAssertTrue(generator.generateClient(schema).contains("decodeOutcome("))
    }

    func testInvalidSealedDirectoriesAreRejectedBeforeGeneration() throws {
        let variants = [
            #"[{"id":0,"name":"Ready","fields":[]}]"#,
            #"[{"id":65536,"name":"Ready","fields":[]}]"#,
            #"[{"id":1,"name":"Ready","fields":[]},{"id":1,"name":"Other","fields":[]}]"#,
            #"[{"id":1,"name":"Ready","fields":[]},{"id":2,"name":"Ready","fields":[]}]"#,
            #"[{"id":1,"name":"Ready","fields":[{"id":0,"name":"value","type":"Int"}]}]"#,
            #"[{"id":1,"name":"Ready","fields":[{"id":1,"name":"value","type":"Sealed","typeName":"Missing"}]}]"#,
            #"[{"id":1,"name":"Ready","fields":[{"id":1,"name":"value","type":"Int"},{"id":2,"name":"value","type":"String"}]}]"#,
        ]
        for cases in variants {
            let body = #"{"models":{},"apis":{},"sealeds":{"Outcome":{"name":"Outcome","variants":\#(cases)}}}"#
            let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(body.utf8))
            XCTAssertThrowsError(
                try {
                    try schema.validateIDs(); try SwiftEnumCodegen.validate(schema)
                }(), cases)
        }
        let empty = #"{"models":{},"apis":{},"sealeds":{"Empty":{"name":"Empty","variants":[]}}}"#
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: Data(empty.utf8))
        XCTAssertNoThrow(try schema.validateIDs())
        XCTAssertNoThrow(try SwiftEnumCodegen.validate(schema))
    }

    func testSealedParameterPlanKeepsExactCaseAndObjectDepth() throws {
        let types: [String: [String: APISchema.SelectionFieldSchema]] = [
            "@sealed:Outcome": ["Ready": .init(fieldID: 1, typeName: "Outcome.Ready", type: "Model")],
            "Outcome.Ready": [
                "count": .init(fieldID: 1, type: "Int"),
                "title": .init(fieldID: 3, type: "String"),
                "child": .init(fieldID: 2, typeName: "Outcome", type: "Sealed", nullable: true),
            ],
        ]
        let params = [APISchema.ParamSchema(fieldID: 1, name: "value", type: "Sealed", typeName: "Outcome")]
        let plan = try XCTUnwrap(JSONParameterPlan(params: params, types: types))
        func encode(_ value: LuxoValue) throws -> Data {
            var writer = JSONWriter()
            try plan.writeJSON(value, named: "value", to: &writer)
            return Data(writer.bytes)
        }
        for value: LuxoValue in [
            .object([:]), .object(["Other": .object([:])]),
            .object(["Ready": .object([:]), "Other": .object([:])]),
            .object(["Ready": .null]), .object(["Ready": .object(["count": .string("7")])]),
            .object(["Ready": .object(["typo": .int(7)])]),
        ] {
            XCTAssertThrowsError(try encode(value))
        }
        XCTAssertNoThrow(try encode(.object(["Ready": .object(["title": .string("ok")])])))
        var value: LuxoValue = .object(["Ready": .object(["count": .int(7)])])
        for _ in 0..<31 { value = .object(["Ready": .object(["child": value])]) }
        XCTAssertNoThrow(try encode(value))
        value = .object(["Ready": .object(["child": value])])
        XCTAssertThrowsError(try encode(value))
    }

    func testSealedKeysUseExactUTF8IdentityBeforeReplacement() throws {
        let types: [String: [String: APISchema.SelectionFieldSchema]] = [
            "@sealed:Outcome": ["Café": .init(fieldID: 1, typeName: "Outcome.Café", type: "Model")],
            "Outcome.Café": ["café": .init(fieldID: 1, type: "Int")],
        ]
        let schema = LuxoJSONReadSchema.model("@sealed:Outcome", types: types)
        XCTAssertNoThrow(try JSONReader.decode(Data(#"{"Café":{"café":1}}"#.utf8), schema: schema))
        for json in [#"{"Café":{"café":1,"cafe\u0301":2}}"#, #"{"Café":{"cafe\u0301":2}}"#] {
            XCTAssertThrowsError(try JSONReader.decode(Data(json.utf8), schema: schema), json)
        }
        let params = [APISchema.ParamSchema(fieldID: 1, name: "value", type: "Sealed", typeName: "Outcome")]
        let plan = try XCTUnwrap(JSONParameterPlan(params: params, types: types))
        for value: LuxoValue in [
            .object(["Café": .object(["cafe\u{301}": .int(2)])]),
            .object(["Cafe\u{301}": .object(["café": .int(1)])]),
        ] {
            var writer = JSONWriter()
            XCTAssertThrowsError(try plan.writeJSON(value, named: "value", to: &writer))
        }
    }

    func testSealedJSONShapeIsClosedBeforeCodableMaterialization() throws {
        let types: [String: [String: APISchema.SelectionFieldSchema]] = [
            "@sealed:Outcome": [
                "Success": .init(fieldID: 1, typeName: "Outcome.Success", type: "Model"),
                "Pending": .init(fieldID: 3, typeName: "Outcome.Pending", type: "Model"),
            ],
            "Outcome.Success": ["value": .init(fieldID: 1, type: "Int")], "Outcome.Pending": [:],
        ]
        let schema = LuxoJSONReadSchema.model("@sealed:Outcome", types: types)
        for text in [#"{"Success":{"value":7}}"#, #"{"Success":{}}"#, #"{"Pending":{}}"#] {
            XCTAssertNoThrow(try JSONReader.decode(Data(text.utf8), schema: schema), text)
        }
        for text in [
            #"{}"#, #"{"Unknown":{}}"#, #"{"Success":{},"Pending":{}}"#,
            #"{"Pending":{},"Pending":{}}"#, #"{"Pending":null}"#, #"{"Pending":[]}"#, #"{"Pending":{"typo":7}}"#,
        ] {
            XCTAssertThrowsError(try JSONReader.decode(Data(text.utf8), schema: schema), text)
        }
    }
}
