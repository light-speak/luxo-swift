import Foundation
import XCTest
@testable import LuxoClient

final class WebSocketRenewalTests: XCTestCase {
    func testLiveGoGatewayStreamExpiryNeverReplaysSubscriptions() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["LUXO_WS_RENEWAL_URL"],
            ProcessInfo.processInfo.environment["LUXO_WS_RENEWAL_STREAM"] == "1"
        else { throw XCTSkip("requires owned Go stream renewal fixture") }
        for mode in [TransportMode.json, .binary] {
            try await checkLiveStreamRenewal(endpoint: endpoint, mode: mode)
        }
    }

    private func liveStreamCounts(_ endpoint: String) async throws -> LiveStreamCounts {
        let (data, response) = try await URLSession.shared.data(from: URL(string: endpoint + "/stats")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(LiveStreamCounts.self, from: data)
    }

    private func waitForLiveStreamCleanup(_ endpoint: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            let counts = try await liveStreamCounts(endpoint)
            if counts.gateway == 0 && counts.backend == 0 { return }
            if clock.now >= deadline { XCTFail("old subscriptions retained"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func checkLiveStreamRenewal(endpoint: String, mode: TransportMode) async throws {
        try await waitForLiveStreamCleanup(endpoint)
        let before = try await liveStreamCounts(endpoint).started
        let (data, response) = try await URLSession.shared.data(from: URL(string: endpoint + "/token")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let refresh = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Refresh-Token"))
        let token = try XCTUnwrap(String(data: data, encoding: .utf8))
        let transport = try WebSocketTransport(
            url: endpoint.replacingOccurrences(of: "http://", with: "ws://") + "/ws", token: token, timeout: 5)
        defer { transport.close() }
        try transport.setSchema(["identity": APISchema(id: 7), "watch": APISchema(id: 8)])
        transport.setMode(mode)
        let first = expectation(description: "initial stream value")
        let ended = expectation(description: "old subscription fails once")
        let renewed = expectation(description: "HTTP refresh")
        first.assertForOverFulfill = true; ended.assertForOverFulfill = true; renewed.assertForOverFulfill = true
        transport.onTokenExpired = {
            do {
                var request = URLRequest(url: URL(string: endpoint + "/refresh")!)
                request.setValue("Bearer " + refresh, forHTTPHeaderField: "Authorization")
                let (body, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                renewed.fulfill()
                return String(data: body, encoding: .utf8)
            } catch { XCTFail("refresh failed: \(error)"); renewed.fulfill(); return nil }
        }
        transport.connect()
        let expected = mode == .json ? Data("42".utf8) : Data([84])
        _ = try await transport.subscribe(
            "watch", decoder: { $0 },
            observer: StreamObserver(
                onComplete: { XCTFail("expiry is not normal completion") },
                onError: { error in
                    XCTAssertEqual(error.code, 401); ended.fulfill()
                }
            )
        ) { value in
            XCTAssertEqual(value.mode, mode); XCTAssertEqual(value.data, expected); first.fulfill()
        }
        await fulfillment(of: [first], timeout: 5)
        await fulfillment(of: [ended, renewed], timeout: 6)
        let current = try await transport.call("identity")
        XCTAssertEqual(current.data, expected)
        try await waitForLiveStreamCleanup(endpoint)
        let oldCounts = try await liveStreamCounts(endpoint)
        XCTAssertEqual(oldCounts.started, before + 1)
        let fresh = expectation(description: "explicit new subscription")
        fresh.assertForOverFulfill = true
        let stop = try await transport.subscribe(
            "watch", decoder: { $0 },
            observer: StreamObserver(
                onError: { error in
                    XCTFail("new subscription failed: \(error)"); fresh.fulfill()
                }
            )
        ) { value in
            XCTAssertEqual(value.mode, mode); XCTAssertEqual(value.data, expected); fresh.fulfill()
        }
        await fulfillment(of: [fresh], timeout: 5)
        let newCounts = try await liveStreamCounts(endpoint)
        XCTAssertEqual(newCounts.started, before + 2)
        stop()
    }

    func testLiveGoExpiryRefreshAndReconnect() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["LUXO_WS_RENEWAL_URL"] else {
            throw XCTSkip("requires owned Go renewal fixture")
        }
        for mode in [TransportMode.json, .binary] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: endpoint + "/token")!)
            let refresh = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Refresh-Token"))
            let token = try XCTUnwrap(String(data: data, encoding: .utf8))
            let transport = try WebSocketTransport(
                url: endpoint.replacingOccurrences(of: "http://", with: "ws://") + "/ws", token: token, timeout: 5)
            defer { transport.close() }
            try transport.setSchema(["identity": APISchema(id: 7)])
            transport.setMode(mode)
            let refreshed = expectation(description: "real expiry triggers HTTP refresh")
            transport.onTokenExpired = {
                do {
                    var request = URLRequest(url: URL(string: endpoint + "/refresh")!)
                    request.setValue("Bearer " + refresh, forHTTPHeaderField: "Authorization")
                    let (body, response) = try await URLSession.shared.data(for: request)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    refreshed.fulfill()
                    return String(data: body, encoding: .utf8)
                } catch { XCTFail("refresh failed: \(error)"); refreshed.fulfill(); return nil }
            }
            transport.connect()
            let first = try await transport.call("identity")
            XCTAssertEqual(first.data, mode == .json ? Data("42".utf8) : Data([84]))
            await fulfillment(of: [refreshed], timeout: 6)
            let second = try await transport.call("identity")
            XCTAssertEqual(second.data, first.data)
            XCTAssertEqual(second.mode, mode)
        }
    }

    func testRefreshReconnectsWithNewTokenWithoutReplayingOldWork() async throws {
        let old = MockWebSocketTask(), fresh = MockWebSocketTask()
        let session = MockWebSocketSession(sockets: [old, fresh])
        let transport = try WebSocketTransport(url: "ws://localhost/test", token: "old", session: session)
        defer { transport.close() }
        let started = expectation(description: "refresh started")
        let ready = expectation(description: "new connection")
        fresh.onResume = { ready.fulfill() }
        transport.onTokenExpired = {
            started.fulfill(); return "new"
        }
        transport.connect()
        old.expireAccess()
        await fulfillment(of: [started, ready], timeout: 2)
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
        XCTAssertTrue(fresh.sentMessages.isEmpty)
        fresh.onSend = { [weak fresh] _ in fresh?.deliver(.success(.string(#"{"$id":1,"data":42}"#))) }
        let value = try await transport.call("echo")
        XCTAssertEqual(value.data, Data("42".utf8))
    }

    func testFailedRenewalSettlesAllConcurrentWaiters() async throws {
        for mode in [TransportMode.json, .binary] {
            let old = MockWebSocketTask(), fresh = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "ws://localhost/test", session: MockWebSocketSession(sockets: [old, fresh]))
            defer { transport.close() }
            try transport.setSchema(["echo": APISchema(id: 1)])
            transport.setMode(mode)
            let gate = RenewalTestGate()
            let started = expectation(description: "one refresh callback")
            started.assertForOverFulfill = true
            transport.onTokenExpired = {
                started.fulfill()
                await gate.wait()
                return nil
            }
            transport.connect()
            old.expireAccess()
            await fulfillment(of: [started], timeout: 1)
            let launched = expectation(description: "eight callers launched")
            let finished = expectation(description: "eight callers ended")
            launched.expectedFulfillmentCount = 8
            finished.expectedFulfillmentCount = 8
            finished.assertForOverFulfill = true
            let callers = (0..<8).map { _ in
                Task {
                    launched.fulfill()
                    defer { finished.fulfill() }
                    do {
                        _ = try await transport.call("echo")
                        XCTFail("failed renewal must not return data")
                    } catch let error as LuxoError {
                        XCTAssertEqual(error.code, 401)
                    } catch { XCTFail("unexpected renewal error: \(error)") }
                }
            }
            defer { callers.forEach { $0.cancel() }; gate.release() }
            await fulfillment(of: [launched], timeout: 1)
            gate.release()
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertFalse(fresh.isResumed)
            XCTAssertTrue(old.sentMessages.isEmpty)
        }
    }

    func testNewCallsWaitForSharedRefreshInBothModes() async throws {
        for mode in [TransportMode.json, .binary] {
            let old = MockWebSocketTask(), fresh = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "ws://localhost/test", session: MockWebSocketSession(sockets: [old, fresh]))
            defer { transport.close() }
            try transport.setSchema(["echo": APISchema(id: 1)])
            transport.setMode(mode)
            let gate = RenewalTestGate()
            let started = expectation(description: "refresh")
            transport.onTokenExpired = {
                started.fulfill(); await gate.wait(); return "fresh"
            }
            transport.connect()
            old.expireAccess()
            await fulfillment(of: [started], timeout: 1)
            let call = Task { try await transport.call("echo") }
            fresh.onSend = { [weak fresh] _ in
                if mode == .binary {
                    fresh?.deliver(.success(.data(Data([2, 1, 42]))))
                } else {
                    fresh?.deliver(.success(.string(#"{"$id":1,"data":42}"#)))
                }
            }
            gate.release()
            let response = try await call.value
            XCTAssertEqual(response.mode, mode)
            XCTAssertEqual(response.data, mode == .binary ? Data([42]) : Data("42".utf8))
            XCTAssertTrue(old.sentMessages.isEmpty)
            XCTAssertEqual(fresh.sentMessages.count, 1)
        }
    }

    func testCancelledWaiterDoesNotCancelRefreshAndManualTokenWins() async throws {
        let old = MockWebSocketTask(), fresh = MockWebSocketTask()
        let session = MockWebSocketSession(sockets: [old, fresh])
        let transport = try WebSocketTransport(url: "ws://localhost/test", token: "old", session: session)
        defer { transport.close() }
        let gate = RenewalTestGate()
        let started = expectation(description: "refresh waiting")
        let finished = expectation(description: "refresh returned")
        transport.onTokenExpired = {
            started.fulfill()
            await gate.wait()
            finished.fulfill()
            return "late"
        }
        transport.connect()
        old.expireAccess()
        await fulfillment(of: [started], timeout: 1)
        let cancelled = Task { try await transport.call("echo") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("cancelled waiter") } catch is CancellationError {}
        XCTAssertFalse(fresh.isResumed)
        transport.setToken("manual")
        XCTAssertTrue(fresh.isResumed)
        gate.release()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer manual")
        fresh.onSend = { [weak fresh] _ in fresh?.deliver(.success(.string(#"{"$id":1,"data":42}"#))) }
        let response = try await transport.call("echo")
        XCTAssertEqual(response.data, Data("42".utf8))
    }

    func testRefreshTimeoutAndCloseDoNotInstallLateCredential() async throws {
        for close in [false, true] {
            let old = MockWebSocketTask(), fresh = MockWebSocketTask()
            let session = MockWebSocketSession(sockets: [old, fresh])
            let transport = try WebSocketTransport(
                url: "ws://localhost/test", token: "old", timeout: 0.05, session: session)
            defer { transport.close() }
            let gate = RenewalTestGate()
            let started = expectation(description: "callback waiting")
            let finished = expectation(description: "callback returned")
            transport.onTokenExpired = {
                started.fulfill()
                await gate.wait()
                finished.fulfill()
                return "late"
            }
            transport.connect()
            old.expireAccess()
            await fulfillment(of: [started], timeout: 1)
            if close { transport.close() }
            do { _ = try await transport.call("echo"); XCTFail("must fail") } catch let error as LuxoError {
                XCTAssertEqual(error.code, close ? 0 : 401)
            }
            gate.release()
            await fulfillment(of: [finished], timeout: 1)
            XCTAssertFalse(fresh.isResumed)
            XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer old")
        }
    }
}

private final class RenewalTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        await withCheckedContinuation { value in
            let done = lock.withLock {
                if released { return true }; continuation = value; return false
            }
            if done { value.resume() }
        }
    }
    func release() {
        let value = lock.withLock {
            released = true; let value = continuation; continuation = nil; return value
        }
        value?.resume()
    }
}

private struct LiveStreamCounts: Decodable {
    let started: Int
    let gateway: Int
    let backend: Int
}
