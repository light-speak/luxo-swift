import Foundation
import LuxoClient
import LuxoCompiler

@main
struct LuxoConsumer {
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--generate" {
            let codegen = try LuxoCodegen(
                endpoint: CommandLine.arguments[2],
                introspectionKey: "consumer-fixture-key"
            )
            try await codegen.generate(outputDir: CommandLine.arguments[3])
            return
        }

        let transport = try URLSessionTransport(endpoint: "https://example.com/luvia")
        transport.setMode(.binary)
        transport.setSchema(["getUser": APISchema(id: 1)])

        var encoder = Encoder()
        try encoder.writeField(1, value: 7, type: "Int")

        let analyzer = SelectAnalyzer()
        analyzer.analyzeSource(
            """
            let user = await client.getUser()
            print(user.name)
            """
        )
        guard analyzer.buildHints() == ["getUser": "name"] else {
            throw LuxoError(code: 0, message: "unexpected select hints", name: "ConsumerError")
        }

        _ = try await transport.call("getUser", params: ["id": 7])
    }
}
