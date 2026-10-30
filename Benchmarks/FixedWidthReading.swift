// Compile with LuxoClient sources and -module-name LuxoClient -O -whole-module-optimization.
import Foundation
import Dispatch
@main enum Main {
    @inline(never) static func measure(_ data: Data, _ uuid: Bool, _ count: Int) -> (Double, UInt64) {
        var sum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count {
            var decoder = Decoder(data)
            if uuid { sum &+= UInt64(decoder.readUUID().uuid.15) } else { sum &+= decoder.readFixed64().bitPattern }
            precondition(decoder.error == nil)
        }
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / Double(count), sum)
    }
    static func main() throws {
        var float = Encoder(); try float.writeFixed64(1.25)
        let uuid = Data((0..<16).map(UInt8.init))
        for (name, bytes, isUUID) in [("float", float.data, false), ("uuid", uuid, true)] {
            for view in [false, true] {
                var parent = Data(repeating: 91, count: 7); parent.append(bytes); parent.append(12)
                let input = view ? parent[7..<7 + bytes.count] : bytes
                _ = measure(input, isUUID, 10000)
                let result = measure(input, isUUID, 1000000)
                print("\(name)-\(view),\(result.0),\(result.1)")
            }
        }
        UUIDColumnBenchmark.run()
    }
}

enum UUIDColumnBenchmark {
    @inline(never) static func decode(_ data: Data, _ nullable: Bool) -> Int {
        var decoder = ColumnarDecoder(data: data)
        precondition(decoder.nextColumn())
        let sum: Int
        if nullable {
            let values = decoder.readColumnUUIDPtr()
            sum = values.count + Int(values.last!!.uuid.15)
        } else {
            let values = decoder.readColumnUUID()
            sum = values.count + Int(values.last!.uuid.15)
        }
        precondition(!decoder.nextColumn() && decoder.error == nil && decoder.isAtEnd)
        return sum
    }
    static func run() {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        for count in [1, 128] {
            for nullable in [false, true] {
                var encoder = Encoder()
                encoder.writeVarint(UInt64(count)); encoder.writeVarint(0); encoder.writeVarint(1)
                for _ in 0..<count {
                    if nullable { encoder.writeBool(true) }
                    encoder.writeUUID(uuid)
                }
                encoder.writeEnd()
                for view in [false, true] {
                    var parent = Data(repeating: 91, count: 7); parent.append(encoder.data); parent.append(92)
                    let data = view ? parent[7..<7 + encoder.data.count] : encoder.data
                    for _ in 0..<1000 { _ = decode(data, nullable) }
                    let iterations = count == 1 ? 100000 : 10000
                    var sum = 0
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<iterations { sum &+= decode(data, nullable) }
                    let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations)
                    print("\(count)-\(nullable)-\(view),\(ns),\(sum)")
                }
            }
        }
    }
}
