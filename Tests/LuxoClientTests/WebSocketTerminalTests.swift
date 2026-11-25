import Foundation
import XCTest
@testable import LuxoClient

final class WebSocketTerminalTests: XCTestCase {
    func testCredentialRotationRetiresConnectedWorkAndReplacesUpgrade() async throws {
        let old = MockWebSocketTask(), fresh = MockWebSocketTask(), anonymous = MockWebSocketTask()
        let session = MockWebSocketSession(sockets: [old, fresh, anonymous])
        let transport = try WebSocketTransport(
            url: "ws://localhost/test?token=original&keep=x&keep=y", timeout: 1, session: session)
        defer { transport.close() }
        transport.connect()
        XCTAssertTrue(old.isResumed)
        XCTAssertTrue(try XCTUnwrap(session.lastRequest?.url?.query).contains("token=original"))

        let sent = expectation(description: "in-flight original call")
        old.onSend = { _ in sent.fulfill() }
        let pending = Task { try await transport.call("echo") }
        await fulfillment(of: [sent], timeout: 1)
        transport.setToken("new")
        XCTAssertEqual(old.cancelCode, .goingAway)
        XCTAssertTrue(fresh.isResumed)
        do {
            _ = try await pending.value
            XCTFail("expected cancellation")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "CancelledError")
        }
        let request = try XCTUnwrap(session.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
        XCTAssertEqual(request.url?.query, "keep=x&keep=y")

        old.expireAccess()
        fresh.onSend = { [weak fresh] _ in
            fresh?.deliver(.success(.string(#"{"$id":2,"data":42}"#)))
        }
        let result = try await transport.call("echo")
        XCTAssertEqual(result.data, Data("42".utf8))
        XCTAssertEqual(old.sentMessages.count, 1)

        transport.setToken("new")
        XCTAssertNil(fresh.cancelCode)
        transport.setToken("")
        XCTAssertEqual(fresh.cancelCode, .goingAway)
        XCTAssertTrue(anonymous.isResumed)
        XCTAssertNil(session.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(session.lastRequest?.url?.query, "keep=x&keep=y")
    }

    func testCredentialRotationRetiresUpgradeBeforeItReceivesAnything() throws {
        let old = MockWebSocketTask(), fresh = MockWebSocketTask()
        let session = MockWebSocketSession(sockets: [old, fresh])
        let transport = try WebSocketTransport(url: "ws://localhost/test", token: "old", session: session)
        defer { transport.close() }
        transport.connect()
        XCTAssertTrue(old.isResumed)
        transport.setToken("new")
        XCTAssertEqual(old.cancelCode, .goingAway)
        XCTAssertTrue(fresh.isResumed)
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    func testBearerUpgradeFiltersEncodedTokenNamesAndPreservesQueryValues() throws {
        let examples: [(query: String, expected: String?)] = [
            ("cursor=a%2Bb%26token%3Dtext&mode=live", "cursor=a%2Bb%26token%3Dtext&mode=live"),
            ("tag=x&%74oken=legacy&tag=y&token=legacy", "tag=x&tag=y"),
            ("Token=other&t%6Fken=legacy&flag&blank=", "Token=other&flag&blank="),
            ("tokenized=one&key=token&%25token=two", "tokenized=one&key=token&%25token=two"),
            ("token", nil),
            ("", ""),
        ]
        for sample in examples {
            let socket = MockWebSocketTask()
            let session = MockWebSocketSession(sockets: [socket])
            let transport = try WebSocketTransport(
                url: "ws://localhost/test?\(sample.query)", token: "new", session: session
            )
            defer { transport.close() }
            transport.connect()
            let request = try XCTUnwrap(session.lastRequest)
            let endpoint = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
            XCTAssertTrue(socket.isResumed)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
            XCTAssertEqual(components.percentEncodedQuery, sample.expected, sample.query)
        }
    }

    func testInvalidErrorStatusOnlyEndsItsOwnSubscription() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let failed = TerminalValues(), peer = TerminalValues()
            let cancel = try await transport.subscribe("watch", decoder: { $0 }, observer: failed.observer) {
                failed.append($0.data)
            }
            let cancelPeer = try await transport.subscribe("watch", decoder: { $0 }, observer: peer.observer) {
                peer.append($0.data)
            }
            socket.deliver(.success(try failure(mode, 1, code: 0)))
            socket.deliver(.success(try failure(mode, 1, code: 0)))
            socket.deliver(.success(data(mode, 2, 7)))
            XCTAssertEqual(failed.errors.map(\.name), ["ParseError"])
            XCTAssertEqual(failed.completed, 0)
            XCTAssertTrue(failed.rows.isEmpty)
            XCTAssertEqual(peer.rows.count, 1)
            XCTAssertTrue(peer.errors.isEmpty)
            cancel()
            cancelPeer()
        }
    }

    func testExpiredAccessRejectsOldWorkAndDoesNotReconnectExpiredCredential() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let ended = expectation(description: "expired subscription")
            let cancel = try await transport.subscribe(
                "watch", decoder: { $0 },
                observer: StreamObserver(onError: { error in
                    XCTAssertEqual(error.code, 401)
                    XCTAssertEqual(error.name, "Unauthorized")
                    ended.fulfill()
                })
            ) { _ in XCTFail("expired data") }
            let sent = expectation(description: "pending call")
            socket.onSend = { _ in sent.fulfill() }
            let call = Task { try await transport.call("watch") }
            await fulfillment(of: [sent], timeout: 1)
            socket.onSend = nil
            socket.expireAccess()
            do { _ = try await call.value; XCTFail("expected expiry") } catch let error as LuxoError {
                XCTAssertEqual(error.code, 401)
            }
            await fulfillment(of: [ended], timeout: 1)
            transport.connect()
            do { _ = try await transport.call("watch"); XCTFail("expired token must not reconnect") } catch let error
                as LuxoError
            { XCTAssertEqual(error.code, 401) }
            cancel()
            XCTAssertEqual(socket.sentMessages.count, 2)
        }
    }

    func testExplicitNewAccessCanReconnectWithoutRestoringExpiredWork() async throws {
        let old = MockWebSocketTask(), fresh = MockWebSocketTask()
        let session = MockWebSocketSession(sockets: [old, fresh])
        let transport = try WebSocketTransport(url: "ws://localhost/test", token: "old", session: session)
        defer { transport.close() }
        transport.connect()
        old.expireAccess()
        transport.setToken("new")
        transport.connect()
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
        XCTAssertTrue(fresh.sentMessages.isEmpty)
        old.expireAccess()
        fresh.onSend = { [weak fresh] _ in fresh?.deliver(.success(.string(#"{"$id":1,"data":42}"#))) }
        let response = try await transport.call("echo")
        XCTAssertEqual(response.data, Data("42".utf8))
        XCTAssertEqual(fresh.sentMessages.count, 1)
    }

    func testMalformedJSONFailsPendingCallsAcknowledgementsAndObservers() async throws {
        for mode in [TransportMode.json, .binary] {
            try await verifyMalformedMessage(mode, message: .string(#"{"$id":3,"data":"#))
        }
    }

    func testMalformedBinaryFailsPendingCallsAcknowledgementsAndObservers() async throws {
        for mode in [TransportMode.json, .binary] {
            for data in [
                Data(), Data([2]), Data([2, 128]), Data([2]) + Data(repeating: 128, count: 9) + Data([2]),
                Data([0x82, 0, 1]), Data([0xff, 1]), Data([0x15, 128]),
            ] {
                try await verifyMalformedMessage(mode, message: .data(data))
            }
        }
    }

    private func verifyMalformedMessage(_ mode: TransportMode, message: URLSessionWebSocketTask.Message) async throws {
        let (transport, socket) = try fixture(mode)
        defer { transport.close() }
        let ended = expectation(description: "all established subscriptions fail")
        ended.expectedFulfillmentCount = 2
        let observer = StreamObserver(
            onComplete: { XCTFail("parse failure is not completion") },
            onError: { error in
                XCTAssertEqual(error.name, "ParseError"); ended.fulfill()
            })
        let first = try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in
            XCTFail("bad data")
        }
        let second = try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in
            XCTFail("bad data")
        }
        let sent = expectation(description: "call and pending acknowledgement sent")
        sent.expectedFulfillmentCount = 2
        socket.onSend = { _ in sent.fulfill() }
        let call = Task { try await transport.call("watch") }
        let setup = Task {
            try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in XCTFail("bad data") }
        }
        await fulfillment(of: [sent], timeout: 1)
        socket.onSend = nil
        socket.deliver(.success(message))
        do { _ = try await call.value; XCTFail("expected ParseError") } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ParseError")
        }
        do { _ = try await setup.value; XCTFail("expected ParseError") } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ParseError")
        }
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertEqual(socket.cancelCode, .goingAway)
        socket.deliver(.failure(URLError(.networkConnectionLost)))
        first(); second()
        XCTAssertEqual(socket.sentMessages.count, 4)
    }

    func testMalformedJSONNotifiesOutsideLocksAndNeverReplaysOldSubscriptions() async throws {
        for body in ["", "{", "[1]", "null", "1", #"{"$id":1} trailing"#, #"{"data":"\uD800"}"#] {
            let first = MockWebSocketTask(), second = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "ws://localhost/test", timeout: 1,
                session: MockWebSocketSession(sockets: [first, second]))
            defer { transport.close() }
            transport.connect()
            first.onSend = { [weak first] _ in first?.deliver(.success(.string(#"{"$sub":1,"ok":true}"#))) }
            let ended = expectation(description: "ParseError observer may replace connection")
            let cancel = try await transport.subscribe(
                "watch", decoder: { $0 },
                observer: StreamObserver(onError: { error in
                    XCTAssertEqual(error.name, "ParseError", body)
                    let reentered = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        transport.connect(); reentered.signal()
                    }
                    XCTAssertEqual(reentered.wait(timeout: .now() + 1), .success)
                    ended.fulfill()
                })
            ) { _ in XCTFail("bad data") }
            first.deliver(.success(.string(body)))
            await fulfillment(of: [ended], timeout: 1)
            XCTAssertEqual(first.cancelCode, .goingAway)
            XCTAssertTrue(second.sentMessages.isEmpty)
            first.deliver(.success(.string("{"))); cancel()
            second.onSend = { [weak second] _ in second?.deliver(.success(.string(#"{"$id":2,"data":7}"#))) }
            let value = try await transport.call("watch")
            XCTAssertEqual(value.data, Data("7".utf8))
            XCTAssertNil(second.cancelCode)
        }
    }

    func testExplicitCloseDoesNotNotifyEstablishedObservers() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, _) = try fixture(mode)
            let notified = expectation(description: "explicit close remains silent")
            notified.isInverted = true
            let observer = StreamObserver(onComplete: { notified.fulfill() }, onError: { _ in notified.fulfill() })
            let cancel = try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in }
            transport.close()
            cancel()
            await fulfillment(of: [notified], timeout: 0.02)
        }
    }

    func testConcurrentTerminalAndDisconnectNotifyAtMostOnce() async throws {
        for mode in [TransportMode.json, .binary] {
            for _ in 0..<32 {
                let (transport, socket) = try fixture(mode)
                let values = TerminalValues()
                let notified = expectation(description: "one terminal outcome")
                let observer = StreamObserver(
                    onComplete: {
                        values.observer.onComplete?(); notified.fulfill()
                    },
                    onError: { error in
                        values.observer.onError?(error); notified.fulfill()
                    })
                _ = try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in }
                let message = completion(mode, 1)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { socket.deliver(.success(message)) }
                    group.addTask { socket.deliver(.failure(URLError(.networkConnectionLost))) }
                }
                await fulfillment(of: [notified], timeout: 1)
                transport.close()
                XCTAssertEqual(values.completed + values.errors.count, 1)
                XCTAssertTrue(values.errors.allSatisfy { $0.name == "NetworkError" })
            }
        }
    }

    func testSetupFailureThrowsWithoutCallingObserver() async throws {
        for mode in [TransportMode.json, .binary] {
            for terminal in [false, true] {
                let (transport, socket) = try fixture(mode)
                defer { transport.close() }
                let values = TerminalValues()
                let message = try failure(mode, 1, acknowledgement: !terminal)
                socket.onSend = { [weak socket] _ in socket?.deliver(.success(message)) }
                do {
                    _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) { _ in }
                    XCTFail("expected setup failure")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, terminal ? "ParseError" : "Rejected")
                }
                XCTAssertEqual(values.completed, 0)
                XCTAssertTrue(values.errors.isEmpty)
            }
        }
    }

    func testOldConnectionTerminalCannotFinishAnExplicitNewSubscription() async throws {
        for mode in [TransportMode.json, .binary] {
            let first = MockWebSocketTask()
            let second = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "ws://localhost/test", timeout: 1,
                session: MockWebSocketSession(sockets: [first, second]))
            defer { transport.close() }
            try transport.setSchema(["watch": APISchema(id: 77)])
            transport.setMode(mode)
            transport.connect()
            let acknowledgement: URLSessionWebSocketTask.Message =
                mode == .json
                ? .string(#"{"$sub":1,"ok":true}"#) : .data(frame(0x13, 1))
            first.onSend = { [weak first] _ in first?.deliver(.success(acknowledgement)) }
            let values = TerminalValues()
            let ended = expectation(description: "old subscription disconnected")
            _ = try await transport.subscribe(
                "watch", decoder: { $0 },
                observer: StreamObserver(onError: { error in
                    values.observer.onError?(error)
                    ended.fulfill()
                })
            ) { _ in }
            transport.connect()
            await fulfillment(of: [ended], timeout: 1)
            let fresh = TerminalValues()
            let nextAcknowledgement: URLSessionWebSocketTask.Message =
                mode == .json ? .string(#"{"$sub":2,"ok":true}"#) : .data(frame(0x13, 2))
            second.onSend = { [weak second] _ in second?.deliver(.success(nextAcknowledgement)) }
            _ = try await transport.subscribe("watch", decoder: { $0 }, observer: fresh.observer) {
                fresh.append($0.data)
            }
            first.deliver(.success(completion(mode, 1)))
            XCTAssertEqual(values.completed, 0)
            XCTAssertEqual(values.errors.map(\.name), ["NetworkError"])
            second.deliver(.success(completion(mode, 1)))
            XCTAssertEqual(fresh.completed, 0)
            second.deliver(.success(completion(mode, 2)))
            XCTAssertEqual(fresh.completed, 1)
            XCTAssertTrue(fresh.errors.isEmpty)
        }
    }

    func testConcurrentTerminalCancelAndCloseDoNotNotifyTwice() async throws {
        for mode in [TransportMode.json, .binary] {
            for _ in 0..<16 {
                let (transport, socket) = try fixture(mode)
                let values = TerminalValues()
                let cancel = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) { _ in }
                let message = completion(mode, 1)
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 { group.addTask { socket.deliver(.success(message)) } }
                    group.addTask { cancel() }
                    group.addTask { transport.close() }
                }
                transport.close()
                XCTAssertLessThanOrEqual(values.completed, 1)
                XCTAssertTrue(values.errors.isEmpty)
            }
        }
    }

    func testCompletionFollowsAllDataOnceAndKeepsOtherSubscriptionAlive() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let values = TerminalValues()
            let cancel = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
                values.append($0.data)
            }
            let other = TerminalValues()
            let cancelOther = try await transport.subscribe("watch", decoder: { $0 }) { other.append($0.data) }
            for number in 0..<64 { socket.deliver(.success(data(mode, 1, UInt8(number)))) }
            socket.deliver(.success(completion(mode, 1)))
            socket.deliver(.success(completion(mode, 1)))
            socket.deliver(.success(data(mode, 1, 99)))
            socket.deliver(.success(data(mode, 2, 7)))
            XCTAssertEqual(values.rows, (0..<64).map { mode == .json ? Data(String($0).utf8) : Data([UInt8($0)]) })
            XCTAssertEqual(values.terminalRowCounts, [64])
            XCTAssertEqual(values.completed, 1)
            XCTAssertTrue(values.errors.isEmpty)
            XCTAssertEqual(other.rows.count, 1)
            let sent = socket.sentMessages.count
            cancel()
            XCTAssertEqual(socket.sentMessages.count, sent)
            XCTAssertNil(socket.cancelCode)
            cancelOther()
        }
    }

    func testTerminalFailurePreservesNumbersAndUnsignedMaximum() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode, start: .max - 1)
            defer { transport.close() }
            let values = TerminalValues()
            _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
                values.append($0.data)
            }
            socket.deliver(.success(try failure(mode, .max)))
            socket.deliver(.success(try failure(mode, .max)))
            socket.deliver(.success(completion(mode, .max)))
            XCTAssertEqual(values.errors.count, 1)
            let error = try XCTUnwrap(values.errors.first)
            XCTAssertEqual(error.name, "Rejected")
            XCTAssertEqual(error.code, 409)
            XCTAssertEqual(error.traceId, "trace")
            XCTAssertEqual(error.cause, "details")
            let payload = try XCTUnwrap(error.data as? [String: Any])
            XCTAssertEqual(payload["n"] as? JSONNumber, try JSONNumber("123456789012345678901234567890"))
            XCTAssertEqual(payload["fraction"] as? JSONNumber, try JSONNumber("1.2345678901234567890123456789"))
            XCTAssertEqual(payload["zero"] as? JSONNumber, try JSONNumber("-0"))
            XCTAssertEqual(values.completed, 0)
            XCTAssertNil(socket.cancelCode)
        }
    }

    func testTerminalUsesOriginalModeAfterModeChange() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode, start: .max - 1)
            defer { transport.close() }
            let values = TerminalValues()
            _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
                values.append($0.data)
            }
            let other: TransportMode = mode == .json ? .binary : .json
            transport.setMode(other)
            socket.deliver(.success(completion(other, .max)))
            XCTAssertEqual(values.completed, 0)
            socket.deliver(.success(completion(mode, .max)))
            XCTAssertEqual(values.completed, 1)
        }
    }

    func testInvalidAndAmbiguousJSONIDsDoNotTerminate() async throws {
        let (transport, socket) = try fixture(.json)
        defer { transport.close() }
        let values = TerminalValues()
        _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
            values.append($0.data)
        }
        for id in ["2", "-1", "-0", "1.0", "1e0", "true", "null", "\"1\"", "18446744073709551616"] {
            socket.deliver(.success(.string("{\"$end\":\(id),\"ok\":true}")))
        }
        for other in ["$sub", "$stream", "$id"] {
            socket.deliver(.success(.string("{\"$end\":1,\"\(other)\":1,\"ok\":true}")))
        }
        XCTAssertEqual(values.completed, 0)
        XCTAssertTrue(values.errors.isEmpty)
        XCTAssertTrue(values.rows.isEmpty)
        socket.deliver(.success(completion(.json, 1)))
        XCTAssertEqual(values.completed, 1)
    }

    func testMalformedJSONTerminalReportsParseError() async throws {
        for tail in [
            "", #", "ok":false"#, #", "ok":"true""#, #", "ok":{}"#, #", "ok":true,"data":null"#,
            #", "error":"Rejected""#, #", "ok":true,"error":"Rejected","code":409,"message":"no""#,
        ] {
            let (transport, socket) = try fixture(.json)
            defer { transport.close() }
            let values = TerminalValues()
            _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
                values.append($0.data)
            }
            socket.deliver(.success(.string("{\"$end\":1\(tail)}")))
            XCTAssertEqual(values.errors.map(\.name), ["ParseError"], tail)
            XCTAssertEqual(values.completed, 0)
        }
    }

    func testMalformedBinaryTerminalReportsParseError() async throws {
        for type in [UInt64(0x15), 0x16] {
            let (transport, socket) = try fixture(.binary)
            defer { transport.close() }
            let values = TerminalValues()
            _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
                values.append($0.data)
            }
            socket.deliver(.success(.data(frame(type, 1, Data([1])))))
            XCTAssertEqual(values.errors.map(\.name), ["ParseError"])
        }
    }

    func testValidRetiredBinaryFramesDoNotTerminate() async throws {
        let (transport, socket) = try fixture(.binary)
        defer { transport.close() }
        let values = TerminalValues()
        _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
            values.append($0.data)
        }
        socket.deliver(.success(.data(frame(0x15, 2))))
        XCTAssertEqual(values.completed, 0)
        XCTAssertTrue(values.errors.isEmpty)
        socket.deliver(.success(completion(.binary, 1)))
        XCTAssertEqual(values.completed, 1)
    }

    func testCorrelatedBinaryAcknowledgementPayloadOnlyFailsItsSubscription() async throws {
        let (transport, socket) = try fixture(.binary)
        defer { transport.close() }
        let peer = TerminalValues()
        socket.onSend = { [weak socket] message in
            guard case .data(let data) = message else { return }
            var decoder = Decoder(data)
            let type = decoder.readVarint(), id = decoder.readVarint()
            var response = Encoder()
            response.writeVarint(type == 0x10 ? 0x13 : 2)
            response.writeVarint(id)
            if id == 1 || type == 1 { response.writeRawBytes(Data([42])) }
            socket?.deliver(.success(.data(response.data)))
        }
        do {
            _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in XCTFail("bad ACK delivered data") }
            XCTFail("malformed ACK succeeded")
        } catch let error as LuxoError { XCTAssertEqual(error.name, "ParseError") }
        let cancel = try await transport.subscribe("watch", decoder: { $0 }, observer: peer.observer) {
            peer.append($0.data)
        }
        socket.deliver(.success(.data(frame(0x13, 99, Data([42])))))
        socket.deliver(.success(data(.binary, 2, 7)))
        XCTAssertEqual(peer.rows, [Data([7])])
        XCTAssertTrue(peer.errors.isEmpty)
        let result = try await transport.call("watch")
        XCTAssertEqual(result.data, Data([42]))
        XCTAssertNil(socket.cancelCode)
        cancel()
    }

    func testExplicitCancellationAndAbsentObserversRemainSilent() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let values = TerminalValues()
            let cancel = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) {
                values.append($0.data)
            }
            cancel()
            socket.deliver(.success(completion(mode, 1)))
            socket.deliver(.success(try failure(mode, 1)))
            _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in }
            socket.deliver(.success(completion(mode, 2)))
            _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in }
            socket.deliver(.success(try failure(mode, 3)))
            XCTAssertTrue(values.errors.isEmpty)
            XCTAssertEqual(values.completed, 0)
        }
    }

    func testObserverNotificationsDoNotHoldTransportLocks() async throws {
        for mode in [TransportMode.json, .binary] {
            for fail in [false, true] {
                let (transport, socket) = try fixture(mode)
                defer { transport.close() }
                let callback: @Sendable () -> Void = {
                    let finished = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        transport.close(); finished.signal()
                    }
                    XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
                }
                let observer = StreamObserver(onComplete: callback, onError: { _ in callback() })
                _ = try await transport.subscribe("watch", decoder: { $0 }, observer: observer) { _ in }
                socket.deliver(.success(try fail ? failure(mode, 1) : completion(mode, 1)))
            }
        }
    }

    func testExistentialForwardingWithAndWithoutParamsKeepsObserver() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let erased: any Transport = transport
            let values = TerminalValues()
            _ = try await erased.subscribe("watch", decoder: { $0 }, observer: values.observer) { _ in }
            socket.deliver(.success(completion(mode, 1)))
            _ = try await erased.subscribe("watch", decoder: { $0 }, params: nil, observer: values.observer) { _ in }
            socket.deliver(.success(completion(mode, 2)))
            XCTAssertEqual(values.completed, 2)
        }
    }

    func testEstablishedAcknowledgementFailureNotifiesOnce() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let values = TerminalValues()
            _ = try await transport.subscribe("watch", decoder: { $0 }, observer: values.observer) { _ in }
            socket.deliver(.success(try failure(mode, 1, acknowledgement: true)))
            socket.deliver(.success(try failure(mode, 1, acknowledgement: true)))
            XCTAssertEqual(values.errors.map(\.name), ["Rejected"])
        }
    }

    private func fixture(_ mode: TransportMode, start: UInt64 = 0) throws -> (WebSocketTransport, MockWebSocketTask) {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "ws://localhost/test", timeout: 1,
            session: MockWebSocketSession(socket: socket), initialSequence: start)
        try transport.setSchema(["watch": APISchema(id: 77)])
        transport.setMode(mode)
        transport.connect()
        socket.onSend = { [weak socket] message in
            switch message {
            case .string(let text):
                guard case .object(let json) = try? LuxoValue.decodeJSONData(Data(text.utf8)), json["$sub"] != nil,
                    let id = LuxoWebSocketProtocol.jsonRequestID(value: json["$id"])
                else { return }
                socket?.deliver(.success(.string("{\"$sub\":\(id),\"ok\":true}")))
            case .data(let data):
                var decoder = Decoder(data)
                guard decoder.readVarint() == 0x10 else { return }
                var encoder = Encoder()
                encoder.writeVarint(0x13)
                encoder.writeVarint(decoder.readVarint())
                socket?.deliver(.success(.data(encoder.data)))
            @unknown default: break
            }
        }
        return (transport, socket)
    }

    private func data(_ mode: TransportMode, _ id: UInt64, _ value: UInt8) -> URLSessionWebSocketTask.Message {
        mode == .json ? .string("{\"$stream\":\(id),\"data\":\(value)}") : .data(frame(0x12, id, Data([value])))
    }

    private func completion(_ mode: TransportMode, _ id: UInt64) -> URLSessionWebSocketTask.Message {
        mode == .json ? .string("{\"$end\":\(id),\"ok\":true}") : .data(frame(0x15, id))
    }

    private func failure(_ mode: TransportMode, _ id: UInt64, acknowledgement: Bool = false, code: Int64 = 409) throws
        -> URLSessionWebSocketTask.Message
    {
        let json = #"{"n":123456789012345678901234567890,"fraction":1.2345678901234567890123456789,"zero":-0}"#
        if mode == .json {
            return .string(
                "{\"$\(acknowledgement ? "sub" : "end")\":\(id),\"data\":\(json),\"error\":\"Rejected\",\"code\":\(code),\"message\":\"no\",\"traceId\":\"trace\",\"cause\":\"details\"}"
            )
        }
        var encoder = Encoder()
        encoder.writeVarint(1); encoder.writeSvarint(code)
        encoder.writeVarint(2); encoder.writeString("Rejected")
        encoder.writeVarint(3); encoder.writeString("no")
        encoder.writeVarint(4); encoder.writeString("trace")
        encoder.writeVarint(5); encoder.writeBytes(Data(json.utf8))
        encoder.writeVarint(6); encoder.writeString("details")
        encoder.writeEnd()
        return .data(frame(acknowledgement ? 0x14 : 0x16, id, encoder.data))
    }

    private func frame(_ type: UInt64, _ id: UInt64, _ payload: Data = Data()) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(type); encoder.writeVarint(id); encoder.writeRawBytes(payload)
        return encoder.data
    }
}

private final class TerminalValues: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []
    private var failures: [LuxoError] = []
    private var completions = 0
    private var counts: [Int] = []
    var rows: [Data] { lock.withLock { data } }
    var errors: [LuxoError] { lock.withLock { failures } }
    var completed: Int { lock.withLock { completions } }
    var terminalRowCounts: [Int] { lock.withLock { counts } }
    func append(_ value: Data) { lock.withLock { data.append(value) } }
    var observer: StreamObserver {
        StreamObserver(
            onComplete: {
                self.lock.withLock {
                    self.completions += 1; self.counts.append(self.data.count)
                }
            },
            onError: { error in
                self.lock.withLock {
                    self.failures.append(error); self.counts.append(self.data.count)
                }
            })
    }
}
