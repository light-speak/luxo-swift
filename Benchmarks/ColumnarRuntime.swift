// Compile with the same generated schema from each compared generator.
import Dispatch
import Foundation
import LuxoClient
#if canImport(Darwin)
    import Darwin
#endif

@main enum ColumnarRuntimeBenchmark {
    struct Fixture {
        let name: String
        let data: Data
        let expected: UInt64
        let count: Int
        let page: Bool
        let invalid: Bool
    }

    static func main() throws {
        let args = CommandLine.arguments
        let setupStart = DispatchTime.now().uptimeNanoseconds
        let fixture = try makeFixture(args[2])
        let setup = DispatchTime.now().uptimeNanoseconds - setupStart
        let firstStart = DispatchTime.now().uptimeNanoseconds
        let expected = try operation(fixture)
        let first = DispatchTime.now().uptimeNanoseconds - firstStart
        precondition(expected == fixture.expected, "decoded fixture differs")
        if args[1] == "alloc" {
            var sum: UInt64 = 0
            for _ in 0..<10 {
                sum &+= try columnarAllocationIteration(fixture)
                let block = columnarAllocationCalibration()
                free(block)
            }
            precondition(sum == (expected &+ 1) &* 10)
            print("READY iterations=10 checksum=\(sum)")
            fflush(stdout)
            _ = readLine()
            return
        }
        var count = 1
        var samples = [Double(first)]
        if args[1] == "warm" {
            for _ in 0..<10 {
                let value = try operation(fixture)
                precondition(value == expected)
            }
            while try measure(fixture, count).0 < 30_000_000 { count *= 2 }
            samples = try (0..<5).map { _ in
                let result = try measure(fixture, count)
                precondition(result.1 == expected &* UInt64(count))
                return Double(result.0) / Double(count)
            }
        }
        let report: [String: Any] = [
            "kind": "runtime", "name": fixture.name, "phase": args[1],
            "fixture_ns": setup, "first_ns": first, "samples_ns": samples, "iterations": count,
            "result": expected, "payload_bytes": fixture.data.count,
        ]
        print(
            String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    @inline(never) static func measure(_ fixture: Fixture, _ count: Int) throws -> (UInt64, UInt64) {
        let start = DispatchTime.now().uptimeNanoseconds
        var sum: UInt64 = 0
        for _ in 0..<count { sum &+= try operation(fixture) }
        return (DispatchTime.now().uptimeNanoseconds - start, sum)
    }

    @inline(never) static func operation(_ fixture: Fixture) throws -> UInt64 {
        do {
            if fixture.page {
                let page = try decodePaginatedBenchRecord(fixture.data)
                return try fingerprint(page.items) &+ UInt64(page.total + page.page + page.pageSize)
            }
            return try fingerprint(decodeColumnarBenchRecord(fixture.data))
        } catch let error as LuxoError where fixture.invalid && error.name == "DecodeError" {
            return UInt64(error.name.utf8.count + error.message.utf8.count)
        }
    }

    static func fingerprint(_ rows: [BenchRecord]) throws -> UInt64 {
        var sum = UInt64(rows.count)
        for row in rows {
            sum = mix(sum, UInt64(bitPattern: Int64(try row.id.requireValue())))
            sum = mix(sum, UInt64(try row.label.requireValue().utf8.count))
            sum = mix(sum, UInt64(try row.optional.requireValue()?.utf8.count ?? 17))
            for value in try row.values.requireValue() { sum = mix(sum, UInt64(bitPattern: Int64(value))) }
            if let child = try row.child.requireValue() {
                sum = mix(sum, UInt64(bitPattern: Int64(try child.code.requireValue())))
                sum = mix(sum, UInt64(try child.note.requireValue()?.utf8.count ?? 19))
            } else {
                sum = mix(sum, 23)
            }
        }
        return sum
    }

    static func makeFixture(_ name: String) throws -> Fixture {
        let counts = [
            "empty": 0, "mixed1": 1, "mixed128": 128, "mixed4096": 4096,
            "page0": 0, "page128": 128, "errorNested128": 128,
        ]
        guard let count = counts[name] else { throw NSError(domain: "unknown case", code: 1) }
        let page = name.hasPrefix("page")
        let invalid = name == "errorNested128"
        var enc = Encoder()
        enc.writeVarint(UInt64(count))
        enc.writeVarint(0)
        let label = "東京-\u{feff}-hello"
        if count > 0 {
            enc.writeVarint(1)
            for index in 0..<count { enc.writeSvarint(Int64.min + Int64(index)) }
            enc.writeVarint(2)
            for _ in 0..<count { enc.writeString(label) }
            enc.writeVarint(3)
            for index in 0..<count { enc.writeBool(index % 3 != 0); if index % 3 != 0 { enc.writeString("optional") } }
            enc.writeVarint(4)
            for index in 0..<count {
                var array = Encoder()
                try array.writeArrayHeader(3)
                for value in [Int64(index), Int64.min, Int64.max] { array.writeSvarint(value) }
                enc.writeBytes(array.data)
            }
            enc.writeVarint(5)
            for index in 0..<count {
                let present = index % 3 != 0 || (invalid && index == count - 1)
                enc.writeBool(present)
                if present {
                    var child = Encoder()
                    child.writeVarint(0); child.writeVarint(1); child.writeSvarint(Int64(index))
                    child.writeVarint(2); child.writeBool(true); child.writeString("child"); child.writeEnd()
                    if invalid && index == count - 1 { child = Encoder(); child.writeVarint(0); child.writeVarint(99) }
                    enc.writeBytes(child.data)
                }
            }
        }
        enc.writeVarint(0)
        if page { enc.writeSvarint(Int64(count)); enc.writeSvarint(1); enc.writeSvarint(64) }
        var expected = UInt64(count)
        for index in 0..<count {
            expected = mix(expected, UInt64(bitPattern: Int64.min + Int64(index)))
            expected = mix(expected, UInt64(label.utf8.count))
            expected = mix(expected, index % 3 == 0 ? 17 : 8)
            for value in [Int64(index), Int64.min, Int64.max] { expected = mix(expected, UInt64(bitPattern: value)) }
            if index % 3 != 0 {
                expected = mix(expected, UInt64(index)); expected = mix(expected, 5)
            } else {
                expected = mix(expected, 23)
            }
        }
        if page { expected &+= UInt64(count + 65) }
        if invalid { expected = UInt64("DecodeError".utf8.count + "unknown BenchChild field ID 99".utf8.count) }
        return Fixture(name: name, data: enc.data, expected: expected, count: count, page: page, invalid: invalid)
    }

    static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 { (a &* 31) &+ b }

    @inline(never) static func columnarAllocationIteration(_ fixture: Fixture) throws -> UInt64 {
        try operation(fixture) &+ 1
    }

    @inline(never) static func columnarAllocationCalibration() -> UnsafeMutableRawPointer { malloc(12345)! }
}
