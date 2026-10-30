import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import XCTest
@testable import LuxoClient
@testable import LuxoNIO

private final class FallbackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path != "/hold" else {
            NotificationCenter.default.post(name: Notification.Name("LuxoFallbackHolding"), object: nil)
            return
        }
        if request.url?.path == "/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let body = request.url?.path == "/large" ? Data(repeating: 1, count: 64) : Data("{\"data\":42}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AutomaticFallbackTests: XCTestCase {
    private func fallback(_ path: String = "/api", maximum: Int = 1024) throws -> URLSessionHTTPBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FallbackProtocol.self]
        return try URLSessionHTTPBackend(
            endpoint: "https://localhost\(path)", timeout: 2, maximum: maximum,
            session: URLSession(configuration: config))
    }

    func testVerifiedH1SelectsFallbackOnceBeforeBusinessCalls() async throws {
        let config = try IntegrationTests.Configuration()
        var selections = 0
        let backend = try await AutomaticHTTPBackend.select(
            maximumRequest: 1024, maximumConcurrent: 2,
            connectHTTP2: {
                try await NIOHTTPBackend.connectForSelection(
                    endpoint: "https://localhost:\(config.http1Port)", trustRootsFile: config.certificate)
            },
            makeFallback: {
                selections += 1; return try self.fallback()
            })
        let transport = AutomaticHTTPTransport(backend: backend)
        XCTAssertEqual(backend.selectedBackend, .urlSession)
        do {
            for _ in 0..<3 {
                let result = try await transport.call("viewer")
                XCTAssertEqual(result.data, Data("42".utf8))
            }
            XCTAssertEqual(selections, 1)
            try await transport.close()
            try await transport.close()
            do { _ = try await transport.call("viewer"); XCTFail("closed call accepted") } catch let error as LuxoError
            { XCTAssertEqual(error.name, "NetworkError") }
        } catch { try? await transport.close(); throw error }
    }

    func testOtherConnectionErrorsAndCancellationNeverSelectFallback() async throws {
        for error in [ConnectionFailure.deadline, .invalidConfiguration, .overloaded] {
            do {
                _ = try await AutomaticHTTPBackend.select(
                    maximumRequest: 1024, maximumConcurrent: 1,
                    connectHTTP2: { throw error },
                    makeFallback: {
                        XCTFail("fallback selected"); return try self.fallback()
                    })
                XCTFail("error ignored")
            } catch { XCTAssertTrue(error is ConnectionFailure) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AutomaticHTTPBackend.select(
                maximumRequest: 1024, maximumConcurrent: 1,
                connectHTTP2: { throw ConnectionFailure.requiresHTTP2 },
                makeFallback: {
                    XCTFail("cancelled fallback selected"); return try self.fallback()
                })
        }
        do { _ = try await task.value; XCTFail("cancelled selection succeeded") } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFallbackKeepsBodyAndHeaderLimits() async throws {
        for path in ["/api", "/large"] {
            let backend = try AutomaticHTTPBackend(
                fallback: fallback(path, maximum: 16), maximumRequest: 4, maximumConcurrent: 1)
            do {
                do {
                    _ = try await backend.send(body: Data(count: 5), mode: .binary, headers: [:]);
                    XCTFail("oversize sent")
                } catch let error as LuxoError { XCTAssertEqual(error.name, "ConfigError") }
                do {
                    _ = try await backend.send(body: Data(), mode: .binary, headers: ["x": "a\r\nb"]);
                    XCTFail("bad header")
                } catch let error as LuxoError { XCTAssertEqual(error.name, "ConfigError") }
                if path == "/large" {
                    do {
                        _ = try await backend.send(body: Data(), mode: .binary, headers: [:]);
                        XCTFail("oversize received")
                    } catch let error as LuxoError { XCTAssertEqual(error.name, "ParseError") }
                }
                try await backend.close()
            } catch { try? await backend.close(); throw error }
        }
    }

    func testFallbackAdmissionAndCloseCancelPendingRequest() async throws {
        let started = expectation(forNotification: Notification.Name("LuxoFallbackHolding"), object: nil)
        let backend = try AutomaticHTTPBackend(
            fallback: fallback("/hold"), maximumRequest: 1024, maximumConcurrent: 1)
        let pending = Task { try await backend.send(body: Data(), mode: .binary, headers: [:]) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await backend.send(body: Data(), mode: .binary, headers: [:]); XCTFail("limit ignored") } catch let
            error as LuxoError
        { XCTAssertEqual(error.code, 503) }
        try await backend.close()
        do { _ = try await pending.value; XCTFail("closed request succeeded") } catch {}
    }

    func testFailedFallbackRequestDoesNotReconnect() async throws {
        var selections = 0
        let backend = try await AutomaticHTTPBackend.select(
            maximumRequest: 1024, maximumConcurrent: 1,
            connectHTTP2: { throw ConnectionFailure.requiresHTTP2 },
            makeFallback: {
                selections += 1; return try self.fallback("/failure")
            })
        do { _ = try await backend.send(body: Data(), mode: .binary, headers: [:]); XCTFail("failure accepted") } catch
        { XCTAssertEqual(selections, 1) }
        XCTAssertEqual(backend.selectedBackend, .urlSession)
        try await backend.close()
    }
}
