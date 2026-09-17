import Foundation

#if LUXO_PAYLOAD_BENCHMARK
    enum TransportPayloadBenchmark {
        static func run() async throws {
            for mode in [TransportMode.json, .binary] {
                let pair = try Pair(mode: mode)
                defer { pair.close() }
                try await TransportMetadataBenchmark.compareAsync("Payload unary \(mode)") {
                    let data = try await pair.before.call("watch")
                    precondition(data.count == 1)
                    return UInt64(data.count)
                } after: {
                    let payload = try await pair.after.call("watch")
                    precondition(payload.mode == mode && payload.data.count == 1)
                    return UInt64(payload.data.count)
                }
                try await TransportMetadataBenchmark.compareAsync("Payload subscribe/ACK/cancel \(mode)") {
                    let cancel = try await pair.before.subscribe("watch") { _ in }
                    cancel()
                    return 1
                } after: {
                    let cancel = try await pair.after.subscribe("watch", decoder: { $0 }) { _ in }
                    cancel()
                    return 1
                }
                for decode in [false, true] { try await compareDispatch(mode: mode, decode: decode) }
            }
            print(
                "Value storage: Data stride=\(MemoryLayout<Data>.stride), payload stride=\(MemoryLayout<TransportPayload>.stride); not a heap-allocation measurement"
            )
        }

        private struct Pair {
            let before: PrePayloadWebSocketTransport
            let after: WebSocketTransport
            let oldSocket = BenchmarkSocket(legacy: false)
            let newSocket = BenchmarkSocket(legacy: false)

            init(mode: TransportMode) throws {
                before = try PrePayloadWebSocketTransport(
                    url: "ws://localhost/bench", session: BenchmarkSession(oldSocket))
                after = try WebSocketTransport(url: "ws://localhost/bench", session: BenchmarkSession(newSocket))
                let schema = ["watch": APISchema(id: 7)]
                before.setSchema(schema); after.setSchema(schema)
                before.setMode(mode); after.setMode(mode)
                before.connect(); after.connect()
            }
            func close() { before.close(); after.close() }
        }

        private static func compareDispatch(mode: TransportMode, decode: Bool) async throws {
            let pair = try Pair(mode: mode)
            defer { pair.close() }
            let oldMode = PreviousClientMode(mode)
            let oldSocket = pair.oldSocket
            let newSocket = pair.newSocket
            _ = try await pair.before.subscribe("watch") { data in
                if decode { precondition(read(data, mode: oldMode.value) == 7) } else { precondition(data.count == 1) }
                oldSocket.record()
            }
            _ = try await pair.after.subscribe("watch", decoder: { $0 }) { payload in
                if decode {
                    precondition(read(payload.data, mode: payload.mode) == 7)
                } else {
                    precondition(payload.data.count == 1)
                }
                newSocket.record()
            }
            let frame: URLSessionWebSocketTask.Message =
                mode == .json ? .string("{\"$stream\":1,\"data\":7}") : .data(Data([0x12, 1, 14]))
            TransportMetadataBenchmark.compare(
                "Payload dispatch \(mode) scalar-decode=\(decode)", iterations: 50_000, warmup: 10_000,
                before: { _ in
                    oldSocket.deliver(frame); return 1
                },
                after: { _ in
                    newSocket.deliver(frame); return 1
                })
            precondition(oldSocket.receivedCount == 880_000 && newSocket.receivedCount == 880_000)
        }

        private static func read(_ data: Data, mode: TransportMode) -> Int {
            if mode == .binary {
                var decoder = Decoder(data)
                let result = Int(decoder.readSvarint())
                precondition(decoder.error == nil && decoder.isAtEnd)
                return result
            }
            return (try? LuxoJSONDecoder().decode(Int.self, from: data)) ?? -1
        }

        // Mirrors the former generated client's lock-protected mode getter.
        private final class PreviousClientMode: @unchecked Sendable {
            private let lock = NSLock()
            private var mode: TransportMode
            init(_ mode: TransportMode) { self.mode = mode }
            var value: TransportMode { lock.withLock { mode } }
        }
    }
#endif
