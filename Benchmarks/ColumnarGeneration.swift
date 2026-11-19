// Compile against an enable-testing SDK module with -O.
import Dispatch
import Foundation
@testable import LuxoClient
#if canImport(Darwin)
    import Darwin
#endif

@main enum ColumnarGenerationBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        let start = DispatchTime.now().uptimeNanoseconds
        let generator = try LuxoCodegen(endpoint: "http://127.0.0.1/unused", introspectionKey: "unused")
        let constructor = DispatchTime.now().uptimeNanoseconds - start
        if args[1] == "emit" {
            let schema = try runtimeSchema()
            let directory = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, source) in [
                "Models.swift": generator.generateModels(schema),
                "Decoders.swift": generator.generateDecoders(schema),
                "Schema.swift": generator.generateSchema(schema),
            ] {
                try source.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            return
        }
        let schemaStart = DispatchTime.now().uptimeNanoseconds
        let schema = try fields(Int(args[2])!)
        let setup = DispatchTime.now().uptimeNanoseconds - schemaStart
        let firstStart = DispatchTime.now().uptimeNanoseconds
        let expected = operation(generator, schema)
        let first = DispatchTime.now().uptimeNanoseconds - firstStart
        if args[1] == "alloc" {
            var sum: UInt64 = 0
            for _ in 0..<10 {
                sum &+= columnarAllocationIteration(generator, schema)
                let block = columnarAllocationCalibration()
                free(block)
            }
            precondition(sum == (expected &+ 1) &* 10)
            print("READY iterations=10 checksum=\(sum)")
            fflush(stdout)
            _ = readLine()
            return
        }
        var iterations = 1
        var samples = [Double(first)]
        if args[1] == "warm" {
            for _ in 0..<10 { precondition(operation(generator, schema) == expected) }
            while measure(generator, schema, iterations).0 < 30_000_000 { iterations *= 2 }
            samples = try (0..<5).map { _ in
                let result = measure(generator, schema, iterations)
                guard result.1 == expected &* UInt64(iterations) else { throw failure("generation checksum") }
                return Double(result.0) / Double(iterations)
            }
        }
        let report: [String: Any] = [
            "kind": "generation", "fields": Int(args[2])!, "phase": args[1],
            "constructor_ns": constructor, "fixture_ns": setup, "first_ns": first,
            "samples_ns": samples, "iterations": iterations, "result": expected,
        ]
        print(
            String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    @inline(never) static func operation(_ generator: LuxoCodegen, _ schema: LuxoSchema) -> UInt64 {
        UInt64(generator.generateDecoders(schema).utf8.count)
    }

    @inline(never) static func measure(_ generator: LuxoCodegen, _ schema: LuxoSchema, _ count: Int) -> (UInt64, UInt64)
    {
        let start = DispatchTime.now().uptimeNanoseconds
        var sum: UInt64 = 0
        for _ in 0..<count { sum &+= operation(generator, schema) }
        return (DispatchTime.now().uptimeNanoseconds - start, sum)
    }

    @inline(never) static func columnarAllocationIteration(_ generator: LuxoCodegen, _ schema: LuxoSchema) -> UInt64 {
        operation(generator, schema) &+ 1
    }

    @inline(never) static func columnarAllocationCalibration() -> UnsafeMutableRawPointer { malloc(12345)! }

    static func fields(_ count: Int) throws -> LuxoSchema {
        let types = ["Int", "String", "Duration", "Float"]
        let fields = (0..<count).map { index in
            field(index + 1, "field\(index)", types[index % 4], nullable: index % 3 == 0, list: index % 5 == 0)
        }
        return LuxoSchema(
            models: ["GeneratorRecord": LuxoModel(name: "GeneratorRecord", usage: .output, fields: fields)],
            apis: [:], enums: nil, types: nil)
    }

    static func runtimeSchema() throws -> LuxoSchema {
        let fields = [
            field(1, "id", "Int"), field(2, "label", "String"),
            field(3, "optional", "String", nullable: true), field(4, "values", "Int", list: true),
            field(5, "child", "Model", nullable: true, typeName: "BenchChild"),
        ]
        let child = [field(1, "code", "Int"), field(2, "note", "String", nullable: true)]
        return LuxoSchema(
            models: ["BenchRecord": LuxoModel(name: "BenchRecord", usage: .output, fields: fields)],
            apis: [:], enums: nil,
            types: ["BenchChild": LuxoTypeDecl(name: "BenchChild", usage: .output, fields: child)])
    }

    static func field(
        _ id: Int, _ name: String, _ type: String, nullable: Bool = false,
        list: Bool = false, typeName: String? = nil
    ) -> LuxoField {
        LuxoField(id: id, name: name, type: type, typeName: typeName, nullable: nullable, isList: list, relation: false)
    }

    static func failure(_ message: String) -> NSError { NSError(domain: message, code: 1) }
}
