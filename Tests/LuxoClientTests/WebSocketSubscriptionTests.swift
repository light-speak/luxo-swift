import Foundation
import XCTest
@testable import LuxoClient

final class WebSocketSubscriptionTests: XCTestCase {
    func testCompletionBeforeAcknowledgementRejectsEstablishment() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: mode)
            defer { transport.close() }
            let message: URLSessionWebSocketTask.Message =
                mode == .json
                ? .string(#"{"$end":1,"ok":true}"#) : .data(frame(0x15, 1))
            socket.onSend = { [weak socket] sent in
                guard (try? Self.subscriptionID(sent)) != nil else { return }
                socket?.deliver(.success(message))
            }
            do {
                _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in XCTFail("unexpected data") }
                XCTFail("completion before ACK must fail")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "ParseError")
            }
        }
    }

    func testSubscriptionThroughTransportProtocolUsesWebSocketImplementation() async throws {
        let socket = MockWebSocketTask()
        let transport = try makeTransport(socket, mode: .json)
        defer { transport.close() }
        acknowledgeSentSubscriptions(socket, mode: .json)
        let erased: any Transport = transport
        let cancel = try await erased.subscribe("watch", decoder: { $0 }) { _ in }
        XCTAssertEqual(try sentIDs(socket), [1])
        cancel()
    }

    func testCancellationAfterAcknowledgementDoesNotLeakItsSubscription() async throws {
        let socket = MockWebSocketTask()
        let transport = try makeTransport(socket, mode: .json)
        defer { transport.close() }
        socket.onSend = { [weak socket] message in
            guard (try? Self.subscriptionID(message)) != nil else { return }
            socket?.deliver(.success(.string(#"{"$sub":1,"ok":true}"#)))
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let task = Task {
            try await transport.subscribe("watch", decoder: { $0 }) { _ in XCTFail("cancelled handler ran") }
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(socket.sentMessages.count, 2)
        socket.deliver(.success(stream(.json, 1, 1)))
    }

    func testFullWidthSubscriptionFramesAndRetiredTags() throws {
        for id in [UInt64(0), 1, 9_007_199_254_740_993, UInt64(Int64.max) + 1, UInt64.max] {
            for type in [UInt64(0x12), 0x13, 0x14] {
                let decoded = try XCTUnwrap(LuxoWebSocketProtocol.decodeBinaryFrame(frame(type, id)))
                XCTAssertEqual(decoded.id, id)
                XCTAssertEqual(decoded.type, type)
            }
            let values: [String: LuxoValue] = [
                "$sub": .jsonNumber(JSONNumber(validated: String(id))), "ok": .bool(true),
            ]
            XCTAssertNotNil(LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: values))
        }
        for type in UInt8(4)...8 {
            XCTAssertNil(LuxoWebSocketProtocol.decodeBinaryFrame(Data([type, 1])))
        }
    }

    func testSameAPISubscriptionsRetainIndependentUnsignedIdentities() async throws {
        let starts: [UInt64] = [0, 9_007_199_254_740_990, UInt64(Int64.max) - 1, UInt64.max - 2]
        for mode in [TransportMode.json, .binary] {
            for start in starts {
                let socket = MockWebSocketTask()
                let transport = try makeTransport(socket, mode: mode, start: start)
                defer { transport.close() }
                acknowledgeSentSubscriptions(socket, mode: mode)
                let firstValues = SubscriptionValues()
                let secondValues = SubscriptionValues()
                let first = try await transport.subscribe("watch", decoder: { $0 }) { firstValues.append($0.data) }
                let second = try await transport.subscribe("watch", decoder: { $0 }) { secondValues.append($0.data) }
                XCTAssertEqual(try sentIDs(socket), [start + 1, start + 2])
                socket.deliver(.success(stream(mode, start + 2, 2)))
                socket.deliver(.success(stream(mode, start + 1, 1)))
                XCTAssertEqual(firstValues.values, [Data([mode == .json ? 49 : 1])])
                XCTAssertEqual(secondValues.values, [Data([mode == .json ? 50 : 2])])
                first(); second()
            }
        }
    }

    func testOldFramesAndRepeatedCancelCannotAffectAnotherSubscription() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: mode)
            defer { transport.close() }
            acknowledgeSentSubscriptions(socket, mode: mode)
            let oldValues = SubscriptionValues()
            let currentValues = SubscriptionValues()
            let old = try await transport.subscribe("watch", decoder: { $0 }) { oldValues.append($0.data) }
            old()
            let current = try await transport.subscribe("watch", decoder: { $0 }) { currentValues.append($0.data) }
            let count = socket.sentMessages.count
            old()
            XCTAssertEqual(socket.sentMessages.count, count)
            socket.deliver(.success(stream(mode, 1, 9)))
            socket.deliver(.success(failure(mode, 1)))
            socket.deliver(.success(stream(mode, 2, 2)))
            XCTAssertTrue(oldValues.values.isEmpty)
            XCTAssertEqual(currentValues.values.count, 1)
            current()
        }
    }

    func testSubscriptionModeAndCancellationRemainStableAfterModeChange() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: mode, start: .max - 1)
            defer { transport.close() }
            acknowledgeSentSubscriptions(socket, mode: mode)
            let values = SubscriptionValues()
            let cancel = try await transport.subscribe("watch", decoder: { $0 }) {
                XCTAssertEqual($0.mode, mode)
                values.append($0.data)
            }
            let other: TransportMode = mode == .json ? .binary : .json
            transport.setMode(other)
            socket.deliver(.success(stream(other, .max, 9)))
            XCTAssertTrue(values.values.isEmpty)
            socket.deliver(.success(stream(mode, .max, 2)))
            XCTAssertEqual(values.values.count, 1)
            socket.onSend = nil
            cancel()
            if mode == .json {
                guard case .string(let message) = socket.sentMessages.last else { return XCTFail("wrong cancel mode") }
                XCTAssertEqual(message, #"{"$unsub":18446744073709551615}"#)
            } else {
                XCTAssertEqual(socket.dataMessage(at: 1), frame(0x11, .max))
            }
            do {
                _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in }
                XCTFail("expected exhaustion")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "RequestIDExhausted")
            }
        }
    }

    func testTimeoutSendsCancellationForTheOriginalID() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: mode)
            defer { transport.close() }
            do {
                _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in }
                XCTFail("expected timeout")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "TimeoutError")
            }
            if mode == .json {
                guard case .string(let message) = socket.sentMessages.last else { return XCTFail("missing cancel") }
                XCTAssertEqual(message, #"{"$unsub":1}"#)
            } else {
                XCTAssertEqual(socket.dataMessage(at: 1), frame(0x11, 1))
            }
        }
    }

    func testConcurrentSubscriptionsSendInUnsignedOrder() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let start = UInt64(Int64.max) - 63
            let transport = try makeTransport(socket, mode: mode, start: start)
            defer { transport.close() }
            acknowledgeSentSubscriptions(socket, mode: mode)
            let cancellations = try await withThrowingTaskGroup(of: (@Sendable () -> Void).self) { group in
                for _ in 0..<128 { group.addTask { try await transport.subscribe("watch", decoder: { $0 }) { _ in } } }
                var result: [@Sendable () -> Void] = []
                for try await cancel in group { result.append(cancel) }
                return result
            }
            XCTAssertEqual(try sentIDs(socket), (1...128).map { start + UInt64($0) })
            cancellations.forEach { $0() }
        }
    }

    func testReverseAcknowledgementsAndPreAcknowledgementData() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: mode)
            defer { transport.close() }
            let firstSent = expectation(description: "first subscription")
            socket.onSend = { _ in firstSent.fulfill() }
            let firstValues = SubscriptionValues()
            let first = Task { try await transport.subscribe("watch", decoder: { $0 }) { firstValues.append($0.data) } }
            await fulfillment(of: [firstSent], timeout: 1)
            let secondSent = expectation(description: "second subscription")
            socket.onSend = { _ in secondSent.fulfill() }
            let secondValues = SubscriptionValues()
            let second = Task {
                try await transport.subscribe("watch", decoder: { $0 }) { secondValues.append($0.data) }
            }
            await fulfillment(of: [secondSent], timeout: 1)
            socket.onSend = nil
            socket.deliver(.success(stream(mode, 1, 1)))
            socket.deliver(.success(stream(mode, 2, 2)))
            XCTAssertTrue(firstValues.values.isEmpty)
            XCTAssertTrue(secondValues.values.isEmpty)
            socket.deliver(.success(acknowledgement(mode, 2)))
            let cancelSecond = try await second.value
            socket.deliver(.success(acknowledgement(mode, 1)))
            let cancelFirst = try await first.value
            socket.deliver(.success(stream(mode, 2, 2)))
            socket.deliver(.success(stream(mode, 1, 1)))
            XCTAssertEqual(firstValues.values.count, 1)
            XCTAssertEqual(secondValues.values.count, 1)
            cancelFirst(); cancelSecond()
        }
    }

    func testCancellationBeforeAndWhileWaitingForAcknowledgement() async throws {
        for mode in [TransportMode.json, .binary] {
            for beforeStart in [false, true] {
                let socket = MockWebSocketTask()
                let transport = try makeTransport(socket, mode: mode)
                defer { transport.close() }
                let sent = beforeStart ? nil : expectation(description: "pending subscription")
                socket.onSend = { _ in sent?.fulfill() }
                let task = Task {
                    if beforeStart { withUnsafeCurrentTask { $0?.cancel() } }
                    return try await transport.subscribe("watch", decoder: { $0 }) { _ in
                        XCTFail("cancelled handler ran")
                    }
                }
                if let sent { await fulfillment(of: [sent], timeout: 1) }
                socket.onSend = nil
                task.cancel()
                do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
                XCTAssertEqual(socket.sentMessages.count, beforeStart ? 0 : 2)
                socket.deliver(.success(acknowledgement(mode, 1)))
                socket.deliver(.success(stream(mode, 1, 1)))
            }
        }
    }

    func testReconnectTerminatesOldSubscriptionsWithoutReplayingThem() async throws {
        for mode in [TransportMode.json, .binary] {
            let first = MockWebSocketTask()
            let second = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "wss://example.com/socket", session: MockWebSocketSession(sockets: [first, second]),
                initialSequence: UInt64(Int64.max) - 1)
            defer { transport.close() }
            transport.setMode(mode)
            transport.setSchema(["watch": APISchema(id: 77)])
            transport.connect()
            acknowledgeSentSubscriptions(first, mode: mode)
            let values = SubscriptionValues()
            let ended = expectation(description: "three subscriptions disconnected")
            ended.expectedFulfillmentCount = 3
            let observer = StreamObserver(
                onComplete: { XCTFail("disconnect is not completion") },
                onError: { error in
                    XCTAssertEqual(error.name, "NetworkError")
                    ended.fulfill()
                })
            var stops: [@Sendable () -> Void] = []
            for _ in 0..<3 {
                stops.append(
                    try await transport.subscribe(
                        "watch", decoder: { $0 }, params: ["$select": "id"], observer: observer
                    ) {
                        values.append($0.data)
                    })
            }
            transport.setMode(mode == .json ? .binary : .json)
            transport.setSchema([:])
            transport.connect()
            await fulfillment(of: [ended], timeout: 1)
            XCTAssertTrue(second.sentMessages.isEmpty)
            for id in try sentIDs(first) {
                first.deliver(.success(stream(mode, id, 9)))
                second.deliver(.success(stream(mode, id, 9)))
                second.deliver(.success(acknowledgement(mode, id)))
                second.deliver(.success(stream(mode, id, 2)))
            }
            stops.forEach { $0() }
            XCTAssertTrue(second.sentMessages.isEmpty)
            XCTAssertTrue(values.values.isEmpty)
        }
    }

    func testOldSendFailureAndCancelCannotRemoveAnExplicitNewSubscription() async throws {
        for mode in [TransportMode.json, .binary] {
            let first = MockWebSocketTask()
            let second = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "wss://example.com/socket", session: MockWebSocketSession(sockets: [first, second]))
            defer { transport.close() }
            transport.setMode(mode)
            transport.setSchema(["watch": APISchema(id: 77)])
            transport.connect()
            acknowledgeSentSubscriptions(first, mode: mode)
            acknowledgeSentSubscriptions(second, mode: mode)
            first.holdSendCompletions = true
            let values = SubscriptionValues()
            let old = try await transport.subscribe("watch", decoder: { $0 }) { _ in XCTFail("old handler ran") }
            transport.connect()
            XCTAssertTrue(second.sentMessages.isEmpty)
            let cancel = try await transport.subscribe("watch", decoder: { $0 }) { values.append($0.data) }
            old()
            first.completeSend(at: 0, error: URLError(.networkConnectionLost))
            second.deliver(.success(stream(mode, 1, 9)))
            second.deliver(.success(stream(mode, 2, 2)))
            XCTAssertEqual(values.values.count, 1)
            cancel()
        }
    }

    func testInlineDisconnectNotifiesOutsideAllTransportLocks() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: mode)
            defer { transport.close() }
            acknowledgeSentSubscriptions(socket, mode: mode)
            let notified = expectation(description: "disconnect observer")
            notified.expectedFulfillmentCount = 2
            let observer = StreamObserver(onError: { error in
                XCTAssertEqual(error.name, "NetworkError")
                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    transport.close(); finished.signal()
                }
                XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .success)
                notified.fulfill()
            })
            for _ in 0..<2 { _ = try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in } }
            socket.onSend = { [weak socket] _ in
                socket?.deliver(.failure(URLError(.networkConnectionLost)))
            }
            do {
                _ = try await transport.subscribe(
                    "watch", decoder: { $0 },
                    observer: StreamObserver(onError: { _ in
                        XCTFail("pending setup must throw, not notify")
                    })
                ) { _ in }
                XCTFail("expected setup failure")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "NetworkError")
            }
            await fulfillment(of: [notified], timeout: 1)
        }
    }

    func testClosingDuringConcurrentRegistrationCompletesEveryWaiter() async throws {
        for _ in 0..<25 {
            let socket = MockWebSocketTask()
            let transport = try makeTransport(socket, mode: .json)
            acknowledgeSentSubscriptions(socket, mode: .json)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do {
                            let cancel = try await transport.subscribe("watch", decoder: { $0 }) { _ in }; cancel()
                        } catch {
                            XCTAssertEqual((error as? LuxoError)?.name, "ConnectionError")
                        }
                    }
                }
                group.addTask { transport.close() }
            }
            transport.close()
        }
    }

    private func makeTransport(_ socket: MockWebSocketTask, mode: TransportMode, start: UInt64 = 0) throws
        -> WebSocketTransport
    {
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket", timeout: 0.5,
            session: MockWebSocketSession(socket: socket), initialSequence: start)
        transport.setSchema(["watch": APISchema(id: 77)])
        transport.setMode(mode)
        transport.connect()
        return transport
    }

    private func acknowledgeSentSubscriptions(_ socket: MockWebSocketTask, mode: TransportMode) {
        socket.onSend = { [weak socket] message in
            guard let id = try? Self.subscriptionID(message) else { return }
            if mode == .json {
                socket?.deliver(.success(.string("{\"$sub\":\(id),\"ok\":true}")))
            } else {
                var encoder = Encoder()
                encoder.writeVarint(0x13)
                encoder.writeVarint(id)
                socket?.deliver(.success(.data(encoder.data)))
            }
        }
    }

    private static func subscriptionID(_ message: URLSessionWebSocketTask.Message) throws -> UInt64? {
        switch message {
        case .string(let text):
            guard case .object(let json) = try LuxoValue.decodeJSONData(Data(text.utf8)), json["$sub"] != nil else {
                return nil
            }
            guard let id = LuxoWebSocketProtocol.jsonRequestID(value: json["$id"]) else {
                throw LuxoError(code: 0, message: "missing numeric subscription ID", name: "TestFailure")
            }
            return id
        case .data(let data):
            var decoder = Decoder(data)
            guard decoder.readVarint() == 0x10 else { return nil }
            let id = decoder.readVarint()
            XCTAssertEqual(decoder.readVarint(), 77)
            return id
        @unknown default:
            return nil
        }
    }

    private func sentIDs(_ socket: MockWebSocketTask) throws -> [UInt64] {
        try socket.sentMessages.compactMap(Self.subscriptionID)
    }

    private func stream(_ mode: TransportMode, _ id: UInt64, _ value: UInt8) -> URLSessionWebSocketTask.Message {
        mode == .json ? .string("{\"$stream\":\(id),\"data\":\(value)}") : .data(frame(0x12, id, Data([value])))
    }

    private func acknowledgement(_ mode: TransportMode, _ id: UInt64) -> URLSessionWebSocketTask.Message {
        mode == .json ? .string("{\"$sub\":\(id),\"ok\":true}") : .data(frame(0x13, id))
    }

    private func failure(_ mode: TransportMode, _ id: UInt64) -> URLSessionWebSocketTask.Message {
        if mode == .json {
            return .string("{\"$sub\":\(id),\"error\":\"NotFound\",\"code\":404,\"message\":\"missing\"}")
        }
        var encoder = Encoder()
        encoder.writeVarint(1)
        encoder.writeSvarint(404)
        encoder.writeVarint(2)
        encoder.writeString("NotFound")
        encoder.writeVarint(3)
        encoder.writeString("missing")
        encoder.writeEnd()
        return .data(frame(0x14, id, encoder.data))
    }

    private func frame(_ type: UInt64, _ id: UInt64, _ payload: Data = Data()) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(type)
        encoder.writeVarint(id)
        encoder.writeRawBytes(payload)
        return encoder.data
    }
}

private final class SubscriptionValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    var values: [Data] { lock.withLock { storage } }
    func append(_ value: Data) { lock.withLock { storage.append(value) } }
}
