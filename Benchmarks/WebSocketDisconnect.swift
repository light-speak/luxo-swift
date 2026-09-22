import Foundation

#if LUXO_DISCONNECT_BENCHMARK
    enum WebSocketDisconnectBenchmark {
        static func run() async throws {
            for mode in [TransportMode.json, .binary] {
                let before = try Fixture(mode: mode, baseline: true)
                let after = try Fixture(mode: mode, baseline: false)
                defer { before.transport.close(); after.transport.close() }
                try await TransportMetadataBenchmark.compareAsync("Disconnect-aware unary \(mode)") {
                    try await before.call()
                } after: {
                    try await after.call()
                }
                try await TransportMetadataBenchmark.compareAsync("Disconnect-aware subscribe/ACK/cancel \(mode)") {
                    try await before.subscribeAndCancel()
                } after: {
                    try await after.subscribeAndCancel()
                }
                let oldData = try Fixture(mode: mode, baseline: true)
                let newData = try Fixture(mode: mode, baseline: false)
                defer { oldData.transport.close(); newData.transport.close() }
                try await oldData.watch()
                try await newData.watch()
                TransportMetadataBenchmark.compare(
                    "Disconnect-aware data \(mode)", iterations: 50_000, warmup: 10_000,
                    before: { _ in oldData.deliver() }, after: { _ in newData.deliver() })
                precondition(oldData.socket.receivedCount == 880_000 && newData.socket.receivedCount == 880_000)
                for count in [1, 8, 64] {
                    for observed in [false, true] {
                        try await measureRetirement(mode: mode, count: count, observed: observed)
                    }
                }
            }
        }

        private struct Fixture {
            let transport: any BenchmarkTransport
            let socket: BenchmarkSocket
            let mode: TransportMode

            init(mode: TransportMode, baseline: Bool) throws {
                socket = BenchmarkSocket(legacy: false)
                self.mode = mode
                let session = BenchmarkSession(socket)
                transport =
                    baseline
                    ? try PreDisconnectWebSocketTransport(url: "ws://localhost/bench", session: session)
                    : PayloadBenchmarkTransport(
                        base: try WebSocketTransport(url: "ws://localhost/bench", session: session))
                try transport.setSchema(["watch": APISchema(id: 7)])
                transport.setMode(mode)
                transport.connect()
            }

            func call() async throws -> UInt64 {
                let data = try await transport.call("watch", params: nil)
                precondition(data == Data([mode == .json ? 55 : 7]))
                return UInt64(data.count)
            }

            func subscribeAndCancel() async throws -> UInt64 {
                let cancel = try await transport.subscribe("watch") { _ in }
                cancel()
                return 1
            }

            func watch() async throws {
                let socket = socket
                let byte: UInt8 = mode == .json ? 55 : 7
                _ = try await transport.subscribe("watch") { data in
                    precondition(data == Data([byte]))
                    socket.record()
                }
            }

            func deliver() -> UInt64 {
                // Both fixtures reserve ID 1 once; frame construction is shared overhead.
                socket.deliver(mode == .json ? .string("{\"$stream\":1,\"data\":7}") : .data(Data([0x12, 1, 7])))
                return 1
            }
        }

        private static func measureRetirement(mode: TransportMode, count: Int, observed: Bool) async throws {
            var samples: [Double] = []
            for iteration in 0..<40 {
                let fixture = try Fixture(mode: mode, baseline: false)
                let finished = DispatchGroup()
                let observer =
                    observed
                    ? StreamObserver(onError: { error in
                        precondition(error.name == "NetworkError")
                        finished.leave()
                    }) : nil
                for _ in 0..<count {
                    if observed { finished.enter() }
                    _ = try await fixture.transport.subscribe("watch", observer: observer) { _ in
                        preconditionFailure("no data expected during retirement")
                    }
                }
                let elapsed = retire(fixture.socket, finished: finished)
                fixture.transport.close()
                if iteration >= 8 { samples.append(elapsed) }
            }
            print("Retirement absolute \(mode) count=\(count) observer=\(observed): \(median(samples)) ns")
        }

        // Includes asynchronous notifications and the wait, but excludes subscription setup.
        private static func retire(_ socket: BenchmarkSocket, finished: DispatchGroup) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            socket.disconnect()
            precondition(finished.wait(timeout: .now() + 5) == .success)
            return Double(DispatchTime.now().uptimeNanoseconds - start)
        }

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
    }
#endif
