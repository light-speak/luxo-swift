import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import LuxoNIO

final class OperationTests: XCTestCase {
    func testResponseFailureClosesOnlyItsStreamAndReleasesOnce() throws {
        let loop = EmbeddedEventLoop()
        let failed = EmbeddedChannel(loop: loop)
        let healthy = EmbeddedChannel(loop: loop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        try failed.connect(to: address).wait()
        try healthy.connect(to: address).wait()
        let failure = loop.makePromise(of: NIOResponse.self)
        let success = loop.makePromise(of: NIOResponse.self)
        var releases = [0, 0]
        let first = RequestOperation(promise: failure, maximum: 4, release: { releases[0] += 1 })
        let second = RequestOperation(promise: success, maximum: 4, release: { releases[1] += 1 })
        try failed.pipeline.syncOperations.addHandler(first.collector)
        try healthy.pipeline.syncOperations.addHandler(second.collector)
        first.arm(timeout: .seconds(30))
        second.arm(timeout: .seconds(30))
        first.attach(failed, path: "/", authority: "localhost", body: Data(), headers: HTTPHeaders())
        second.attach(healthy, path: "/", authority: "localhost", body: Data(), headers: HTTPHeaders())
        try failed.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok)))
        try failed.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [1, 2, 3, 4, 5])))
        XCTAssertThrowsError(try failure.futureResult.wait()) { error in
            guard case ResponseFailure.tooLarge = error else { return XCTFail("unexpected error: \(error)") }
        }
        loop.run()
        XCTAssertEqual(releases, [1, 0])
        XCTAssertFalse(failed.isActive)
        XCTAssertTrue(healthy.isActive)
        try healthy.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok)))
        try healthy.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [42])))
        try healthy.writeInbound(HTTPClientResponsePart.end(nil))
        XCTAssertEqual(try success.futureResult.wait().body, Data([42]))
        first.cancel(CancellationError())
        loop.advanceTime(by: .seconds(30))
        XCTAssertEqual(releases[0], 1)
        _ = try failed.finish(acceptAlreadyClosed: true)
        _ = try healthy.finish(acceptAlreadyClosed: true)
        XCTAssertEqual(releases, [1, 1])
    }

    func testSuccessfulResponseDoesNotActivelyCancelStream() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
        var released = 0
        let operation = RequestOperation(promise: promise, maximum: 4, release: { released += 1 })
        try channel.pipeline.syncOperations.addHandler(operation.collector)
        operation.arm(timeout: .seconds(30))
        operation.attach(channel, path: "/", authority: "localhost", body: Data(), headers: HTTPHeaders())
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok)))
        try channel.writeInbound(HTTPClientResponsePart.end(nil))
        _ = try promise.futureResult.wait()
        XCTAssertTrue(channel.isActive, "Successful END_STREAM must be left to the HTTP/2 multiplexer")
        XCTAssertEqual(released, 0)
        _ = try channel.finish(acceptAlreadyClosed: true)
        XCTAssertEqual(released, 1)
    }

    func testCancelledBeforeStreamCreationClosesLateStream() throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOResponse.self)
        var released = 0
        let operation = RequestOperation(promise: promise, maximum: 4, release: { released += 1 })
        operation.arm(timeout: .seconds(30))
        operation.cancel(CancellationError())
        XCTAssertThrowsError(try promise.futureResult.wait())
        XCTAssertEqual(released, 0)
        let channel = EmbeddedChannel(loop: loop)
        operation.attach(channel, path: "/", authority: "localhost", body: Data(), headers: HTTPHeaders())
        loop.run()
        XCTAssertEqual(released, 1)
        XCTAssertFalse(channel.isActive)
        XCTAssertNil(try channel.readOutbound(as: NIOAny.self))
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    func testDeadlineAndCreationFailureReleaseOnce() throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOResponse.self)
        var released = 0
        let operation = RequestOperation(promise: promise, maximum: 4, release: { released += 1 })
        operation.arm(timeout: .milliseconds(1))
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertThrowsError(try promise.futureResult.wait())
        operation.creationFailed(ResponseFailure.disconnected)
        operation.creationFailed(ResponseFailure.disconnected)
        XCTAssertEqual(released, 1)
    }
}
