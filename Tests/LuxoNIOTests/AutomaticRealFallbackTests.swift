#if canImport(Security)
    import Foundation
    import Security
    import XCTest
    @testable import LuxoClient
    @testable import LuxoNIO

    // Test-owned trust anchors; system trust configuration is never modified.
    private final class FixtureTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
        let certificate: SecCertificate
        init(path: String) throws {
            let pem = try String(contentsOfFile: path, encoding: .utf8)
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            guard let der = Data(base64Encoded: pem, options: .ignoreUnknownCharacters),
                let certificate = SecCertificateCreateWithData(nil, der as CFData)
            else { throw URLError(.serverCertificateUntrusted) }
            self.certificate = certificate
        }

        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                let trust = challenge.protectionSpace.serverTrust,
                SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                SecTrustEvaluateWithError(trust, nil)
            else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private actor ProtocolProbeBackend: HTTPBackend {
        let backend: AutomaticHTTPBackend
        let fixtureHeaders: [String: String]
        private(set) var bodies: [Data] = []
        private(set) var tokens: [String?] = []
        private(set) var refreshes = 0

        init(_ backend: AutomaticHTTPBackend, status: Int, target: String) {
            self.backend = backend
            fixtureHeaders = [
                "X-Test-Status": String(status), "X-Test-Target": target,
                "X-Test-Refresh": "true", "X-Project-Key": "test-only-key",
            ]
        }

        init(_ backend: AutomaticHTTPBackend, headers: [String: String]) {
            self.backend = backend
            fixtureHeaders = headers
        }

        func refreshToken() -> String? { refreshes += 1; return "renewed" }

        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            bodies.append(body)
            tokens.append(headers["Authorization"])
            return try await backend.send(
                body: body, mode: mode,
                headers: headers.merging(fixtureHeaders) { _, fixture in fixture })
        }
    }

    @MainActor
    final class AutomaticRealFallbackTests: XCTestCase {
        func testHandwrittenCodableDepthAndRecoveryThroughBothTLSBackends() async throws {
            final class Node: Decodable { let child: Node?; let metadata: JSONValue? }
            var expected = JSONValue.integer(7)
            for _ in 0..<128 { expected = .array([expected]) }
            let decoder = LuxoJSONDecoder()
            try await withReplayBackends { backend in
                let key = UUID().uuidString
                for generated in [false, true] {
                    for (models, json, valid) in [(64, 128, true), (65, 128, false), (64, 129, false), (64, 128, true)]
                    {
                        let probe = ProtocolProbeBackend(
                            backend,
                            headers: [
                                "X-Test-Case": key, "X-Test-Action": "codable",
                                "X-Test-Models": String(models), "X-Test-JSON": String(json),
                            ])
                        let transport = HTTPTransport(backend: probe, timeout: 2)
                        let payload = try await invoke(transport, generated)
                        XCTAssertEqual(payload.mode, .json)
                        if valid {
                            var node = try decoder.decode(Node.self, from: payload.data)
                            for _ in 1..<64 { node = try XCTUnwrap(node.child) }
                            XCTAssertNil(node.child)
                            XCTAssertEqual(node.metadata, expected)
                        } else {
                            XCTAssertThrowsError(try decoder.decode(Node.self, from: payload.data)) { error in
                                XCTAssertEqual(
                                    (error as? LuxoError)?.name, models == 65 ? "DecodingError" : "ParseError")
                            }
                        }
                    }
                }
                try await verifyReplayCount(backend, key, expected: 8)
            }
        }

        private struct ReplayRequest: GeneratedRequest {
            let apiID = 1
            func writeParameters(to encoder: inout Encoder) throws {}
            func toJSONParameters() throws -> [String: LuxoValue] { [:] }
        }

        func testHTTPStatusErrorsNeverImplicitlyReplayPOST() async throws {
            try await withReplayBackends { backend in
                for mode in [TransportMode.json, .binary] {
                    for generated in [false, true] {
                        for status in [408, 503] {
                            let (transport, probe, key) = try replayTransport(backend, mode, String(status))
                            do {
                                _ = try await invoke(transport, generated)
                                XCTFail("status error implicitly replayed")
                            } catch let error as LuxoError {
                                XCTAssertEqual(error.code, status)
                                XCTAssertEqual(error.name, "Unavailable")
                            }
                            try await verifyReplayCount(backend, key, expected: 1)
                            _ = try await invoke(transport, generated)
                            try await verifyReplayCount(backend, key, expected: 2)
                            let refreshes = await probe.refreshes
                            XCTAssertEqual(refreshes, 0)
                        }
                    }
                }
            }
        }

        func testHTTPLostResponseDoesNotReplayExecutedPOST() async throws {
            try await withReplayBackends { backend in
                for mode in [TransportMode.json, .binary] {
                    for generated in [false, true] {
                        let (transport, probe, key) = try replayTransport(backend, mode, "lost")
                        _ = try await invoke(transport, generated)
                        do {
                            _ = try await invoke(transport, generated)
                            XCTFail("lost response implicitly replayed")
                        } catch let error as LuxoError {
                            XCTAssertEqual(backend.selectedBackend, .http2)
                            XCTAssertEqual(error.name, "NetworkError")
                        } catch let error as URLError {
                            XCTAssertEqual(backend.selectedBackend, .urlSession)
                            XCTAssertEqual(error.code, .networkConnectionLost)
                        }
                        try await verifyReplayCount(backend, key, expected: 2, reused: true)
                        _ = try await invoke(transport, generated)
                        try await verifyReplayCount(backend, key, expected: 3)
                        let bodies = await probe.bodies
                        XCTAssertEqual(bodies.count, 3)
                        XCTAssertTrue(bodies.allSatisfy { $0 == bodies.first })
                    }
                }
            }
        }

        func testHTTPRealRefreshRetainsBodyAndUpdatesOnlyToken() async throws {
            try await withReplayBackends { backend in
                for mode in [TransportMode.json, .binary] {
                    for generated in [false, true] {
                        let (transport, probe, key) = try replayTransport(backend, mode, "refresh")
                        _ = try await invoke(transport, generated)
                        try await verifyReplayCount(backend, key, expected: 2)
                        let bodies = await probe.bodies
                        let tokens = await probe.tokens
                        let refreshes = await probe.refreshes
                        XCTAssertEqual(bodies.count, 2)
                        XCTAssertTrue(bodies.allSatisfy { $0 == bodies.first })
                        XCTAssertEqual(tokens, ["Bearer original", "Bearer renewed"])
                        XCTAssertEqual(refreshes, 1)
                    }
                }
            }
        }

        private func replayTransport(_ backend: AutomaticHTTPBackend, _ mode: TransportMode, _ action: String) throws
            -> (HTTPTransport<ProtocolProbeBackend>, ProtocolProbeBackend, String)
        {
            let key = UUID().uuidString
            let probe = ProtocolProbeBackend(backend, headers: ["X-Test-Case": key, "X-Test-Action": action])
            let transport = HTTPTransport(backend: probe, token: "original", timeout: 2)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            transport.setMode(mode)
            transport.onTokenExpired = { await probe.refreshToken() }
            return (transport, probe, key)
        }

        private func invoke(_ transport: HTTPTransport<ProtocolProbeBackend>, _ generated: Bool) async throws
            -> TransportPayload
        {
            if generated { return try await transport.call("viewer", request: ReplayRequest()) }
            return try await transport.call("viewer")
        }

        private func verifyReplayCount(
            _ backend: AutomaticHTTPBackend, _ key: String, expected: Int, reused: Bool = false
        )
            async throws
        {
            let response = try await backend.send(
                body: Data([1]), mode: .binary, headers: ["X-Test-Case": key, "X-Test-Probe": "true"])
            let values = String(decoding: response.body, as: UTF8.self).components(separatedBy: "\n")
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(values.count, 3)
            XCTAssertEqual(values.first, String(expected))
            if reused && values.count == 3 {
                XCTAssertFalse(values[1].isEmpty)
                XCTAssertEqual(values[1], values[2], "lost-response probe did not reuse its warm connection")
            }
        }

        private func withAutomaticBackend(
            _ config: IntegrationTests.Configuration, port: Int, path: String,
            verify: (AutomaticHTTPBackend) async throws -> Void
        ) async throws {
            let endpoint = "https://localhost:\(port)\(path)"
            let session = URLSession(
                configuration: .ephemeral, delegate: try FixtureTrust(path: config.certificate), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let backend = try await AutomaticHTTPBackend.select(
                maximumRequest: 1024, maximumConcurrent: 2,
                connectHTTP2: {
                    try await NIOHTTPBackend.connectForSelection(
                        endpoint: endpoint, trustRootsFile: config.certificate)
                },
                makeFallback: {
                    try URLSessionHTTPBackend(endpoint: endpoint, timeout: 2, maximum: 1024, session: session)
                })
            do {
                XCTAssertEqual(backend.selectedBackend, port == config.port ? .http2 : .urlSession)
                try await verify(backend)
                try await backend.close()
            } catch { try? await backend.close(); throw error }
        }

        private func withReplayBackends(_ verify: (AutomaticHTTPBackend) async throws -> Void) async throws {
            let config = try IntegrationTests.Configuration()
            for port in [config.port, config.http1Port] {
                try await withAutomaticBackend(config, port: port, path: "/replay", verify: verify)
            }
        }

        func testAutomaticBackendsNeverReplayBusinessRedirects() async throws {
            let config = try IntegrationTests.Configuration()
            for port in [config.port, config.http1Port] {
                try await withAutomaticBackend(config, port: port, path: "/redirect") { backend in
                    let otherPort = port == config.port ? config.http1Port : config.port
                    for mode in [TransportMode.json, .binary] {
                        for status in [301, 302, 303, 307, 308] {
                            for target in ["/redirect-target", "https://localhost:\(otherPort)/redirect-target"] {
                                let response = try await backend.send(
                                    body: Data("private-input".utf8), mode: mode,
                                    headers: [
                                        "X-Project-Key": "test-only-key", "X-Test-Status": String(status),
                                        "X-Test-Target": target,
                                    ])
                                XCTAssertEqual(response.status, status)
                            }
                        }
                    }
                    try await verifyRefreshRedirects(backend, otherPort: otherPort)
                    let next = try await backend.send(body: Data([1]), mode: .binary, headers: [:])
                    XCTAssertEqual(next.status, 200)
                    XCTAssertEqual(next.body, Data("0".utf8))
                }
            }
        }

        private func verifyRefreshRedirects(_ backend: AutomaticHTTPBackend, otherPort: Int) async throws {
            for mode in [TransportMode.json, .binary] {
                for status in [301, 302, 303, 307, 308] {
                    for target in ["/redirect-target", "https://localhost:\(otherPort)/redirect-target"] {
                        let probe = ProtocolProbeBackend(backend, status: status, target: target)
                        let transport = HTTPTransport(backend: probe, token: "old", timeout: 2)
                        try transport.setSchema(["viewer": APISchema(id: 1)])
                        transport.setMode(mode)
                        var refreshed = 0
                        transport.onTokenExpired = {
                            refreshed += 1; return "renewed"
                        }
                        do {
                            _ = try await transport.call("viewer")
                            XCTFail("redirect accepted after refresh")
                        } catch let error as LuxoError {
                            XCTAssertEqual(error.code, status)
                        }
                        XCTAssertEqual(refreshed, 1)
                        let bodies = await probe.bodies
                        let tokens = await probe.tokens
                        XCTAssertEqual(bodies.count, 2)
                        if bodies.count == 2 { XCTAssertEqual(bodies[0], bodies[1]) }
                        XCTAssertEqual(tokens, ["Bearer old", "Bearer renewed"])
                    }
                }
            }
        }

        func testVerifiedH1FallbackCarriesRealJSONAndBinaryRequests() async throws {
            let config = try IntegrationTests.Configuration()
            try await withAutomaticBackend(config, port: config.http1Port, path: "/api-h1") { backend in
                let json = try await backend.send(body: Data("{}".utf8), mode: .json, headers: [:])
                XCTAssertEqual(json.status, 200)
                XCTAssertEqual(json.body, Data("{\"data\":42}".utf8))
                let binary = try await backend.send(body: Data([0]), mode: .binary, headers: [:])
                XCTAssertEqual(binary.status, 200)
                XCTAssertEqual(binary.body, Data([84]))
                let unauthorized = try await backend.send(
                    body: Data([0]), mode: .binary, headers: ["Authorization": "Bearer old"])
                XCTAssertEqual(unauthorized.status, 401)
            }
        }
    }
#endif
