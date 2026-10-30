import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class HTTPResponseCollectorTests: XCTestCase {
    func testHeaderOnlyResponsePreservesTimeoutAndEmptyCompletionChecksLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnfinishedHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for path in ["header-timeout", "empty-oversized", "empty"] {
            do {
                let (body, _) = try await HTTPResponseCollector(maximum: 64).read(
                    session: session, request: URLRequest(url: URL(string: "https://example.test/\(path)")!))
                XCTAssertEqual(path, "empty")
                XCTAssertTrue(body.isEmpty)
            } catch let error as URLError {
                XCTAssertEqual(path, "header-timeout")
                XCTAssertEqual(error.code, .timedOut)
            } catch let error as LuxoError {
                XCTAssertEqual(path, "empty-oversized")
                XCTAssertEqual(error.name, "ParseError")
            }
        }
    }

    func testOverflowDoesNotWaitForEOFOrInvalidateSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnfinishedHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for path in ["declared", "chunked", "untyped"] {
            let completed = expectation(description: "reject \(path) before EOF")
            let worker = Task {
                do {
                    _ = try await HTTPResponseCollector(maximum: 64).read(
                        session: session, request: URLRequest(url: URL(string: "https://example.test/\(path)")!))
                    XCTFail("oversized unfinished response accepted")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, "ParseError")
                } catch { XCTFail("unexpected error: \(error)") }
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 2)
            worker.cancel()
            let (body, _) = try await HTTPResponseCollector(maximum: 64).read(
                session: session, request: URLRequest(url: URL(string: "https://example.test/small")!))
            XCTAssertEqual(body, Data([42]))
        }
    }

    func testCancellationBeforeStartDoesNotLeaveContinuationWaiting() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnfinishedHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let completed = expectation(description: "cancelled collector finishes")
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await HTTPResponseCollector(maximum: 64).read(
                    session: session, request: URLRequest(url: URL(string: "https://example.test/stall")!))
                XCTFail("cancelled operation succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        worker.cancel()
    }

    func testCancellationAfterPartialBodyKeepsOtherRequestsAlive() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnfinishedHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let received = expectation(description: "partial response delivered")
        let notification = Notification.Name(UUID().uuidString)
        let observer = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: nil) { _ in
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var request = URLRequest(url: URL(string: "https://example.test/partial")!)
        request.setValue(notification.rawValue, forHTTPHeaderField: "X-Test-Notification")
        let partialRequest = request
        let worker = Task {
            try await HTTPResponseCollector(maximum: 64).read(session: session, request: partialRequest)
        }
        defer { worker.cancel() }
        await fulfillment(of: [received], timeout: 2)
        let other = Task {
            try await HTTPResponseCollector(maximum: 64).read(
                session: session, request: URLRequest(url: URL(string: "https://example.test/small")!))
        }
        worker.cancel()
        do {
            _ = try await worker.value
            XCTFail("cancelled partial response succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        let (body, _) = try await other.value
        XCTAssertEqual(body, Data([42]))
    }
}

private final class UnfinishedHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/stall" { return }
        var headers = ["Content-Type": "application/x-luxo", "X-Content-Type-Options": "nosniff"]
        if ["/declared", "/header-timeout", "/empty-oversized"].contains(url.path) {
            headers["Content-Length"] = "65"
        }
        if url.path == "/untyped" { headers = [:] }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/header-timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        } else if url.path == "/empty" || url.path == "/empty-oversized" {
            client?.urlProtocolDidFinishLoading(self)
        } else if url.path == "/declared" {
            client?.urlProtocol(self, didLoad: Data([1]))
        } else if url.path == "/chunked" {
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 32))
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 33))
        } else if url.path == "/untyped" {
            // Foundation may sniff untyped prefixes before delivering callbacks.
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 8192))
        } else if url.path == "/partial" {
            client?.urlProtocol(self, didLoad: Data([42]))
            if let name = request.value(forHTTPHeaderField: "X-Test-Notification") {
                NotificationCenter.default.post(name: Notification.Name(name), object: nil)
            }
        } else if url.path == "/small" {
            client?.urlProtocol(self, didLoad: Data([42]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
