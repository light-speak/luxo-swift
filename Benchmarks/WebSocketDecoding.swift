import Foundation

#if LUXO_DECODING_BENCHMARK
    enum WebSocketDecodingBenchmark {
        static func run() async throws {
            for mode in [TransportMode.json, .binary] {
                try await compareLifecycle(mode: mode)
                for value in [Int64(7), Int64.max] {
                    try await compareDispatch(mode: mode, value: value, typed: true)
                }
                try await compareDispatch(mode: mode, value: 7, typed: false)
            }
            print("Fake socket only; allocation counts, generated models, error cleanup and network not measured")
        }

        private struct Pair {
            let before: PreDecodeWebSocketTransport
            let after: WebSocketTransport
            let oldSocket = BenchmarkSocket(legacy: false)
            let newSocket = BenchmarkSocket(legacy: false)

            init(mode: TransportMode) throws {
                before = try PreDecodeWebSocketTransport(
                    url: "ws://localhost/bench", session: BenchmarkSession(oldSocket))
                after = try WebSocketTransport(url: "ws://localhost/bench", session: BenchmarkSession(newSocket))
                let schema = ["watch": APISchema(id: 7)]
                before.setSchema(schema); try after.setSchema(schema)
                before.setMode(mode); after.setMode(mode)
                before.connect(); after.connect()
            }

            func close() { before.close(); after.close() }
        }

        private static func compareLifecycle(mode: TransportMode) async throws {
            let pair = try Pair(mode: mode)
            defer { pair.close() }
            try await TransportMetadataBenchmark.compareAsync("Decoding unary \(mode)") {
                let payload = try await pair.before.call("watch")
                precondition(payload.mode == mode && payload.data.count == 1)
                return UInt64(payload.data.count)
            } after: {
                let payload = try await pair.after.call("watch")
                precondition(payload.mode == mode && payload.data.count == 1)
                return UInt64(payload.data.count)
            }
            let onData: @Sendable (Int64) -> Void = { precondition($0 == 7) }
            try await TransportMetadataBenchmark.compareAsync("Decoding subscribe/ACK/cancel \(mode)") {
                let cancel = try await pair.before.subscribe("watch") { payload in
                    guard let value = try? read(payload) else { return }
                    onData(value)
                }
                cancel()
                return 1
            } after: {
                let cancel = try await pair.after.subscribe("watch", decoder: read, handler: onData)
                cancel()
                return 1
            }
        }

        private static func compareDispatch(mode: TransportMode, value: Int64, typed: Bool) async throws {
            let pair = try Pair(mode: mode)
            defer { pair.close() }
            try await subscribe(pair: pair, value: value, typed: typed)
            let frame = streamFrame(mode: mode, value: value)
            TransportMetadataBenchmark.compare(
                "Decoding dispatch \(mode) value=\(value) typed=\(typed)", iterations: 50_000, warmup: 10_000,
                before: { _ in
                    pair.oldSocket.deliver(frame); return 1
                },
                after: { _ in
                    pair.newSocket.deliver(frame); return 1
                })
            precondition(pair.oldSocket.receivedCount == 880_000 && pair.newSocket.receivedCount == 880_000)
        }

        private static func subscribe(pair: Pair, value: Int64, typed: Bool) async throws {
            let oldSocket = pair.oldSocket
            let newSocket = pair.newSocket
            if typed {
                let oldHandler: @Sendable (Int64) -> Void = {
                    precondition($0 == value); oldSocket.record()
                }
                let newHandler: @Sendable (Int64) -> Void = {
                    precondition($0 == value); newSocket.record()
                }
                _ = try await pair.before.subscribe("watch") { payload in
                    guard let result = try? read(payload) else { return }
                    oldHandler(result)
                }
                _ = try await pair.after.subscribe("watch", decoder: read, handler: newHandler)
            } else {
                _ = try await pair.before.subscribe("watch") { payload in
                    precondition(payload.data.count == 1); oldSocket.record()
                }
                _ = try await pair.after.subscribe("watch", decoder: { $0 }) { payload in
                    precondition(payload.data.count == 1); newSocket.record()
                }
            }
        }

        private static func streamFrame(mode: TransportMode, value: Int64) -> URLSessionWebSocketTask.Message {
            if mode == .json { return .string("{\"$stream\":1,\"data\":\(value)}") }
            var encoder = Encoder()
            encoder.writeVarint(LuxoBinaryProtocol.stream)
            encoder.writeVarint(1)
            encoder.writeSvarint(value)
            return .data(encoder.data)
        }

        private static func read(_ payload: TransportPayload) throws -> Int64 {
            if payload.mode == .json {
                return try LuxoJSONDecoder().decode(Int64.self, from: payload.data)
            }
            var decoder = Decoder(payload.data)
            let result = decoder.readSvarint()
            guard decoder.error == nil && decoder.isAtEnd else {
                throw LuxoError(code: 0, message: decoder.error ?? "trailing benchmark data", name: "DecodeError")
            }
            return result
        }
    }
#endif
