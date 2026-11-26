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

extension HTTPBackendTests {
    private actor RefreshBatch {
        private let entered: XCTestExpectation
        private let token: String?
        private var pending: [CheckedContinuation<String?, Never>] = []
        private var released = false
        private(set) var calls = 0

        init(entered: XCTestExpectation, token: String? = "renewed") {
            self.entered = entered
            self.token = token
        }

        func receive() async -> String? {
            calls += 1
            if calls == 1 { entered.fulfill() }
            if released { return token }
            return await withCheckedContinuation { pending.append($0) }
        }

        func release() {
            released = true
            let waiting = pending
            pending.removeAll()
            for continuation in waiting { continuation.resume(returning: token) }
        }
    }

    private actor ConcurrentUnauthorizedBackend: HTTPBackend {
        static let names = ["first", "second", "late", "fresh"]

        struct Attempt: Equatable {
            let body: Data
            let token: String
        }

        let arrived: XCTestExpectation
        let freshArrived: XCTestExpectation?
        private var pending: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []
        private(set) var attempts: [String: [Attempt]] = [:]

        init(arrived: XCTestExpectation, freshArrived: XCTestExpectation? = nil) {
            self.arrived = arrived
            self.freshArrived = freshArrived
        }

        func release(_ name: String) {
            released.insert(name)
            pending.removeValue(forKey: name)?.resume()
        }

        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            let name: String
            if mode == .binary {
                var decoder = Decoder(body)
                let id = decoder.readVarint()
                guard (1...UInt64(Self.names.count)).contains(id) else { throw URLError(.badServerResponse) }
                name = Self.names[Int(id) - 1]
            } else {
                let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                name = try XCTUnwrap(decoded?["$api"] as? String)
            }
            let token = headers["Authorization", default: ""]
            attempts[name, default: []].append(Attempt(body: body, token: token))
            if token == "Bearer old" {
                if name == "fresh" { freshArrived?.fulfill() } else { arrived.fulfill() }
                if !released.contains(name) {
                    await withCheckedContinuation { pending[name] = $0 }
                }
                return unauthorized(mode, message: "expired")
            }
            if name == "late" {
                return unauthorized(mode, message: "retry denied")
            }
            let body = mode == .binary ? Data([84]) : Data(#"{"data":42}"#.utf8)
            return HTTPBackendResponse(status: 200, body: body)
        }

        private func unauthorized(_ mode: TransportMode, message: String) -> HTTPBackendResponse {
            if mode == .binary {
                var encoder = Encoder()
                encoder.writeVarint(1)
                encoder.writeSvarint(401)
                encoder.writeVarint(2)
                encoder.writeString("Unauthorized")
                encoder.writeVarint(3)
                encoder.writeString(message)
                encoder.writeEnd()
                return HTTPBackendResponse(status: 401, body: encoder.data)
            }
            let json = #"{"error":"Unauthorized","code":401,"message":"\#(message)"}"#
            return HTTPBackendResponse(status: 401, body: Data(json.utf8))
        }
    }

    func testRefreshCallbackReturnsItsNestedUnauthorizedErrorWithoutWaitingOnItself() async throws {
        for mode in [TransportMode.json, .binary] {
            let arrived = expectation(description: "the protected request reached the backend")
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
            await backend.release("first")
            await backend.release("fresh")
            let transport = try makeRefreshTransport(backend, mode: mode)
            defer { transport.onTokenExpired = nil }
            let refreshed = expectation(description: "one refresh callback ran")
            refreshed.assertForOverFulfill = true
            transport.onTokenExpired = { [weak transport] in
                guard let transport else { return nil }
                refreshed.fulfill()
                do {
                    _ = try await transport.call("fresh")
                    XCTFail("the nested request must keep its original unauthorized error")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.code, 401)
                    XCTAssertEqual(error.name, "Unauthorized")
                    XCTAssertEqual(error.message, "expired")
                } catch { XCTFail("unexpected nested error: \(error)") }
                return "renewed"
            }

            let result = try await transport.call("first")
            XCTAssertEqual(result.mode, mode)
            XCTAssertEqual(result.data, mode == .binary ? Data([84]) : Data("42".utf8))
            await fulfillment(of: [arrived, refreshed], timeout: 1)
            let attempts = await backend.attempts
            XCTAssertEqual(attempts["fresh"]?.map(\.token), ["Bearer old"])
            XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old", "Bearer renewed"])
        }
    }

    func testNestedTransportRefreshKeepsTheAncestorUnauthorizedError() async throws {
        for mode in [TransportMode.json, .binary] {
            let firstArrived = expectation(description: "first transport received its call")
            let secondArrived = expectation(description: "second transport received its call")
            let firstBackend = ConcurrentUnauthorizedBackend(arrived: firstArrived)
            let secondBackend = ConcurrentUnauthorizedBackend(arrived: secondArrived)
            await firstBackend.release("first")
            await firstBackend.release("fresh")
            await secondBackend.release("second")
            let first = try makeRefreshTransport(firstBackend, mode: mode)
            let second = try makeRefreshTransport(secondBackend, mode: mode)
            defer {
                first.onTokenExpired = nil
                second.onTokenExpired = nil
            }
            let expected = mode == .binary ? Data([84]) : Data("42".utf8)
            first.onTokenExpired = { [weak second] in
                guard let second else { return nil }
                do {
                    let result = try await second.call("second")
                    XCTAssertEqual(result.data, expected)
                    return "first-renewed"
                } catch {
                    XCTFail("the second transport could not finish its refresh: \(error)")
                    return nil
                }
            }
            second.onTokenExpired = { [weak first] in
                guard let first else { return nil }
                do {
                    _ = try await first.call("fresh")
                    XCTFail("the ancestor transport's nested call must remain unauthorized")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.code, 401)
                    XCTAssertEqual(error.name, "Unauthorized")
                    XCTAssertEqual(error.message, "expired")
                } catch { XCTFail("unexpected ancestor error: \(error)") }
                return "second-renewed"
            }

            let result = try await first.call("first")
            XCTAssertEqual(result.data, expected)
            await fulfillment(of: [firstArrived, secondArrived], timeout: 1)
            let firstAttempts = await firstBackend.attempts
            let secondAttempts = await secondBackend.attempts
            XCTAssertEqual(firstAttempts["fresh"]?.map(\.token), ["Bearer old"])
            XCTAssertEqual(firstAttempts["first"]?.map(\.token), ["Bearer old", "Bearer first-renewed"])
            XCTAssertEqual(secondAttempts["second"]?.map(\.token), ["Bearer old", "Bearer second-renewed"])
        }
    }

    func testTaskInheritingRetiredRefreshCanRefreshTheNewCredentialRevision() async throws {
        for mode in [TransportMode.json, .binary] {
            try await verifyRetiredRefreshDescendant(mode)
        }
    }

    private func verifyRetiredRefreshDescendant(_ mode: TransportMode) async throws {
        let arrived = expectation(description: "the protected request reached the backend")
        let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
        await backend.release("first")
        await backend.release("fresh")
        let transport = try makeRefreshTransport(backend, mode: mode)
        defer { transport.onTokenExpired = nil }
        let oldRefresh = RefreshGate()
        let allowDescendant = RefreshGate()
        let retiredRefreshEntered = expectation(description: "original refresh spawned a descendant")
        let descendantFinished = expectation(description: "descendant retried under the new revision")
        let newRefreshRan = expectation(description: "new revision triggered its own refresh")
        newRefreshRan.assertForOverFulfill = true
        transport.onTokenExpired = { [weak transport] in
            guard let transport else { return nil }
            Task {
                defer { descendantFinished.fulfill() }
                _ = await allowDescendant.wait()
                do {
                    let result = try await transport.call("fresh")
                    XCTAssertEqual(result.data, mode == .binary ? Data([84]) : Data("42".utf8))
                } catch { XCTFail("the retired refresh blocked a subsequent refresh: \(error)") }
            }
            retiredRefreshEntered.fulfill()
            return await oldRefresh.wait()
        }

        let first = Task { try await transport.call("first") }
        await fulfillment(of: [arrived, retiredRefreshEntered], timeout: 2)
        transport.setToken("old")
        transport.onTokenExpired = {
            newRefreshRan.fulfill()
            return "renewed"
        }
        await allowDescendant.release()
        switch await first.result {
        case .success: XCTFail("the retired refresh retried its original call")
        case .failure(let error): XCTAssertEqual((error as? LuxoError)?.code, 401)
        }
        await fulfillment(of: [descendantFinished, newRefreshRan], timeout: 6)
        await oldRefresh.release()
        let attempts = await backend.attempts
        XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
        XCTAssertEqual(attempts["fresh"]?.map(\.token), ["Bearer old", "Bearer renewed"])
    }

    func testThreeRequestsShareRefreshAndLate401RetriesOnlyOnce() async throws {
        for mode in [TransportMode.json, .binary] {
            try await verifyConcurrentRefresh(mode)
        }
    }

    private func makeRefreshTransport(_ backend: ConcurrentUnauthorizedBackend, mode: TransportMode) throws
        -> HTTPTransport<ConcurrentUnauthorizedBackend>
    {
        let transport = HTTPTransport(backend: backend, token: "old", timeout: 5)
        transport.setMode(mode)
        let schemas = ConcurrentUnauthorizedBackend.names.enumerated().map {
            ($0.element, APISchema(id: $0.offset + 1, params: [.init(fieldID: 1, name: "value", type: "Int")]))
        }
        try transport.setSchema(Dictionary(uniqueKeysWithValues: schemas))
        return transport
    }

    private func verifyConcurrentRefresh(_ mode: TransportMode) async throws {
        let arrived = expectation(description: "three requests sent with the original credential")
        arrived.expectedFulfillmentCount = 3
        let refreshing = expectation(description: "refresh callback entered")
        let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
        let refresh = RefreshBatch(entered: refreshing)
        let transport = try makeRefreshTransport(backend, mode: mode)
        transport.onTokenExpired = { await refresh.receive() }

        let first = Task { try await transport.call("first", params: ["value": .int(1)]) }
        let second = Task { try await transport.call("second", params: ["value": .int(2)]) }
        let late = Task { try await transport.call("late", params: ["value": .int(3)]) }

        await fulfillment(of: [arrived], timeout: 2)
        await backend.release("first")
        await fulfillment(of: [refreshing], timeout: 2)
        await backend.release("second")
        await refresh.release()
        let early = [await first.result, await second.result]
        await backend.release("late")
        let lateResult = await late.result

        for outcome in early {
            switch outcome {
            case .success(let payload):
                XCTAssertEqual(payload.mode, mode)
                XCTAssertEqual(payload.data, mode == .binary ? Data([84]) : Data("42".utf8))
            case .failure(let error): XCTFail("expected a retried success, got \(error)")
            }
        }
        switch lateResult {
        case .success: XCTFail("401 from the retry must be returned")
        case .failure(let error):
            XCTAssertEqual((error as? LuxoError)?.message, "retry denied")
        }

        let calls = await refresh.calls
        let attempts = await backend.attempts
        XCTAssertEqual(calls, 1)
        for name in ["first", "second", "late"] {
            let requests = try XCTUnwrap(attempts[name])
            XCTAssertEqual(requests.map(\.token), ["Bearer old", "Bearer renewed"])
            XCTAssertEqual(requests.first?.body, requests.last?.body)
        }
    }

    func testPendingRefreshAndLate401CannotReplayAcrossIdentityReplacement() async throws {
        for mode in [TransportMode.json, .binary] {
            for replacement in ["different-user", "old", ""] {
                try await verifyRefreshInvalidation(mode: mode, replacement: replacement)
            }
        }
    }

    private func verifyRefreshInvalidation(mode: TransportMode, replacement: String) async throws {
        let arrived = expectation(description: "two requests sent with the old credential")
        arrived.expectedFulfillmentCount = 2
        let refreshing = expectation(description: "refresh callback is waiting")
        let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
        let refresh = RefreshBatch(entered: refreshing)
        let transport = try makeRefreshTransport(backend, mode: mode)
        transport.onTokenExpired = { await refresh.receive() }

        let first = Task { try await transport.call("first") }
        let late = Task { try await transport.call("late") }
        await fulfillment(of: [arrived], timeout: 2)
        await backend.release("first")
        await fulfillment(of: [refreshing], timeout: 2)
        transport.setToken(replacement)
        await backend.release("late")
        assertUnauthorized(await late.result)
        await refresh.release()
        assertUnauthorized(await first.result)
        let attempts = await backend.attempts
        let calls = await refresh.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
        XCTAssertEqual(attempts["late"]?.map(\.token), ["Bearer old"])
    }

    func testLateUnauthorizedAfterMissingRefreshDoesNotStartAnotherAttempt() async throws {
        for mode in [TransportMode.json, .binary] {
            let arrived = expectation(description: "three requests sent with the original credential")
            arrived.expectedFulfillmentCount = 3
            let refreshing = expectation(description: "refresh callback entered")
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
            let refresh = RefreshBatch(entered: refreshing, token: nil)
            let transport = try makeRefreshTransport(backend, mode: mode)
            transport.onTokenExpired = { await refresh.receive() }

            let first = Task { try await transport.call("first") }
            let second = Task { try await transport.call("second") }
            let late = Task { try await transport.call("late") }
            await fulfillment(of: [arrived], timeout: 2)
            await backend.release("first")
            await fulfillment(of: [refreshing], timeout: 2)
            await backend.release("second")
            await refresh.release()
            assertUnauthorized(await first.result)
            assertUnauthorized(await second.result)
            await backend.release("late")
            assertUnauthorized(await late.result)

            let initialCalls = await refresh.calls
            XCTAssertEqual(initialCalls, 1)
            await backend.release("fresh")
            let fresh = Task { try await transport.call("fresh") }
            assertUnauthorized(await fresh.result)
            let totalCalls = await refresh.calls
            XCTAssertEqual(totalCalls, 2)
            let attempts = await backend.attempts
            for name in ConcurrentUnauthorizedBackend.names {
                XCTAssertEqual(attempts[name]?.map(\.token), ["Bearer old"])
            }
        }
    }

    func testLateUnauthorizedKeepsDeclinedRefreshAfterAnotherGenerationSucceeds() async throws {
        for mode in [TransportMode.json, .binary] {
            let arrived = expectation(description: "two requests sent with the original credential")
            arrived.expectedFulfillmentCount = 2
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
            let transport = try makeRefreshTransport(backend, mode: mode)
            transport.onTokenExpired = { nil }

            let first = Task { try await transport.call("first") }
            let late = Task { try await transport.call("late") }
            await fulfillment(of: [arrived], timeout: 2)
            await backend.release("first")
            assertUnauthorized(await first.result)

            transport.onTokenExpired = { "renewed" }
            await backend.release("fresh")
            let payload = try await transport.call("fresh")
            XCTAssertEqual(payload.data, mode == .binary ? Data([84]) : Data("42".utf8))

            await backend.release("late")
            switch await late.result {
            case .success: XCTFail("the declined refresh must preserve the initial 401")
            case .failure(let error): XCTAssertEqual((error as? LuxoError)?.message, "expired")
            }
            let attempts = await backend.attempts
            XCTAssertEqual(attempts["fresh"]?.map(\.token), ["Bearer old", "Bearer renewed"])
            XCTAssertEqual(attempts["late"]?.map(\.token), ["Bearer old"])
        }
    }

    private func assertUnauthorized(
        _ result: Result<TransportPayload, Error>, file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .success: XCTFail("expected the original 401", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual((error as? LuxoError)?.code, 401, file: file, line: line)
            XCTAssertEqual((error as? LuxoError)?.message, "expired", file: file, line: line)
        }
    }
}

extension HTTPBackendTests {
    func testCancellingOneUnauthorizedCallPreservesTheOther() async throws {
        for index in 0..<48 {
            let arrived = expectation(description: "both original requests sent")
            arrived.expectedFulfillmentCount = 2
            let refreshing = expectation(description: "first refresh started")
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
            let refresh = RefreshBatch(entered: refreshing)
            let transport = try makeRefreshTransport(backend, mode: .json)
            transport.onTokenExpired = { await refresh.receive() }

            let first = Task { try await transport.call("first") }
            let second = Task { try await transport.call("second") }
            await fulfillment(of: [arrived], timeout: 2)
            await backend.release("first")
            await fulfillment(of: [refreshing], timeout: 2)
            await backend.release("second")
            for _ in 0..<(index % 8) { await Task.yield() }
            first.cancel()
            await refresh.release()

            if case .failure(let error) = await first.result {
                XCTAssertTrue(error is CancellationError)
            } else {
                XCTFail("a cancelled request must not retry")
            }
            let response = try await second.value
            XCTAssertEqual(response.data, Data("42".utf8))
            let attempts = await backend.attempts
            XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
            XCTAssertEqual(attempts["second"]?.map(\.token), ["Bearer old", "Bearer renewed"])
        }
    }

    func testCancellingFirstRefreshWaiterPreservesLaterRequests() async throws {
        for mode in [TransportMode.json, .binary] {
            let arrived = expectation(description: "both waiting requests sent")
            arrived.expectedFulfillmentCount = 2
            let refreshing = expectation(description: "the first refresh started")
            let freshArrived = expectation(description: "the later request sent with the same credential")
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived, freshArrived: freshArrived)
            let refresh = RefreshBatch(entered: refreshing)
            let transport = try makeRefreshTransport(backend, mode: mode)
            transport.onTokenExpired = { await refresh.receive() }

            let first = Task { try await transport.call("first") }
            let second = Task { try await transport.call("second") }
            await fulfillment(of: [arrived], timeout: 2)
            await backend.release("first")
            await fulfillment(of: [refreshing], timeout: 2)
            await backend.release("second")

            first.cancel()
            if case .failure(let error) = await first.result {
                XCTAssertTrue(error is CancellationError)
            } else {
                XCTFail("a cancelled request must not retry")
            }

            let later = Task { try await transport.call("fresh") }
            await fulfillment(of: [freshArrived], timeout: 2)
            await backend.release("fresh")
            await refresh.release()

            let expected = mode == .binary ? Data([84]) : Data("42".utf8)
            let responses = try await [second.value, later.value]
            XCTAssertEqual(responses.map(\.data), [expected, expected])
            let attempts = await backend.attempts
            XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
            for name in ["second", "fresh"] {
                XCTAssertEqual(attempts[name]?.map(\.token), ["Bearer old", "Bearer renewed"])
            }
        }
    }

    func testCancellingAdditionalRefreshWaiterPreservesFirstAndRetiresWhenEmpty() async throws {
        for mode in [TransportMode.json, .binary] {
            try await verifyAdditionalWaiterCancellation(mode, cancelLastWaiter: false)
            try await verifyAdditionalWaiterCancellation(mode, cancelLastWaiter: true)
        }
    }

    private func verifyAdditionalWaiterCancellation(_ mode: TransportMode, cancelLastWaiter: Bool) async throws {
        let arrived = expectation(description: "both requests sent with the original credential")
        arrived.expectedFulfillmentCount = 2
        let refreshing = expectation(description: "the first request started refresh")
        let cancelled = XCTestExpectation(description: "the last waiter cancelled the suspended refresh")
        let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
        let refresh = RefreshBatch(entered: refreshing)
        let transport = try makeRefreshTransport(backend, mode: mode)
        transport.onTokenExpired = {
            await withTaskCancellationHandler {
                await refresh.receive()
            } onCancel: {
                cancelled.fulfill()
            }
        }

        let first = Task { try await transport.call("first") }
        let second = Task { try await transport.call("second") }
        await fulfillment(of: [arrived], timeout: 2)
        await backend.release("first")
        await fulfillment(of: [refreshing], timeout: 2)
        await backend.release("second")
        // Give the second 401 a chance to join while the first keeps the refresh suspended.
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        let secondResult = await second.result
        if cancelLastWaiter {
            first.cancel()
            await fulfillment(of: [cancelled], timeout: 2)
        }
        await refresh.release()

        let firstResult = await first.result
        let attempts = await backend.attempts
        let refreshCalls = await refresh.calls
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(attempts["second"]?.map(\.token), ["Bearer old"])
        if case .failure(let error) = secondResult {
            XCTAssertTrue(error is CancellationError)
        } else {
            XCTFail("a cancelled additional waiter must not retry")
        }
        if cancelLastWaiter {
            if case .failure(let error) = firstResult {
                XCTAssertTrue(error is CancellationError)
            } else {
                XCTFail("the last cancelled waiter must not retry")
            }
            XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
        } else {
            let expected = mode == .binary ? Data([84]) : Data("42".utf8)
            XCTAssertEqual(try firstResult.get().data, expected)
            XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old", "Bearer renewed"])
        }
    }

    func testCancellationRacingUnauthorizedDoesNotReplay() async throws {
        for index in 0..<128 {
            let arrived = expectation(description: "original request sent")
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
            let refresh = RefreshBatch(entered: XCTestExpectation(description: "refresh may start"))
            let transport = try makeRefreshTransport(backend, mode: .json)
            transport.onTokenExpired = { await refresh.receive() }

            let request = Task { try await transport.call("first") }
            await fulfillment(of: [arrived], timeout: 2)
            await backend.release("first")
            for _ in 0..<(index % 8) { await Task.yield() }
            request.cancel()
            await refresh.release()

            if case .failure(let error) = await request.result {
                XCTAssertTrue(error is CancellationError)
            } else {
                XCTFail("a cancelled request must not retry")
            }
            let attempts = await backend.attempts
            XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
        }
    }

    func testIdentityReplacementRacingRefreshDoesNotSendTheNewIdentity() async throws {
        for index in 0..<128 {
            let arrived = expectation(description: "request sent with the original credential")
            let refreshing = expectation(description: "refresh callback is waiting")
            let backend = ConcurrentUnauthorizedBackend(arrived: arrived)
            let refresh = RefreshBatch(entered: refreshing)
            let transport = try makeRefreshTransport(backend, mode: .json)
            transport.onTokenExpired = { await refresh.receive() }

            let request = Task { try await transport.call("first") }
            await fulfillment(of: [arrived], timeout: 2)
            await backend.release("first")
            await fulfillment(of: [refreshing], timeout: 2)
            await refresh.release()
            for _ in 0..<(index % 8) { await Task.yield() }
            transport.setToken("different-user")

            let outcome = await request.result
            let attempts = await backend.attempts
            switch outcome {
            case .success(let response):
                XCTAssertEqual(response.data, Data("42".utf8))
                XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old", "Bearer renewed"])
            case .failure:
                assertUnauthorized(outcome)
                XCTAssertEqual(attempts["first"]?.map(\.token), ["Bearer old"])
            }
        }
    }
}
