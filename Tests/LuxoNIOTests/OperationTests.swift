import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import LuxoNIO

final class OperationTests: XCTestCase {
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
