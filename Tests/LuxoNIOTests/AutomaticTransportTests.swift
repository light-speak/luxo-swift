import Foundation
import LuxoClient
import XCTest
@testable import LuxoNIO

@MainActor
final class AutomaticTransportTests: XCTestCase {
    func testAutomaticUsesH2AndPreservesGeneratedProtocol() async throws {
        let config = try IntegrationTests.Configuration()
        let transport = try await AutomaticHTTPTransport.connect(
            endpoint: "https://localhost:\(config.port)/api", trustRootsFile: config.certificate)
        XCTAssertEqual(transport.backend.selectedBackend, .http2)
        do {
            let result = try await transport.call("viewer")
            XCTAssertEqual(result.data, Data("42".utf8))
            try await transport.close()
        } catch { try? await transport.close(); throw error }
    }

    func testOnlyVerifiedHTTP1NegotiationIsEligibleForFallback() async throws {
        let config = try IntegrationTests.Configuration()
        do {
            _ = try await NIOHTTPBackend.connectForSelection(
                endpoint: "https://localhost:\(config.http1Port)", trustRootsFile: config.certificate)
            XCTFail("HTTP/1 accepted as HTTP/2")
        } catch ConnectionFailure.requiresHTTP2 {} catch { XCTFail("unexpected error: \(error)") }
        do {
            _ = try await AutomaticHTTPTransport.connect(
                endpoint: "https://localhost:\(config.http1Port)", trustRootsFile: config.wrongCertificate)
            XCTFail("invalid certificate accepted")
        } catch let error as LuxoError { XCTAssertEqual(error.name, "NetworkError") }
    }

    func testFallbackDoesNotDiscardCustomTrustConfiguration() async throws {
        let config = try IntegrationTests.Configuration()
        do {
            _ = try await AutomaticHTTPTransport.connect(
                endpoint: "https://localhost:\(config.http1Port)", trustRootsFile: config.certificate)
            XCTFail("custom trust silently discarded")
        } catch let error as LuxoError { XCTAssertEqual(error.name, "ConfigError") }
    }

    func testClosedAutomaticTransportNeverSwitchesOrReplays() async throws {
        let config = try IntegrationTests.Configuration()
        let transport = try await AutomaticHTTPTransport.connect(
            endpoint: "https://localhost:\(config.port)/api", trustRootsFile: config.certificate)
        try await transport.close()
        do { _ = try await transport.call("viewer"); XCTFail("closed request accepted") } catch let error as LuxoError {
            XCTAssertEqual(error.name, "NetworkError")
        }
        XCTAssertEqual(transport.backend.selectedBackend, .http2)
    }
}
