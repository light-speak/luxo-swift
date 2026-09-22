import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if LUXO_HTTP_REFRESH_BENCHMARK
    // Build against the before/after Transport.swift snapshots separately.
    // URLProtocol exercises URLSession without claiming real network latency.
    @main
    enum HTTPRefreshStatusBenchmark {
        static func main() async throws {
            precondition(CommandLine.arguments.count == 2)
            let before = CommandLine.arguments[1] == "before"
            precondition(before || CommandLine.arguments[1] == "after")
            for mode in [TransportMode.json, .binary] {
                for scenario in RefreshScenario.allCases {
                    try await measure(mode: mode, scenario: scenario, before: before)
                }
            }
            print("URLProtocol only; allocations, real network and device costs are not measured")
        }

        private static func measure(mode: TransportMode, scenario: RefreshScenario, before: Bool) async throws {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RefreshProtocol.self]
            config.httpAdditionalHeaders = ["X-Scenario": scenario.rawValue]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let transport = try URLSessionTransport(endpoint: "https://localhost/benchmark", session: session)
            transport.setMode(mode)
            try transport.setSchema(["echo": APISchema(id: 1)])
            transport.onTokenExpired = {
                RefreshProtocol.counts.refreshed()
                return scenario == .refresh ? "renewed" : nil
            }
            for _ in 0..<200 { try await perform(transport, mode: mode, scenario: scenario) }
            RefreshProtocol.counts.reset()
            let iterations = 2000
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { try await perform(transport, mode: mode, scenario: scenario) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let counts = RefreshProtocol.counts.snapshot()
            precondition(counts.requests == iterations * (scenario == .refresh ? 2 : 1))
            let refreshes = scenario == .refresh || (before && scenario == .forbidden) ? iterations : 0
            precondition(counts.refreshes == refreshes)
            print("\(scenario.rawValue)/\(mode) \(Double(elapsed) / Double(iterations)) ns/op")
        }

        private static func perform(
            _ transport: URLSessionTransport, mode: TransportMode, scenario: RefreshScenario
        ) async throws {
            if scenario == .refresh { transport.setToken("expired") }
            do {
                let payload = try await transport.call("echo")
                precondition(scenario != .forbidden)
                precondition(payload.mode == mode)
                precondition(payload.data == (mode == .json ? Data("42".utf8) : Data([84])))
            } catch let error as LuxoError {
                guard scenario == .forbidden else { throw error }
                precondition(error.code == 401 && error.name == "Unauthorized" && error.message == "expired")
            }
        }
    }

    private enum RefreshScenario: String, CaseIterable {
        case success, refresh, forbidden
    }

    private final class RefreshCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0
        private var refreshes = 0

        func requested() { lock.lock(); defer { lock.unlock() }; requests += 1 }
        func refreshed() { lock.lock(); defer { lock.unlock() }; refreshes += 1 }
        func reset() { lock.lock(); defer { lock.unlock() }; requests = 0; refreshes = 0 }
        func snapshot() -> (requests: Int, refreshes: Int) {
            lock.lock(); defer { lock.unlock() }
            return (requests, refreshes)
        }
    }

    private final class RefreshProtocol: URLProtocol, @unchecked Sendable {
        static let counts = RefreshCounts()
        private static let jsonError = Data(#"{"error":"Unauthorized","code":401,"message":"expired"}"#.utf8)
        private static let binaryError: Data = {
            var encoder = Encoder()
            encoder.writeVarint(1); encoder.writeSvarint(401)
            encoder.writeVarint(2); encoder.writeString("Unauthorized")
            encoder.writeVarint(3); encoder.writeString("expired")
            encoder.writeEnd()
            return encoder.data
        }()

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.counts.requested()
            guard let value = request.value(forHTTPHeaderField: "X-Scenario"),
                let scenario = RefreshScenario(rawValue: value), let url = request.url
            else { preconditionFailure("missing benchmark metadata") }
            let binary = request.value(forHTTPHeaderField: "X-Luxo-Mode") == "binary"
            let expired =
                scenario == .refresh && request.value(forHTTPHeaderField: "Authorization") != "Bearer renewed"
            let status = scenario == .forbidden ? 403 : (expired ? 401 : 200)
            let data =
                status == 200
                ? (binary ? Data([84]) : Data(#"{"data":42}"#.utf8))
                : (binary ? Self.binaryError : Self.jsonError)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)
            else { preconditionFailure("invalid benchmark response") }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
#endif
