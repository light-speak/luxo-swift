import NIOHTTP1
import NIOCore
import NIOEmbedded
import NIOTLS
import XCTest
@testable import LuxoNIO

final class TLSReadinessTests: XCTestCase {
    func testOnlyHTTP2NegotiationSucceeds() throws {
        for negotiated in ["h2", "http/1.1", nil] as [String?] {
            let channel = EmbeddedChannel()
            let ready = channel.eventLoop.makePromise(of: Void.self)
            try channel.pipeline.syncOperations.addHandler(TLSReadiness(promise: ready))
            channel.pipeline.fireUserInboundEventTriggered(
                TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiated))
            if negotiated == "h2" {
                XCTAssertNoThrow(try ready.futureResult.wait())
            } else {
                XCTAssertThrowsError(try ready.futureResult.wait())
            }
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
    }

    func testPipelineIsConfiguredOnlyAfterVerifiedHTTP2() throws {
        for negotiated in ["h2", "http/1.1", "unexpected", nil] as [String?] {
            let channel = EmbeddedChannel()
            let ready = channel.eventLoop.makePromise(of: Void.self)
            var configured = 0
            try channel.pipeline.syncOperations.addHandler(
                TLSReadiness(promise: ready) {
                    configured += 1
                    return channel.eventLoop.makeSucceededVoidFuture()
                })
            XCTAssertEqual(configured, 0)
            channel.pipeline.fireUserInboundEventTriggered(
                TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiated))
            XCTAssertEqual(configured, negotiated == "h2" ? 1 : 0)
            if negotiated == "h2" {
                XCTAssertNoThrow(try ready.futureResult.wait())
            } else {
                XCTAssertThrowsError(try ready.futureResult.wait())
            }
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
    }

    func testDisconnectBeforeHandshakeFails() throws {
        let channel = EmbeddedChannel()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.syncOperations.addHandler(TLSReadiness(promise: ready))
        try channel.close().wait()
        XCTAssertThrowsError(try ready.futureResult.wait())
        _ = try channel.finish(acceptAlreadyClosed: true)
    }
}
