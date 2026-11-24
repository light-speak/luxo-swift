import Foundation
import LuxoClient
import XCTest
@testable import LuxoNIO

@MainActor
final class TransportIntegrationTests: XCTestCase {
    private struct EmptyRequest: GeneratedRequest {
        let apiID = 1
        func writeParameters(to encoder: inout Encoder) throws {}
        func toJSONParameters() throws -> [String: LuxoValue] { [:] }
    }

    private func connect(_ path: String = "/api", timeout: TimeInterval = 30, maximum: Int = 1024) async throws
        -> NIOHTTPTransport
    {
        let config = try IntegrationTests.Configuration()
        return try await NIOHTTPTransport.connect(
            endpoint: "https://localhost:\(config.port)\(path)",
            timeout: timeout, maxResponseBytes: maximum, trustRootsFile: config.certificate)
    }

    func testInvalidConfigurationRejectedBeforeConnecting() async throws {
        for endpoint in ["http://localhost", "https://user:pass@localhost", "https://localhost/#fragment", "invalid"] {
            do {
                _ = try await NIOHTTPTransport.connect(endpoint: endpoint)
                XCTFail("invalid endpoint accepted")
            } catch let error as LuxoError { XCTAssertEqual(error.name, "ConfigError") }
        }
        for timeout in [0, -1, .nan, .infinity, Double(Int64.max)] {
            do {
                _ = try await NIOHTTPTransport.connect(endpoint: "https://localhost", timeout: timeout)
                XCTFail("invalid timeout accepted")
            } catch let error as LuxoError { XCTAssertEqual(error.name, "ConfigError") }
        }
    }

    func testGeneratedBinaryAndJSONShareProtocolImplementation() async throws {
        let transport = try await connect()
        do {
            try transport.setSchema(["viewer": APISchema(id: 1)])
            let json = try await transport.call("viewer", request: EmptyRequest())
            XCTAssertEqual(json.mode, .json)
            XCTAssertEqual(json.data, Data("42".utf8))
            transport.setMode(.binary)
            let binary = try await transport.call("viewer", request: EmptyRequest())
            XCTAssertEqual(binary.mode, .binary)
            XCTAssertEqual(binary.data, Data([84]))
            try await transport.close()
        } catch { try? await transport.close(); throw error }
    }

    func testAuthenticationRefreshAndForbiddenDoNotReplay() async throws {
        for path in ["/api", "/api-forbidden"] {
            let transport = try await connect(path)
            var refreshed = 0
            transport.setToken("old")
            transport.onTokenExpired = {
                refreshed += 1; return "new"
            }
            do {
                if path == "/api" {
                    let result = try await transport.call("viewer")
                    XCTAssertEqual(result.data, Data("42".utf8))
                    XCTAssertEqual(refreshed, 1)
                } else {
                    do { _ = try await transport.call("viewer"); XCTFail("403 accepted") } catch let error as LuxoError
                    { XCTAssertEqual(error.code, 401) }
                    XCTAssertEqual(refreshed, 0)
                }
                try await transport.close()
            } catch { try? await transport.close(); throw error }
        }
    }

    func testTimeoutAndConcurrentCloseTerminateCalls() async throws {
        let transport = try await connect("/slow", timeout: 0.05)
        do {
            do { _ = try await transport.call("viewer"); XCTFail("deadline ignored") } catch let error as LuxoError {
                XCTAssertEqual(error.name, "TimeoutError")
            }
            let pending = Task { try await transport.call("viewer") }
            async let first: Void = transport.close()
            async let second: Void = transport.close()
            _ = try await (first, second)
            do { _ = try await pending.value; XCTFail("closed request succeeded") } catch let error as LuxoError {
                XCTAssertEqual(error.name, "NetworkError")
            }
            do { _ = try await transport.call("viewer"); XCTFail("closed transport accepted request") } catch let error
                as LuxoError
            { XCTAssertEqual(error.name, "NetworkError") }
        } catch { try? await transport.close(); throw error }
    }

    func testCancellationAndInvalidHeadersLeaveConnectionUsable() async throws {
        let transport = try await connect()
        do {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await transport.call("viewer")
            }
            do { _ = try await cancelled.value; XCTFail("cancelled call succeeded") } catch {
                XCTAssertTrue(error is CancellationError)
            }
            transport.setToken("invalid\r\ninjected: header")
            do { _ = try await transport.call("viewer"); XCTFail("invalid header accepted") } catch let error
                as LuxoError
            { XCTAssertEqual(error.name, "ConfigError") }
            transport.setToken("new")
            let result = try await transport.call("viewer")
            XCTAssertEqual(result.data, Data("42".utf8))
            try await transport.close()
        } catch { try? await transport.close(); throw error }
    }
    func testPublicRequestAndResponseLimits() async throws {
        let config = try IntegrationTests.Configuration()
        for responseLimit in [true, false] {
            let transport = try await NIOHTTPTransport.connect(
                endpoint: "https://localhost:\(config.port)/api",
                maxResponseBytes: responseLimit ? 1 : 1024, maxRequestBytes: responseLimit ? 1024 : 1,
                trustRootsFile: config.certificate)
            do {
                do { _ = try await transport.call("viewer"); XCTFail("body limit ignored") } catch let error
                    as LuxoError
                {
                    XCTAssertEqual(error.name, responseLimit ? "ParseError" : "ConfigError")
                }
                try await transport.close()
            } catch { try? await transport.close(); throw error }
        }
    }

}
