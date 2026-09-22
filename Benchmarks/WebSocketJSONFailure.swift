import Foundation

#if LUXO_JSON_FAILURE_BENCHMARK
    enum WebSocketJSONFailureBenchmark {
        static func run() async throws {
            for mode in [TransportMode.json, .binary] {
                try await lifecycle(mode)
                try await dispatch(mode)
            }
            print("Same decoder contract; fake sockets; allocations, failure cleanup, network and devices unmeasured")
        }

        private struct Pair {
            let before: BeforeJSONWebSocketTransport
            let after: WebSocketTransport
            let oldSocket = BenchmarkSocket(legacy: false)
            let newSocket = BenchmarkSocket(legacy: false)

            init(_ mode: TransportMode) throws {
                before = try BeforeJSONWebSocketTransport(
                    url: "ws://localhost/test", session: BenchmarkSession(oldSocket))
                after = try WebSocketTransport(url: "ws://localhost/test", session: BenchmarkSession(newSocket))
                before.setMode(mode); after.setMode(mode)
                before.setSchema(["watch": APISchema(id: 7)]); try after.setSchema(["watch": APISchema(id: 7)])
                before.connect(); after.connect()
            }

            func close() { before.close(); after.close() }
        }

        private static func lifecycle(_ mode: TransportMode) async throws {
            let pair = try Pair(mode)
            defer { pair.close() }
            let expected = mode == .json ? Data("7".utf8) : Data([7])
            try await TransportMetadataBenchmark.compareAsync("JSON failure unary \(mode)") {
                let value = try await pair.before.call("watch")
                precondition(value.mode == mode && value.data == expected)
                return UInt64(value.data.count)
            } after: {
                let value = try await pair.after.call("watch")
                precondition(value.mode == mode && value.data == expected)
                return UInt64(value.data.count)
            }
            try await TransportMetadataBenchmark.compareAsync("JSON failure setup ACK cancel \(mode)") {
                try await pair.before.subscribe("watch", decoder: { $0 }) { _ in }()
                return 1
            } after: {
                try await pair.after.subscribe("watch", decoder: { $0 }) { _ in }()
                return 1
            }
        }

        private static func dispatch(_ mode: TransportMode) async throws {
            let pair = try Pair(mode)
            defer { pair.close() }
            let oldSocket = pair.oldSocket, newSocket = pair.newSocket
            let before = try await pair.before.subscribe("watch", decoder: { $0 }) {
                precondition($0.mode == mode && $0.data.count == 1); oldSocket.record()
            }
            let after = try await pair.after.subscribe("watch", decoder: { $0 }) {
                precondition($0.mode == mode && $0.data.count == 1); newSocket.record()
            }
            let frame: URLSessionWebSocketTask.Message =
                mode == .json
                ? .string(#"{"$stream":1,"data":7}"#) : .data(Data([0x12, 1, 14]))
            TransportMetadataBenchmark.compare(
                "JSON failure data \(mode)", iterations: 50_000, warmup: 10_000,
                before: { _ in
                    oldSocket.deliver(frame); return 1
                },
                after: { _ in
                    newSocket.deliver(frame); return 1
                })
            precondition(oldSocket.receivedCount == 880_000 && newSocket.receivedCount == 880_000)
            before(); after()
        }
    }
#endif
