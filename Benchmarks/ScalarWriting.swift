// Compile with the LuxoClient sources and -module-name LuxoClient -O -whole-module-optimization.
import Foundation
import Dispatch
@main struct Main {
    @inline(never) static func measure(_ text: String, _ floats: Bool, _ count: Int) -> (Double, Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        var checksum = 0
        for _ in 0..<count {
            var writer = Encoder()
            writer.writeVarint(1)
            if floats { try! writer.writeFixed64(1.25) } else { writer.writeString(text) }
            checksum &+= writer.data.count + Int(writer.data.last ?? 0)
        }
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / Double(count), checksum)
    }
    static func main() {
        let cases = [
            ("empty", ""), ("short", "hello"), ("ascii128", String(repeating: "a", count: 128)),
            ("chinese4k", String(repeating: "中文", count: 700)), ("chinese72k", String(repeating: "中文", count: 12288)),
            ("float", ""),
        ]
        for (name, text) in cases {
            _ = measure(text, name == "float", 2000)
            let result = measure(text, name == "float", text.utf8.count > 10000 ? 10000 : 300000)
            print("\(name),\(result.0),\(result.1)")
        }
    }
}
