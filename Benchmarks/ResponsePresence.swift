import Foundation

#if LUXO_RESPONSE_PRESENCE_BENCHMARK

    // Compile identical harness and class names against the two source sets.
    @main
    enum ResponsePresenceBenchmark {
        private static let sampleCount = 10
        private static let warmupCount = 2_000
        private static let dispatchCount = 50_000
        private static let lifecycleCount = 10_000

        static func main() async throws {
            for mode in [TransportMode.json, .binary] {
                try await lifecycle(mode)
                try await dispatch(mode, text: "7")
                if mode == .json {
                    try await dispatch(mode, text: "null")
                    try await dispatch(mode, text: #"{"id":7,"name":"sample"}"#)
                }
            }
            print("fake socket; no full generated decoder, allocation, real network or failure-cleanup measurement")
        }

        private struct Fixture {
            let socket: BenchmarkSocket
            let transport: WebSocketTransport

            init(_ mode: TransportMode) throws {
                socket = BenchmarkSocket(legacy: false)
                transport = try WebSocketTransport(url: "ws://localhost/bench", session: BenchmarkSession(socket))
                transport.setMode(mode)
                try transport.setSchema(["watch": APISchema(id: 7)])
                transport.connect()
            }
        }

        private static func lifecycle(_ mode: TransportMode) async throws {
            let fixture = try Fixture(mode)
            defer { fixture.transport.close() }
            let expected = mode == .json ? Data("7".utf8) : Data([7])
            try await measureAsync("unary/\(mode)") {
                let payload = try await fixture.transport.call("watch")
                precondition(payload.mode == mode && payload.data == expected)
                return UInt64(payload.data.count)
            }
            try await measureAsync("setup-ack-cancel/\(mode)") {
                let cancel = try await fixture.transport.subscribe("watch", decoder: { $0 }) { _ in }
                cancel()
                return 1
            }
        }

        private static func dispatch(_ mode: TransportMode, text: String) async throws {
            let fixture = try Fixture(mode)
            defer { fixture.transport.close() }
            let socket = fixture.socket
            let expected = mode == .json ? Data(text.utf8) : Data([7])
            let cancel = try await fixture.transport.subscribe("watch", decoder: { $0 }) {
                precondition($0.mode == mode && $0.data == expected)
                socket.record()
            }
            defer { cancel() }
            let frame: URLSessionWebSocketTask.Message =
                mode == .json
                ? .string("{\"$stream\":1,\"data\":\(text)}") : .data(Data([0x12, 1, 7]))
            measure("dispatch/\(mode)/\(text)") {
                socket.deliver(frame)
                return UInt64(expected.count)
            }
            precondition(socket.receivedCount == warmupCount + sampleCount * dispatchCount)
        }

        private static func measure(_ label: String, operation: () -> UInt64) {
            var sink: UInt64 = 0
            for _ in 0..<warmupCount { sink &+= operation() }
            var samples: [Double] = []
            for _ in 0..<sampleCount {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<dispatchCount { sink &+= operation() }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(dispatchCount))
            }
            report(label, samples: samples, sink: sink)
        }

        private static func measureAsync(_ label: String, operation: () async throws -> UInt64) async throws {
            var sink: UInt64 = 0
            for _ in 0..<warmupCount { sink &+= try await operation() }
            var samples: [Double] = []
            for _ in 0..<sampleCount {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<lifecycleCount { sink &+= try await operation() }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(lifecycleCount))
            }
            report(label, samples: samples, sink: sink)
        }

        private static func report(_ label: String, samples: [Double], sink: UInt64) {
            let sorted = samples.sorted()
            print(
                "\(label) median_ns=\((sorted[4] + sorted[5]) / 2) min_ns=\(sorted[0]) max_ns=\(sorted[9]) sink=\(sink)"
            )
        }
    }

#endif
