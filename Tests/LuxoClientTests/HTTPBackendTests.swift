import Foundation
import XCTest
@testable import LuxoClient

final class HTTPBackendTests: XCTestCase {
    func testHTTPEnvelopeUsesResponseSchemaForIndependentJSONRoots() async throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let model = LuxoJSONReadSchema.model("Packet", types: ["Packet": ["value": .init(fieldID: 1, type: "JSON")]])
        for (schema, payload) in [(LuxoJSONReadSchema.list(.json), "[\(json)]"), (model, "{\"value\":\(json)}")] {
            let backend = EnvelopeBackend(status: 200, body: "{\"data\":\(payload)}")
            let transport = HTTPTransport(backend: backend)
            try transport.setSchema(["read": APISchema(id: 1, response: schema)])
            let response = try await transport.call("read")
            XCTAssertEqual(response.data, Data(payload.utf8))
        }
    }

    func testHTTPRefreshRetainsOriginalResponseSchema() async throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let payload = "[\(json)]"
        let backend = EnvelopeBackend(
            status: 401, body: #"{"error":"Unauthorized","code":401,"message":"expired"}"#,
            laterBody: "{\"data\":\(payload)}")
        let transport = HTTPTransport(backend: backend)
        try transport.setSchema(["read": APISchema(id: 1, response: .list(.json))])
        transport.onTokenExpired = {
            do { try transport.setSchema(["read": APISchema(id: 1, response: .json)]) } catch {
                XCTFail("schema update failed: \(error)")
            }
            return "renewed"
        }
        let response = try await transport.call("read")
        XCTAssertEqual(response.data, Data(payload.utf8))
        let calls = await backend.calls
        XCTAssertEqual(calls, 2)
    }

    private actor RefreshGate {
        var released = false
        var continuation: CheckedContinuation<String?, Never>?
        func wait() async -> String? {
            if released { return "late-token" }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(returning: "late-token"); continuation = nil }
    }

    private final class RequestReference: @unchecked Sendable {
        private let lock = NSLock()
        private weak var value: AnyObject?
        var isRetained: Bool { lock.withLock { value != nil } }
        func observe(_ value: AnyObject) { lock.withLock { self.value = value } }
    }

    private final class RetainedRequest: GeneratedRequest {
        let apiID = 1
        private let payload = Data(repeating: 37, count: 256 * 1024)
        init(_ reference: RequestReference) { reference.observe(self) }
        func writeParameters(to encoder: inout Encoder) throws {
            encoder.writeVarint(1)
            encoder.writeBytes(payload)
        }
        func toJSONParameters() throws -> [String: LuxoValue] { ["payload": .bytes(payload)] }
    }

    private static func trackedBody(onRelease: @escaping @Sendable () -> Void) -> Data {
        let size = 256 * 1024
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        bytes.initializeMemory(as: UInt8.self, repeating: 37, count: size)
        return Data(
            bytesNoCopy: bytes, count: size,
            deallocator: .custom { bytes, _ in
                bytes.deallocate()
                onRelease()
            })
    }

    func testCompletedDeadlineReleasesRequestWhileRefreshIsBlocked() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let gate = RefreshGate()
            let transport = HTTPTransport(backend: backend, timeout: 0.2)
            transport.setMode(mode)
            try transport.setSchema([
                "viewer": APISchema(id: 1, params: [.init(fieldID: 1, name: "payload", type: "Bytes")])
            ])
            let reference = RequestReference()
            let entered = expectation(description: "refresh waits without retaining original input")
            transport.onTokenExpired = {
                entered.fulfill(); return await gate.wait()
            }
            let worker = Task {
                do {
                    _ = try await transport.call("viewer", request: RetainedRequest(reference))
                    XCTFail("expired call succeeded")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, "TimeoutError")
                } catch { XCTFail("unexpected error: \(error)") }
            }
            await fulfillment(of: [entered], timeout: 1)
            await worker.value
            for _ in 0..<100 {
                if !reference.isRetained { break }
                await Task.yield()
            }
            XCTAssertFalse(reference.isRetained, "completed \(mode) request retained by pending refresh")
            await gate.release()
        }
    }

    func testDeadlineRetiresPreparedBodyAfterSuccessAndFailure() async throws {
        for failing in [false, true] {
            let deadline = HTTPCallDeadline(parameters: .dynamic(nil))
            let original = Data(repeating: 37, count: 256 * 1024)
            do {
                _ = try await deadline.run(timeout: 1) {
                    try deadline.prepareRequest { _ in original }
                    XCTAssertEqual(try deadline.requestBody(), original)
                    if failing { throw URLError(.badServerResponse) }
                    return TransportPayload(data: Data([84]), mode: .binary)
                }
                XCTAssertFalse(failing)
            } catch let error as URLError {
                XCTAssertTrue(failing)
                XCTAssertEqual(error.code, .badServerResponse)
            }
            XCTAssertThrowsError(try deadline.requestBody()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(
                try deadline.prepareRequest { _ in
                    XCTFail("finished deadline encoded another request")
                    return Data()
                }
            ) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(original, Data(repeating: 37, count: 256 * 1024))
        }
        XCTAssertThrowsError(try HTTPCallDeadline().prepareRequest { _ in Data() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testDeadlineRetiresPreparedBodyWhileOperationIgnoresCancellation() async throws {
        for cancelled in [false, true] {
            let deadline = HTTPCallDeadline(parameters: .dynamic(nil))
            let gate = RefreshGate()
            let entered = expectation(description: "prepared body available")
            let exited = expectation(description: "owned operation exited")
            let released = expectation(description: "body storage released before blocked operation exits")
            let makeBody: @Sendable (RequestParameters) throws -> Data = { _ in
                HTTPBackendTests.trackedBody { released.fulfill() }
            }
            let worker = Task {
                try await deadline.run(timeout: cancelled ? 1 : 0.1) {
                    defer { exited.fulfill() }
                    try deadline.prepareRequest(makeBody)
                    entered.fulfill()
                    _ = await gate.wait()
                    return TransportPayload(data: Data([84]), mode: .binary)
                }
            }
            await fulfillment(of: [entered], timeout: 1)
            if cancelled { worker.cancel() }
            do {
                _ = try await worker.value
                XCTFail("terminated deadline returned success")
            } catch is CancellationError {
                XCTAssertTrue(cancelled)
            } catch let error as LuxoError {
                XCTAssertFalse(cancelled)
                XCTAssertEqual(error.name, "TimeoutError")
            }
            XCTAssertThrowsError(try deadline.requestBody()) { XCTAssertTrue($0 is CancellationError) }
            await fulfillment(of: [released], timeout: 1)
            await gate.release()
            await fulfillment(of: [exited], timeout: 1)
        }
    }

    func testDeadlineReleasesItsBodyStorageAtNormalTermination() async throws {
        for failing in [false, true] {
            let deadline = HTTPCallDeadline(parameters: .dynamic(nil))
            let released = expectation(description: "normal terminal releases body storage")
            let makeBody: @Sendable (RequestParameters) throws -> Data = { _ in
                HTTPBackendTests.trackedBody { released.fulfill() }
            }
            do {
                _ = try await deadline.run(timeout: 1) {
                    try deadline.prepareRequest(makeBody)
                    XCTAssertEqual(try deadline.requestBody().count, 256 * 1024)
                    if failing { throw URLError(.badServerResponse) }
                    return TransportPayload(data: Data([84]), mode: .binary)
                }
                XCTAssertFalse(failing)
            } catch let error as URLError {
                XCTAssertTrue(failing)
                XCTAssertEqual(error.code, .badServerResponse)
            }
            await fulfillment(of: [released], timeout: 1)
            XCTAssertThrowsError(try deadline.requestBody()) { XCTAssertTrue($0 is CancellationError) }
        }
    }

    func testDeadlineRejectsBodyEncodedAfterItsDeadlineFinishes() async throws {
        let deadline = HTTPCallDeadline(parameters: .dynamic(nil))
        let entered = expectation(description: "encoding started")
        let exited = expectation(description: "encoding observed completed deadline")
        let release = DispatchSemaphore(value: 0)
        let worker = Task {
            try await deadline.run(timeout: 0.05) {
                defer { exited.fulfill() }
                try deadline.prepareRequest { _ in
                    entered.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
                    return Data(repeating: 37, count: 256 * 1024)
                }
                XCTFail("late encoding installed a new body")
                return TransportPayload(data: Data([84]), mode: .binary)
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        do {
            _ = try await worker.value
            XCTFail("expired encoding returned success")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "TimeoutError")
        }
        XCTAssertThrowsError(try deadline.requestBody()) { XCTAssertTrue($0 is CancellationError) }
        release.signal()
        await fulfillment(of: [exited], timeout: 1)
        XCTAssertThrowsError(try deadline.requestBody()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testInvalidDeadlineNeverEncodesOrSendsTheRequest() async throws {
        for timeout in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            for mode in [TransportMode.json, .binary] {
                let backend = SuccessfulBackend()
                let request = MutableRequest()
                let transport = HTTPTransport(backend: backend, timeout: timeout)
                transport.setMode(mode)
                try transport.setSchema(["viewer": APISchema(id: 1)])
                do {
                    _ = try await transport.call("viewer", request: request)
                    XCTFail("invalid deadline accepted")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, "ConfigError")
                }
                XCTAssertEqual(request.encodes, 0)
                let calls = await backend.calls
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testDecoratedRefreshHandlerPreservesItsOriginalProvider() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let transport = HTTPTransport(backend: backend, token: "old")
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            XCTAssertNil(transport.onTokenExpired)
            transport.onTokenExpired = { "renewed" }
            let original = transport.onTokenExpired
            transport.onTokenExpired = {
                guard let token = await original?() else { return nil }
                return token + "-wrapped"
            }
            _ = try await transport.call("viewer")
            let tokens = await backend.tokens
            XCTAssertEqual(tokens, ["Bearer old", "Bearer renewed-wrapped"])
        }
    }

    func testCancellationFinishesWhileRefreshIgnoresCancellation() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let gate = RefreshGate()
            let transport = HTTPTransport(backend: backend, token: "original")
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            let entered = expectation(description: "refresh entered")
            let finished = expectation(description: "cancelled caller finished")
            transport.onTokenExpired = {
                entered.fulfill(); return await gate.wait()
            }
            let worker = Task {
                defer { finished.fulfill() }
                do {
                    _ = try await transport.call("viewer"); XCTFail("cancelled call succeeded")
                } catch is CancellationError {} catch { XCTFail("wrong error: \(error)") }
            }
            await fulfillment(of: [entered], timeout: 1)
            worker.cancel()
            await fulfillment(of: [finished], timeout: 0.2)
            await gate.release()
            await worker.value
            _ = try await transport.call("viewer")
            let tokens = await backend.tokens
            XCTAssertEqual(tokens, ["Bearer original", "Bearer original"])
        }
    }

    func testDeadlineFinishesPendingRefreshAndIgnoresLateToken() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let gate = RefreshGate()
            let transport = HTTPTransport(backend: backend, token: "original", timeout: 0.1)
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            transport.onTokenExpired = { await gate.wait() }
            let finished = expectation(description: "deadline finishes pending refresh")
            let worker = Task {
                defer { finished.fulfill() }
                do { _ = try await transport.call("viewer"); XCTFail("expired call succeeded") } catch let error
                    as LuxoError
                { XCTAssertEqual(error.name, "TimeoutError") } catch { XCTFail("wrong error: \(error)") }
            }
            await fulfillment(of: [finished], timeout: 1)
            await gate.release()
            await worker.value
            _ = try await transport.call("viewer")
            let tokens = await backend.tokens
            XCTAssertEqual(tokens, ["Bearer original", "Bearer original"])
        }
    }

    private actor RetryBackend: HTTPBackend {
        var calls = 0
        var cancelled = false
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            calls += 1
            if calls == 1 {
                return HTTPBackendResponse(
                    status: 401, body: Data(#"{"error":"Unauthorized","code":401,"message":"expired"}"#.utf8))
            }
            do { try await Task.sleep(for: .seconds(10)) } catch { cancelled = true; throw error }
            return HTTPBackendResponse(status: 200, body: Data(#"{"data":true}"#.utf8))
        }
    }

    func testDeadlineCancelsRetryBackend() async throws {
        let backend = RetryBackend()
        let transport = HTTPTransport(backend: backend, timeout: 0.2)
        transport.onTokenExpired = {
            try? await Task.sleep(for: .milliseconds(50)); return "renewed"
        }
        do { _ = try await transport.call("viewer"); XCTFail("expired retry succeeded") } catch let error as LuxoError {
            XCTAssertEqual(error.name, "TimeoutError")
        }
        for _ in 0..<100 {
            if await backend.cancelled { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let calls = await backend.calls
        let cancelled = await backend.cancelled
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(cancelled)
    }

    func testAlreadyCancelledDeadlineDoesNotStartOperation() async throws {
        actor Counter {
            var calls = 0
            func increment() { calls += 1 }
        }
        let counter = Counter()
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await HTTPCallDeadline().run(timeout: 1) {
                    await counter.increment()
                    return TransportPayload(data: Data(), mode: .binary)
                }
                XCTFail("cancelled deadline returned success")
            } catch is CancellationError {} catch { XCTFail("wrong error: \(error)") }
        }
        await worker.value
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
    }

    func testDeadlineCompletionCancellationRacesSettleOnce() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                group.addTask {
                    let worker = Task {
                        try await HTTPCallDeadline().run(timeout: 0.001) {
                            for _ in 0..<(index % 8) { await Task.yield() }
                            return TransportPayload(data: Data([42]), mode: .binary)
                        }
                    }
                    if index % 3 == 0 { await Task.yield() }
                    if index % 2 == 0 { worker.cancel() }
                    do {
                        let result = try await worker.value
                        XCTAssertEqual(result.data, Data([42]))
                    } catch is CancellationError {
                    } catch let error as LuxoError {
                        XCTAssertEqual(error.name, "TimeoutError")
                    } catch { XCTFail("unexpected race result: \(error)") }
                }
            }
        }
    }

    private static func blockSynchronously() {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.3)
    }

    func testDeadlineDoesNotRunBlockingOperationOnWaitingCaller() async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await HTTPCallDeadline().run(timeout: 0.02) {
                Self.blockSynchronously()
                return TransportPayload(data: Data(), mode: .binary)
            }
            XCTFail("expired operation succeeded")
        } catch let error as LuxoError { XCTAssertEqual(error.name, "TimeoutError") }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.2, "blocking operation delayed its caller despite deadline")
    }

    private struct CancellingRequest: GeneratedRequest {
        let apiID = 1
        func writeParameters(to encoder: inout Encoder) throws {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        func toJSONParameters() throws -> [String: LuxoValue] {
            withUnsafeCurrentTask { $0?.cancel() }
            return [:]
        }
    }

    private actor SuccessfulBackend: HTTPBackend {
        var calls = 0
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            calls += 1
            return HTTPBackendResponse(status: 200, body: Data(#"{"data":true}"#.utf8))
        }
    }

    func testCancellationDuringEncodingDoesNotSendRequest() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = SuccessfulBackend()
            let transport = HTTPTransport(backend: backend)
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            do {
                _ = try await transport.call("viewer", request: CancellingRequest())
                XCTFail("cancelled encoding reached the backend")
            } catch is CancellationError {
            } catch { XCTFail("wrong error: \(error)") }
            let calls = await backend.calls
            XCTAssertEqual(calls, 0)
        }
    }

    private final class MutableRequest: GeneratedRequest, @unchecked Sendable {
        let apiID = 1
        private let lock = NSLock()
        private var value: Int64 = 42
        private var count = 0
        var encodes: Int { lock.withLock { count } }
        func change() { lock.withLock { value = 99 } }
        func writeParameters(to encoder: inout Encoder) throws {
            let value = lock.withLock {
                count += 1; return self.value
            }
            encoder.writeVarint(1)
            encoder.writeSvarint(value)
        }
        func toJSONParameters() throws -> [String: LuxoValue] {
            lock.withLock {
                count += 1; return ["count": .int(value)]
            }
        }
    }

    private actor SnapshotBackend: HTTPBackend {
        var bodies: [Data] = []
        private let responses = Backend()
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            bodies.append(body)
            return try await responses.send(body: body, mode: mode, headers: headers)
        }
    }

    func testRefreshReusesEncodedGeneratedRequest() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = SnapshotBackend()
            let request = MutableRequest()
            let transport = HTTPTransport(backend: backend)
            transport.setMode(mode)
            try transport.setSchema([
                "viewer": APISchema(id: 1, params: [.init(fieldID: 1, name: "count", type: "Int")])
            ])
            transport.onTokenExpired = {
                request.change(); return "renewed"
            }
            _ = try await transport.call("viewer", request: request)
            var bodies = await backend.bodies
            XCTAssertEqual(bodies.count, 2)
            XCTAssertEqual(bodies[0], bodies[1])
            XCTAssertEqual(request.encodes, 1)
            _ = try await transport.call("viewer", request: request)
            bodies = await backend.bodies
            XCTAssertNotEqual(bodies[0], bodies[2])
            XCTAssertEqual(request.encodes, 2)
        }
    }

    private actor EnvelopeBackend: HTTPBackend {
        let first: HTTPBackendResponse
        let later: Data
        var calls = 0
        init(status: Int, body: String, laterBody: String = #"{"data":true}"#) {
            first = HTTPBackendResponse(status: status, body: Data(body.utf8))
            later = Data(laterBody.utf8)
        }
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            calls += 1
            return calls == 1 ? first : HTTPBackendResponse(status: 200, body: later)
        }
    }

    func testHTTPStatusAndErrorPresenceOverrideJSONData() async throws {
        for (status, body, name) in [
            (200, #"{"data":true,"error":null,"code":401,"message":"bad"}"#, "ParseError"),
            (200, #"{"data":true,"error":false,"code":401,"message":"bad"}"#, "ParseError"),
            (200, #"{"data":true,"error":"Unauthorized","code":401,"message":"bad"}"#, "Unauthorized"),
            (201, #"{"data":true}"#, "ParseError"),
            (403, #"{"data":true}"#, "ParseError"),
            (500, #"{"data":true}"#, "ParseError"),
        ] {
            let backend = EnvelopeBackend(status: status, body: body)
            let transport = HTTPTransport(backend: backend)
            transport.onTokenExpired = {
                XCTFail("unexpected refresh")
                return "unused"
            }
            do {
                _ = try await transport.call("echo")
                XCTFail("invalid response returned data")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, name)
                XCTAssertEqual(error.code, name == "Unauthorized" ? 401 : status)
            }
            let failedCalls = await backend.calls
            XCTAssertEqual(failedCalls, 1)
            let result = try await transport.call("echo")
            XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "true")
            let calls = await backend.calls
            XCTAssertEqual(calls, 2)
        }
    }

    private actor Backend: HTTPBackend {
        var tokens: [String?] = []
        var beforeFirstResponse: (@Sendable () -> Void)?
        func beforeFirstResponse(_ action: @escaping @Sendable () -> Void) {
            beforeFirstResponse = action
        }
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            tokens.append(headers["Authorization"])
            if tokens.count == 1 {
                let action = beforeFirstResponse
                beforeFirstResponse = nil
                action?()
            }
            if mode == .binary {
                if tokens.count != 1 { return HTTPBackendResponse(status: 200, body: Data([84])) }
                var encoder = Encoder()
                encoder.writeVarint(1)
                encoder.writeSvarint(401)
                encoder.writeVarint(2)
                encoder.writeString("Unauthorized")
                encoder.writeVarint(3)
                encoder.writeString("expired")
                encoder.writeEnd()
                return HTTPBackendResponse(status: 401, body: encoder.data)
            }
            let text =
                tokens.count == 1
                ? "{\"error\":\"Unauthorized\",\"code\":401,\"message\":\"expired\"}"
                : "{\"data\":42}"
            return HTTPBackendResponse(status: tokens.count == 1 ? 401 : 200, body: Data(text.utf8))
        }
    }

    func testSharedBackendRefreshesExactlyOnce() async throws {
        let backend = Backend()
        let transport = HTTPTransport(backend: backend, token: "old")
        transport.onTokenExpired = { "new" }
        let response = try await transport.call("viewer")
        XCTAssertEqual(response.mode, .json)
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "42")
        let tokens = await backend.tokens
        XCTAssertEqual(tokens, ["Bearer old", "Bearer new"])
    }

    func testRefreshCannotOverwriteExplicitIdentityReplacement() async throws {
        for mode in [TransportMode.json, .binary] {
            for replacement in ["different-user", "original"] {
                let backend = Backend()
                let transport = HTTPTransport(backend: backend, token: "original")
                transport.setMode(mode)
                try transport.setSchema(["viewer": APISchema(id: 1)])
                transport.onTokenExpired = {
                    transport.setToken(replacement)
                    return "old-user-refreshed"
                }
                defer { transport.onTokenExpired = nil }
                do {
                    _ = try await transport.call("viewer")
                    XCTFail("stale refresh returned success")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.code, 401)
                }
                _ = try await transport.call("viewer")
                let tokens = await backend.tokens
                XCTAssertEqual(tokens, ["Bearer original", "Bearer \(replacement)"])
            }
        }
    }

    func testRefreshPreservesOriginalMode() async throws {
        for mode in [TransportMode.json, .binary] {
            let transport = HTTPTransport(backend: Backend(), token: "original")
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            let next: TransportMode = mode == .json ? .binary : .json
            transport.onTokenExpired = {
                transport.setMode(next)
                return "renewed"
            }
            defer { transport.onTokenExpired = nil }
            let first = try await transport.call("viewer")
            XCTAssertEqual(first.mode, mode)
            let second = try await transport.call("viewer")
            XCTAssertEqual(second.mode, next)
        }
    }

    func testStaleUnauthorizedResponseDoesNotRefreshReplacementIdentity() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let transport = HTTPTransport(backend: backend, token: "original")
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            await backend.beforeFirstResponse { transport.setToken("different-user") }
            transport.onTokenExpired = {
                XCTFail("stale response started refresh")
                return "old-user-refreshed"
            }
            do {
                _ = try await transport.call("viewer")
                XCTFail("stale unauthorized response returned success")
            } catch let error as LuxoError {
                XCTAssertEqual(error.code, 401)
            }
            _ = try await transport.call("viewer")
            let tokens = await backend.tokens
            XCTAssertEqual(tokens, ["Bearer original", "Bearer different-user"])
        }
    }

    func testMissingRefreshTokenPreservesFailureAndCredentials() async throws {
        for mode in [TransportMode.json, .binary] {
            for installed in [false, true] {
                let backend = Backend()
                let transport = HTTPTransport(backend: backend, token: "original")
                transport.setMode(mode)
                try transport.setSchema(["viewer": APISchema(id: 1)])
                if installed { transport.onTokenExpired = { nil } }
                do {
                    _ = try await transport.call("viewer")
                    XCTFail("missing refresh token returned success")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.code, 401)
                    XCTAssertEqual(error.name, "Unauthorized")
                }
                let failedTokens = await backend.tokens
                XCTAssertEqual(failedTokens, ["Bearer original"])
                _ = try await transport.call("viewer")
                let tokens = await backend.tokens
                XCTAssertEqual(tokens, ["Bearer original", "Bearer original"])
            }
        }
    }
    func testCancellationBeforeUnauthorizedResponseDoesNotStartRefresh() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let transport = HTTPTransport(backend: backend, token: "original")
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            await backend.beforeFirstResponse {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            transport.onTokenExpired = {
                XCTFail("cancelled response started user refresh")
                return nil
            }
            do {
                _ = try await transport.call("viewer")
                XCTFail("cancelled response succeeded")
            } catch is CancellationError {
            } catch { XCTFail("wrong error: \(error)") }
            _ = try await transport.call("viewer")
            let tokens = await backend.tokens
            XCTAssertEqual(tokens, ["Bearer original", "Bearer original"])
        }
    }

    func testCancelledRefreshCannotReplaceCredentials() async throws {
        for mode in [TransportMode.json, .binary] {
            let backend = Backend()
            let transport = HTTPTransport(backend: backend, token: "original")
            transport.setMode(mode)
            try transport.setSchema(["viewer": APISchema(id: 1)])
            transport.onTokenExpired = {
                withUnsafeCurrentTask { $0?.cancel() }
                return "late-token"
            }
            let first = Task { try await transport.call("viewer") }
            do {
                _ = try await first.value
                XCTFail("cancelled refresh returned success")
            } catch is CancellationError {
            }
            _ = try await transport.call("viewer")
            let tokens = await backend.tokens
            XCTAssertEqual(tokens, ["Bearer original", "Bearer original"])
        }
    }

}
